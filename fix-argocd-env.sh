#!/bin/bash

################################################################################
# Fix ArgoCD Environment Variables and Force Re-sync
# Patches argocd-repo-server with NAS variables and restarts
################################################################################

set -e

ARGOCD_NS="argocd"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

echo "════════════════════════════════════════════════════════════════"
echo "Fixing ArgoCD Environment Variables"
echo "════════════════════════════════════════════════════════════════"
echo ""

# 1. Get values from cluster-vars ConfigMap
echo "1️⃣ Reading NAS variables from cluster-vars ConfigMap..."
NAS_IMMICH_DATA=$(kubectl get configmap cluster-vars -n "$ARGOCD_NS" -o jsonpath='{.data.NAS_IMMICH_DATA}' 2>/dev/null || echo "")
NAS_NEXTCLOUD_DATA=$(kubectl get configmap cluster-vars -n "$ARGOCD_NS" -o jsonpath='{.data.NAS_NEXTCLOUD_DATA}' 2>/dev/null || echo "")
NAS_BACKUPS_DIR=$(kubectl get configmap cluster-vars -n "$ARGOCD_NS" -o jsonpath='{.data.NAS_BACKUPS_DIR}' 2>/dev/null || echo "")

if [ -z "$NAS_IMMICH_DATA" ] || [ -z "$NAS_NEXTCLOUD_DATA" ] || [ -z "$NAS_BACKUPS_DIR" ]; then
    echo "   ✗ Error: Some NAS variables are missing from cluster-vars ConfigMap"
    echo "   Please run: ansible-playbook -i ansible/inventory.ini ansible/apply-secrets.yml"
    exit 1
fi

echo "   ✓ NAS_IMMICH_DATA=$NAS_IMMICH_DATA"
echo "   ✓ NAS_NEXTCLOUD_DATA=$NAS_NEXTCLOUD_DATA"
echo "   ✓ NAS_BACKUPS_DIR=$NAS_BACKUPS_DIR"
echo ""

# 2. Patch argocd-repo-server deployment
echo "2️⃣ Patching argocd-repo-server deployment with environment variables..."
kubectl patch deployment argocd-repo-server -n "$ARGOCD_NS" \
  --type='json' \
  -p="[
    {
      \"op\": \"add\",
      \"path\": \"/spec/template/spec/containers/0/env/-\",
      \"value\": {
        \"name\": \"NAS_IMMICH_DATA\",
        \"value\": \"$NAS_IMMICH_DATA\"
      }
    },
    {
      \"op\": \"add\",
      \"path\": \"/spec/template/spec/containers/0/env/-\",
      \"value\": {
        \"name\": \"NAS_NEXTCLOUD_DATA\",
        \"value\": \"$NAS_NEXTCLOUD_DATA\"
      }
    },
    {
      \"op\": \"add\",
      \"path\": \"/spec/template/spec/containers/0/env/-\",
      \"value\": {
        \"name\": \"NAS_BACKUPS_DIR\",
        \"value\": \"$NAS_BACKUPS_DIR\"
      }
    }
  ]" 2>/dev/null && echo "   ✓ Deployment patched" || echo "   ⚠ Patch may have already been applied"
echo ""

# 3. Wait for repo-server to rollout
echo "3️⃣ Waiting for argocd-repo-server to restart (this may take 30-60 seconds)..."
kubectl rollout status deployment/argocd-repo-server -n "$ARGOCD_NS" --timeout=5m
echo "   ✓ Deployment rolled out"
echo ""

# 4. Verify variables are in the pod
echo "4️⃣ Verifying environment variables in pod..."
POD=$(kubectl get pod -n "$ARGOCD_NS" -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].metadata.name}')
IMMICH_CHECK=$(kubectl exec -n "$ARGOCD_NS" "$POD" -- env | grep NAS_IMMICH_DATA || echo "NOT FOUND")

if [[ "$IMMICH_CHECK" == *"$NAS_IMMICH_DATA"* ]]; then
    echo "   ✓ Variables confirmed in pod"
else
    echo "   ✗ Variables not found in pod! Something went wrong."
    exit 1
fi
echo ""

# 5. Force applications to re-sync
echo "5️⃣ Forcing applications to re-sync..."
kubectl get application -n "$ARGOCD_NS" -o name | while read app; do
    echo "   Refreshing $app..."
    kubectl patch "$app" -n "$ARGOCD_NS" \
        -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"normal"}}}' \
        --type merge
done
echo "   ✓ All applications marked for refresh"
echo ""

echo "════════════════════════════════════════════════════════════════"
echo "✓ Fixed! ArgoCD environment variables are now configured."
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "Monitor the re-sync:"
echo "  watch kubectl get applications -n argocd"
echo ""
echo "Check specific application status:"
echo "  kubectl get application immich -n argocd -o wide"
echo "  kubectl get application cloud -n argocd -o wide"
echo ""
echo "If applications are still OutOfSync after 2-3 minutes:"
echo "  - Check ArgoCD logs: kubectl logs -f deployment/argocd-repo-server -n argocd"
echo "  - Check application details: kubectl describe application immich -n argocd"
echo ""
