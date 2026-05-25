# Phase 1: Local Storage Setup

This document guides you through setting up local storage on your homelab server before migrating to Longhorn.

## Overview

**Phase 1: Local Storage** (current)

- Create local directories on homelab server
- Extract TAR file backups into directories
- ArgoCD deploys services using local-path storage
- Services run with real data

**Phase 2: Add Longhorn Volumes**

- Create Longhorn volumes alongside local ones
- Copy data from local → Longhorn
- Verify Longhorn backups work

**Phase 3: Migrate to Longhorn**

- Switch services to use Longhorn PVCs
- Remove local PVCs
- Longhorn becomes primary storage with working backups

---

## Phase 1 Setup Instructions

### Step 1: Create Local Directories

On your homelab server, create these directories in the homelab user's home folder:

```bash
# SSH to your homelab server
ssh homelab@172.20.20.3

# Create directory structure for each PVC
mkdir -p ~/pvc-data/postgres-data
mkdir -p ~/pvc-data/pgadmin-data
mkdir -p ~/pvc-data/authentik-data
mkdir -p ~/pvc-data/authentik-templates
mkdir -p ~/pvc-data/nextcloud-data
mkdir -p ~/pvc-data/prometheus-grafana

# Verify directories exist
ls -la ~/pvc-data/
```

### Step 2: Install local-path Provisioner

The `local-path` storage class should already be available in k3s, but verify:

```bash
kubectl get storageclass
# Should show "local-path" (default)
```

### Step 3: Extract TAR File Backups

Extract the backup TAR files into the corresponding directories:

```bash
# Create a temporary work directory
mkdir -p /tmp/backups
cd /tmp/backups

# Extract all TAR files
tar -xzf /mnt/nas/backups/k3s/2026-05-22_04-00-01/db_postgres-data.tar.gz
tar -xzf /mnt/nas/backups/k3s/2026-05-22_04-00-01/db_pgadmin-data.tar.gz
tar -xzf /mnt/nas/backups/k3s/2026-05-22_04-00-01/auth_authentik-data.tar.gz
tar -xzf /mnt/nas/backups/k3s/2026-05-22_04-00-01/cloud_nextcloud-data.tar.gz

# List what was extracted to understand the structure
ls -la /tmp/backups/
```

### Step 4: Copy Data to PVC Directories

Copy the extracted data to the PVC directories:

```bash
# Copy postgres data (assuming it extracts to a postgres/ or var/lib/postgresql/data directory)
cp -r /tmp/backups/var/lib/postgresql/data/* ~/pvc-data/postgres-data-lh/

# Copy pgadmin data
cp -r /tmp/backups/var/lib/pgadmin/* ~/pvc-data/pgadmin-data-lh/

# Copy authentik data
cp -r /tmp/backups/var/lib/authentik/* ~/pvc-data/authentik-data-lh/

# Copy nextcloud data
cp -r /tmp/backups/var/www/html/data/* ~/pvc-data/nextcloud-data-lh/
```

**NOTE:** You may need to adjust paths based on how the TAR files are structured. Run this first to inspect:

```bash
# Inspect TAR file structure before extracting
tar -tzf /mnt/nas/backups/k3s/2026-05-22_04-00-01/db_postgres-data.tar.gz | head -20
```

### Step 5: Fix Permissions

Ensure directories have correct permissions for Kubernetes pods:

```bash
# Make directories readable/writable
chmod 755 ~/pvc-data/*

# Kubernetes will handle per-app permissions via initContainers
```

### Step 6: Create StorageClass Configuration

Create a ConfigMap that maps local directories to PVCs (k3s local-path provisioner needs this):

```bash
kubectl create configmap local-path-provisioner-config \
  -n local-path-storage \
  --from-literal=config.json='{"nodePathMap":null}' \
  --dry-run=client -o yaml | kubectl apply -f -
```

Actually, for k3s's local-path provisioner, just ensure the directories exist and have proper permissions. The provisioner will create `local-path-` PVs automatically.

### Step 7: Deploy Applications with ArgoCD

Push your changes to git (all PVCs now use `local-path`):

```bash
cd /path/to/homelab-infra
git add k8s/
git commit -m "Phase 1: Switch to local-path storage for initial deployment"
git push
```

ArgoCD will automatically pick up the changes and:

1. Create PVs in the local directories
2. Bind PVCs to those PVs
3. Deploy pods with your restored data

Monitor the deployment:

```bash
kubectl get applications -n argocd -w
kubectl get pvc -A
kubectl get pv -A
```

### Step 8: Verify Data is Accessible

Once pods are running, verify data was restored correctly:

```bash
# Check PVC bindings
kubectl get pvc -A

# Verify data in pods
kubectl exec -it postgres-xxx -n db -- psql -U postgres -c "SELECT version();"
kubectl exec -it nextcloud-xxx -n cloud -- ls -la /data
```

---

## Troubleshooting Phase 1

**Problem: PVC stuck in Pending**

```bash
# Check PV creation
kubectl get pv

# Check for local-path provisioner logs
kubectl logs -n local-path-storage -l app=local-path-provisioner
```

**Problem: Permission denied when pod writes to volume**

- Ensure initContainers are running and fixing permissions
- Check pod logs: `kubectl logs -f <pod-name> -n <namespace>`

**Problem: Data not restored correctly**

- Verify TAR file was extracted to correct location
- Check file permissions match what the app expects
- Inspect pod container: `kubectl exec -it <pod> -n <ns> -- ls -la /path/to/volume`

---

## Next Steps: Phase 2 (Longhorn Migration)

Once Phase 1 is stable and all services are running with local data:

1. Create Longhorn Volumes with readable names
2. Copy data from local PVCs to Longhorn PVCs
3. Create backup jobs
4. Verify backup → restore workflow

Then proceed to Phase 3: Switch services to use Longhorn.

---

## PVC to Directory Mapping

| PVC Name            | Namespace | TAR File                          | Local Directory                |
| ------------------- | --------- | --------------------------------- | ------------------------------ |
| postgres-data       | db        | db_postgres-data.tar.gz           | ~/pvc-data/postgres-data       |
| pgadmin-data        | db        | db_pgadmin-data.tar.gz            | ~/pvc-data/pgadmin-data        |
| authentik-data      | auth      | auth_authentik-data.tar.gz        | ~/pvc-data/authentik-data      |
| authentik-templates | auth      | auth_authentik-templates.tar.gz   | ~/pvc-data/authentik-templates |
| nextcloud-data      | cloud     | cloud_nextcloud-data.tar.gz       | ~/pvc-data/nextcloud-data      |
| prometheus-grafana  | monitor   | (Grafana uses emptyDir initially) | ~/pvc-data/prometheus-grafana  |

## Future: Longhorn Versions (Phase 2)

Once you migrate to Longhorn, these PVCs will be created with `-lh` suffix:

- postgres-data-lh
- pgadmin-data-lh
- authentik-data-lh
- authentik-templates-lh
- nextcloud-data-lh
- prometheus-grafana-lh

---

## Summary

✅ All PVC names updated (removed `-lh` suffix)
✅ All PVCs now use `local-path` storage class
✅ Ready for manual directory creation and TAR extraction
✅ ArgoCD will automatically deploy services when you push changes
✅ Phase 2 will create `-lh` versions for Longhorn volumes
✅ Phase 3 will migrate services to Longhorn
