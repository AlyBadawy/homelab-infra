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
Installs k3s Kubernetes and Helm package manager:
- Installs k3s **without Traefik** (nginx-ingress to be added later via ArgoCD)
- Installs Helm package manager
- **Does NOT install Longhorn** — managed entirely by ArgoCD (prevents Helm conflicts)
- Saves kubeconfig to your local machine
- Ready for ArgoCD to take over infrastructure management

**Versions (customizable):**
```yaml
vars:
  k3s_version: ""              # Leave empty for latest
  helm_version: ""
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
```

**Why Longhorn isn't installed here:**
Longhorn is installed by ArgoCD via the `infra-longhorn` Application (see `k8s/argocd/apps/`). This avoids Helm state conflicts and establishes a single source of truth (git) for Longhorn configuration.

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

### acme-cert.yml
Generates a wildcard TLS certificate for your domain via Let's Encrypt using ACME.sh:
- Installs ACME.sh to your user home directory (`~/.acme.sh`)
- Uses Vercel DNS-01 validation (requires Vercel API token)
- Generates wildcard certificate for `*.{{ domain }}` and `{{ domain }}`
- Creates Kubernetes TLS secret in the `ingress-nginx` namespace
- Configures auto-renewal (30 days before expiration)
- **Required before deploying ingress-nginx** to serve HTTPS traffic

**Prerequisites:**
- Domain must be using Vercel's DNS service
- Vercel API token (personal access token from Vercel dashboard)

**Configuration:**
```yaml
vars:
  domain: "in.alybadawy.com"              # Your domain
  acme_email: "admin@in.alybadawy.com"    # Email for ACME notifications
  cert_secret_name: "wildcard-in-alybadawy-com"  # K8s secret name
```

**Run:**
```bash
ansible-playbook -i ansible/inventory.ini ansible/acme-cert.yml \
  -e "vercel_api_token=YOUR_VERCEL_TOKEN"
```

**Optional: custom email**
```bash
ansible-playbook -i ansible/inventory.ini ansible/acme-cert.yml \
  -e "vercel_api_token=YOUR_TOKEN" \
  -e "acme_email=youremail@example.com"
```

**What it does:**
1. Validates Vercel API token is provided
2. Creates NAS certs directory (`/mnt/nas/homelab/certs`)
3. Installs ACME.sh (if not already installed)
4. Persists Vercel token to `~/.acme.sh/account.conf` for auto-renewal cron
5. Checks for existing valid certificate (>30 days remaining)
6. Requests wildcard certificate from Let's Encrypt via Vercel DNS validation (if needed)
7. Installs certificate with **renewal deploy hook** to NAS
8. Creates Kubernetes TLS secret from certificate files
9. Verifies both NAS and Kubernetes secret creation

**Certificate Storage:**
- **NAS:** `/mnt/nas/homelab/certs/` (persistent, survives fresh installs)
- **Kubernetes:** `ingress-nginx/wildcard-in-alybadawy-com` secret
- **ACME.sh:** `~/.acme.sh/wildcard_in.alybadawy.com/` (registration + renewal config)

**Auto-Renewal Workflow:**
1. ACME.sh cron runs twice daily
2. If cert expires in <30 days, renewal begins
3. Vercel DNS-01 validation using token from `account.conf`
4. On success, deploy hook automatically copies renewed cert to NAS
5. **Note:** Kubernetes secret requires manual update on renewal (re-run this playbook)

```bash
# Re-run after renewal to update K8s secret
ansible-playbook -i ansible/inventory.ini ansible/acme-cert.yml \
  -e "vercel_api_token=YOUR_TOKEN"
```

**Verify certificate:**
```bash
# Check NAS certificate
openssl x509 -enddate -noout -in /mnt/nas/homelab/certs/fullchain.pem

# Check Kubernetes secret exists
kubectl get secret wildcard-in-alybadawy-com -n ingress-nginx

# View certificate details
kubectl get secret wildcard-in-alybadawy-com -n ingress-nginx \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout
```

**Check renewal status:**
```bash
~/.acme.sh/acme.sh --list
~/.acme.sh/acme.sh --info -d "*.in.alybadawy.com"
```

**Manual renewal:**
```bash
~/.acme.sh/acme.sh --renew -d "in.alybadawy.com" \
  -d "*.in.alybadawy.com" --dns dns_vercel
```

**View auto-renewal logs:**
```bash
~/.acme.sh/acme.sh --cron --debug
```

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

### longhorn-bootstrap.yml
Manually installs and validates Longhorn storage before ArgoCD:
- Creates NAS backup directory at `/mnt/nas/backups/k3s-longhorn`
- Installs Longhorn via Helm with backup target pre-configured
- Waits for longhorn-manager DaemonSet to be ready
- Waits for longhorn-ui Deployment to be ready
- Patches Longhorn backup-target Setting CRD
- Verifies backup target validation status
- Verifies longhorn storage class exists
- **Critical:** Runs BEFORE argocd-bootstrap.yml to ensure storage is healthy

**Why separate from ArgoCD?**
Longhorn must be healthy and its storage class must exist before ArgoCD attempts to create PVCs. This prevents Pending PVC issues and ensures clean deployment.

**Run:**
```bash
ansible-playbook -i ansible/inventory.ini ansible/longhorn-bootstrap.yml
```

### pre-create-pvcs.yml
Pre-creates empty PersistentVolumeClaims before applications deploy:
- Clones git repository to access manifests
- Creates required namespaces (db, auth, cloud, immich, monitor)
- Extracts PVC objects from application manifests
- Creates PVCs with longhorn storage class bindings
- Waits for PVCs to be Bound to volumes

**Why pre-create?**
ArgoCD can now deploy applications and immediately bind to existing PVCs instead of waiting for them to be created during sync. Improves deployment speed and reliability.

**Run:**
```bash
ansible-playbook -i ansible/inventory.ini ansible/pre-create-pvcs.yml
```

### argocd-bootstrap.yml
Bootstraps the GitOps deployment by applying the root Application:
- Verifies ArgoCD is installed via Helm
- Verifies cluster-vars ConfigMap exists (from apply-secrets.yml)
- Verifies CMP plugin is configured (argocd-cmp-kustomize-envsubst)
- **Patches argocd-repo-server with NAS environment variables**
- **Applies root application** from `k8s/argocd/root-app.yaml`
- Waits for root app to be created
- Monitors sync progress of all applications
- Displays sync wave deployment order

**Prerequisites:**
1. Longhorn installed and healthy (longhorn-bootstrap.yml)
2. PVCs pre-created (pre-create-pvcs.yml)
3. apply-secrets.yml run (creates cluster-vars ConfigMap)

**Run:**
```bash
ansible-playbook -i ansible/inventory.ini ansible/argocd-bootstrap.yml
```

**What it does:**
1. Checks ArgoCD is installed in argocd namespace
2. Checks cluster-vars ConfigMap exists
3. Checks CMP plugin (argocd-cmp-kustomize-envsubst) exists
4. **Reads cluster-vars ConfigMap** to extract NAS variables (NAS_IMMICH_DATA, NAS_NEXTCLOUD_DATA, NAS_BACKUPS_DIR)
5. **Patches argocd-repo-server deployment** with JSON patch operations to add NAS environment variables to container
6. **Waits for repo-server to rollout** with new environment variables
7. Applies k8s/argocd/root-app.yaml via kubectl apply
8. Waits for root app to be created
9. Displays all applications synced by root app
10. Monitors ingress-nginx and longhorn (wave 0-1) sync progress
11. Shows sync status and next steps

**Environment Variable Substitution:**
The CMP plugin (kustomize-envsubst) uses an awk script to substitute `${VAR}` patterns in Kubernetes manifests. Variables come from the argocd-repo-server process environment. This playbook automatically patches the deployment to include:
- `NAS_IMMICH_DATA`: Path to Immich media storage on NAS
- `NAS_NEXTCLOUD_DATA`: Path to Nextcloud data storage on NAS
- `NAS_BACKUPS_DIR`: Path to backups on NAS

These are used in application manifests to configure hostPath volumes.

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

**Recommended: Run the automated fresh install script**
```bash
chmod +x fresh-install.sh
./fresh-install.sh
```

This will guide you through the entire deployment process with interactive prompts.

**Manual step-by-step:**

1. **Update the inventory** to match your server details:
   ```bash
   nano ansible/inventory.ini
   ```

2. **Test SSH connectivity**:
   ```bash
   ansible all -i ansible/inventory.ini -m ping
   ```

3. **Run playbooks in order:**
   ```bash
   # System setup (bootstrap, dependencies, swap, NFS)
   ansible-playbook -i ansible/inventory.ini ansible/bootstrap.yml
   ansible-playbook -i ansible/inventory.ini ansible/dependencies.yml
   ansible-playbook -i ansible/inventory.ini ansible/swap.yml
   ansible-playbook -i ansible/inventory.ini ansible/nfs-mounts.yml
   
   # Kubernetes setup
   ansible-playbook -i ansible/inventory.ini ansible/k3s.yml
   
   # TLS certificate (required for ingress)
   ansible-playbook -i ansible/inventory.ini ansible/acme-cert.yml \
     -e "vercel_api_token=YOUR_TOKEN"
   
   # Kubernetes secrets and ArgoCD
   ansible-playbook -i ansible/inventory.ini ansible/apply-secrets.yml
   ansible-playbook -i ansible/inventory.ini ansible/argocd-bootstrap.yml
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

## Automated Fresh Install

The `fresh-install.sh` script automates the entire deployment process by running all playbooks in the correct order:

```bash
./fresh-install.sh
```

**What it does:**
1. **Validates requirements:** Checks for ansible-playbook, ssh, inventory.ini
2. **Tests SSH connectivity:** Verifies you can reach all servers
3. **Prompts for configuration:** Requests Vercel token, GitHub repo, ACME email
4. **Displays summary:** Shows configuration before proceeding
5. **Runs playbooks in order:**
   1. `bootstrap.yml` - System updates
   2. `dependencies.yml` - Required packages
   3. `swap.yml` - 12GB swap file
   4. `nfs-mounts.yml` - NAS mounts
   5. `k3s.yml` - Kubernetes + Helm
   6. `acme-cert.yml` - TLS certificate
   7. `apply-secrets.yml` - Kubernetes secrets & cluster-vars ConfigMap
   8. `longhorn-bootstrap.yml` - Longhorn storage (manual Helm install)
   9. `pre-create-pvcs.yml` - Pre-create empty PVCs for applications
   10. `argocd-bootstrap.yml` - GitOps deployment (root application)
   11. `restore-longhorn-volumes.yml` - **(optional)** Restore backups from NAS

6. **Tracks progress:** Shows completed vs. failed playbooks
7. **Provides next steps:** kubectl commands for monitoring

**Key order constraints:**
- `longhorn-bootstrap.yml` must run **before** `pre-create-pvcs.yml` (storage class must exist)
- `pre-create-pvcs.yml` must run **before** `argocd-bootstrap.yml` (PVCs ready for binding)
- `apply-secrets.yml` must run **before** `argocd-bootstrap.yml` (cluster-vars ConfigMap needed)
- `acme-cert.yml` should run **before** `argocd-bootstrap.yml` (TLS secret needed for ingress)

**Setup (first time):**
```bash
# Make script executable
chmod +x fresh-install.sh

# Ensure inventory is configured
nano ansible/inventory.ini

# Test SSH connectivity
ansible all -i ansible/inventory.ini -m ping
```

**Run the fresh install:**
```bash
./fresh-install.sh
```

**You will be prompted for:**
```
Enter your Vercel API token: [YOUR_TOKEN]
Enter GitHub repository URL [https://github.com/AlyBadawy/homelab-infra]: 
Enter email for ACME certificate [admin@in.alybadawy.com]: 
```

**Progress tracking:**
The script will confirm before running each playbook:
```
════════════════════════════════════════════════════════════════
Running: System Bootstrap (apt update/upgrade)
Playbook: bootstrap.yml
Continue? (y/n)
```

**If something fails:**
The script tracks which playbooks completed and which failed. Fix the issue and re-run:
```bash
# Re-run just the failed playbook
ansible-playbook -i ansible/inventory.ini ansible/FAILED_PLAYBOOK.yml

# Or restart the full script
./fresh-install.sh
```

**After completion:**
The script displays:
- List of successfully completed playbooks
- List of any failed playbooks
- Next steps for monitoring ArgoCD deployment

**Monitor deployment:**
```bash
# Watch applications sync
watch kubectl get applications -n argocd

# Check root application status
kubectl get application root -n argocd -o wide

# Monitor all pods
kubectl get pods -A --watch
```

## Playbook Checklist

### Infrastructure Provisioning (Ansible)
- [x] System bootstrap (apt update/upgrade)
- [x] System dependencies (packages, NTP, iSCSI)
- [x] Swap file configuration (12GB)
- [x] NFS mounts configuration
- [x] Kubernetes/k3s + Helm (Longhorn managed by ArgoCD)
- [x] TLS certificate generation (ACME.sh + Vercel DNS)
- [x] Kubernetes secrets and cluster configuration
- [x] ArgoCD bootstrap (root application deployment)
- [x] Longhorn backup discovery and restoration
- [x] **Fresh install automation script** (fresh-install.sh)

### Infrastructure Components (via ArgoCD)
- [x] nginx-ingress (ingress-nginx, wave 0)
- [x] Longhorn storage (infra-longhorn, wave 0)
- [ ] Monitoring stack (Prometheus, Grafana) (via ArgoCD, wave 1)
- [ ] Databases (PostgreSQL, Redis) (via ArgoCD, wave 1)
- [ ] Applications (Authentik, Nextcloud, Immich, etc.) (via ArgoCD, wave 2+)
- [ ] Backup automation (via ArgoCD)
- [ ] Container registry configuration (optional)
- [ ] Network policies and security (optional)

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

**Recommended: Use `fresh-install.sh` for automated deployment**
```bash
chmod +x fresh-install.sh
./fresh-install.sh
```

**Manual workflow (if not using script):**
```bash
# 1. Bootstrap system
ansible-playbook -i ansible/inventory.ini ansible/bootstrap.yml
ansible-playbook -i ansible/inventory.ini ansible/dependencies.yml
ansible-playbook -i ansible/inventory.ini ansible/swap.yml
ansible-playbook -i ansible/inventory.ini ansible/nfs-mounts.yml

# 2. Install k3s and Helm
ansible-playbook -i ansible/inventory.ini ansible/k3s.yml

# 3. Generate TLS certificate (required for ingress)
ansible-playbook -i ansible/inventory.ini ansible/acme-cert.yml \
  -e "vercel_api_token=YOUR_TOKEN"

# 4. Apply secrets and cluster configuration
ansible-playbook -i ansible/inventory.ini ansible/apply-secrets.yml

# 5. Bootstrap ArgoCD and all applications
ansible-playbook -i ansible/inventory.ini ansible/argocd-bootstrap.yml

# 6. (Optional) Restore Longhorn volumes from backups
ansible-playbook -i ansible/inventory.ini ansible/restore-longhorn-volumes.yml

# 7. Monitor sync progress
watch kubectl get applications -n argocd

# 8. Access ArgoCD UI
kubectl port-forward -n argocd svc/argocd-server 8080:443
# Open: https://localhost:8080

# 9. Update applications by committing to git
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
