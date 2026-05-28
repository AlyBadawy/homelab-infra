# Live Secrets Extraction Guide

**Purpose:** Extract all manually-created and configured secrets from your running Kubernetes cluster before rebuild.

---

## Why This Matters

You've added secrets to your cluster in multiple ways:
- Bootstrap secrets from `/mnt/nas/homelab/secrets.yaml` (one-time)
- Manually via `kubectl create secret` commands
- Automatically generated secrets (TLS certificates, tokens, etc.)
- ConfigMaps with sensitive configuration

All of these are stored in the running cluster and must be extracted before rebuild.

---

## Two Methods to Extract

### Method 1: Bash Script (Recommended)

**Requirements:**
- kubectl installed
- Access to your cluster
- Bash shell

**Steps:**

```bash
# SSH into your homelab server
ssh homelab@172.20.20.3

# Navigate to project directory
cd /path/to/homelab-infra

# Make script executable
chmod +x extract-live-secrets.sh

# Run extraction
./extract-live-secrets.sh
```

**Output:**
- `secrets-live-backup-YYYYMMDD-HHMMSS.yaml` - Complete backup file
- Screen output showing what was extracted

### Method 2: Python Script (More Portable)

**Requirements:**
- Python 3.6+
- kubectl installed
- PyYAML library

**Steps:**

```bash
# SSH into your homelab server
ssh homelab@172.20.20.3

# Navigate to project directory
cd /path/to/homelab-infra

# Make script executable
chmod +x extract-live-secrets.py

# Run extraction
python3 extract-live-secrets.py
```

Or with custom kubeconfig:

```bash
python3 extract-live-secrets.py /path/to/custom/kubeconfig
```

Or via environment variable:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
python3 extract-live-secrets.py
```

**Output:**
- `secrets-live-backup-YYYYMMDD-HHMMSS.yaml` - Complete backup file
- Detailed extraction report

---

## What Gets Extracted

### Secrets
All Kubernetes Secret objects from all namespaces:
- Database credentials
- API keys and tokens
- SSH keys
- TLS certificates and keys
- Docker registry credentials
- Any manual secrets

### ConfigMaps
All ConfigMap objects (often contain configuration secrets):
- Application configuration
- Scripts and certificates
- Environment-specific settings

### All Namespaces
Nothing is skipped:
- `argocd` - ArgoCD and cluster-vars
- `db` - Database credentials
- `auth` - Authentication secrets
- `cloud` - Nextcloud credentials
- `immich` - Immich API keys
- `monitor` - Monitoring credentials
- `backup` - Backup scripts and configuration
- `kube-system` - System secrets
- Any custom namespaces

---

## Understanding the Output File

### File Structure

```yaml
apiVersion: v1
kind: List
metadata:
  name: all-secrets-configmaps-backup
items:
  - apiVersion: v1
    kind: Secret
    metadata:
      name: nextcloud-secret
      namespace: cloud
    type: Opaque
    data:
      DB_NAME: <base64-encoded>
      DB_USER: <base64-encoded>
      DB_PASS: <base64-encoded>
  
  - apiVersion: v1
    kind: ConfigMap
    metadata:
      name: cluster-vars
      namespace: argocd
    data:
      DOMAIN: in.alybadawy.com
      # ... more keys
```

### Secret Values
- Values are **base64-encoded**, not encrypted
- Base64 encoding is reversible (anyone with access can decode)
- Store file securely
- Consider encrypting with GPG before storing off-cluster

---

## Secure Storage

### Option 1: Encrypt with GPG

```bash
# Encrypt (ask for passphrase)
gpg --encrypt --recipient your-email@example.com \
    secrets-live-backup-20260528-120000.yaml

# This creates secrets-live-backup-20260528-120000.yaml.gpg
# You can safely store the .gpg file

# Decrypt when needed (ask for passphrase)
gpg --decrypt secrets-live-backup-20260528-120000.yaml.gpg \
    > secrets-live-backup-20260528-120000.yaml
```

### Option 2: Store on Encrypted NAS

```bash
# Move backup to NAS backups directory
cp secrets-live-backup-*.yaml /mnt/nas/backups/

# Ensure NAS filesystem is encrypted
# Verify only you have read access:
ls -la /mnt/nas/backups/secrets-live-backup-*.yaml
```

### Option 3: Use git-crypt

If you use git-crypt for your repo:

```bash
# Add to .gitattributes
echo "secrets-live-backup-*.yaml filter=git-crypt diff=git-crypt" >> .gitattributes

# Commit the backup (will be encrypted in git)
git add secrets-live-backup-*.yaml .gitattributes
git commit -m "Add live secrets backup"
git push
```

---

## Restoring Secrets

### Prerequisites

```bash
# Ensure namespaces exist
kubectl get namespaces

# If missing, create them
kubectl create namespace argocd
kubectl create namespace db
kubectl create namespace cloud
# ... etc
```

### Apply Backup

```bash
# Simple restore (will overwrite existing secrets)
kubectl apply -f secrets-live-backup-20260528-120000.yaml

# Verify restoration
kubectl get secrets --all-namespaces
kubectl get configmaps --all-namespaces

# Check specific namespace
kubectl get secrets -n cloud
kubectl get secret nextcloud-secret -n cloud -o yaml
```

### Restore with Dry-Run First

```bash
# Preview what will be applied
kubectl apply -f secrets-live-backup-20260528-120000.yaml --dry-run=client

# If it looks good, apply for real
kubectl apply -f secrets-live-backup-20260528-120000.yaml
```

### Restore to Different Cluster

If restoring to a new cluster:

```bash
# 1. Create all required namespaces
kubectl create namespace argocd
kubectl create namespace db
kubectl create namespace cloud
# ... all other namespaces

# 2. Apply the backup
kubectl apply -f secrets-live-backup-20260528-120000.yaml

# 3. Verify all secrets are present
kubectl get secrets --all-namespaces
kubectl get configmaps --all-namespaces

# 4. Check if applications can access them
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace>
```

---

## Before System Rebuild Checklist

- [ ] Run extraction script on your homelab server
- [ ] Verify output file was created with content
- [ ] Review the file for what will be backed up
- [ ] Encrypt the backup (GPG or git-crypt recommended)
- [ ] Move to secure storage (NAS, external drive)
- [ ] Test restoration in staging cluster (if possible)
- [ ] Document any secrets not captured by the script
- [ ] Commit backup file to git (if encrypted)
- [ ] Keep extraction scripts in repo for future use

---

## Troubleshooting

### "kubectl not found"

```bash
# Install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/

# Or via package manager
sudo apt install -y kubectl  # Ubuntu/Debian
```

### "connection refused" or "No such file or directory" for kubeconfig

```bash
# Check kubeconfig path
echo $KUBECONFIG
cat /etc/rancher/k3s/k3s.yaml

# Set custom path
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
python3 extract-live-secrets.py

# Or pass as argument
python3 extract-live-secrets.py /path/to/kubeconfig
```

### "Error: secrets not found"

```bash
# Verify you have permission to read secrets
kubectl auth can-i get secrets --all-namespaces

# If permission denied, use sudo
sudo python3 extract-live-secrets.py

# Or check if KUBECONFIG requires sudo
sudo cat $KUBECONFIG
```

### Script runs but extracts few/no secrets

```bash
# Verify secrets actually exist
kubectl get secrets --all-namespaces

# Check specific namespace
kubectl get secrets -n cloud

# If you see secrets in kubectl but not in script,
# check script output for errors
python3 extract-live-secrets.py 2>&1 | tee extraction.log
```

---

## Advanced Usage

### Extract Only Specific Namespace

Edit the script to filter:

```python
# In extract-live-secrets.py, replace:
# namespaces = self.get_namespaces()

# With:
namespaces = ["cloud", "db", "auth"]  # Only these namespaces
```

### Export in Different Format

Convert YAML to JSON:

```bash
# Python
python3 << 'EOF'
import yaml
import json

with open("secrets-live-backup-20260528-120000.yaml") as f:
    data = yaml.safe_load(f)

with open("secrets-live-backup-20260528-120000.json", "w") as f:
    json.dump(data, f, indent=2)
EOF

# Or with yq
yq -P -o json secrets-live-backup-20260528-120000.yaml > secrets-live-backup-20260528-120000.json
```

### Extract Individual Secrets

```bash
# Export one secret
kubectl get secret nextcloud-secret -n cloud -o yaml > nextcloud-secret.yaml

# Export all secrets in a namespace
kubectl get secrets -n cloud -o yaml > cloud-secrets.yaml

# Export all secrets (like our script does)
kubectl get secrets --all-namespaces -o yaml > all-secrets.yaml
```

---

## Security Best Practices

1. **Never store unencrypted in public repos**
   - Use git-crypt or GPG encryption
   - Add to .gitignore if not encrypted

2. **Use strong file permissions**
   ```bash
   chmod 600 secrets-live-backup-*.yaml
   ls -la secrets-live-backup-*.yaml  # Verify only you can read
   ```

3. **Rotate secrets periodically**
   - Extract fresh backup before rebuild
   - Don't reuse old backups

4. **Test in staging**
   - Restore to a test cluster first
   - Verify applications work with restored secrets

5. **Keep multiple copies**
   - Local backup on NAS
   - External drive (off-site)
   - Encrypted in git (if using git-crypt)

---

## Recovery Scenarios

### Scenario 1: Cluster is corrupted, need to restore secrets

```bash
# 1. Decrypt backup (if encrypted)
gpg --decrypt secrets-live-backup-20260528-120000.yaml.gpg > secrets-live-backup-20260528-120000.yaml

# 2. Create namespaces on new cluster
kubectl create namespace argocd db cloud auth immich monitor backup

# 3. Restore secrets
kubectl apply -f secrets-live-backup-20260528-120000.yaml

# 4. Verify all secrets present
kubectl get secrets --all-namespaces | wc -l
```

### Scenario 2: Forgot to extract before rebuild

If you didn't extract beforehand:
- Connect to the old cluster backup/snapshot (if available)
- Run extraction immediately
- Only then proceed with rebuild

### Scenario 3: Some secrets are missing from backup

If any secrets are missing:
- Recreate them manually (document for next time)
- Update this extraction guide
- Consider using external secret management (Sealed Secrets, External Secrets Operator)

---

## Next Steps

1. **Run the extraction**
   ```bash
   ssh homelab@172.20.20.3
   cd /path/to/homelab-infra
   ./extract-live-secrets.sh  # or python3 extract-live-secrets.py
   ```

2. **Secure the backup**
   ```bash
   gpg --encrypt --recipient your-email secrets-live-backup-*.yaml
   rm secrets-live-backup-*.yaml  # Remove unencrypted version
   ```

3. **Store securely**
   - Copy to NAS, external drive, or cloud storage
   - Keep in multiple locations

4. **Test restoration** (optional but recommended)
   - Create test cluster
   - Practice restore procedure
   - Verify all applications work

5. **Document**
   - Update this guide with any custom procedures
   - Note any secrets not captured
   - Document encryption passphrase location (securely!)

6. **Proceed with rebuild**
   - You now have a complete backup
   - Run fresh-install.sh or ansible playbooks
   - Restore secrets after cluster is ready

---

## Additional Resources

- `SECRETS-BACKUP-GUIDE.md` - Bootstrap secrets guide
- `secrets-backup.yaml` - Configuration inventory
- `extract-secrets.py` - Original extraction script
- Kubernetes Secrets documentation: https://kubernetes.io/docs/concepts/configuration/secret/

---

**Last Updated:** May 28, 2026
**For:** Homelab Rebuild Protection
**Owner:** Aly (alybadawy@icloud.com)
