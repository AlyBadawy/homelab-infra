# GitOps Architecture — ArgoCD Deployment Guide

A comprehensive explanation of how the homelab infrastructure is deployed using ArgoCD and true GitOps principles.

## Quick Overview

Your GitOps setup uses **ArgoCD** to declaratively manage all Kubernetes applications. Every change to the `k8s/` directory in the GitHub repository automatically syncs to the cluster. The repository is the single source of truth.

**GitHub Repo:** `https://github.com/AlyBadawy/homelab-infra`

---

## Architecture Overview

### Directory Structure

```
k8s/
├── argocd/
│   ├── helm-values.yaml          # ArgoCD Helm chart values + CMP sidecar config
│   ├── cmp-plugin.yaml           # kustomize-envsubst plugin (ConfigMap)
│   ├── ingress.yaml              # ArgoCD web UI ingress
│   ├── root-app.yaml             # Bootstrap Application (entry point)
│   └── apps/
│       ├── kustomization.yaml    # Kustomization listing all apps
│       ├── db.yaml               # Application CRD for database stack
│       ├── cloud.yaml            # Application CRD for Nextcloud
│       ├── immich.yaml           # Application CRD for Immich
│       ├── auth.yaml             # Application CRD for Authentik
│       ├── whoami.yaml           # Application CRD for Whoami (test app)
│       ├── backup.yaml           # Application CRD for backup CronJobs
│       ├── infra-ingress-nginx.yaml      # Ingress controller (Helm)
│       ├── infra-longhorn.yaml           # Longhorn storage (Helm)
│       ├── infra-longhorn-config.yaml    # Longhorn recurring jobs
│       ├── infra-monitor.yaml            # Prometheus + Grafana (Helm)
│       └── infra-monitor-config.yaml     # Prometheus scrape configs
├── infrastructure/
│   ├── ingress-nginx/helm-values.yaml     # Helm values for nginx-ingress
│   └── longhorn/
│       ├── helm-values.yaml               # Helm values for Longhorn
│       ├── ingress.yaml                   # Longhorn UI ingress
│       └── recurring-jobs.yaml            # Backup job definitions
├── stacks/
│   ├── db/
│   │   ├── kustomization.yaml
│   │   ├── postgres.yaml                  # PostgreSQL deployment + PVC
│   │   ├── redis.yaml                     # Redis deployment
│   │   ├── pgadmin.yaml                   # PgAdmin deployment
│   │   └── ingress.yaml                   # Uses ${PGADMIN_HOST}
│   ├── cloud/
│   │   ├── kustomization.yaml
│   │   ├── nextcloud.yaml                 # Nextcloud deployment
│   │   └── ingress.yaml                   # Uses ${NEXTCLOUD_HOST}
│   ├── immich/
│   │   ├── kustomization.yaml
│   │   ├── immich-server.yaml
│   │   ├── immich-ml.yaml
│   │   └── ingress.yaml
│   ├── auth/
│   │   ├── kustomization.yaml
│   │   ├── authentik.yaml
│   │   └── ingress.yaml
│   ├── whoami/
│   │   ├── kustomization.yaml
│   │   ├── whoami.yaml
│   │   └── ingress.yaml
│   ├── monitor/
│   │   ├── kustomization.yaml
│   │   ├── longhorn-pvcs.yaml            # Longhorn PVCs for Prometheus/Grafana
│   │   ├── helm-values.yaml              # kube-prometheus-stack values
│   │   └── ingress.yaml
│   └── backup/
│       ├── kustomization.yaml
│       ├── namespace.yaml
│       ├── backup-config.yaml
│       ├── rbac.yaml
│       ├── script-configmap.yaml
│       └── cronjob.yaml
└── namespaces/                           # Kubernetes Namespace definitions
    ├── db.yaml
    ├── cloud.yaml
    ├── immich.yaml
    ├── auth.yaml
    ├── whoami.yaml
    ├── monitor.yaml
    └── longhorn-system.yaml
```

---

## How It Works: The GitOps Flow

### 1. Prerequisites (Setup via Ansible)

Before ArgoCD can sync, three things must be in place (handled by `ansible/apply-secrets.yml`):

**A. Kubernetes Secrets** — Created from `/mnt/nas/homelab/secrets.yaml`:

```yaml
secrets:
  - name: postgres-secret
    namespace: db
    data:
      POSTGRES_PASSWORD: securepassword
  - name: nextcloud-secret
    namespace: cloud
    data:
      DB_NAME: nextcloud
      DB_USER: nextcloud_user
      DB_PASS: securepassword
  - name: authentik-secret
    namespace: auth
    data:
      AUTHENTIK_SECRET_KEY: ...
  - name: immich-secret
    namespace: immich
    data:
      DB_PASSWORD: ...
```

**B. cluster-vars ConfigMap** — Created in `argocd` namespace:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-vars
  namespace: argocd
data:
  DOMAIN: "in.alybadawy.com"
  GITHUB_REPO: "https://github.com/AlyBadawy/homelab-infra"
  PGADMIN_HOST: "pgadmin.in.alybadawy.com"
  NEXTCLOUD_HOST: "cloud.in.alybadawy.com"
  IMMICH_HOST: "photos.in.alybadawy.com"
  ARGOCD_HOST: "argocd.in.alybadawy.com"
  GRAFANA_HOST: "grafana.in.alybadawy.com"
  PROMETHEUS_HOST: "prometheus.in.alybadawy.com"
  NAS_IP: "172.20.20.2"
  NAS_BASE_EXPORT: "/var/nfs"
  NAS_NEXTCLOUD_DATA: "/var/nfs/shared/nextcloud"
  NAS_IMMICH_DATA: "/var/nfs/shared/immich"
  TIMEZONE: "UTC"
  WILDCARD_SECRET: "wildcard-in-alybadawy-com"
```

**C. Longhorn Volumes** (if restoring from backups) — Restored via `ansible/restore-longhorn-volumes.yml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data-lh
  namespace: db
spec:
  storageClassName: longhorn
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 20Gi
```

### 2. Bootstrap: Root Application

The **root app** is the entry point. It's deployed first and orchestrates everything else.

**File:** `k8s/argocd/root-app.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${GITHUB_REPO} # Substituted from cluster-vars ConfigMap
    targetRevision: main
    path: k8s/argocd/apps # All Application CRDs
    plugin:
      name: kustomize-envsubst # Uses CMP plugin for variable substitution
  destination:
    server: https://kubernetes.default.svc # This cluster
    namespace: argocd
  syncPolicy:
    automated:
      prune: true # Delete resources removed from git
      selfHeal: true # Resync if cluster diverges
    syncOptions:
      - CreateNamespace=true # Auto-create namespaces
```

**How it works:**

1. The root app reads `k8s/argocd/apps/kustomization.yaml`
2. Kustomization lists all Applications (db.yaml, cloud.yaml, etc.)
3. The `kustomize-envsubst` CMP plugin processes the Applications:
   - Runs `kustomize build .` on the directory
   - Substitutes environment variables like `${GITHUB_REPO}` using the cluster-vars ConfigMap
   - Outputs the rendered manifests
4. ArgoCD applies all Application CRDs to the cluster
5. Each Application then syncs its own resources

---

### 3. Application CRDs — Defining What to Deploy

Each application stack is defined as an ArgoCD **Application** CRD. These live in `k8s/argocd/apps/`.

**Example: `db.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: db
  namespace: argocd
  labels:
    homelab/stack: db
spec:
  project: default
  source:
    repoURL: ${GITHUB_REPO} # GitHub repo URL
    targetRevision: main # Track main branch
    path: k8s/stacks/db # Directory with kustomization.yaml
    plugin:
      name: kustomize-envsubst # Apply variable substitution
  destination:
    server: https://kubernetes.default.svc
    namespace: db # Deploy to 'db' namespace
  syncPolicy:
    automated:
      prune: true # Remove resources no longer in git
      selfHeal: true # Auto-resync if cluster drifts
    syncOptions:
      - CreateNamespace=true # Auto-create 'db' namespace
```

**When synced, this Application:**

1. Clones the Git repo
2. Reads `k8s/stacks/db/kustomization.yaml`
3. Runs the kustomize-envsubst CMP plugin:
   - Builds the kustomization (combines YAML files)
   - Substitutes variables (${TIMEZONE}, ${PGADMIN_HOST}, etc.)
4. Applies the rendered manifests to the cluster (namespace: db)

---

### 4. The kustomize-envsubst CMP Plugin

The **ConfigManagementPlugin** is the "magic" that enables variable substitution.

**File:** `k8s/argocd/cmp-plugin.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cmp-kustomize-envsubst
  namespace: argocd
data:
  plugin.yaml: |
    apiVersion: argoproj.io/v1alpha1
    kind: ConfigManagementPlugin
    metadata:
      name: kustomize-envsubst
    spec:
      generate:
        command: [sh, -c]
        args:
          # 1. kustomize build . → generates the final manifests
          # 2. awk → substitutes ${VAR} with environment values
          - 'kustomize build . | awk ''...substitution logic...'''
```

**How substitution works:**

1. **Source:** `k8s/stacks/db/postgres.yaml`

   ```yaml
   env:
     - name: TZ
       value: ${TIMEZONE}
   ```

2. **Environment:** cluster-vars ConfigMap provides `TIMEZONE=UTC`

3. **Output:** The CMP substitutes and renders:
   ```yaml
   env:
     - name: TZ
       value: UTC
   ```

**All substitutable variables** (from cluster-vars ConfigMap):

- `${DOMAIN}` → Domain name
- `${GITHUB_REPO}` → Repository URL
- `${TIMEZONE}` → Timezone for applications
- `${NAS_IP}` → NAS server IP address
- `${NAS_BASE_EXPORT}` → NAS base export path
- `${NAS_NEXTCLOUD_DATA}` → Nextcloud data mount point
- `${NAS_IMMICH_DATA}` → Immich data mount point
- `${PGADMIN_HOST}`, `${NEXTCLOUD_HOST}`, `${IMMICH_HOST}`, etc. → Service FQDNs

---

### 5. Application Stacks — Defining Resources

Each stack in `k8s/stacks/` contains a Kustomization + manifests.

**Example: `k8s/stacks/db/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - postgres.yaml
  - redis.yaml
  - pgadmin.yaml
  - ingress.yaml
```

**Example: `k8s/stacks/db/postgres.yaml`**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data-lh
  namespace: db
spec:
  storageClassName: longhorn
  resources:
    requests:
      storage: 20Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: db
spec:
  containers:
    - name: postgres
      image: ghcr.io/immich-app/postgres:14-vectorchord...
      envFrom:
        - secretRef:
            name: postgres-secret # References secret from apply-secrets.yml
      env:
        - name: TZ
          value: ${TIMEZONE} # Substituted by CMP
```

**Example: `k8s/stacks/db/ingress.yaml`**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: pgadmin
  namespace: db
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - ${PGADMIN_HOST} # Substituted → pgadmin.in.alybadawy.com
  rules:
    - host: ${PGADMIN_HOST}
      http:
        paths:
          - path: /
            backend:
              service:
                name: pgadmin
                port:
                  number: 80
```

---

### 6. Helm-based Applications

Some apps use **Helm charts** instead of plain YAML. These use the **`sources` array** (multiple sources).

**Example: `k8s/argocd/apps/infra-ingress-nginx.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: infra-ingress-nginx
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0" # Deploy in wave 0 (first)
spec:
  sources:
    # Source 1: Helm chart from upstream repo
    - repoURL: https://kubernetes.github.io/ingress-nginx
      chart: ingress-nginx
      targetRevision: "*" # Latest version
      helm:
        releaseName: ingress-nginx
        valueFiles:
          - $values/k8s/infrastructure/ingress-nginx/helm-values.yaml
        parameters:
          - name: controller.extraArgs.default-ssl-certificate
            value: "ingress-nginx/${WILDCARD_SECRET}" # Substituted by CMP
    # Source 2: Git repo (for values source reference)
    - repoURL: ${GITHUB_REPO}
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: ingress-nginx
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

**How this works:**

1. Fetches Helm chart `ingress-nginx` from upstream repo
2. Merges helm-values.yaml and helm parameters
3. CMP substitutes `${WILDCARD_SECRET}` before rendering
4. Helm renders the chart with substituted values
5. ArgoCD applies the resulting manifests

---

### 7. Deployment Order — Sync Waves

The `argocd.argoproj.io/sync-wave` annotation controls deployment order.

```yaml
# Wave -1: Root app (highest priority)
root app → syncs all Applications

# Wave 0: Infrastructure that other apps depend on
infra-ingress-nginx → nginx-ingress must be ready for Ingress resources
infra-longhorn      → Longhorn must be ready for PVCs to bind

# Wave 1: Databases and infrastructure services
infra-monitor       → Prometheus/Grafana
db                  → PostgreSQL, Redis, PgAdmin
infra-longhorn-config → Longhorn recurring backup jobs

# Wave 2+: Applications (can now use storage and ingress)
auth                → Authentik (needs db)
cloud               → Nextcloud (needs db, storage, ingress)
immich              → Immich (needs db, storage, ingress)
backup              → Backup CronJobs (needs all services ready)
```

**Order ensures:**

1. Ingress controller is ready before Ingress resources
2. Storage is ready before PVC-dependent apps
3. Databases are ready before apps that depend on them
4. Service-to-service dependencies are satisfied

---

## Full Deployment Workflow

### Step 0: Prerequisites (Ansible)

```bash
# 1. Apply secrets and cluster configuration
ansible-playbook -i ansible/inventory.ini ansible/apply-secrets.yml

# ✓ Creates Kubernetes Secrets in respective namespaces
# ✓ Creates cluster-vars ConfigMap in argocd namespace
# ✓ Optionally restores Longhorn volumes from backups
```

### Step 1: Install ArgoCD

```bash
# Create argocd Helm application manifest (not yet created)
# This would deploy ArgoCD itself using Helm
# Must be deployed manually or via separate bootstrap playbook
```

### Step 2: Bootstrap with Root App

```bash
# Apply the root Application CRD
kubectl apply -f k8s/argocd/root-app.yaml

# ✓ Root app reads k8s/argocd/apps/kustomization.yaml
# ✓ kustomize-envsubst CMP processes all Applications
# ✓ All Application CRDs are rendered and applied
# ✓ ArgoCD begins syncing each Application
```

### Step 3: ArgoCD Syncs All Applications

**Wave -1:**

```
root → Syncs all Applications from k8s/argocd/apps/
```

**Wave 0:**

```
infra-ingress-nginx → Deploys nginx-ingress controller
infra-longhorn      → Deploys Longhorn distributed storage
```

**Wave 1:**

```
db                → PostgreSQL, Redis, PgAdmin
infra-monitor     → Prometheus, Grafana
infra-longhorn-config → Longhorn backup jobs
```

**Wave 2:**

```
auth      → Authentik (uses db, ingress)
cloud     → Nextcloud (uses db, storage, ingress)
immich    → Immich (uses db, storage, ingress)
whoami    → Simple test app
backup    → CronJob backups
```

### Step 4: Continuous GitOps

After initial sync, ArgoCD continuously monitors:

1. **Git Repository** — Every commit triggers a sync

   ```bash
   # Change something in git
   git commit -am "Update Nextcloud memory limits"
   git push

   # ArgoCD detects the change
   # Syncs the updated manifests to the cluster
   ```

2. **Cluster State** — If someone manually changes the cluster

   ```bash
   # Manual change (not recommended)
   kubectl patch deployment nextcloud -n cloud --patch '{"spec":{"replicas":2}}'

   # ArgoCD detects drift
   # With selfHeal: true, automatically reverts to git state
   ```

---

## Important Concepts

### Idempotency & Drift Detection

- **All changes go through git** — no manual `kubectl apply`
- **ArgoCD watches git** — automatic syncs on commits
- **selfHeal: true** — auto-reverts manual cluster changes
- **prune: true** — deletes resources removed from git

### Secret Management

- **Secrets in Git:** Never commit actual secret values
- **Secrets in Cluster:** Created separately via `apply-secrets.yml`
- **References:** Manifests reference secrets by name:
  ```yaml
  envFrom:
    - secretRef:
        name: postgres-secret # References secret created by apply-secrets.yml
  ```

### Variable Substitution

- **Source:** cluster-vars ConfigMap in argocd namespace
- **Method:** kustomize-envsubst CMP plugin
- **Timing:** Substitution happens at sync time, not commit time
- **Safety:** Only affects rendered output; git always contains `${VAR}` syntax

### Helm Integration

- **Upstream Charts:** Helm fetches charts from upstream repos
- **Git Values:** Helm values can come from git
- **CMP Substitution:** Variable substitution happens after Helm rendering
- **Parameter Override:** Specific values can be overridden via `helm.parameters`

---

## Adding New Applications

To deploy a new application, follow this workflow:

### 1. Create Stack Directory

```bash
mkdir -p k8s/stacks/myapp
cd k8s/stacks/myapp
```

### 2. Create Application Manifests

```bash
# deployment.yaml, service.yaml, ingress.yaml, etc.
cat > kustomization.yaml << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
  - ingress.yaml
EOF
```

### 3. Use Variables in Manifests

```yaml
# ingress.yaml
spec:
  tls:
    - hosts:
        - ${MYAPP_HOST}
  rules:
    - host: ${MYAPP_HOST}
```

### 4. Create Application CRD

```bash
cat > k8s/argocd/apps/myapp.yaml << EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${GITHUB_REPO}
    targetRevision: main
    path: k8s/stacks/myapp
    plugin:
      name: kustomize-envsubst
  destination:
    server: https://kubernetes.default.svc
    namespace: myapp
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
```

### 5. Register Application

```bash
# Edit k8s/argocd/apps/kustomization.yaml
# Add to resources:
# - myapp.yaml

# Commit to git
git add k8s/
git commit -m "Add myapp to GitOps"
git push
```

### 6. ArgoCD Syncs Automatically

```bash
# ArgoCD detects the new Application
# Syncs k8s/stacks/myapp/ to the cluster
# Creates namespace and all resources
```

---

## Making Changes

### Update an Application

```bash
# Edit the manifest
vim k8s/stacks/db/postgres.yaml

# Commit and push
git add k8s/stacks/db/postgres.yaml
git commit -m "Update Postgres memory limit to 2Gi"
git push

# ArgoCD automatically syncs (within 3 minutes by default)
# Check sync status in ArgoCD UI or CLI
argocd app list
argocd app sync db  # Force immediate sync (optional)
```

### Update ArgoCD Configuration

```bash
# Edit the Helm values or CMP configuration
vim k8s/argocd/helm-values.yaml

# Note: Requires a separate Helm upgrade, not synced by root app
# (because root app can't upgrade itself)
```

### Update a Helm Chart Version

```bash
# Edit the Application CRD
vim k8s/argocd/apps/infra-longhorn.yaml
# Change targetRevision: "~1.6.0" to "~1.7.0"

git add k8s/argocd/apps/infra-longhorn.yaml
git commit -m "Upgrade Longhorn to ~1.7.0"
git push

# ArgoCD automatically syncs the new chart version
```

---

## Troubleshooting

### Check Application Status

```bash
kubectl get applications -n argocd -o wide
kubectl describe application db -n argocd
```

### Check Sync Status

```bash
argocd app list
argocd app status db
argocd app sync db --force
```

### View CMP Plugin Logs

```bash
# CMP runs as a sidecar in argocd-repo-server
kubectl logs -n argocd -c kustomize-envsubst deployment/argocd-repo-server
```

### Test Variable Substitution

```bash
# Manually test the CMP plugin
cd k8s/stacks/db
kustomize build . | awk '{result=""; line=$0; while(match(line,/\$[{][A-Za-z_][A-Za-z0-9_]*[}]/)){v=substr(line,RSTART+2,RLENGTH-3); result=result substr(line,1,RSTART-1) ((v in ENVIRON)?ENVIRON[v]:substr(line,RSTART,RLENGTH)); line=substr(line,RSTART+RLENGTH)}; print result line}'
```

### ArgoCD UI Access

```bash
# Forward ArgoCD web UI
kubectl port-forward -n argocd svc/argocd-server 8080:443

# Access at http://localhost:8080
# Username: admin
# Password: kubectl get secret argocd-initial-admin-secret -n argocd -o json | jq -r .data.password | base64 -d
```

---

## Summary

Your GitOps setup is a **three-tier system**:

1. **Tier 1: Secrets & Config** — Created by Ansible before ArgoCD
   - Kubernetes Secrets (sensitive data)
   - cluster-vars ConfigMap (environment variables)
   - Longhorn Volumes (restored data)

2. **Tier 2: ArgoCD Bootstrap** — Root application syncs all apps
   - Root app reads Application CRDs from git
   - kustomize-envsubst CMP substitutes variables
   - Sync waves control deployment order

3. **Tier 3: Applications** — Fully declarative
   - Kustomize-based YAML stacks
   - Helm-based infrastructure components
   - Automated variable substitution
   - Continuous drift detection & auto-healing

**Everything is in git.** Every change, every configuration, every application deployment goes through the repository. This enables disaster recovery, environment reproducibility, and a complete audit trail of infrastructure changes.
