#!/bin/bash

################################################################################
# Homelab Fresh Install Script
# Runs all Ansible playbooks in the correct order for a clean infrastructure
# deployment using ArgoCD GitOps
################################################################################

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'  # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAYBOOKS_DIR="$SCRIPT_DIR/ansible"

################################################################################
# Functions
################################################################################

print_header() {
    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
}

print_step() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ Error: $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ Warning: $1${NC}"
}

run_playbook() {
    local playbook=$1
    local description=$2
    local extra_vars=$3

    echo ""
    print_header "Running: $description"
    echo "Playbook: $playbook"

    if [ -n "$extra_vars" ]; then
        echo "Variables: $extra_vars"
    fi

    read -p "Continue? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_warning "Skipped: $description"
        return 1
    fi

    if [ -n "$extra_vars" ]; then
        eval "ansible-playbook -i '$PLAYBOOKS_DIR/inventory.ini' '$PLAYBOOKS_DIR/$playbook' $extra_vars"
    else
        ansible-playbook -i "$PLAYBOOKS_DIR/inventory.ini" "$PLAYBOOKS_DIR/$playbook"
    fi

    if [ $? -eq 0 ]; then
        print_step "$description completed successfully"
        return 0
    else
        print_error "$description failed"
        return 1
    fi
}

check_requirements() {
    print_header "Checking Requirements"

    if ! command -v ansible-playbook &> /dev/null; then
        print_error "ansible-playbook not found. Install Ansible first."
        exit 1
    fi
    print_step "Ansible found"

    if ! command -v ssh &> /dev/null; then
        print_error "SSH not found"
        exit 1
    fi
    print_step "SSH found"

    if [ ! -f "$PLAYBOOKS_DIR/inventory.ini" ]; then
        print_error "inventory.ini not found at $PLAYBOOKS_DIR/inventory.ini"
        echo "Update the inventory file with your server details before running this script."
        exit 1
    fi
    print_step "inventory.ini found"

    # Check connectivity
    echo ""
    read -p "Test SSH connectivity to servers in inventory? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        ansible all -i "$PLAYBOOKS_DIR/inventory.ini" -m ping
        if [ $? -eq 0 ]; then
            print_step "SSH connectivity verified"
        else
            print_error "Cannot connect to servers. Check inventory.ini"
            exit 1
        fi
    fi
}

################################################################################
# Main Script
################################################################################

main() {
    print_header "Homelab Fresh Install - Automated Playbook Runner"
    echo ""
    echo "This script will run all Ansible playbooks in order:"
    echo "  1. bootstrap.yml"
    echo "  2. dependencies.yml"
    echo "  3. swap.yml"
    echo "  4. nfs-mounts.yml"
    echo "  5. k3s.yml"
    echo "  6. acme-cert.yml (TLS certificate via Vercel)"
    echo "  7. apply-secrets.yml"
    echo "  8. longhorn-bootstrap.yml (install Longhorn + create storage class)"
    echo "  9. pre-create-pvcs.yml (PVCs bind to longhorn storage class)"
    echo "  10. argocd-bootstrap.yml (ArgoCD takes over from here)"
    echo "  11. restore-longhorn-volumes.yml (optional)"
    echo ""

    # Get required variables
    echo -e "${YELLOW}Required Information:${NC}"
    echo ""

    read -p "Enter your Vercel API token: " VERCEL_TOKEN
    if [ -z "$VERCEL_TOKEN" ]; then
        print_error "Vercel API token is required"
        exit 1
    fi

    read -p "Enter GitHub repository URL [https://github.com/AlyBadawy/homelab-infra]: " GITHUB_REPO
    GITHUB_REPO="${GITHUB_REPO:-https://github.com/AlyBadawy/homelab-infra}"

    read -p "Enter email for ACME certificate [admin@in.alybadawy.com]: " ACME_EMAIL
    ACME_EMAIL="${ACME_EMAIL:-admin@in.alybadawy.com}"

    echo ""
    print_header "Configuration Summary"
    echo "GitHub Repo: $GITHUB_REPO"
    echo "Vercel Token: ${VERCEL_TOKEN:0:10}***"
    echo "ACME Email: $ACME_EMAIL"
    echo ""

    read -p "Proceed with these settings? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_warning "Aborted by user"
        exit 0
    fi

    # Check requirements
    check_requirements

    # Track failed playbooks
    FAILED_PLAYBOOKS=()
    COMPLETED_PLAYBOOKS=()

    # Run playbooks
    echo ""
    print_header "Starting Playbook Execution"

    # 1. Bootstrap
    if run_playbook "bootstrap.yml" "System Bootstrap (apt update/upgrade)"; then
        COMPLETED_PLAYBOOKS+=("bootstrap.yml")
    else
        FAILED_PLAYBOOKS+=("bootstrap.yml")
    fi

    # 2. Dependencies
    if run_playbook "dependencies.yml" "System Dependencies"; then
        COMPLETED_PLAYBOOKS+=("dependencies.yml")
    else
        FAILED_PLAYBOOKS+=("dependencies.yml")
    fi

    # 3. Swap
    if run_playbook "swap.yml" "Swap File Configuration (12GB)"; then
        COMPLETED_PLAYBOOKS+=("swap.yml")
    else
        FAILED_PLAYBOOKS+=("swap.yml")
    fi

    # 4. NFS Mounts
    if run_playbook "nfs-mounts.yml" "NFS Mounts from NAS"; then
        COMPLETED_PLAYBOOKS+=("nfs-mounts.yml")
    else
        FAILED_PLAYBOOKS+=("nfs-mounts.yml")
    fi

    # 5. k3s
    if run_playbook "k3s.yml" "k3s Kubernetes + Helm"; then
        COMPLETED_PLAYBOOKS+=("k3s.yml")
    else
        FAILED_PLAYBOOKS+=("k3s.yml")
        print_error "k3s installation is required. Cannot continue."
        exit 1
    fi

    # 6. ACME Certificate
    if run_playbook "acme-cert.yml" "TLS Certificate via Vercel" "-e vercel_api_token=$VERCEL_TOKEN -e acme_email=$ACME_EMAIL"; then
        COMPLETED_PLAYBOOKS+=("acme-cert.yml")
    else
        FAILED_PLAYBOOKS+=("acme-cert.yml")
        print_warning "TLS certificate generation failed. ingress-nginx may not have a default cert."
    fi

    # 7. Apply Secrets
    if run_playbook "apply-secrets.yml" "Kubernetes Secrets & Cluster Configuration" "-e github_repo='$GITHUB_REPO'"; then
        COMPLETED_PLAYBOOKS+=("apply-secrets.yml")
    else
        FAILED_PLAYBOOKS+=("apply-secrets.yml")
        print_error "Secrets configuration is required. Cannot continue."
        exit 1
    fi

    # 8. Longhorn Bootstrap (Install and validate before ArgoCD)
    if run_playbook "longhorn-bootstrap.yml" "Longhorn Bootstrap (Manual Helm Install & Validation)"; then
        COMPLETED_PLAYBOOKS+=("longhorn-bootstrap.yml")
    else
        FAILED_PLAYBOOKS+=("longhorn-bootstrap.yml")
        print_error "Longhorn bootstrap failed. Cannot proceed without working storage."
        exit 1
    fi

    # 9. Pre-create empty PVCs (fresh install mode)
    if run_playbook "pre-create-pvcs.yml" "Pre-create PVCs for Fresh Install"; then
        COMPLETED_PLAYBOOKS+=("pre-create-pvcs.yml")
    else
        FAILED_PLAYBOOKS+=("pre-create-pvcs.yml")
        print_warning "PVC pre-creation failed (optional, will retry on sync)"
    fi

    # 10. ArgoCD Bootstrap
    if run_playbook "argocd-bootstrap.yml" "ArgoCD Bootstrap (Deploy Root Application)"; then
        COMPLETED_PLAYBOOKS+=("argocd-bootstrap.yml")
    else
        FAILED_PLAYBOOKS+=("argocd-bootstrap.yml")
        print_error "ArgoCD bootstrap failed. GitOps deployment did not complete."
        exit 1
    fi

    # 11. Longhorn Restore (Optional)
    echo ""
    read -p "Restore Longhorn volumes from backups? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if run_playbook "restore-longhorn-volumes.yml" "Restore Longhorn Volumes from NAS Backups"; then
            COMPLETED_PLAYBOOKS+=("restore-longhorn-volumes.yml")
        else
            FAILED_PLAYBOOKS+=("restore-longhorn-volumes.yml")
            print_warning "Longhorn volume restoration failed (optional)"
        fi
    else
        print_step "Skipped Longhorn restore (optional)"
    fi

    # Summary
    echo ""
    print_header "Fresh Install Complete!"
    echo ""
    echo -e "${GREEN}Completed Playbooks (${#COMPLETED_PLAYBOOKS[@]}):${NC}"
    for playbook in "${COMPLETED_PLAYBOOKS[@]}"; do
        echo "  ✓ $playbook"
    done

    if [ ${#FAILED_PLAYBOOKS[@]} -gt 0 ]; then
        echo ""
        echo -e "${RED}Failed Playbooks (${#FAILED_PLAYBOOKS[@]}):${NC}"
        for playbook in "${FAILED_PLAYBOOKS[@]}"; do
            echo "  ✗ $playbook"
        done
        echo ""
        print_warning "Some playbooks failed. Review the output above."
    fi

    echo ""
    print_header "Next Steps"
    echo ""
    echo "1. Monitor ArgoCD deployment:"
    echo "   kubectl get applications -n argocd"
    echo ""
    echo "2. Access ArgoCD UI:"
    echo "   Add to your /etc/hosts: 172.20.20.3  argocd.in.alybadawy.com"
    echo "   Visit: https://argocd.in.alybadawy.com"
    echo ""
    echo "3. Get ArgoCD admin password:"
    echo "   kubectl get secret argocd-initial-admin-secret -n argocd \\"
    echo "     -o jsonpath='{.data.password}' | base64 -d; echo"
    echo ""
    echo "4. Monitor application sync:"
    echo "   kubectl get applications -n argocd -w"
    echo ""
    echo -e "${GREEN}Fresh install completed successfully!${NC}"
}

# Run main function
main "$@"
