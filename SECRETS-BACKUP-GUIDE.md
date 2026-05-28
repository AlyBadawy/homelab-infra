# Secrets and Configuration Backup Guide

**Date Created:** May 28, 2026  
**Purpose:** Preserve all secrets and configuration before system rebuild  
**Status:** Ready for rebuild

---

## Overview

This guide documents the locations and structure of all secrets, environment variables, and configuration in your homelab infrastructure. Two files are provided:

1. **`secrets-backup.yaml`** - Machine-readable inventory of all secrets and configuration references
2. **`SECRETS-BACKUP-GUIDE.md`** - This guide (human-readable documentation)

---

## Critical Information Before Rebuild

### ⚠️ Master Secrets File Location
**Most Important**: Your actual secrets are stored at:
```
/mnt/nas/homelab/secrets.yaml
```

This file contains:
- All Kubernetes Secret data (DB passwords, API keys, credentials)
- Namespace-specific secrets
- Sensitive configuration values

**ACTION REQUIRED:** Ensure this file is backed up before rebuild!

### Configuration Source Files

| File | Purpose | Contains |
|------|---------|----------|
| `ansible/apply-secrets.yml` | Applies secrets to cluster | Secret references, cluster config, namespace setup |
| `ansible/argocd-bootstrap.yml` | Bootstraps ArgoCD | CMP plugin, Helm values, root application |
| `k8s/stacks/*/` | Deployment manifests | Environment variable references, secret/configmap usage |

---

## Cluster Configuration Variables

These variables are defined in `ansible/apply-secrets.yml` and used throughout:

### Domain & Networking
- `DOMAIN` - Base domain (e.g., `in.alybadawy.com`)
- `NAS_IP` - Network-attached storage IP address
- `NAS_BASE_EXPORT` - Base NFS export path

### Storage Paths
- `NAS_IMMICH_DATA` - Immich data path on NAS
- `NAS_NEXTCLOUD_DATA` - Nextcloud data path on NAS
- `NAS_BACKUPS_DIR` - Backup directory on NAS

### Subdomain Configuration
- `CFG_SUB_WHOAMI`, `CFG_SUB_GRAFANA`, `CFG_SUB_PROMETHEUS`, etc.
- These are combined with DOMAIN to create full hostnames

### System Configuration
- `TIMEZONE` - Cluster timezone
- `GITHUB_REPO` - GitHub repository URL (for GitOps)

---

## Kubernetes Secrets

Secrets are applied to specific namespaces and referenced by deployments.

### Referenced Secrets
```yaml
nextcloud-secret:
  - Namespace: cloud
  - Keys: DB_NAME, DB_USER, DB_PASS
  - Used by: Nextcloud deployment
```

### How Secrets Are Applied
```bash
# Run this command to apply secrets from /mnt/nas/homelab/secrets.yaml
ansible-playbook -i ansible/inventory.ini ansible/apply-secrets.yml
```

---

## Environment Variables by Application

### Nextcloud (cloud namespace)
```yaml
- PUID: 1000
- PGID: 1000
- TZ: ${TIMEZONE}
- DB_TYPE: pgsql
- DB_HOST: postgres.db.svc.cluster.local
- DB_NAME: (from secret: nextcloud-secret)
- DB_USER: (from secret: nextcloud-secret)
- DB_PASS: (from secret: nextcloud-secret)
```

### Template Variables
Used in kustomize templates and processed by ArgoCD CMP plugin:
- `${DOMAIN}` - Base domain
- `${TIMEZONE}` - System timezone
- `${NAS_*}` - NAS-related paths and IPs
- `${*_HOST}` - Service hostnames (grafana, prometheus, etc.)
- `${GITHUB_REPO}` - GitOps repository
- `${WILDCARD_SECRET}` - TLS certificate secret name

---

## ConfigMaps and Scripts

### Key ConfigMaps
- **cluster-vars** (argocd namespace) - Contains all cluster-wide substitution variables
- **script-configmap** (backup namespace) - Backup and restore scripts
- **cmp-plugin** (argocd namespace) - Custom kustomize envsubst plugin

### Backup Scripts
Scripts are stored as ConfigMaps in `k8s/stacks/backup/`:
- Backup job definitions
- Restore procedures
- PVC creation scripts

---

## Restore Procedure

### Before System Rebuild
1. ✓ Verify `/mnt/nas/homelab/secrets.yaml` exists and is readable
2. ✓ Create additional backups if needed
3. ✓ Document any custom secrets or environment variables not in the inventory

### During System Setup
```bash
# Step 1: Bootstrap k3s and infrastructure
ansible-playbook -i ansible/inventory.ini ansible/dependencies.yml
ansible-playbook -i ansible/inventory.ini ansible/k3s.yml
ansible-playbook -i ansible/inventory.ini ansible/nfs-mounts.yml

# Step 2: Setup storage
ansible-playbook -i ansible/inventory.ini ansible/longhorn-bootstrap.yml

# Step 3: Apply secrets (CRITICAL)
ansible-playbook -i ansible/inventory.ini ansible/apply-secrets.yml

# Step 4: Bootstrap ArgoCD
ansible-playbook -i ansible/inventory.ini ansible/argocd-bootstrap.yml

# Step 5: Restore data from backups
ansible-playbook -i ansible/inventory.ini ansible/restore-all-backups.yml
```

### Verification After Restore
```bash
# Check namespaces were created
kubectl get namespaces

# Check secrets were applied
kubectl get secrets --all-namespaces

# Check cluster-vars ConfigMap
kubectl get configmap cluster-vars -n argocd -o yaml

# Check ArgoCD applications
kubectl get applications -n argocd
```

---

## File Inventory

### Extracted Backup Files
```
secrets-backup.yaml              - Machine-readable inventory
SECRETS-BACKUP-GUIDE.md          - This file
extract-secrets.py               - Extraction script (can be re-run)
```

### Source Files (Not Included Here)
These remain in the git repository:
```
ansible/apply-secrets.yml        - Secrets application logic
ansible/argocd-bootstrap.yml     - ArgoCD bootstrap logic
k8s/*/                           - All deployment manifests
/mnt/nas/homelab/secrets.yaml   - ACTUAL SECRETS (must backup separately!)
```

---

## Security Considerations

### What This Backup Contains
- ✓ Environment variable definitions and usage patterns
- ✓ Secret names and their required keys
- ✓ ConfigMap references
- ✓ Application-to-secret mappings

### What This Backup Does NOT Contain
- ✗ Actual secret values (encrypted in `/mnt/nas/homelab/secrets.yaml`)
- ✗ Database passwords (in `/mnt/nas/homelab/secrets.yaml`)
- ✗ API keys (in `/mnt/nas/homelab/secrets.yaml`)
- ✗ TLS certificates (managed separately)

### Storage Recommendations
1. Keep `secrets-backup.yaml` with your infrastructure code
2. Keep `/mnt/nas/homelab/secrets.yaml` in a separate secure location
3. Never commit actual secrets to git
4. Use `.gitignore` to protect:
   - `secrets.yaml` files
   - `.env` files
   - TLS certificate files

---

## Troubleshooting

### If Secrets Don't Apply
```bash
# Check if secrets file exists
ls -l /mnt/nas/homelab/secrets.yaml

# Check ansible inventory
cat ansible/inventory.ini

# Run with verbose output
ansible-playbook -i ansible/inventory.ini ansible/apply-secrets.yml -vv
```

### If Environment Variables Are Missing
```bash
# Check if cluster-vars ConfigMap was created
kubectl get configmap cluster-vars -n argocd

# Check ArgoCD plugin is working
kubectl logs -n argocd deployment/argocd-repo-server | grep cmp
```

### If Applications Won't Start
```bash
# Check if required secrets exist
kubectl describe pod <pod-name> -n <namespace>

# Check secret references
kubectl get secret <secret-name> -n <namespace> -o yaml

# Verify environment variable resolution
kubectl set env pod/<pod-name> --list -n <namespace>
```

---

## Re-running Extraction

To update the secrets inventory after making changes:

```bash
python3 extract-secrets.py > secrets-backup.yaml
```

This will:
- Scan all YAML manifests in `k8s/`
- Extract environment variable definitions
- Extract secret and configmap references
- Extract ansible configuration
- Generate an updated `secrets-backup.yaml`

---

## Additional Resources

- README.md - Project overview and architecture
- ADR-001-nfs-consolidation.md - Storage architecture decisions
- NFS-APP-COMPATIBILITY.md - Application-specific NFS requirements
- ArgoCD Application manifests in `k8s/argocd/apps/`

---

## Next Steps

1. ✓ Review this guide
2. ✓ Verify `/mnt/nas/homelab/secrets.yaml` is backed up
3. ✓ Test restore procedure in staging if possible
4. ✓ Keep these backup files in source control (git)
5. ✓ Document any custom secrets or configuration
6. ✓ Before rebuild, run fresh-install.sh or ansible playbooks in order

---

**Last Updated:** May 28, 2026  
**Maintenance:** Re-run extraction after adding new secrets or environment variables  
**Owner:** Aly (alybadawy@icloud.com)
