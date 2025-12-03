# Disaster Recovery Guide

Step-by-step procedures for recovering from various failure scenarios, written for operators of any technical level.

## Table of Contents

- [Quick Reference: What Failed?](#quick-reference-what-failed)
- [Before You Start](#before-you-start)
- [Scenario 1: Application Not Working](#scenario-1-application-not-working)
- [Scenario 2: Database Problem](#scenario-2-database-problem)
- [Scenario 3: Single Node Down](#scenario-3-single-node-down)
- [Scenario 4: Storage Issue](#scenario-4-storage-issue)
- [Scenario 5: Cannot Log In (SSO Down)](#scenario-5-cannot-log-in-sso-down)
- [Scenario 6: Complete Cluster Failure](#scenario-6-complete-cluster-failure)
- [Application-Specific Recovery](#application-specific-recovery)
- [Recovery Verification Checklist](#recovery-verification-checklist)

---

## Quick Reference: What Failed?

Use this table to find the right recovery procedure:

| Symptom | Likely Cause | Go To |
|---------|--------------|-------|
| One app shows errors | Application issue | [Scenario 1](#scenario-1-application-not-working) |
| App shows "database error" | Database problem | [Scenario 2](#scenario-2-database-problem) |
| Multiple apps slow/failing | Node down | [Scenario 3](#scenario-3-single-node-down) |
| Apps show "storage" errors | Longhorn issue | [Scenario 4](#scenario-4-storage-issue) |
| Cannot log in to anything | Authentik down | [Scenario 5](#scenario-5-cannot-log-in-sso-down) |
| Nothing works, all nodes down | Cluster failure | [Scenario 6](#scenario-6-complete-cluster-failure) |

---

## Before You Start

### What You Need

1. **Terminal access** to your workstation (the machine where you run `kubectl`)
2. **kubectl configured** - test with: `kubectl get nodes`
3. **Access to Longhorn UI** at https://longhorn.lab.axiomlayer.com (if SSO working)
4. **Access to ArgoCD UI** at https://argocd.lab.axiomlayer.com (if SSO working)

### Understanding Recovery Time

| Recovery Type | Expected Time | Data Loss |
|---------------|---------------|-----------|
| Restart application | 2-5 minutes | None |
| Restore from snapshot | 10-15 minutes | Up to 24 hours |
| Restore from backup | 15-30 minutes | Up to 24 hours |
| Full cluster rebuild | 2-4 hours | Up to 24 hours |

### Backup Locations

All backups are stored on the UniFi NAS:

| What | Location | Format |
|------|----------|--------|
| Longhorn backups | NAS `/k8s-backup/backupstore/` | Binary |
| SQL dumps | NAS `/k8s-backup/homelab-YYYYMMDD-HHMMSS/` | SQL files |
| Sealed Secrets keys | Encrypted USB drives | YAML |

---

## Scenario 1: Application Not Working

**Symptoms:**
- One application shows errors
- Other applications work fine
- You can still log in

### Step 1: Check Application Status

Open a terminal and run:

```bash
# Replace "outline" with your application name
kubectl get pods -n outline
```

**What you should see:**
```
NAME                       READY   STATUS    RESTARTS   AGE
outline-5f9b8c7d6-abc12    1/1     Running   0          2d
```

**If you see:**
- `CrashLoopBackOff` → Application is crashing, go to Step 2
- `ImagePullBackOff` → Image download failed, go to Step 3
- `Pending` → Storage or scheduling issue, go to Step 4
- `Running` but not working → Check logs, go to Step 5

### Step 2: Restart the Application

```bash
# Replace "outline" with your application name
kubectl rollout restart deployment -n outline
```

Wait 2-3 minutes, then check again:

```bash
kubectl get pods -n outline
```

If still not working, continue to **Scenario 2** (database problem).

### Step 3: Force Image Re-pull

```bash
# Delete the failing pod (Kubernetes will create a new one)
kubectl delete pod -n outline -l app.kubernetes.io/name=outline
```

### Step 4: Check Events

```bash
kubectl get events -n outline --sort-by='.lastTimestamp' | tail -20
```

Look for error messages that explain the problem.

### Step 5: Check Application Logs

```bash
kubectl logs -n outline -l app.kubernetes.io/name=outline --tail=100
```

If you see database errors, continue to **Scenario 2**.

---

## Scenario 2: Database Problem

**Symptoms:**
- Application shows "database connection error"
- Application shows "relation does not exist"
- Application was working, now shows errors

### Step 1: Check Database Pod

```bash
# For Authentik database
kubectl get pods -n authentik -l cnpg.io/cluster=authentik-db

# For Outline database
kubectl get pods -n outline -l cnpg.io/cluster=outline-db
```

**What you should see:**
```
NAME              READY   STATUS    RESTARTS   AGE
authentik-db-1    1/1     Running   0          5d
```

If status is not `Running`, the database pod has a problem.

### Step 2: Try Restarting the Database

```bash
# Delete the database pod (CloudNativePG will recreate it)
kubectl delete pod authentik-db-1 -n authentik
```

Wait 2-3 minutes, then check:

```bash
kubectl get pods -n authentik -l cnpg.io/cluster=authentik-db
```

### Step 3: If Database Still Broken - Restore from Longhorn

If the database won't start or has corrupted data, restore from backup:

#### Option A: Via Longhorn UI (Easiest)

1. Go to https://longhorn.lab.axiomlayer.com
2. Click **Backup** in the left menu
3. Find your database volume (e.g., look for `authentik-db`)
4. Click on it to see available backups
5. Click the most recent backup
6. Click **Restore**
7. Name it something like `restored-authentik-db`
8. Click **OK**
9. Wait for volume to show **Detached** state

#### Option B: Then Attach the Restored Volume

After restoring in Longhorn UI:

```bash
# 1. Scale down the database
kubectl scale deployment authentik-server -n authentik --replicas=0

# 2. Delete the broken PVC
kubectl delete pvc data-authentik-db-1 -n authentik

# 3. Create PV pointing to restored volume
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: restored-authentik-db
spec:
  capacity:
    storage: 10Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Delete
  storageClassName: longhorn
  csi:
    driver: driver.longhorn.io
    fsType: ext4
    volumeHandle: restored-authentik-db
EOF

# 4. Create new PVC
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-authentik-db-1
  namespace: authentik
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  volumeName: restored-authentik-db
  resources:
    requests:
      storage: 10Gi
EOF

# 5. Scale back up
kubectl scale deployment authentik-server -n authentik --replicas=1
```

### Step 4: Verify Recovery

```bash
# Check pods are running
kubectl get pods -n authentik

# Check application works
curl -I https://auth.lab.axiomlayer.com
```

---

## Scenario 3: Single Node Down

**Symptoms:**
- Multiple applications slow or failing
- Node shows "NotReady" in kubectl
- Some pods stuck in "Pending"

### Step 1: Check Node Status

```bash
kubectl get nodes
```

**Example output:**
```
NAME      STATUS     ROLES                  AGE   VERSION
neko      Ready      control-plane,master   90d   v1.33.6+k3s1
neko2     Ready      control-plane,master   90d   v1.33.6+k3s1
panther   NotReady   worker                 90d   v1.33.6+k3s1
bobcat    Ready      worker                 60d   v1.33.6+k3s1
```

### Step 2: If Node is Physical Machine

1. **Check if machine is powered on**
2. **Check network connectivity**: Can you ping it?
3. **Try SSHing to the node**: `ssh panther`

### Step 3: If Node is Unreachable

Kubernetes will automatically reschedule pods to other nodes after 5 minutes.

To speed this up:

```bash
# Force pods to reschedule immediately
kubectl drain panther --ignore-daemonsets --delete-emptydir-data --force
```

### Step 4: When Node Comes Back

```bash
# Allow pods to be scheduled on this node again
kubectl uncordon panther
```

### Step 5: Check Longhorn Volumes

```bash
kubectl get volumes -n longhorn-system -o custom-columns=\
NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness
```

If any show "degraded", Longhorn will automatically rebuild replicas. This may take 10-30 minutes.

---

## Scenario 4: Storage Issue

**Symptoms:**
- Applications show "volume mount failed"
- Longhorn volumes show "degraded" or "faulted"
- Pods stuck in "ContainerCreating"

### Step 1: Check Longhorn Dashboard

1. Go to https://longhorn.lab.axiomlayer.com
2. Look at the **Dashboard** for overall health
3. Look at **Volume** tab for specific issues

### Step 2: For Degraded Volumes

Degraded means some replicas are missing. Longhorn will auto-repair if:
- At least one healthy replica exists
- A node has space for new replica

**Wait 10-30 minutes** and check again. If still degraded:

```bash
# Check which nodes have space
kubectl get nodes.longhorn.io -n longhorn-system \
  -o custom-columns=NAME:.metadata.name,SCHEDULABLE:.spec.allowScheduling,STORAGE:.status.conditions
```

### Step 3: For Faulted Volumes

**CRITICAL**: Faulted means all replicas are unhealthy.

1. **Do not delete the volume**
2. Go to Longhorn UI → **Backup**
3. Find the volume
4. **Restore from the latest backup**
5. Follow the attachment steps in [Scenario 2](#step-3-if-database-still-broken---restore-from-longhorn)

### Step 4: Check NAS Connectivity

```bash
# Test NFS mount
kubectl run nfs-test --rm -it --image=busybox --restart=Never -- sh -c \
  "mount -t nfs -o nfsvers=3 192.168.1.234:/var/nfs/shared/Shared_Drive_Example/k8s-backup /mnt && ls /mnt"
```

If this fails, check:
1. NAS is powered on and accessible
2. Node IPs are in NAS allowed list

---

## Scenario 5: Cannot Log In (SSO Down)

**Symptoms:**
- All applications redirect to login but login fails
- Authentik shows errors
- "502 Bad Gateway" on login page

### Step 1: Check Authentik Status

```bash
# Check all Authentik components
kubectl get pods -n authentik
```

You should see:
- `authentik-server-*` - Running
- `authentik-worker-*` - Running
- `authentik-db-*` - Running
- `ak-outpost-forward-auth-*` - Running

### Step 2: Restart Authentik

```bash
kubectl rollout restart deployment -n authentik
```

Wait 3-5 minutes, then try logging in again.

### Step 3: If Database Issue

Check Authentik database:

```bash
kubectl exec -n authentik authentik-db-1 -- psql -U authentik -d authentik -c "SELECT 1"
```

If this fails, follow **Scenario 2** to restore the database.

### Step 4: Emergency Access Without SSO

If you need to access ArgoCD or other apps without SSO:

```bash
# Get ArgoCD admin password
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d

# Port forward to ArgoCD
kubectl port-forward svc/argocd-helm-server -n argocd 8080:443

# Access at https://localhost:8080
# Username: admin, Password: (from above)
```

### Step 5: Restore Authentik from Backup

If Authentik is completely broken:

1. Restore the Authentik database volume from Longhorn backup (see Scenario 2)
2. Restart all Authentik components:
   ```bash
   kubectl rollout restart deployment -n authentik
   ```

**Recovery time**: 15-30 minutes

---

## Scenario 6: Complete Cluster Failure

**Symptoms:**
- All nodes unreachable
- `kubectl` commands fail
- No applications accessible

### Prerequisites

You need:
1. Access to a machine that can reach the nodes (via Tailscale or local network)
2. The `.env` file with secrets
3. Sealed Secrets keys (from encrypted USB backup)
4. SSH access to nodes

### Step 1: Assess the Damage

Check if nodes are reachable:

```bash
# From your workstation
ping 100.67.134.110  # neko
ping 100.106.35.14   # neko2
ping 100.79.124.94   # panther
ping 100.121.67.60   # bobcat
```

### Step 2: If Nodes are Reachable

SSH to the primary control plane node:

```bash
ssh neko
```

Check K3s status:

```bash
sudo systemctl status k3s
sudo journalctl -u k3s -n 100
```

Try restarting K3s:

```bash
sudo systemctl restart k3s
```

### Step 3: If Cluster Needs Rebuild

#### 3a. Rebuild K3s on First Control Plane

```bash
ssh neko
sudo ./scripts/provision-k3s-server.sh --init
```

#### 3b. Join Other Control Plane Nodes

```bash
ssh neko2
sudo ./scripts/provision-k3s-server.sh --join 100.67.134.110
```

#### 3c. Join Worker Nodes

```bash
ssh panther
# Get join token from neko
JOIN_TOKEN=$(ssh neko "sudo cat /var/lib/rancher/k3s/server/node-token")
curl -sfL https://get.k3s.io | sh -s - agent \
  --server https://100.67.134.110:6443 \
  --token $JOIN_TOKEN \
  --flannel-iface=tailscale0
```

### Step 4: Restore Sealed Secrets Keys

**CRITICAL**: Without these, your existing sealed secrets won't decrypt!

```bash
# From encrypted USB backup
sudo cryptsetup luksOpen /dev/sdb1 backup_crypt
sudo mount /dev/mapper/backup_crypt /mnt
kubectl apply -f /mnt/100-full-backup/secrets/sealed-secrets-keys.yaml
kubectl rollout restart deployment/sealed-secrets-controller -n kube-system
sudo umount /mnt
sudo cryptsetup luksClose backup_crypt
```

### Step 5: Bootstrap ArgoCD

```bash
./scripts/bootstrap-argocd.sh
```

ArgoCD will pull all applications from Git and deploy them.

### Step 6: Restore Volumes from Backup

For each application that needs data restored:

1. Go to https://longhorn.lab.axiomlayer.com
2. Go to **Setting** → Set backup target to NAS
3. Go to **Backup** → You should see old backups
4. Restore volumes as needed
5. Attach restored volumes to applications (see Scenario 2)

### Step 7: Verify Everything Works

```bash
# Run the full test suite
./tests/smoke-test.sh
./tests/test-auth.sh
./tests/test-backup-restore.sh
```

---

## Application-Specific Recovery

### Authentik (SSO)

| Issue | Recovery |
|-------|----------|
| Users can't log in | Restart: `kubectl rollout restart deployment -n authentik` |
| Database error | Restore from Longhorn backup |
| Need to recreate from scratch | Re-seal secrets, reconfigure all OAuth providers |

**Authentik is critical** - if it's down, no one can log into other apps.

### Outline (Documentation)

| Issue | Recovery |
|-------|----------|
| Wiki not loading | Restart: `kubectl rollout restart deployment outline -n outline` |
| Documents missing | Restore outline-db volume from backup |
| Attachments missing | Restore outline-data volume from backup |

### Open WebUI (AI Chat)

| Issue | Recovery |
|-------|----------|
| Chat not loading | Restart: `kubectl rollout restart deployment -n open-webui` |
| Chat history gone | Restore open-webui-db volume from backup |
| Models not working | Check Ollama connectivity (siberian: 100.115.3.88) |

### Plane (Project Management)

| Issue | Recovery |
|-------|----------|
| Projects not loading | Restart: `kubectl rollout restart deployment -n plane` |
| Data missing | Restore plane-pgdb volume from backup |
| Files missing | Restore plane-minio volume from backup |

### n8n (Automation)

| Issue | Recovery |
|-------|----------|
| Workflows not running | Restart: `kubectl rollout restart deployment -n n8n` |
| Workflows missing | Restore n8n-db volume from backup |
| Credentials gone | Restore n8n-data volume from backup |

---

## Recovery Verification Checklist

After any recovery, verify these:

### Basic Cluster Health

- [ ] All nodes show `Ready`: `kubectl get nodes`
- [ ] All pods running: `kubectl get pods -A | grep -v Running | grep -v Completed`
- [ ] ArgoCD apps synced: `kubectl get applications -n argocd`

### Applications Working

- [ ] Can log in via https://auth.lab.axiomlayer.com
- [ ] Dashboard loads: https://db.lab.axiomlayer.com
- [ ] ArgoCD accessible: https://argocd.lab.axiomlayer.com
- [ ] Grafana loads: https://grafana.lab.axiomlayer.com

### Backups Working

- [ ] Longhorn backup target configured: `kubectl get settings backup-target -n longhorn-system`
- [ ] Recent backups exist: `kubectl get backups -n longhorn-system | tail -5`
- [ ] SQL dump CronJob exists: `kubectl get cronjob homelab-backup -n longhorn-system`

### Run Test Suite

```bash
./tests/smoke-test.sh
./tests/test-auth.sh
./tests/test-backup-restore.sh
```

---

## Getting Help

If you're stuck:

1. **Check logs** for the failing component
2. **Check events**: `kubectl get events -A --sort-by='.lastTimestamp' | tail -30`
3. **Review this documentation** and [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
4. **Check the Outline wiki** for additional notes
