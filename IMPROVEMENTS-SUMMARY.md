# Homelab Infrastructure - Recent Improvements

## Overview
Updated the homelab infrastructure deployment pipeline to automatically detect and restore Longhorn volume backups during the fresh install process, eliminating manual restore steps.

## What Changed

### 1. **Updated `pre-create-pvcs.yml` Playbook**

**Before:**
- Created empty PVCs for all applications
- Required separate manual restore step via `restore-longhorn-volumes.yml`
- Users had to manually sync applications after restore

**After:**
- Automatically detects backups in `/mnt/nas/backups/k3s-longhorn/backupstore/volumes/`
- For each backup found:
  - Creates Longhorn Volume with `fromBackup` to restore data
  - Waits for restore to complete (5-15 minutes)
  - Creates PVC bound to restored volume
- For backups not found: Creates empty PVCs (fresh install)
- Everything happens in one playbook run before ArgoCD deploys

**Benefits:**
- No manual restore steps
- Databases ready with real data when applications start
- PostgreSQL, Nextcloud, Immich start with existing data immediately
- Works seamlessly for both fresh installs and restores

### 2. **Updated `fresh-install.sh` Script**

**Before:**
- 11 playbooks total
- Separate optional manual step to restore Longhorn volumes
- Only passed `github_repo` to `apply-secrets.yml`

**After:**
- 10 playbooks (removed separate restore step)
- Prompts for NAS paths during setup:
  - `NAS_NEXTCLOUD_DATA` (default: `/mnt/nas/nextcloud`)
  - `NAS_IMMICH_DATA` (default: `/mnt/nas/immich`)
  - `NAS_BACKUPS_DIR` (default: `/mnt/nas/backups`)
- Passes NAS variables to `apply-secrets.yml`
- Playbook order updated:
  1. bootstrap.yml
  2. dependencies.yml
  3. swap.yml
  4. nfs-mounts.yml
  5. k3s.yml
  6. acme-cert.yml
  7. apply-secrets.yml (now with NAS variables)
  8. longhorn-bootstrap.yml
  9. **pre-create-pvcs.yml (now does restore + pvc creation)**
  10. argocd-bootstrap.yml

### 3. **Environment Variable Fix**

Added automatic injection of NAS environment variables into ArgoCD repo-server deployment in `argocd-bootstrap.yml`:
- Variables: `NAS_IMMICH_DATA`, `NAS_NEXTCLOUD_DATA`, `NAS_BACKUPS_DIR`
- Enables kustomize-envsubst CMP plugin to substitute variables in manifests
- Solves the "empty hostPath" issue where `${NAS_IMMICH_DATA}` wasn't being replaced

### 4. **Documentation Updates**

- Updated README.md `pre-create-pvcs.yml` section
- Updated fresh-install.sh documentation
- All playbooks now clearly document their restore vs. fresh install behavior

## Deployment Flow

### Fresh Install (No Backups)
```
1. Run fresh-install.sh
2. System bootstrapped + k3s + Longhorn + ArgoCD installed
3. pre-create-pvcs.yml finds no backups, creates empty PVCs
4. ArgoCD deploys applications
5. Applications initialize with fresh databases
```

### Restore (With Backups)
```
1. Run fresh-install.sh
2. System bootstrapped + k3s + Longhorn + ArgoCD installed
3. pre-create-pvcs.yml discovers backups:
   - Restores postgres-data-lh
   - Restores nextcloud-data-lh
   - Restores immich-model-cache
   - Restores other backups found
4. ArgoCD deploys applications
5. Applications start with existing databases and data intact
```

## Testing the Flow

To test a restore scenario:

```bash
# Ensure backups exist at the right path
ls -la /mnt/nas/backups/k3s-longhorn/backupstore/volumes/

# Run the fresh install script
./fresh-install.sh

# Script will:
# - Ask for NAS paths
# - Detect backups
# - Restore them automatically
# - Create PVCs bound to restored volumes
# - Deploy applications with data ready
```

## Files Modified

1. `ansible/pre-create-pvcs.yml` - Complete refactor to add backup detection and restoration
2. `ansible/fresh-install.sh` - Updated playbook order, added NAS path prompts
3. `ansible/apply-secrets.yml` - Already supported NAS variables (now passed correctly)
4. `ansible/argocd-bootstrap.yml` - Already has env var patching (working correctly)
5. `README.md` - Updated documentation for both playbooks

## Key Improvements

✅ **Automated:** No manual restore commands needed  
✅ **Intelligent:** Detects backups automatically  
✅ **Flexible:** Works for both fresh installs and restores  
✅ **Integrated:** Everything in the standard deployment pipeline  
✅ **Reliable:** Waits for volumes to be healthy before proceeding  
✅ **Documented:** Clear flow for operators  

## Next Run

When running the updated `fresh-install.sh`:

```bash
chmod +x fresh-install.sh
./fresh-install.sh
```

You'll be prompted for:
- Vercel API token
- GitHub repo URL
- ACME email
- **NEW:** NAS Nextcloud path
- **NEW:** NAS Immich path  
- **NEW:** NAS backups directory

The script will then run all 10 playbooks and automatically restore any available backups during step 9.
