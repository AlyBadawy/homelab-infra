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
- [ ] Docker installation and setup
- [ ] Container registry configuration
- [ ] Kubernetes/k3s setup
- [ ] Monitoring stack (Prometheus, Grafana)
- [ ] Backup automation
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

## Contributing

This is a personal homelab setup. For improvements or additions, test locally first and commit with clear commit messages.

## License

This infrastructure code is for personal use. Customize as needed.
