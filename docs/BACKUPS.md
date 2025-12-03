# Backup and Recovery Guide

Complete documentation for the homelab backup strategy, including automated backups, manual procedures, and disaster recovery.

## Table of Contents

- [Backup Architecture Overview](#backup-architecture-overview)
- [What Gets Backed Up](#what-gets-backed-up)
- [Automated Backups](#automated-backups)
  - [Longhorn Volume Backups](#longhorn-volume-backups)
  - [Database Backups (CronJob)](#database-backups-cronjob)
- [Storage Location](#storage-location)
- [Monitoring Backups](#monitoring-backups)
- [Manual Backup Procedures](#manual-backup-procedures)
- [Restore Procedures](#restore-procedures)
- [Disaster Recovery](#disaster-recovery)
- [Troubleshooting](#troubleshooting)

---

## Backup Architecture Overview

The homelab uses a **layered backup strategy** with two complementary systems:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         BACKUP ARCHITECTURE                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    LAYER 1: LONGHORN BACKUPS                         │   │
│  │                                                                       │   │
│  │   All Kubernetes Persistent Volumes (PVCs)                           │   │
│  │   ├── Local Snapshots (in-cluster, fast recovery)                   │   │
│  │   │   └── Daily at 2:00 AM, retain 7 days                           │   │
│  │   │   └── Weekly on Sunday 3:00 AM, retain 4 weeks                  │   │
│  │   │                                                                   │   │
│  │   └── Remote Backups (to NAS, disaster recovery)                    │   │
│  │       └── Daily at 2:30 AM, retain 7 days                           │   │
│  │       └── Weekly on Sunday 3:30 AM, retain 4 weeks                  │   │
│  │                                                                       │   │
│  │   Covers: All application data, databases, logs, configs            │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    LAYER 2: DATABASE DUMPS                           │   │
│  │                                                                       │   │
│  │   PostgreSQL SQL Dumps (portable, readable)                          │   │
│  │   └── Daily at 4:00 AM, retain 7 days                               │   │
│  │                                                                       │   │
│  │   Databases:                                                          │   │
│  │   ├── Authentik (SSO/identity - CRITICAL)                           │   │
│  │   └── Outline (documentation wiki)                                   │   │
│  │                                                                       │   │
│  │   Why both Longhorn + SQL dumps?                                     │   │
│  │   - Longhorn: Fast, full-state restore                              │   │
│  │   - SQL dumps: Portable, version-independent, auditable             │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    BACKUP DESTINATION                                │   │
│  │                                                                       │   │
│  │   UniFi NAS (192.168.1.234)                                          │   │
│  │   └── NFS Share: /var/nfs/shared/Shared_Drive_Example/k8s-backup    │   │
│  │   └── Direct mount from all cluster nodes                            │   │
│  │   └── No proxy needed - nodes have NAS IP access                    │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Why Two Backup Layers?

| Aspect | Longhorn Backups | SQL Dumps |
|--------|------------------|-----------|
| **Speed** | Fast (block-level) | Slower (logical) |
| **Granularity** | Point-in-time volume state | Schema + data |
| **Portability** | Requires Longhorn | Any PostgreSQL |
| **Recovery** | Restore entire volume | Selective restore possible |
| **Verification** | Binary check | Human-readable SQL |
| **Use Case** | Quick recovery | Migration, audit, selective restore |

---

## What Gets Backed Up

### Longhorn Volume Backups (Complete State)

Every Persistent Volume Claim (PVC) in the cluster is automatically backed up:

| Application | Namespace | Volume | Size | Contains |
|-------------|-----------|--------|------|----------|
| Authentik | authentik | authentik-db-1 | 10Gi | SSO database, users, providers |
| Outline | outline | outline-db-1 | 5Gi | Wiki database, documents |
| Outline | outline | outline-data | 5Gi | File uploads, attachments |
| n8n | n8n | n8n-db-1 | 5Gi | Workflow database |
| n8n | n8n | n8n-data | 5Gi | Workflow files, credentials |
| Open WebUI | open-webui | open-webui-db-1 | 5Gi | Chat history, settings |
| Open WebUI | open-webui | open-webui-data | 10Gi | Uploaded files, embeddings |
| Plane | plane | plane-pgdb-* | 10Gi | Project management data |
| Plane | plane | plane-minio-* | 10Gi | File storage |
| Campfire | campfire | campfire-storage | 5Gi | Chat messages, files |
| Grafana | monitoring | grafana-db-1 | 2Gi | Dashboards, settings |
| Loki | monitoring | storage-loki-0 | 10Gi | Log data |

### Database SQL Dumps (Portable Backups)

Critical databases are also exported as SQL dumps for portability:

| Database | Service | Backed Up | Priority |
|----------|---------|-----------|----------|
| Authentik | authentik-db-rw.authentik.svc | Yes | **CRITICAL** |
| Outline | outline-db-rw.outline.svc | Yes | High |
| n8n | n8n-db-rw.n8n.svc | No (via Longhorn) | Medium |
| Open WebUI | open-webui-db-rw.open-webui.svc | No (via Longhorn) | Medium |
| Grafana | grafana-db-rw.monitoring.svc | No (via Longhorn) | Low |

**Why only Authentik and Outline?**
- Authentik: SSO is the authentication backbone - losing it locks everyone out
- Outline: Documentation is critical for operational knowledge
- Others: Recoverable from Longhorn or less critical

---

## Automated Backups

### Longhorn Volume Backups

Longhorn automatically backs up all volumes using recurring jobs defined in `infrastructure/backups/longhorn-recurring-jobs.yaml`:

#### Local Snapshots (In-Cluster)

Snapshots stay on cluster nodes for fast recovery from accidental changes.

| Job | Schedule | Retention | Purpose |
|-----|----------|-----------|---------|
| daily-snapshot | 2:00 AM daily | 7 snapshots | Quick rollback |
| weekly-snapshot | 3:00 AM Sunday | 4 snapshots | Weekly restore points |

**What are snapshots?**
- Point-in-time copies of volume data
- Stored on cluster nodes (not external)
- Instant recovery (no network transfer)
- Use for: "Oops I deleted something" situations

#### Remote Backups (To NAS)

Backups are exported to the UniFi NAS for disaster recovery.

| Job | Schedule | Retention | Purpose |
|-----|----------|-----------|---------|
| daily-backup | 2:30 AM daily | 7 backups | Daily off-site recovery |
| weekly-backup | 3:30 AM Sunday | 4 backups | Weekly archive |

**What are backups?**
- Complete volume data exported to NFS
- Stored on UniFi NAS (external to cluster)
- Survive complete cluster loss
- Use for: Disaster recovery, cluster rebuild

#### Configuration

```yaml
# infrastructure/backups/longhorn-recurring-jobs.yaml
---
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: daily-backup
  namespace: longhorn-system
spec:
  name: daily-backup
  task: backup          # "backup" = to NAS, "snapshot" = local only
  cron: "30 2 * * *"    # 2:30 AM daily
  retain: 7             # Keep last 7 backups
  concurrency: 2        # Process 2 volumes at a time
  groups:
    - default           # Applies to all volumes in "default" group
```

#### Backup Target Configuration

```yaml
# apps/argocd/applications/longhorn-helm.yaml
defaultSettings:
  backupTarget: nfs://192.168.1.234:/var/nfs/shared/Shared_Drive_Example/k8s-backup
```

### Database Backups (CronJob)

A Kubernetes CronJob runs daily to create SQL dumps:

**Location:** `infrastructure/backups/backup-cronjob.yaml`

| Setting | Value |
|---------|-------|
| Schedule | 4:00 AM daily |
| Namespace | longhorn-system |
| Databases | Authentik, Outline |
| Retention | 7 days |
| Output | `/backup/homelab-YYYYMMDD-HHMMSS/` |

#### How It Works

1. CronJob creates a pod at 4:00 AM
2. Pod mounts NAS directly via NFS
3. Runs `pg_dump` for each database
4. Saves SQL files to timestamped directory
5. Removes directories older than 7 days
6. Pod terminates

#### Backup Directory Structure

```
/var/nfs/shared/Shared_Drive_Example/k8s-backup/
├── homelab-20241203-040001/
│   ├── authentik-db.sql    # Authentik database dump
│   └── outline-db.sql      # Outline database dump
├── homelab-20241202-040002/
│   ├── authentik-db.sql
│   └── outline-db.sql
└── ... (up to 7 directories)
```

---

## Storage Location

All backups go to the UniFi NAS:

| Property | Value |
|----------|-------|
| NAS IP | 192.168.1.234 |
| NFS Path | /var/nfs/shared/Shared_Drive_Example/k8s-backup |
| Protocol | NFSv3 (NFSv4 not supported by UNAS) |
| Access | Direct from all cluster nodes |
| Allowed IPs | 192.168.1.103, 192.168.1.117, 192.168.1.167, 192.168.1.49, 192.168.1.94 |

### NAS Directory Layout

```
/k8s-backup/
├── backupstore/              # Longhorn backup data
│   ├── backup_xxx/           # Individual volume backups
│   ├── volume_xxx/           # Volume metadata
│   └── ...
└── homelab-YYYYMMDD-HHMMSS/  # Database SQL dumps
    ├── authentik-db.sql
    └── outline-db.sql
```

### Why No NFS Proxy?

Previously, an NFS proxy pod ran on the `neko` node because the NAS only allowed one client IP. This was removed because:

1. **Complexity** - Extra moving part that could fail
2. **Single point of failure** - If neko went down, no backups
3. **Better solution** - Added all node IPs to NAS allowed list

Now all nodes mount the NAS directly, simplifying the architecture.

---

## Monitoring Backups

### Check Longhorn Backups

#### Via Longhorn UI

1. Go to https://longhorn.lab.axiomlayer.com
2. Click **Backup** in the left sidebar
3. See all volumes and their backup status
4. Click a volume to see backup history

#### Via Command Line

```bash
# List all recurring jobs
kubectl get recurringjobs -n longhorn-system

# Check backup target health
kubectl get settings backup-target -n longhorn-system -o jsonpath='{.value}'

# List recent backups
kubectl get backups -n longhorn-system --sort-by=.metadata.creationTimestamp | tail -20

# Check backup target connectivity
kubectl get backuptarget -n longhorn-system default -o yaml

# Get volume backup status
kubectl get volumes -n longhorn-system -o custom-columns=\
NAME:.metadata.name,\
STATE:.status.state,\
ROBUSTNESS:.status.robustness,\
LAST-BACKUP:.status.lastBackup
```

### Check Database Backup CronJob

```bash
# Check CronJob status
kubectl get cronjob homelab-backup -n longhorn-system

# Check last run time
kubectl get cronjob homelab-backup -n longhorn-system -o jsonpath='{.status.lastSuccessfulTime}'

# List recent jobs
kubectl get jobs -n longhorn-system -l app.kubernetes.io/name=homelab-backup

# View logs from last backup
kubectl logs -n longhorn-system -l app.kubernetes.io/name=homelab-backup --tail=100
```

### Verify Backup Files

```bash
# Create a temporary pod to check NAS contents
kubectl run backup-check --rm -it --image=busybox --restart=Never -- sh

# Inside the pod:
mount -t nfs 192.168.1.234:/var/nfs/shared/Shared_Drive_Example/k8s-backup /mnt
ls -la /mnt
ls -la /mnt/homelab-*/
exit
```

---

## Manual Backup Procedures

### Trigger Manual Longhorn Backup

#### Via UI (Recommended for Non-Technical Users)

1. Open https://longhorn.lab.axiomlayer.com
2. Click **Volume** in the left sidebar
3. Find the volume you want to backup
4. Click the **vertical three dots** menu on the right
5. Select **Create Backup**
6. Confirm the backup

#### Via Command Line

```bash
# Backup a specific volume
VOLUME=pvc-xxxxx-xxxxx  # Get from: kubectl get volumes -n longhorn-system

# Create snapshot first
kubectl -n longhorn-system exec -it $(kubectl get pods -n longhorn-system -l app=longhorn-manager -o jsonpath='{.items[0].metadata.name}') -- \
  longhorn-manager snapshot create $VOLUME

# Then create backup from snapshot
kubectl -n longhorn-system exec -it $(kubectl get pods -n longhorn-system -l app=longhorn-manager -o jsonpath='{.items[0].metadata.name}') -- \
  longhorn-manager backup create $VOLUME
```

### Trigger Manual Database Backup

```bash
# Create a one-off job from the CronJob
kubectl create job --from=cronjob/homelab-backup homelab-backup-manual-$(date +%s) -n longhorn-system

# Watch the job
kubectl logs -n longhorn-system -l job-name=homelab-backup-manual-$(date +%s) --follow

# Verify completion
kubectl get jobs -n longhorn-system | grep manual
```

### Full Manual Backup Script

For comprehensive manual backup (use before major changes):

```bash
#!/bin/bash
# Save as: scripts/manual-backup.sh

set -e
DATE=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$HOME/homelab-backups/$DATE"
mkdir -p "$BACKUP_DIR"

echo "=== Manual Homelab Backup - $DATE ==="

# 1. Backup Sealed Secrets keys (CRITICAL)
echo "Backing up Sealed Secrets keys..."
kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > "$BACKUP_DIR/sealed-secrets-keys.yaml"

# 2. Backup etcd (K3s snapshot)
echo "Creating etcd snapshot..."
ssh neko "sudo k3s etcd-snapshot save --name manual-backup-$DATE"
ssh neko "sudo cp /var/lib/rancher/k3s/server/db/snapshots/manual-backup-$DATE* /tmp/"
scp neko:/tmp/manual-backup-$DATE* "$BACKUP_DIR/"

# 3. Trigger Longhorn backup for all volumes
echo "Triggering Longhorn backups..."
for vol in $(kubectl get volumes -n longhorn-system -o jsonpath='{.items[*].metadata.name}'); do
  echo "  Backing up $vol..."
  kubectl annotate volume -n longhorn-system $vol recurring-job-group.longhorn.io/manual-backup="true" --overwrite || true
done

# 4. Create fresh database dumps
echo "Creating database dumps..."
kubectl create job --from=cronjob/homelab-backup homelab-backup-$DATE -n longhorn-system

# 5. Export current state
echo "Exporting Kubernetes resources..."
kubectl get all,configmaps,secrets,pvc,ingress,certificates -A -o yaml > "$BACKUP_DIR/cluster-resources.yaml"

# 6. Copy .env file
echo "Backing up environment file..."
cp "$HOME/axiomlayer/.env" "$BACKUP_DIR/.env" 2>/dev/null || echo "No .env file found"

echo ""
echo "=== Backup Complete ==="
echo "Location: $BACKUP_DIR"
ls -la "$BACKUP_DIR"
```

---

## Restore Procedures

### Restore Longhorn Volume

#### Via UI (Recommended)

1. Go to https://longhorn.lab.axiomlayer.com
2. Click **Backup** in left sidebar
3. Find the volume you want to restore
4. Click the backup you want to restore from
5. Click **Restore Latest Backup** or select a specific backup
6. Enter a **new volume name** (e.g., `restored-authentik-db`)
7. Click **OK**
8. Wait for volume to show "detached" state

#### After UI Restore: Attach Volume to Application

After restoring in UI, you need to point your application to the new volume:

```bash
# 1. Scale down the application
kubectl scale deployment/authentik-server -n authentik --replicas=0
kubectl scale deployment/authentik-worker -n authentik --replicas=0

# 2. Note the restored volume name from Longhorn UI (e.g., restored-authentik-db)
RESTORED_VOL=restored-authentik-db
NAMESPACE=authentik
PVC_NAME=data-authentik-db-1
SIZE=10Gi

# 3. Create PersistentVolume pointing to restored volume
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${RESTORED_VOL}
spec:
  capacity:
    storage: ${SIZE}
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Delete
  storageClassName: longhorn
  csi:
    driver: driver.longhorn.io
    fsType: ext4
    volumeHandle: ${RESTORED_VOL}
EOF

# 4. Delete old PVC (WARNING: This deletes the old broken volume!)
kubectl delete pvc ${PVC_NAME} -n ${NAMESPACE}

# 5. Create new PVC bound to restored volume
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  volumeName: ${RESTORED_VOL}
  resources:
    requests:
      storage: ${SIZE}
EOF

# 6. Scale application back up
kubectl scale deployment/authentik-server -n authentik --replicas=1
kubectl scale deployment/authentik-worker -n authentik --replicas=1

# 7. Verify
kubectl get pods -n authentik -w
```

### Restore Database from SQL Dump

Use this when you need to restore specific data or migrate between PostgreSQL versions.

```bash
# 1. Find available backups
kubectl run backup-check --rm -it --image=busybox --restart=Never -- sh -c \
  "mount -t nfs 192.168.1.234:/var/nfs/shared/Shared_Drive_Example/k8s-backup /mnt && ls -la /mnt/homelab-*/"

# 2. Copy backup to local machine
BACKUP_DATE=20241203-040001
kubectl run backup-copy --rm -it --image=postgres:16-alpine --restart=Never -- sh -c \
  "apk add --no-cache nfs-utils && \
   mount -t nfs 192.168.1.234:/var/nfs/shared/Shared_Drive_Example/k8s-backup /mnt && \
   cat /mnt/homelab-${BACKUP_DATE}/authentik-db.sql" > /tmp/authentik-db.sql

# 3. Restore to database
# Get primary pod name
PRIMARY_POD=$(kubectl get pods -n authentik -l cnpg.io/cluster=authentik-db,cnpg.io/instanceRole=primary -o name | head -1)

# Copy backup to pod
kubectl cp /tmp/authentik-db.sql authentik/${PRIMARY_POD#pod/}:/tmp/authentik-db.sql

# Restore (WARNING: This overwrites existing data!)
kubectl exec -n authentik ${PRIMARY_POD#pod/} -- psql -U authentik -d authentik -f /tmp/authentik-db.sql

# Cleanup
kubectl exec -n authentik ${PRIMARY_POD#pod/} -- rm /tmp/authentik-db.sql
```

### Restore Application-Specific Guides

See [Disaster Recovery](#disaster-recovery) for application-specific procedures.

---

## Disaster Recovery

### Scenario 1: Single Application Data Loss

**Symptoms:** Application shows "data not found" or database corruption errors.

**Recovery:**

1. Check Longhorn UI for recent backup of the application's volume
2. Follow [Restore Longhorn Volume](#restore-longhorn-volume) procedure
3. Verify application functionality

**Time to recover:** 10-30 minutes

### Scenario 2: Database Corruption

**Symptoms:** Application errors, "relation does not exist" errors.

**Recovery Options:**

**Option A: Restore from Longhorn (fastest)**
- Use if corruption just happened
- Restores exact database state from backup time
- Follow [Restore Longhorn Volume](#restore-longhorn-volume)

**Option B: Restore from SQL dump (safest)**
- Use if you need a clean slate
- Allows selective data recovery
- Follow [Restore Database from SQL Dump](#restore-database-from-sql-dump)

**Time to recover:** 15-45 minutes

### Scenario 3: Node Failure

**Symptoms:** One node offline, pods rescheduling.

**Impact:** Minimal - Longhorn replicas ensure data availability.

**Recovery:**
1. Longhorn automatically rebuilds replicas on remaining nodes
2. Pods reschedule to healthy nodes
3. No manual intervention needed unless node is permanently lost

**If node permanently lost:**
```bash
# Remove failed node from cluster
kubectl delete node <failed-node>

# Longhorn will rebuild replicas on remaining nodes
kubectl get volumes -n longhorn-system -w
```

**Time to recover:** Automatic (5-30 minutes for replica rebuild)

### Scenario 4: Complete Cluster Loss

**Symptoms:** All nodes down, cluster unrecoverable.

**Recovery:**

1. **Rebuild K3s cluster**
   ```bash
   # On first control plane node
   ./scripts/provision-k3s-server.sh --init

   # On additional control plane nodes
   ./scripts/provision-k3s-server.sh --join <first-node-ip>

   # On worker nodes
   ./scripts/provision-k3s-agent.sh <control-plane-ip>
   ```

2. **Restore Sealed Secrets keys (CRITICAL)**
   ```bash
   # From encrypted USB backup or secure storage
   kubectl apply -f sealed-secrets-keys.yaml
   kubectl rollout restart deployment/sealed-secrets-controller -n kube-system
   ```

3. **Install ArgoCD and sync**
   ```bash
   ./scripts/bootstrap-argocd.sh
   # ArgoCD will pull all applications from Git
   ```

4. **Restore Longhorn and volumes**
   ```bash
   # Longhorn installs via ArgoCD
   # Configure backup target
   kubectl patch settings -n longhorn-system backup-target \
     --type=merge -p '{"value":"nfs://192.168.1.234:/var/nfs/shared/Shared_Drive_Example/k8s-backup"}'

   # Restore volumes from backup (via UI recommended)
   # For each application:
   # 1. Open Longhorn UI → Backup
   # 2. Find volume → Restore
   # 3. Create PV/PVC pointing to restored volume
   ```

5. **Verify all applications**
   ```bash
   kubectl get applications -n argocd
   kubectl get pods -A
   ./tests/smoke-test.sh
   ```

**Time to recover:** 2-4 hours

### Scenario 5: Authentik (SSO) Failure

**Symptoms:** Cannot log in to any application.

**Impact:** HIGH - Authentik is authentication for all apps.

**Recovery:**

1. **Quick fix: Restart Authentik**
   ```bash
   kubectl rollout restart deployment -n authentik
   ```

2. **If data loss: Restore from backup**
   ```bash
   # Restore Longhorn volume (recommended)
   # Or restore from SQL dump
   ```

3. **If total loss: Rebuild from scratch**
   ```bash
   # Delete and recreate Authentik
   kubectl delete application authentik authentik-helm -n argocd
   kubectl apply -f apps/argocd/applications/authentik*.yaml

   # Re-seal secrets with fresh configuration
   # Reconfigure all OAuth2 providers
   # Update client secrets in all applications
   ```

**Time to recover:** 15 minutes (restart) to 2 hours (full rebuild)

---

## Troubleshooting

### Backup Job Not Running

```bash
# Check CronJob status
kubectl get cronjob homelab-backup -n longhorn-system

# Check for suspended CronJob
kubectl get cronjob homelab-backup -n longhorn-system -o jsonpath='{.spec.suspend}'

# Check recent jobs
kubectl get jobs -n longhorn-system -l app.kubernetes.io/name=homelab-backup

# Check job logs
kubectl logs -n longhorn-system -l app.kubernetes.io/name=homelab-backup --tail=100

# Manually trigger backup to test
kubectl create job --from=cronjob/homelab-backup test-backup -n longhorn-system
kubectl logs -n longhorn-system -l job-name=test-backup --follow
```

### Longhorn Backup Failing

```bash
# Check backup target
kubectl get settings backup-target -n longhorn-system -o jsonpath='{.value}'

# Check backup target status
kubectl get backuptarget -n longhorn-system default -o yaml

# Test NFS connectivity
kubectl run nfs-test --rm -it --image=busybox --restart=Never -- sh -c \
  "mount -t nfs -o nfsvers=3,nolock 192.168.1.234:/var/nfs/shared/Shared_Drive_Example/k8s-backup /mnt && ls /mnt"

# Check Longhorn manager logs
kubectl logs -n longhorn-system -l app=longhorn-manager --tail=100 | grep -i backup
```

### NAS Mount Failures

```bash
# Test NFS from a node
ssh neko "showmount -e 192.168.1.234"

# Check allowed IPs on NAS
# Go to NAS UI → Settings → NFS → Exports

# Test manual mount
ssh neko "sudo mount -t nfs -o nfsvers=3 192.168.1.234:/var/nfs/shared/Shared_Drive_Example/k8s-backup /mnt/test && ls /mnt/test"
```

### Database Dump Failures

```bash
# Check database connectivity
kubectl exec -n authentik authentik-db-1 -- pg_isready

# Test pg_dump manually
kubectl exec -n authentik authentik-db-1 -- pg_dump -U authentik authentik | head -100

# Check backup job environment variables
kubectl get cronjob homelab-backup -n longhorn-system -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env}'
```

### Restore Not Working

```bash
# Check restored volume status
kubectl get volumes -n longhorn-system | grep restored

# Check PV/PVC binding
kubectl get pv,pvc -n <namespace>

# Check pod events
kubectl describe pod <pod-name> -n <namespace>

# Check volume attachment
kubectl get volumeattachments
```

---

## Related Documentation

- [RUNBOOKS.md](RUNBOOKS.md) - Operational procedures
- [INFRASTRUCTURE.md](INFRASTRUCTURE.md) - Longhorn and storage details
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - General troubleshooting
- [encrypted-backup-recovery.md](encrypted-backup-recovery.md) - USB backup encryption
