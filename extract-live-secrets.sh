#!/bin/bash

################################################################################
# Extract ALL Live Secrets from Kubernetes Cluster
#
# Produces clean YAML that can be directly applied with: kubectl apply -f file.yaml
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
# LIVE KUBERNETES SECRETS & CONFIGMAPS BACKUP
#
# This file contains ALL secrets and configmaps currently stored in your cluster.
# It can be directly applied to a new cluster with:
#   kubectl apply -f secrets-live-backup-TIMESTAMP.yaml
#
# SECURITY: Store this file securely. It contains encoded secret values.
#
################################################################################

EOF

# Counter for secrets found
TOTAL_SECRETS=0
TOTAL_CONFIGMAPS=0

# Extract secrets from each namespace
for namespace in $NAMESPACES; do
    echo "📦 Processing namespace: $namespace"

    # Get all secrets in this namespace - export as separate documents
    SECRET_COUNT=$(kubectl get secrets -n "$namespace" --no-headers 2>/dev/null | wc -l)
    if [ "$SECRET_COUNT" -gt 0 ]; then
        echo "  ✓ Found $SECRET_COUNT secret(s)"
        TOTAL_SECRETS=$((TOTAL_SECRETS + SECRET_COUNT))

        # Get secret names and export each one
        kubectl get secrets -n "$namespace" -o name | while read secret; do
            secret_name=$(echo "$secret" | cut -d'/' -f2)
            # Skip kubernetes default secrets unless they have data we need
            if [[ "$secret_name" == "default-token-"* ]] || [[ "$secret_name" == "sh.helm.release"* ]]; then
                continue
            fi
            kubectl get "$secret" -n "$namespace" -o yaml >> "$OUTPUT_FILE"
            echo "---" >> "$OUTPUT_FILE"
        done
    fi

    # Get all configmaps in this namespace
    CM_COUNT=$(kubectl get configmaps -n "$namespace" --no-headers 2>/dev/null | wc -l)
    if [ "$CM_COUNT" -gt 0 ]; then
        echo "  ✓ Found $CM_COUNT ConfigMap(s)"
        TOTAL_CONFIGMAPS=$((TOTAL_CONFIGMAPS + CM_COUNT))

        # Get configmap names and export each one
        kubectl get configmaps -n "$namespace" -o name | while read cm; do
            kubectl get "$cm" -n "$namespace" -o yaml >> "$OUTPUT_FILE"
            echo "---" >> "$OUTPUT_FILE"
        done
    fi
done

# Remove trailing --- from end of file
sed -i '$d' "$OUTPUT_FILE"

echo ""
echo "✅ Extraction complete!"
echo ""
echo "Summary:"
echo "  📊 Total Secrets: $TOTAL_SECRETS"
echo "  📊 Total ConfigMaps: $TOTAL_CONFIGMAPS"
echo "  📄 Output file: $OUTPUT_FILE"
echo ""

# Validate file is proper YAML
echo "🔍 Validating YAML..."
if kubectl apply -f "$OUTPUT_FILE" --dry-run=client &>/dev/null; then
    echo "✓ YAML is valid and can be applied to cluster"
else
    echo "⚠️  Validation error - checking file..."
    head -50 "$OUTPUT_FILE"
fi
echo ""

echo "📋 File size: $(du -h "$OUTPUT_FILE" | cut -f1)"
echo ""

echo "🔐 SECURITY:"
echo "  Encrypt with GPG:"
echo "    gpg --encrypt --recipient your-email $OUTPUT_FILE"
echo ""

echo "🔄 TO RESTORE:"
echo "  kubectl apply -f $OUTPUT_FILE"
echo ""

echo "✨ Done! File is ready to use."
