#!/bin/bash

################################################################################
# Extract ALL Live Secrets from Kubernetes Cluster
#
# This script exports all secrets currently stored in your cluster,
# including those created manually via kubectl commands.
#
# RUN THIS ON YOUR HOMELAB SERVER:
#   ssh homelab@172.20.20.3
#   cd /path/to/homelab-infra
#   ./extract-live-secrets.sh
#
# Output: secrets-live-backup-TIMESTAMP.yaml
################################################################################

set -e

KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_FILE="secrets-live-backup-${TIMESTAMP}.yaml"
TEMP_DIR=$(mktemp -d)

trap "rm -rf $TEMP_DIR" EXIT

echo "╔══════════════════════════════════════════════════════════════════════════════╗"
echo "║         Extracting ALL Live Secrets from Kubernetes Cluster                  ║"
echo "╚══════════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "Using kubeconfig: $KUBECONFIG"
echo "Output file: $OUTPUT_FILE"
echo ""

# Check kubeconfig exists
if [ ! -f "$KUBECONFIG" ]; then
    echo "❌ ERROR: kubeconfig not found at $KUBECONFIG"
    exit 1
fi

# Check kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "❌ ERROR: kubectl not found. Install kubectl first."
    exit 1
fi

# Export KUBECONFIG for all kubectl commands
export KUBECONFIG

# Get list of all namespaces
echo "🔍 Discovering namespaces..."
NAMESPACES=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}')
echo "Found namespaces: $NAMESPACES"
echo ""

# Initialize output file with header
cat > "$OUTPUT_FILE" << 'EOF'
################################################################################
# LIVE KUBERNETES SECRETS BACKUP
#
# This file contains ALL secrets currently stored in your Kubernetes cluster.
# These include:
#   - Manually created secrets (via kubectl)
#   - Secrets from bootstrapping
#   - Generated secrets (TLS certs, etc)
#   - All application secrets
#
# SECURITY: Store this file securely. It contains encoded secret values.
#
# RESTORE INSTRUCTIONS:
#   kubectl apply -f secrets-live-backup-TIMESTAMP.yaml
#
################################################################################

---
apiVersion: v1
kind: List
metadata:
  name: all-secrets-backup
  namespace: default
items:
EOF

# Counter for secrets found
TOTAL_SECRETS=0
TOTAL_CONFIGMAPS=0

# Extract secrets from each namespace
for namespace in $NAMESPACES; do
    echo "📦 Processing namespace: $namespace"

    # Get all secrets in this namespace
    SECRET_COUNT=$(kubectl get secrets -n "$namespace" --no-headers 2>/dev/null | wc -l)
    if [ "$SECRET_COUNT" -gt 0 ]; then
        echo "  ✓ Found $SECRET_COUNT secret(s)"
        TOTAL_SECRETS=$((TOTAL_SECRETS + SECRET_COUNT))

        # Export each secret
        kubectl get secrets -n "$namespace" -o yaml 2>/dev/null | \
            yq eval "
                .items[] |= (
                    .kind = \"Secret\" |
                    .apiVersion = \"v1\"
                )
            " >> "$OUTPUT_FILE" 2>/dev/null || \
            kubectl get secrets -n "$namespace" -o yaml >> "$OUTPUT_FILE"
    fi

    # Also get ConfigMaps (often contain configuration secrets)
    CONFIGMAP_COUNT=$(kubectl get configmaps -n "$namespace" --no-headers 2>/dev/null | wc -l)
    if [ "$CONFIGMAP_COUNT" -gt 0 ]; then
        echo "  ✓ Found $CONFIGMAP_COUNT ConfigMap(s)"
        TOTAL_CONFIGMAPS=$((TOTAL_CONFIGMAPS + CONFIGMAP_COUNT))

        kubectl get configmaps -n "$namespace" -o yaml 2>/dev/null >> "$OUTPUT_FILE"
    fi
done

echo ""
echo "✅ Extraction complete!"
echo ""
echo "Summary:"
echo "  📊 Total Secrets: $TOTAL_SECRETS"
echo "  📊 Total ConfigMaps: $TOTAL_CONFIGMAPS"
echo "  📄 Output file: $OUTPUT_FILE"
echo ""

# Verify file is valid YAML
if command -v yamllint &> /dev/null; then
    echo "🔍 Validating YAML..."
    if yamllint -d relaxed "$OUTPUT_FILE" > /dev/null 2>&1; then
        echo "✓ YAML is valid"
    else
        echo "⚠️  YAML validation warnings (might be okay)"
    fi
else
    echo "⚠️  yamllint not installed, skipping validation"
fi

echo ""
echo "📋 File size: $(du -h "$OUTPUT_FILE" | cut -f1)"
echo ""

# Show sample of what was exported
echo "📝 Sample content:"
echo "---"
head -30 "$OUTPUT_FILE" | tail -20
echo "..."
echo ""

echo "🔐 SECURITY NOTES:"
echo "  1. This file contains encoded secrets - handle with care"
echo "  2. Store securely (not in public repos)"
echo "  3. Consider encrypting before storing off-cluster:"
echo ""
echo "     # Encrypt the backup"
echo "     gpg --encrypt --recipient YOUR_EMAIL $OUTPUT_FILE"
echo ""
echo "     # Decrypt when needed"
echo "     gpg --decrypt $OUTPUT_FILE.gpg > $OUTPUT_FILE"
echo ""

echo "🔄 TO RESTORE TO A NEW CLUSTER:"
echo "  1. Ensure new cluster has all required namespaces"
echo "  2. Apply the backup:"
echo "     kubectl apply -f $OUTPUT_FILE"
echo "  3. Verify restoration:"
echo "     kubectl get secrets --all-namespaces"
echo ""

echo "📦 Next steps:"
echo "  1. Review the generated file for sensitive data"
echo "  2. Move to a secure location (NAS, backup system)"
echo "  3. Consider encrypting with GPG"
echo "  4. Test restore procedure in staging before production rebuild"
echo ""
