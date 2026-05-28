# Testing the Secrets Extraction

## What the Output File Looks Like

The script produces clean YAML documents separated by `---`:

```yaml
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

apiVersion: v1
kind: Secret
metadata:
  name: nextcloud-secret
  namespace: cloud
  labels:
    app: nextcloud
type: Opaque
data:
  DB_NAME: bmV4dGNsb3VkX2Ri  # base64-encoded
  DB_USER: bmV4dGNsb3VkX3VzZXI=  # base64-encoded
  DB_PASS: c29tZXBhc3N3b3Jk  # base64-encoded
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-vars
  namespace: argocd
data:
  DOMAIN: in.alybadawy.com
  GITHUB_REPO: https://github.com/user/repo
  TIMEZONE: America/Los_Angeles
---
apiVersion: v1
kind: Secret
metadata:
  name: wildcard-tls
  namespace: argocd
  labels:
    cert-type: wildcard
type: kubernetes.io/tls
data:
  tls.crt: LS0tLS1CRUdJTi... # base64-encoded certificate
  tls.key: LS0tLS1CRUdJTi... # base64-encoded key
```

## Testing Before Running

### 1. Check if kubectl is available

```bash
which kubectl
kubectl version --short
```

### 2. Check if you have cluster access

```bash
kubectl get nodes
kubectl get namespaces
```

### 3. Check if secrets exist

```bash
# See all secrets
kubectl get secrets --all-namespaces

# Count secrets
kubectl get secrets --all-namespaces | wc -l

# See secrets in specific namespace
kubectl get secrets -n cloud
kubectl get secrets -n db
```

### 4. Run extraction

```bash
cd /path/to/homelab-infra

# Choose one:
./extract-live-secrets.sh
# OR
python3 extract-live-secrets.py
```

### 5. Check output file

```bash
# List it
ls -lh secrets-live-backup-*.yaml

# View first 50 lines
head -50 secrets-live-backup-20260528-120000.yaml

# Count how many documents (each secret/configmap is one)
grep -c "^---" secrets-live-backup-20260528-120000.yaml

# Count secrets and configmaps
grep "kind: Secret" secrets-live-backup-20260528-120000.yaml | wc -l
grep "kind: ConfigMap" secrets-live-backup-20260528-120000.yaml | wc -l
```

### 6. Validate the YAML

```bash
# Dry-run (don't actually apply, just validate)
kubectl apply -f secrets-live-backup-20260528-120000.yaml --dry-run=client

# If you see "resource(s) would be created", it's valid!
```

## Troubleshooting

### "error: error validating YAML"

The script should produce valid YAML. If you get errors:

```bash
# Check YAML syntax
python3 -m yaml secrets-live-backup-20260528-120000.yaml

# Or use yamllint if available
yamllint secrets-live-backup-20260528-120000.yaml
```

### "no secrets found"

```bash
# Verify secrets actually exist
kubectl get secrets --all-namespaces

# If none, check if namespace has secrets
kubectl get secrets -n <namespace>
```

### "connection refused"

```bash
# Check kubeconfig
echo $KUBECONFIG
cat /etc/rancher/k3s/k3s.yaml

# Try with explicit kubeconfig
python3 extract-live-secrets.py /etc/rancher/k3s/k3s.yaml
```

## Restoring for Testing

### 1. Create a test namespace

```bash
kubectl create namespace test-restore
```

### 2. Apply only specific secrets

```bash
# Create a test file with just one secret
head -100 secrets-live-backup-20260528-120000.yaml > test-one-secret.yaml

# Apply to test namespace
kubectl apply -f test-one-secret.yaml
```

### 3. Verify restoration

```bash
# Check if secret was created
kubectl get secrets -n cloud

# Check secret details
kubectl get secret nextcloud-secret -n cloud -o yaml

# Try decoding a value
kubectl get secret nextcloud-secret -n cloud -o jsonpath='{.data.DB_NAME}' | base64 -d
```

### 4. If it works, use the full backup

```bash
# Apply full backup
kubectl apply -f secrets-live-backup-20260528-120000.yaml

# Verify all secrets
kubectl get secrets --all-namespaces
```

## File Format Verification

### Check structure

```bash
# Should see alternating metadata and data sections
cat secrets-live-backup-20260528-120000.yaml | grep -E "^(apiVersion|kind|metadata|data):" | head -20
```

### Check for common issues

```bash
# No stray spaces/tabs
grep "^  $" secrets-live-backup-20260528-120000.yaml  # Should be empty

# Proper indentation
python3 << 'EOF'
import yaml
with open("secrets-live-backup-20260528-120000.yaml") as f:
    docs = yaml.safe_load_all(f)
    count = 0
    for doc in docs:
        if doc:
            count += 1
            print(f"Doc {count}: {doc.get('kind')} - {doc['metadata']['name']}")
print(f"\nTotal: {count} documents")
EOF
```

## Performance Notes

File sizes:
- 1-5 MB: Normal for most setups
- 5-10 MB: Large cluster with many secrets
- 10+ MB: Very large cluster, consider splitting

If large:
```bash
# Check size
du -h secrets-live-backup-*.yaml

# Split into smaller files if needed
split -l 100 secrets-live-backup-20260528-120000.yaml secrets-

# Apply each part
for f in secrets-*; do kubectl apply -f "$f"; done
```

## Security Verification

```bash
# Make sure file is readable only by you
ls -la secrets-live-backup-*.yaml
chmod 600 secrets-live-backup-*.yaml

# Verify no unencrypted files are in git
git status | grep secrets

# If encrypted with GPG, verify
file secrets-live-backup-*.yaml.gpg
```

## Summary Checklist

Before running on your homelab:
- [ ] kubectl is installed: `which kubectl`
- [ ] kubeconfig exists: `cat /etc/rancher/k3s/k3s.yaml`
- [ ] Can connect to cluster: `kubectl get nodes`
- [ ] Secrets exist: `kubectl get secrets --all-namespaces`
- [ ] Extract scripts are executable: `ls -l extract-live-secrets.*`
- [ ] You have disk space for backup

When extraction completes:
- [ ] Output file created: `secrets-live-backup-*.yaml`
- [ ] File size reasonable: `du -h secrets-live-backup-*.yaml`
- [ ] Can validate: `kubectl apply -f secrets-live-backup-*.yaml --dry-run=client`
- [ ] Can encrypt: `gpg --encrypt ...`
- [ ] Can store: `/mnt/nas/backups/`

Ready to restore:
- [ ] New cluster has namespaces created
- [ ] Can apply file: `kubectl apply -f secrets-live-backup-*.yaml`
- [ ] All secrets present: `kubectl get secrets --all-namespaces`
- [ ] Application can use them: Check pod logs

## Help

If something goes wrong:

1. Check YAML validity:
   ```bash
   python3 -m yaml secrets-live-backup-*.yaml
   ```

2. Check extraction output:
   ```bash
   ./extract-live-secrets.sh 2>&1 | tee extraction.log
   ```

3. Check what was extracted:
   ```bash
   grep "kind:" secrets-live-backup-*.yaml | sort | uniq -c
   ```

4. Re-run extraction:
   ```bash
   rm secrets-live-backup-*.yaml
   ./extract-live-secrets.sh
   ```

Good luck! 🚀
