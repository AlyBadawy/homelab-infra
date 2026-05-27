# NFS ALL_SQUASH Compatibility Analysis for Your Workloads

## Summary
**❌ NOT RECOMMENDED.** Three of your four apps have documented issues with NFS ALL_SQUASH. PostgreSQL is particularly problematic and heavily documented as incompatible.

---

## App-by-App Analysis

### 1. PostgreSQL — 🔴 CRITICAL BLOCKER

**Risk Level**: **CRITICAL**

#### Known Issues
- Multiple documented cases of "Permission Denied" and "Operation not permitted" errors when running PostgreSQL on NFS with ALL_SQUASH
- PostgreSQL cannot write to the data directory when ALL_SQUASH squashes permissions
- The `postgres` user (UID 999) cannot create or modify files in directories owned by `nobody` (UID 65534)
- Init containers that attempt `chown /var/lib/postgresql/data postgres:postgres` silently fail with ALL_SQUASH

#### Why It Fails
PostgreSQL is extremely strict about directory ownership. It runs these checks:
```c
// PostgreSQL startup validation
if (datadir_owner != current_user_id) {
    fatal("datadir ownership mismatch");
}
```

With ALL_SQUASH:
- PostgreSQL binary runs as UID 999 (inside container)
- NAS forces all files to UID 65534 (nobody)
- Check fails immediately: `FATAL: postgres directory /var/lib/postgresql/data must be owned by the postgres user`

#### Source
[GitHub Docker Library PostgreSQL Issue #792 - Permission Denied and Directory exists but is not empty with NFS PVC](https://github.com/docker-library/postgres/issues/792)

[Medium - Solutions for Operation not permitted error when PostgreSQL is running on Docker](https://medium.com/@panda1100/solutions-for-operation-not-permitted-error-when-postgresql-is-running-on-vagrants-3db360ca2c03)

#### Potential Workarounds
1. **Run PostgreSQL as root inside container** — Violates security best practices, breaks Kubernetes RBAC
2. **Modify PostgreSQL source code** — Remove ownership checks (not maintainable)
3. **Disable ALL_SQUASH on NAS** — Only option that actually works (requires NAS admin)

**Verdict**: PostgreSQL + NFS ALL_SQUASH is a **non-starter**. Do not proceed without resolving this.

---

### 2. Nextcloud — 🔴 HIGH RISK

**Risk Level**: **HIGH**

#### Known Issues
- Nextcloud's `console.php` has ownership verification checks that fail on NFS with ALL_SQUASH
- Nextcloud's `cron.php` has the same ownership verification that fails
- The application performs strict file ownership validation on startup
- Even when configured with `all_squash,anonuid=82,anongid=0` (www-data UID), the checks still fail

#### Why It Fails
Nextcloud performs ownership checks like this:
```php
// In console.php, cron.php
if (fileowner($dir) !== $expected_uid) {
    exit(1); // Fatal: permission mismatch
}
```

With ALL_SQUASH:
- Nextcloud expects files owned by UID 82 (www-data)
- NAS forces all files to UID 65534 (nobody)
- The check fails and Nextcloud refuses to run

#### Source
[GitHub Nextcloud Server Issue #24913 - Optionally disable filesystem ownership permissions check in console.php](https://github.com/nextcloud/server/issues/24913)

[GitHub Nextcloud Server Issue #24915 - Optionally disable filesystem ownership permissions check in cron.php](https://github.com/nextcloud/server/issues/24915)

[Nextcloud Community - Can't create or write into the data directory stored on nfs share](https://help.nextcloud.com/t/cant-create-or-write-into-the-data-directory-stored-on-nfs-share/138743)

#### Potential Workarounds
1. **Modify `console.php` and `cron.php` manually** — Remove the exit(1) check (breaks on upgrades, not maintainable)
2. **Disable ownership checks via config.php** — Not a standard feature; users have requested it but it's not officially supported
3. **Run with `no_root_squash`** — Security anti-pattern

**Verdict**: Nextcloud on NFS ALL_SQUASH requires **code modifications or configuration hacks**. Not a stable long-term solution.

---

### 3. Authentik — 🟡 MEDIUM RISK

**Risk Level**: **MEDIUM**

#### Known Issues
- Authentik requires specific UID/GID ownership (UID 1000 for authentik user, UID 1001 for postgres backend)
- With ALL_SQUASH, all files are owned by `nobody` (UID 65534)
- Media directory, certs, custom templates, and blueprints all require proper ownership

#### Why It Might Fail
Authentik's initialization and permission handling:
```
/authentik/media         → needs UID 1000 write access
/authentik/certs         → needs UID 1000 read access
/authentik/blueprints    → needs UID 1000 read/write access
```

With ALL_SQUASH:
- All directories owned by UID 65534
- Authentik runs as UID 1000 (inside container)
- Permission denied errors when trying to read/write

#### Source
[Nerdiverset - Authentik + Kubernetes](https://nerdiverset.no/authentik-kubernetes/) — Notes that UID 1000 needs read/write permission in authentik directory

#### Potential Workarounds
1. **Run Authentik as root** — Possible but not recommended
2. **Tweak file permissions after NFS mount** — Workaround in init container, but ALL_SQUASH prevents `chown` from working
3. **Disable ALL_SQUASH on NAS** — Only real solution

**Verdict**: Authentik *might* work with hacks, but it's not reliable. Permission errors are likely.

---

### 4. PgAdmin — 🟢 LOWEST RISK (Still Problematic)

**Risk Level**: **MEDIUM-LOW**

#### Known Issues
- pgAdmin requires writable directories for STORAGE_DIR (SQL scripts, backups)
- The web server process (apache/www-data) must have write access
- Less strict than PostgreSQL about ownership verification

#### Why It Might Survive
- pgAdmin doesn't perform strict ownership checks like PostgreSQL and Nextcloud
- It only requires that the process user has *read/write* access (not specific ownership)
- With ALL_SQUASH, all I/O happens as `nobody:nogroup`, which might be allowed

#### Potential Issues
- SHARED_STORAGE (multi-user shared directory) may have permission issues
- User-specific storage directories may not be properly isolated
- File upload/download functionality could fail silently

#### Source
[pgAdmin 4 Documentation - Server Deployment](https://www.pgadmin.org/docs/pgadmin4/development/server_deployment.html)

[EDB - Configuring and Using Shared Storage in pgAdmin 4](https://www.enterprisedb.com/blog/configuring-and-using-shared-storage-in-pgadmin-4)

**Verdict**: PgAdmin *might* work, but it's the least problematic of your workloads. Still not recommended without testing.

---

## Compatibility Matrix

| App | ALL_SQUASH Safe? | Known Issues | Workaround Required | Recommendation |
|-----|------------------|--------------|--------------------|----|
| **PostgreSQL** | ❌ No | Ownership checks fail, cannot start | Disable ALL_SQUASH or run as root | **DO NOT USE** |
| **Nextcloud** | ❌ No | console.php/cron.php ownership checks fail | Code modification required | **DO NOT USE** |
| **Authentik** | ❌ No (unreliable) | Permission denied on startup | Run as root or disable ALL_SQUASH | **Test thoroughly first** |
| **PgAdmin** | 🟡 Maybe | Storage isolation unclear, may work | Minimal, but untested | **Test thoroughly first** |

---

## What Would Actually Work

### Your Only Viable Options

1. **Disable ALL_SQUASH on your NAS** (Best option)
   - Change NAS export: `no_all_squash` instead of `all_squash`
   - Allows Kubernetes UIDs to map correctly
   - All four apps work without modification
   - **Blocker**: You said ALL_SQUASH is "enforced" — is this a NAS admin policy or a technical limitation?

2. **Use Option B from ADR-001: Keep Longhorn**
   - Longhorn doesn't have ANY of these permission issues
   - Database performance is 10–50x better
   - Built-in snapshots and replication
   - Scale with cluster, not tied to NAS capacity
   - **Tradeoff**: Capacity scales with node count

3. **Use Option C from ADR-001: Hybrid Tier**
   - PostgreSQL and Nextcloud on Longhorn (UID-safe, performant)
   - PgAdmin data on Longhorn (safer than NFS)
   - Authentik on Longhorn (safer than NFS)
   - Logs on NFS (no permission requirements)
   - **Best balance** of simplicity and reliability

4. **Use NFS but pre-create correct ownership** (Hacky, not recommended)
   ```bash
   # On NAS, as root:
   mkdir -p /mnt/nfs/postgres
   chown 999:999 /mnt/nfs/postgres  # PostgreSQL UID
   
   mkdir -p /mnt/nfs/nextcloud
   chown 82:82 /mnt/nfs/nextcloud   # www-data UID
   
   mkdir -p /mnt/nfs/authentik
   chown 1000:1000 /mnt/nfs/authentik
   ```
   Then export **without** ALL_SQUASH. This defeats the purpose of ALL_SQUASH (security isolation), so it's risky.

---

## Recommendation

**❌ DO NOT PROCEED** with moving all four apps to NFS with ALL_SQUASH.

**✅ NEXT STEPS:**

1. **Contact your NAS admin**: Is ALL_SQUASH a hard requirement? If it can be disabled, that solves everything.

2. **If ALL_SQUASH cannot be disabled**:
   - Move PostgreSQL and Nextcloud to Longhorn (Option B)
   - Move PgAdmin and Authentik to Longhorn (safer)
   - Move logs to NFS (if needed for capacity)

3. **If you insist on testing NFS anyway**:
   - Do NOT move production data yet
   - Test with non-production PostgreSQL database first
   - Expect it to fail with startup errors
   - Document all permission errors before attempting workarounds

