# Homelab Infrastructure

A portable, Ansible-based infrastructure as code setup for provisioning and managing a homelab server.

## Project Overview

This project uses Ansible to provision and manage a homelab server. The infrastructure is defined as code, making it reproducible and version-controlled.

## Prerequisites

- **Ansible** (version 2.9 or later)
- **SSH access** to the target server(s)
- **Python 3** installed on target servers
- **sudo privileges** on the remote user account

### Installation

```bash
# Install Ansible (macOS with Homebrew)
brew install ansible

# Install Ansible (Ubuntu/Debian)
sudo apt install ansible

# Or with pip
pip install ansible
```

## Project Structure

```
homelab-infra/
├── ansible/
│   ├── inventory.ini      # Host inventory and connection settings
│   ├── bootstrap.yml      # Initial system bootstrap playbook
│   └── ...                # Additional playbooks (coming soon)
├── README.md              # This file
└── .gitignore
```

## Inventory Configuration

The `ansible/inventory.ini` file defines your infrastructure:

```ini
[homelab]
server1 ansible_host=172.20.20.3

[homelab:vars]
ansible_user=homelab              # SSH user
ansible_become=true               # Use sudo
ansible_become_method=sudo
ansible_become_flags=-H -S
ansible_python_interpreter=/usr/bin/python3
```

**To add more servers**, simply add new lines in the `[homelab]` section:
```ini
server1 ansible_host=172.20.20.3
server2 ansible_host=172.20.20.4
```

## Available Playbooks

### bootstrap.yml
Performs initial system setup and updates:
- Runs `apt update` to refresh package lists
- Runs `apt upgrade` (dist-upgrade) to update all packages to latest versions

**Run:**
```bash
ansible-playbook -i ansible/inventory.ini ansible/bootstrap.yml
```

### dependencies.yml
Installs system dependencies required for homelab services:
- **Package Management**: curl, git, jq, gettext-base
- **Storage**: nfs-common, open-iscsi
- **Python**: python3, python3-pip, python3-yaml
- **Services**: Enables iscsid daemon (required for storage), enables NTP time sync

**Run:**
```bash
ansible-playbook -i ansible/inventory.ini ansible/dependencies.yml
```

### swap.yml
Configures a swap file on the system:
- Removes any existing swap
- Creates a new swap file (default: 12GB, configurable via `swap_size_gb` variable)
- Persists swap configuration in `/etc/fstab`

**Edit swap size:**
```yaml
vars:
  swap_size_gb: 12  # Change this value
```

**Run:**
```bash
ansible-playbook -i ansible/inventory.ini ansible/swap.yml
```

### nfs-mounts.yml
Mounts NFS shares from your NAS:
- Creates mount point directories
- Adds entries to `/etc/fstab` for persistent mounting
- Mounts all configured shares
- Configures NFS options (timeout, automount, etc.)

**Configure your NAS and mounts:**
```yaml
vars:
  nas_ip: "172.20.20.1"  # Your NAS IP
  nfs_mounts:
    - nfs_path: "/var/nfs/homelab"
      mount_point: "/mnt/nas/homelab"
    - nfs_path: "/var/nfs/immich"
      mount_point: "/mnt/nas/immich"
    # Add more as needed
```

**Run:**
```bash
ansible-playbook -i ansible/inventory.ini ansible/nfs-mounts.yml
```

### k3s.yml
Installs k3s Kubernetes, Helm, and Longhorn storage:
- Installs k3s **without Traefik** (nginx-ingress to be added later)
- Installs Helm package manager
- Installs Longhorn distributed storage (ready for persistent volumes)
- Configures everything but no PVCs are created yet
- Saves kubeconfig to your local machine

**Versions (customizable):**
```yaml
vars:
  k3s_version: ""              # Leave empty for latest
  helm_version: ""
  longhorn_version: ""
```

**Run:**
```bash
ansible-playbook -i ansible/inventory.ini ansible/k3s.yml
```

**After installation:**
```bash
# Set kubeconfig
export KUBECONFIG=~/.kube/k3s-config.yaml

# Verify cluster
kubectl get nodes

# Access Longhorn UI (if needed)
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80
# Then visit http://localhost:8080
```

### longhorn-restore.yml
Discovers Longhorn volume backups and provides guided restore instructions:
- Scans NAS backup directory for available volume backups
- **Interactively prompts** you to select which volumes to restore
- Displays PVC names and backup metadata
- Provides manual kubectl commands for restoration
- Use this for **manual control** over the restore process

**Configure backup paths:**
```yaml
vars:
  backup_store_path: "/mnt/nas/backups/longhorn/backupstore"
  nas_ip: "172.20.20.2"
  nas_backup_path: "/var/nfs/backups/longhorn/backupstore"
```

**Run:**
```bash
ansible-playbook -i ansible/inventory.ini ansible/longhorn-restore.yml
```

### restore-longhorn-volumes.yml
Restore Longhorn volumes from backups (GitOps-ready):
- Scans NAS for available backups
- **Interactively asks** which volumes to restore
- Creates Longhorn Volume objects
- Creates PersistentVolumeClaims bound to volumes
- Waits for volumes and PVCs to be fully ready
- **Ideal for GitOps**: all volumes ready before ArgoCD deployment

**Run:**
```bash
ansible-playbook -i ansible/inventory.ini ansible/restore-longhorn-volumes.yml
```

**Workflow:**
```bash
# 1. Restore volumes from backups (this playbook)
ansible-playbook -i ansible/inventory.ini ansible/restore-longhorn-volumes.yml

# 2. Once complete, deploy ArgoCD with applications
# (volumes are already ready and populated)
ansible-playbook -i ansible/inventory.ini argocd.yml
```

### longhorn-backup-restore.yml
Automatically restores Longhorn volume backups using Longhorn API:
- Scans NAS backup directory for available volumes
- **Interactively prompts** which volumes to restore
- Creates Longhorn `Volume` objects properly
- Restores from backup via Longhorn API using Python
- Automatically creates `PersistentVolumeClaim` for each restored volume
- Waits for volumes and PVCs to be ready
- Use this for **fully automated** restoration with proper API handling

**Configure backup paths:**
```yaml
vars:
  backup_store_path: "/mnt/nas/backups/longhorn/backupstore"
  nas_ip: "172.20.20.2"
  nas_backup_path: "/var/nfs/backups/longhorn/backupstore"
```

**Run:**
```bash
ansible-playbook -i ansible/inventory.ini ansible/longhorn-backup-restore.yml
```

**What it does:**
1. Discovers all available backups on NAS
2. Shows PVC names (e.g., postgres-data-lh, nextcloud-data-lh)
3. Prompts you to select which volumes to restore (comma-separated, or "all")
4. Creates Longhorn Volume objects with correct specifications
5. Uses Longhorn API to restore from backup via Python
6. Creates PersistentVolumeClaims for each restored volume
7. Waits for volumes to be ready
8. Displays final status and next steps

### apply-secrets.yml
Applies Kubernetes secrets and cluster configuration from NAS:
- Reads secrets from `/mnt/nas/homelab/secrets.yaml`
- Creates required namespaces (from secrets + argocd)
- **Applies Kubernetes Secret objects** with base64-encoded data
- Creates **cluster-vars ConfigMap** in argocd namespace for ArgoCD CMP variable substitution
- Idempotent using `kubectl apply` with `--dry-run=client`
- Use this **before deploying ArgoCD** to ensure all secrets and config are available

**Run:**
```bash
ansible-playbook -i ansible/inventory.ini ansible/apply-secrets.yml
```

### argocd-bootstrap.yml
Bootstraps the GitOps deployment by applying the root Application:
- Verifies ArgoCD is installed
- Verifies cluster-vars ConfigMap exists (from apply-secrets.yml)
- Verifies CMP plugin is configured (in ArgoCD Helm values)
- **Applies root application** from `k8s/argocd/root-app.yaml`
- Waits for root app to be created
- Monitors sync progress of all applications
- Verifies namespaces are created
- Displays sync wave deployment order

**Prerequisites:**
1. ArgoCD installed (via Helm)
2. apply-secrets.yml run (creates cluster-vars ConfigMap)

**Run:**
```bash
ansible-playbook -i ansible/inventory.ini ansible/argocd-bootstrap.yml
```

**What it does:**
1. Checks ArgoCD is installed in argocd namespace
2. Checks cluster-vars ConfigMap exists
3. Checks CMP plugin (argocd-cmp-kustomize-envsubst) exists
4. Applies k8s/argocd/root-app.yaml via kubectl apply
5. Waits for root app to be created
6. Displays all applications synced by root app
7. Monitors ingress-nginx and longhorn (wave 0-1) sync progress
8. Displays created namespaces
9. Shows sync status and next steps

**Secrets file format:**
```yaml
secrets:
  - name: database-credentials
    namespace: postgres
    data:
      username: postgres
      password: securepassword
  - name: api-keys
    namespace: default
    data:
      github_token: ghp_xxxx
      api_key: xxxxx
```

**Configure cluster variables via CLI (optional):**
```bash
ansible-playbook -i ansible/inventory.ini ansible/apply-secrets.yml \
  -e "nas_ip=172.20.20.2" \
  -e "timezone=America/New_York" \
  -e "github_repo=https://github.com/user/homelab-gitops"
```

**Or via group_vars/all.yml:**
```yaml
nas_ip: "172.20.20.2"
timezone: "UTC"
github_repo: "https://github.com/user/homelab-gitops"
```

**Default values:**
- Domain: `in.alybadawy.com` (set in playbook)
- NAS IP: `172.20.20.2`
- Timezone: `UTC`

**Run:**
```bash
ansible-playbook -i ansible/inventory.ini ansible/apply-secrets.yml
```

**What it does:**
1. Validates secrets file exists at `/mnt/nas/homelab/secrets.yaml`
2. Extracts unique namespaces from secrets definition
3. Creates all required namespaces
4. Generates Kubernetes Secret manifests with base64-encoded data
5. Applies secrets via kubectl
6. Creates cluster-vars ConfigMap with:
   - Domain and subdomain hostnames
   - NAS configuration (IP, export paths)
   - GitHub repository URL
   - Timezone
   - Service URLs for all applications (Grafana, Prometheus, Nextcloud, etc.)
7. Displays verification of all created secrets and ConfigMaps

## Quick Start

1. **Update the inventory** to match your server details:
   ```bash
   nano ansible/inventory.ini
   ```

2. **Test SSH connectivity**:
   ```bash
   ansible all -i ansible/inventory.ini -m ping
   ```

3. **Run the bootstrap playbook**:
   ```bash
   ansible-playbook -i ansible/inventory.ini ansible/bootstrap.yml
   ```

## SSH Key Setup (Optional but Recommended)

For password-less authentication, set up SSH keys:

```bash
# Generate a key if you don't have one
ssh-keygen -t ed25519 -f ~/.ssh/homelab_key

# Copy to server
ssh-copy-id -i ~/.ssh/homelab_key.pub homelab@172.20.20.3
```

Then update `inventory.ini`:
```ini
[homelab:vars]
ansible_ssh_private_key_file=~/.ssh/homelab_key
```

## Making Changes

When modifying playbooks:
1. Test syntax first:
   ```bash
   ansible-playbook --syntax-check ansible/bootstrap.yml
   ```

2. Do a dry-run before applying:
   ```bash
   ansible-playbook -i ansible/inventory.ini ansible/bootstrap.yml --check
   ```

3. Commit changes to git:
   ```bash
   git add .
   git commit -m "description of changes"
   ```

## Playbook Checklist

- [x] System bootstrap (apt update/upgrade)
- [x] System dependencies (packages, NTP, iSCSI)
- [x] Swap file configuration
- [x] NFS mounts configuration
- [x] Kubernetes/k3s + Helm + Longhorn
- [x] Longhorn backup discovery and restoration
- [x] Kubernetes secrets and cluster configuration
- [x] ArgoCD bootstrap (root application deployment)
- [ ] nginx-ingress installation (via ArgoCD)
- [ ] Monitoring stack (Prometheus, Grafana) (via ArgoCD)
- [ ] Applications (Authentik, Nextcloud, Immich) (via ArgoCD)
- [ ] Backup automation (via ArgoCD)
- [ ] Container registry configuration
- [ ] Network configuration

## Troubleshooting

**Connection refused:**
- Verify the server IP in `inventory.ini`
- Check SSH key permissions: `chmod 600 ~/.ssh/homelab_key`
- Ensure the `ansible_user` has SSH access

**Python interpreter not found:**
- SSH to the server and verify: `python3 --version`
- Update `ansible_python_interpreter` in `inventory.ini` if needed

**Permission denied errors:**
- Verify `ansible_user` has sudo privileges
- Test: `ssh homelab@172.20.20.3 "sudo whoami"`

## GitOps Deployment Architecture

The homelab uses **ArgoCD** for true GitOps deployment. All Kubernetes applications are declaratively defined in the `k8s/` directory and automatically synced to the cluster.

**Key concepts:**
- **Single source of truth:** The GitHub repository
- **Automatic syncs:** Every git push triggers cluster updates
- **Variable substitution:** Environment-specific values injected at sync time
- **Drift detection:** Automatic reversion if cluster state diverges from git
- **Sync waves:** Controlled deployment order (ingress → storage → databases → apps)

**For detailed architecture documentation, see:** [GITOPS-ARCHITECTURE.md](GITOPS-ARCHITECTURE.md)

### Quick GitOps Workflow

```bash
# 1. Apply secrets and configuration (Ansible)
ansible-playbook -i ansible/inventory.ini ansible/apply-secrets.yml

# 2. Deploy ArgoCD via Helm
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm install argocd argo/argo-cd -n argocd --create-namespace \
  -f k8s/argocd/helm-values.yaml

# 3. Bootstrap all applications (Ansible)
ansible-playbook -i ansible/inventory.ini ansible/argocd-bootstrap.yml

# 4. Monitor sync progress
argocd app list
argocd app status db

# 5. Access ArgoCD UI
kubectl port-forward -n argocd svc/argocd-server 8080:443
# Open: https://localhost:8080

# 6. Update applications by committing to git
git commit -am "Update app configuration"
git push
# ArgoCD automatically syncs within 3 minutes
```

---

## Contributing

This is a personal homelab setup. For improvements or additions:
1. Create a new branch
2. Test changes locally (use `--dry-run` with Ansible)
3. Commit with clear messages
4. Push and let ArgoCD sync

For new applications:
1. Create stack directory: `k8s/stacks/myapp/`
2. Define manifests with variable substitution (`${VAR}`)
3. Create Application CRD: `k8s/argocd/apps/myapp.yaml`
4. Register in: `k8s/argocd/apps/kustomization.yaml`
5. Commit and push — ArgoCD syncs automatically

## License

This infrastructure code is for personal use. Customize as needed.
