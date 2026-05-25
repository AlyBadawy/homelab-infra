#!/bin/bash

################################################################################
# Debug ArgoCD Environment Variables and CMP Plugin
# Verifies that NAS variables are available to the repo-server and can be
# substituted by the kustomize-envsubst CMP plugin
################################################################################

set -e

ARGOCD_NS="argocd"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

echo "════════════════════════════════════════════════════════════════"
echo "ArgoCD Environment Variable Debugging"
echo "════════════════════════════════════════════════════════════════"
echo ""

# 1. Check if repo-server deployment exists
echo "1️⃣ Checking argocd-repo-server deployment..."
if kubectl get deployment argocd-repo-server -n "$ARGOCD_NS" &>/dev/null; then
    echo "   ✓ Deployment found"
else
    echo "   ✗ Deployment not found!"
    exit 1
fi
echo ""

# 2. Show environment variables in the deployment
echo "2️⃣ Environment variables in argocd-repo-server deployment:"
kubectl get deployment argocd-repo-server -n "$ARGOCD_NS" \
    -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' \
    | tr ' ' '\n' | grep -E '(NAS|GITHUB)' || echo "   ⚠ No NAS variables found in deployment spec!"
echo ""

# 3. Check the actual running pod
echo "3️⃣ Getting argocd-repo-server pod..."
POD=$(kubectl get pod -n "$ARGOCD_NS" -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$POD" ]; then
    echo "   ✗ No running pod found!"
    exit 1
fi

echo "   Pod: $POD"
echo ""

# 4. Show environment variables in the running pod
echo "4️⃣ Environment variables in running pod:"
kubectl exec -n "$ARGOCD_NS" "$POD" -- env | grep -E '(NAS|GITHUB)' || echo "   ⚠ No NAS variables found in running pod!"
echo ""

# 5. Check cluster-vars ConfigMap
echo "5️⃣ Checking cluster-vars ConfigMap in argocd namespace:"
if kubectl get configmap cluster-vars -n "$ARGOCD_NS" &>/dev/null; then
    echo "   ✓ ConfigMap found"
    echo ""
    echo "   NAS_IMMICH_DATA: $(kubectl get configmap cluster-vars -n "$ARGOCD_NS" -o jsonpath='{.data.NAS_IMMICH_DATA}' || echo 'NOT SET')"
    echo "   NAS_NEXTCLOUD_DATA: $(kubectl get configmap cluster-vars -n "$ARGOCD_NS" -o jsonpath='{.data.NAS_NEXTCLOUD_DATA}' || echo 'NOT SET')"
    echo "   NAS_BACKUPS_DIR: $(kubectl get configmap cluster-vars -n "$ARGOCD_NS" -o jsonpath='{.data.NAS_BACKUPS_DIR}' || echo 'NOT SET')"
else
    echo "   ✗ ConfigMap not found! Run: ansible-playbook -i ansible/inventory.ini ansible/apply-secrets.yml"
fi
echo ""

# 6. Check CMP plugin
echo "6️⃣ Checking CMP plugin ConfigMap:"
if kubectl get configmap argocd-cmp-kustomize-envsubst -n "$ARGOCD_NS" &>/dev/null; then
    echo "   ✓ CMP plugin ConfigMap found"
else
    echo "   ✗ CMP plugin not found!"
fi
echo ""

# 7. Force application re-sync
echo "7️⃣ To force re-sync of applications with new variables:"
echo ""
echo "   Option A: Restart repo-server pod (causes brief sync interruption):"
echo "   kubectl rollout restart deployment/argocd-repo-server -n argocd"
echo ""
echo "   Option B: Force sync specific application:"
echo "   argocd app sync immich --refresh"
echo "   argocd app sync cloud --refresh"
echo ""
echo "   Option C: Patch and manually refresh all applications:"
echo "   kubectl get application -n argocd -o name | xargs -I {} kubectl patch {} -n argocd -p '{\"spec\":{\"syncPolicy\":{\"automated\":null}}}' --type merge"
echo ""

echo "════════════════════════════════════════════════════════════════"
echo "If NAS variables are missing from deployment/pod:"
echo "  1. Run: ansible-playbook -i ansible/inventory.ini ansible/argocd-bootstrap.yml"
echo "  2. Verify patch succeeded"
echo "  3. Restart pod: kubectl rollout restart deployment/argocd-repo-server -n argocd"
echo "  4. Force re-sync: kubectl get applications -n argocd -o name | xargs -I {} kubectl patch {} -n argocd -p '{\"metadata\":{\"annotations\":{\"argocd.argoproj.io/refresh\":\"normal\"}}}' --type merge"
echo "════════════════════════════════════════════════════════════════"
