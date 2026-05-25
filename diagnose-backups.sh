#!/bin/bash

################################################################################
# Longhorn Backup Restoration Diagnostic Script
# Run this on your homelab server to diagnose backup and restoration issues
################################################################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
}

print_section() {
    echo ""
    echo -e "${YELLOW}→ $1${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo "  $1"
}

################################################################################
# Main Diagnostics
################################################################################

print_header "Longhorn Backup Restoration Diagnostics"

# 1. Check Kubernetes access
print_section "1. Checking Kubernetes Access"
if kubectl cluster-info &> /dev/null; then
    print_success "Kubernetes cluster accessible"
else
    print_error "Cannot access Kubernetes cluster"
    echo "Make sure KUBECONFIG is set:"
    echo "  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml"
    exit 1
fi

# 2. Check Longhorn status
print_section "2. Checking Longhorn Installation"
if kubectl get namespace longhorn-system &> /dev/null; then
    print_success "Longhorn namespace exists"

    MANAGER_PODS=$(kubectl get pods -n longhorn-system -l app=longhorn-manager -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    if [ -n "$MANAGER_PODS" ]; then
        print_success "Longhorn manager pods running"
        for pod in $MANAGER_PODS; do
            print_info "  - $pod"
        done
    else
        print_error "No Longhorn manager pods found"
    fi
else
    print_error "Longhorn namespace not found"
    exit 1
fi

# 3. Check NAS mount
print_section "3. Checking NAS Mount Status"
if mount | grep -q "/mnt/nas"; then
    print_success "NAS mounted at /mnt/nas"
    mount | grep /mnt/nas | while read line; do
        print_info "$line"
    done
else
    print_error "NAS not mounted at /mnt/nas"
    echo "Mount NAS with:"
    echo "  ansible-playbook -i ansible/inventory.ini ansible/nfs-mounts.yml"
fi

# 4. Check NAS backup directory
print_section "4. Checking NAS Backup Directory Structure"
BACKUP_BASE="/mnt/nas/backups/k3s-longhorn"
if [ -d "$BACKUP_BASE" ]; then
    print_success "Backup directory exists: $BACKUP_BASE"

    if [ -d "$BACKUP_BASE/backupstore" ]; then
        print_info "  Found: backupstore/"

        if [ -d "$BACKUP_BASE/backupstore/volumes" ]; then
            print_info "  Found: backupstore/volumes/"
            VOLUME_COUNT=$(ls -1 "$BACKUP_BASE/backupstore/volumes" 2>/dev/null | wc -l)
            print_info "  Contains $VOLUME_COUNT volume backup(s)"

            if [ "$VOLUME_COUNT" -gt 0 ]; then
                ls -1 "$BACKUP_BASE/backupstore/volumes" | while read vol; do
                    print_info "    - $vol"
                done
            fi
        else
            print_error "  NOT FOUND: backupstore/volumes/"
        fi
    else
        print_error "  NOT FOUND: backupstore/"
    fi
else
    print_error "Backup directory NOT FOUND: $BACKUP_BASE"
    echo "Expected structure:"
    echo "  $BACKUP_BASE/backupstore/volumes/<volume-name>"
fi

# 5. Check Longhorn backup-target Setting
print_section "5. Checking Longhorn backup-target Setting"
BACKUP_TARGET=$(kubectl get setting backup-target -n longhorn-system -o jsonpath='{.value}' 2>/dev/null || echo "ERROR")

if [ "$BACKUP_TARGET" = "ERROR" ] || [ -z "$BACKUP_TARGET" ]; then
    print_error "Cannot retrieve backup-target Setting"
else
    if [[ "$BACKUP_TARGET" == *"/var/nfs/shared/backups"* ]]; then
        print_success "Backup-target points to correct path"
    else
        print_error "Backup-target may be pointing to wrong path:"
    fi
    print_info "Current value:"
    print_info "  $BACKUP_TARGET"

    print_info "Expected value:"
    print_info "  nfs://172.20.20.2:/var/nfs/shared/backups/k3s-longhorn?nfsOptions=nfsvers%3D3%2Cnolock"
fi

# 6. Check backup-target validation
print_section "6. Checking Backup Target Validation"
BACKUP_VALID=$(kubectl get setting backup-target-valid -n longhorn-system -o jsonpath='{.value}' 2>/dev/null || echo "unknown")
print_info "backup-target-valid: $BACKUP_VALID"

if [ "$BACKUP_VALID" = "true" ]; then
    print_success "Backup target is valid and accessible"
elif [ "$BACKUP_VALID" = "false" ]; then
    print_error "Backup target validation FAILED"
    echo "Check Longhorn manager logs:"
    echo "  kubectl logs -n longhorn-system -l app=longhorn-manager --tail=50"
else
    print_info "Validation status: $BACKUP_VALID (Longhorn may still be checking)"
fi

# 7. Check available backups (Longhorn API)
print_section "7. Checking Available Backups (via Longhorn API)"
AVAILABLE=$(kubectl get backups.longhorn.io -n longhorn-system 2>/dev/null || echo "ERROR")
if [ "$AVAILABLE" = "ERROR" ]; then
    print_error "Cannot query backups from Longhorn"
else
    # Parse and display backups
    BACKUP_COUNT=$(echo "$AVAILABLE" | grep -c "^[a-z]" || echo "0")
    if [ "$BACKUP_COUNT" -eq 0 ]; then
        print_error "No backups found via Longhorn API"
        echo "This could mean:"
        echo "  1. Backup-target Setting points to wrong path"
        echo "  2. NAS backup directory is inaccessible to Longhorn pods"
        echo "  3. Backup files exist but not in expected format"
    else
        print_success "Found $BACKUP_COUNT backup(s)"
        kubectl get backups.longhorn.io -n longhorn-system 2>/dev/null | tail -n +2 | while read line; do
            print_info "  $line"
        done
    fi
fi

# 8. Check Longhorn volumes
print_section "8. Checking Longhorn Volumes"
VOLUME_COUNT=$(kubectl get volumes.longhorn.io -n longhorn-system 2>/dev/null | wc -l)
if [ "$VOLUME_COUNT" -le 1 ]; then
    print_error "No Longhorn volumes found"
else
    print_success "Found $((VOLUME_COUNT - 1)) volume(s)"
    kubectl get volumes.longhorn.io -n longhorn-system 2>/dev/null | tail -n +2
fi

# 9. Check PersistentVolumeClaims
print_section "9. Checking PersistentVolumeClaims"
PVC_COUNT=$(kubectl get pvc -A 2>/dev/null | wc -l)
if [ "$PVC_COUNT" -le 1 ]; then
    print_error "No PVCs found"
else
    print_success "Found $((PVC_COUNT - 1)) PVC(s)"
    kubectl get pvc -A 2>/dev/null | grep -E "postgres|pgadmin|authentik|nextcloud|immich" || echo "(No matching PVCs found)"
fi

# 10. Recommendations
print_header "Recommendations"

if [ "$BACKUP_TARGET" != "ERROR" ] && [[ "$BACKUP_TARGET" == *"/var/nfs/shared/backups"* ]]; then
    print_success "Backup-target is correctly configured"
else
    print_error "Backup-target needs to be fixed"
    echo ""
    echo "Run this command to fix:"
    echo ""
    echo "kubectl patch setting backup-target -n longhorn-system \\"
    echo "  --type merge \\"
    echo "  -p '{\"value\":\"nfs://172.20.20.2:/var/nfs/shared/backups/k3s-longhorn?nfsOptions=nfsvers%3D3%2Cnolock\"}'"
    echo ""
fi

if [ "$BACKUP_VALID" = "false" ]; then
    echo "Check Longhorn manager logs for access issues:"
    echo "  kubectl logs -n longhorn-system -l app=longhorn-manager --tail=100 | grep -i 'backup\|error\|nfs'"
fi

print_header "Diagnostic Complete"
echo ""
echo "Next steps:"
echo "1. Review the diagnostics output above"
echo "2. If backup-target needs fixing, run the patch command"
echo "3. After fixing, you can restore backups manually:"
echo "   ansible-playbook -i ansible/inventory.ini ansible/longhorn-restore.yml"
echo ""
