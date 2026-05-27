# ADR-001: Consolidate PVCs to NFS via nfs-subdir-external-provisioner

**Status:** Proposed  
**Date:** 2026-05-27  
**Deciders:** Aly  

---

## Context

Currently running mixed storage:
- **Longhorn** backing multiple PVCs (databases, caches, logs, app data)
- **Local node storage** for some workloads
- **NAS with NFS** already receiving Longhorn backups
- **Capacity**: 600GB used of 4TB NAS, growing 30–50GB/month
- **RTO/RPO**: Zero data loss tolerance (critical)
- **Goals**: Increase capacity, simplify infrastructure, improve replication/snapshots/backups

The proposal is to consolidate all PVCs onto the NAS via `nfs-subdir-external-provisioner`, which dynamically creates subdirectories per PVC on an NFS share.

---

## Decision

**Proposal: Move from Longhorn + local storage to centralized NFS storage via nfs-subdir-external-provisioner**

This decision carries **substantial operational and architectural risks** due to:
1. NAS ALL_SQUASH enforcement conflicting with Kubernetes UID expectations
2. Loss of Longhorn's built-in replication and snapshot orchestration
3. Increased backup/recovery complexity despite consolidation goals
4. Performance and reliability concerns for stateful workloads

---

## Options Considered

### Option A: NFS via nfs-subdir-external-provisioner (Proposed)

| Dimension | Assessment |
|-----------|------------|
| Complexity | **Medium** (provisioner setup is simple, but operational complexity increases due to lost Longhorn features) |
| Cost | Low |
| Scalability | Medium (limited by NAS bandwidth, NFS protocol, and zero-copy performance) |
| Team familiarity | Low (nfs-subdir-external-provisioner is less common than Longhorn or managed block storage) |
| Data durability | Medium (depends entirely on NAS RAID + external backups) |
| RTO/RPO achievability | **High risk** (see consequences below) |

**Pros:**
- Single centralized storage (simpler operational overview)
- Increased capacity (4TB NAS vs Longhorn node capacity limits)
- Lower cost (no additional storage hardware)
- Easier capacity planning (visible on NAS filesystem)
- Natural fit if you already have NAS infrastructure

**Cons:**
- ALL_SQUASH UID mapping will break permission-dependent workloads (databases, stateful apps)
- Network I/O latency higher than block storage (affects databases, caches)
- Loss of Longhorn's orchestrated replication (no cross-node redundancy)
- Loss of Longhorn's built-in snapshot/backup features
- Increased complexity around backup strategy (need external tooling)
- Single point of failure (NAS down = all PVCs down)
- NFS protocol limitations (no distributed locking for HA databases)

---

### Option B: Keep Longhorn + Add NAS-backed Longhorn Replicas

| Dimension | Assessment |
|-----------|------------|
| Complexity | Medium (requires Longhorn NAS backend configuration) |
| Cost | Low |
| Scalability | High |
| Team familiarity | High (you already use Longhorn) |
| Data durability | **High** (multi-replica architecture) |
| RTO/RPO achievability | **High confidence** |

**Pros:**
- Preserves Longhorn's UID/permission handling
- Maintains distributed replication across nodes
- Longhorn can back up to NAS as today, but also replicate to NAS natively
- Better performance for databases and caches
- Built-in snapshot and recovery workflows
- Scales with your cluster (add nodes = add storage)

**Cons:**
- Storage capacity tied to node count
- Requires Longhorn NAS backend (more complex Longhorn setup)
- Higher cost if you need to add nodes for storage

---

### Option C: Hybrid – High-Performance on Longhorn, Archive/Logs on NFS

| Dimension | Assessment |
|-----------|------------|
| Complexity | **High** (requires workload classification and migration strategy) |
| Cost | Low-Medium |
| Scalability | High |
| Team familiarity | Medium |
| Data durability | High |
| RTO/RPO achievability | High (for critical workloads) |

**Pros:**
- Databases and caches stay on Longhorn (best performance + replication)
- Logs and non-critical app data on NFS (saves Longhorn capacity)
- Clear tier-based strategy (hot vs. cold storage)
- Maintains zero-data-loss for critical workloads

**Cons:**
- Operational overhead (managing two storage tiers)
- Workload classification decisions upfront
- Migration complexity (moving PVCs between storage classes)

---

## Risk Deep Dive: ALL_SQUASH Conflict

This is the **highest-severity blocker** for Option A. Here's why:

### The Problem

Your NAS enforces `ALL_SQUASH`, which means:
- All incoming NFS requests are mapped to a single user (e.g., `nobody:65534`)
- The kernel on the NAS ignores UID/GID headers from clients
- Even if your container runs as UID 1000, the NAS sees it as UID 65534

### How This Breaks Workloads

1. **Databases (PostgreSQL, MySQL)**
   - PostgreSQL expects to run as a specific UID (e.g., `postgres:5432`)
   - Data directory ownership matters: `chown postgres:postgres /var/lib/postgresql`
   - With ALL_SQUASH, file ownership is `nobody:nobody`
   - PostgreSQL init scripts check UID and fail: `FATAL: must be run as postgres user`
   - **Result**: Database won't start

2. **Caches (Redis)**
   - Redis data durability relies on correct file permissions
   - AOF (Append-Only File) rewrite requires the owner to match
   - ALL_SQUASH breaks this assumption
   - **Result**: Redis can start but RDB/AOF persistence may fail

3. **Init containers and permission setup**
   - Apps often have init processes that `chown` directories
   - With ALL_SQUASH, `chown` syscalls are silently ignored
   - Init containers succeed but directories remain owned by `nobody`
   - App code then can't read/write
   - **Result**: Silent permission failures, data corruption risk

4. **Volume permission enforcement**
   - Longhorn currently respects Kubernetes security contexts
   - NFS + ALL_SQUASH ignores Kubernetes RBAC/security context entirely
   - **Result**: Workloads expecting isolated permissions lose that guarantee

### Potential Workarounds (All Problematic)

| Workaround | Viability | Issues |
|-----------|-----------|--------|
| Disable ALL_SQUASH on NAS | **Not possible** — you stated it's enforced | Would require NAS admin change (likely not feasible) |
| Run all containers as root | Very low | Security anti-pattern, violates Kubernetes best practices |
| Run all containers as `nobody` | Very low | Breaks app assumptions, cascading failures |
| Use Kubernetes SecurityContext to match NAS UID | Very low | Constrains all workloads to one UID; doesn't solve init container issues |
| Apply `chown` in initContainers constantly | Medium | Workaround, not a solution; masks the real issue; adds startup overhead |

**Verdict**: ALL_SQUASH makes Option A **high-risk for stateful workloads**. This is not a minor inconvenience — it directly threatens your "no data loss" requirement because permission failures can silently corrupt data.

---

## Risk #2: Loss of Replication and Snapshot Orchestration

### Current Longhorn Capabilities
- **Multi-replica architecture**: 2–3 replicas across nodes for durability
- **Orchestrated snapshots**: Built-in snapshot workflow, versioned
- **Volume backups**: Longhorn manages backup scheduling and recovery
- **Self-healing**: If a replica fails, Longhorn re-syncs

### What You Lose with NFS

Switching to NFS means:
1. **No distributed replication** — all data sits in one place (the NAS)
2. **No automatic snapshots** — you must implement external snapshot logic
3. **No backup orchestration** — you're responsible for backup scheduling/retention
4. **No self-healing** — if NAS has a corruption event, there's no recovery path

### Implications for "No Data Loss" Goal

You stated zero data loss tolerance. NFS alone does **not** provide this:
- **NAS RAID protects against disk failure**, but NOT against:
  - NAS firmware bugs → silent corruption
  - Network faults → partial writes
  - Accidental deletion → no versioning
  - Ransomware → NAS becomes infected

**You will need external backup + snapshot strategy.** This increases operational complexity, not decreases it.

---

## Risk #3: Network I/O Latency for Stateful Workloads

### Performance Characteristics

| Workload | Longhorn (block) | NFS (subdir) | Impact |
|----------|------------------|--------------|--------|
| Database writes | <5ms latency | 20–100ms latency | Slower transactions, higher CPU on NAS |
| Cache reads/writes | <2ms latency | 10–50ms latency | Cache hit ratio degradation, app timeout risk |
| Log writes | <5ms latency | 15–50ms latency | Acceptable if buffered |
| Sequential reads | Network speed | Network speed | Similar |

**Critical concern**: Your logs mention databases and caches. Both are **extremely sensitive to latency**. Moving them to NFS may cause:
- Database query timeouts
- Cache misses cascading to DB queries
- Cluster instability if NAS becomes slow (network blip)

---

## Risk #4: Backup Strategy Complexity Increases

### Current State
```
App writes → Longhorn replica 1 (node A)
          → Longhorn replica 2 (node B)
          → Longhorn backup → NAS
```

Longhorn orchestrates all of this.

### Proposed State (NFS Option A)
```
App writes → NFS subdir on NAS
          → (no automatic replication)
          → (no automatic snapshot)
          → (you must implement external backup)
```

**New responsibilities**:
- Implement NFS snapshots (NAS-side, likely manual cron job)
- Implement backup copy-off (NAS → external storage, for disaster recovery)
- Implement restore testing (who validates backups work?)
- Implement retention policy (when to delete old snapshots)

**This contradicts your "simplification" goal.** You're moving complexity from Longhorn (which handles it) to custom tooling (which you must maintain).

---

## Risk #5: Single Point of Failure

| Component | Current (Longhorn) | Proposed (NFS) | Blast Radius |
|-----------|-------------------|----------------|--------------|
| Node failure | Longhorn re-syncs replicas | (N/A — no replicas) | N/A |
| NAS failure | (Backup copy exists) | **All PVCs inaccessible** | All workloads down |
| Network partition | Replicas isolated, eventual consistency | All I/O blocked | All workloads frozen |
| NAS OS crash | (Backup copy exists) | **No fallback** | Complete data loss if no ext. backup |

**Risk**: If your NAS fails or becomes unreachable, your entire cluster becomes inoperable. Longhorn's multi-replica design avoids this.

---

## Risk #6: Kubernetes UID Mapping and SecurityContext Violations

Kubernetes SecurityContext allows you to enforce:
```yaml
securityContext:
  runAsUser: 1000
  runAsGroup: 3000
  fsGroup: 2000
```

With ALL_SQUASH:
- `runAsUser` is ignored (NAS forces `nobody`)
- `fsGroup` is ignored (can't set group ownership)
- The container *thinks* it's running as UID 1000, but filesystem sees UID 65534

This creates a **security trust boundary violation**:
- Workload assumes isolated UID, but isolation is illusory
- Workload assumes file ownership applies, but it doesn't
- Audit logs show workload UID, but actual filesystem owner is different

**This is not just a technical issue — it's a security issue.**

---

## Risk #7: Migration and Rollback Complexity

### Forward Path
1. Provision nfs-subdir-external-provisioner
2. Create new NFS-backed storage class
3. Migrate each PVC (likely requires downtime or dual-write)
4. Decommission Longhorn
5. Wipe old node storage

**Estimated time**: 2–4 hours of cluster coordination

### Rollback Path (If Things Break)
1. Longhorn already gone (backed up to NAS, but recovery is slow)
2. NFS data may be corrupted (permission issues make this likely)
3. Restore from backup requires external backup copy
4. No point-in-time recovery (unlike Longhorn snapshots)

**Estimated recovery time**: 4–8 hours, assuming backups are available

---

## Recommended Path Forward

### Short-term (Next month)
1. **Audit current Longhorn setup** — Which PVCs are using it? Which are local?
2. **Quantify your workloads** — Database size, cache size, log volume
3. **Test nfs-subdir-external-provisioner** — In a dev/test cluster, with ALL_SQUASH enforced
4. **Attempt to run your actual workloads** on the NFS backend and **document all failures**

### Medium-term (Months 2–3)
Based on your audit, choose one of:

**If most workloads fail with NFS (likely):**
→ **Adopt Option B or C**: Keep Longhorn for stateful workloads, explore NFS for logs/non-critical data

**If most workloads tolerate NFS:**
→ **Implement external backup pipeline** before migration (use tools like Velero + restic to backup NFS to external storage)

---

## Consequences

### If You Proceed with Option A (NFS Consolidation)

**What becomes easier:**
- Capacity planning (single shared pool)
- Adding storage (just expand NAS)
- Seeing disk usage (single filesystem)

**What becomes harder:**
- Troubleshooting permission errors (ALL_SQUASH confusion)
- Ensuring zero data loss (manual backup strategy required)
- Database performance and reliability
- Disaster recovery (single point of failure)
- Compliance/audit (UID mapping breaks security context expectations)

**What you'll need to revisit:**
- Backup and recovery SLA (new strategy required)
- Database tuning (higher latency tolerance)
- Monitoring (NAS bandwidth, NFS client CPU, network)
- Security posture (UID mapping implications)

---

## Action Items

- [ ] **Run proof-of-concept**: Deploy nfs-subdir-external-provisioner in test environment
- [ ] **Test actual workloads**: Attempt to run PostgreSQL, Redis, and log collectors on NFS with ALL_SQUASH
- [ ] **Document failures**: Capture all permission/startup errors
- [ ] **Implement backup pipeline**: Design external backup strategy (Velero + object storage, or similar)
- [ ] **Evaluate Option B/C**: Compare performance and operational overhead
- [ ] **Get buy-in**: Align on RTO/RPO and acceptable risk before proceeding

---

## Appendix: ALL_SQUASH Configuration on NAS

If you want to confirm your NAS ALL_SQUASH settings, check the NAS export options:
```bash
# On NAS, typically in /etc/exports or equivalent
/mnt/share *(rw,all_squash,anonuid=65534,anongid=65534)
```

To disable ALL_SQUASH (if possible):
```bash
/mnt/share *(rw,no_all_squash)
```

This would allow Kubernetes UID mapping to work correctly. **However**, if your NAS enforces this policy at a higher level (hardware, VLAN ACLs, etc.), you may not be able to change it via export options alone.

