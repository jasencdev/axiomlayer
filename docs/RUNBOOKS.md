# Operational Runbooks

Step-by-step procedures for common operational tasks in the homelab cluster.

## Table of Contents

- [Daily Operations](#daily-operations)
- [Deploying a New Application](#deploying-a-new-application)
- [Upgrading Applications](#upgrading-applications)
- [Node Operations](#node-operations)
- [Backup and Restore](#backup-and-restore)
- [Secret Rotation](#secret-rotation)
- [Certificate Operations](#certificate-operations)
- [Disaster Recovery](#disaster-recovery)

---

## Daily Operations

### Morning Health Check

```bash
#!/bin/bash
# Run this to check cluster health

echo "=== Node Status ==="
kubectl get nodes -o wide

echo -e "\n=== Unhealthy Pods ==="
kubectl get pods -A | grep -v Running | grep -v Completed

echo -e "\n=== ArgoCD Applications ==="
kubectl get applications -n argocd

echo -e "\n=== Certificates Expiring Soon ==="
kubectl get certificates -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.status.notAfter}{"\n"}{end}'

echo -e "\n=== Resource Usage ==="
kubectl top nodes

echo -e "\n=== Recent Events (last 10) ==="
kubectl get events -A --sort-by='.lastTimestamp' | tail -10
```

### Check Longhorn Storage

```bash
# Volume health
kubectl get volumes -n longhorn-system \
  -o custom-columns=NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness

# Node storage
kubectl get nodes.longhorn.io -n longhorn-system \
  -o custom-columns=NAME:.metadata.name,SCHEDULABLE:.spec.allowScheduling
```

---

## Deploying a New Application

### Checklist

- [ ] Create application directory structure
- [ ] Create namespace.yaml
- [ ] Create deployment.yaml with security context
- [ ] Create service.yaml
- [ ] Create certificate.yaml
- [ ] Create ingress.yaml with SSO
- [ ] Create network policies
- [ ] Create sealed secrets (if needed)
- [ ] Create ArgoCD Application
- [ ] Update kustomization
- [ ] Update dashboard
- [ ] Update README

### Step-by-Step

#### 1. Create Directory Structure

```bash
APP_NAME=myapp
mkdir -p apps/${APP_NAME}
```

#### 2. Create Namespace

```bash
cat > apps/${APP_NAME}/namespace.yaml << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: myapp
  labels:
    app.kubernetes.io/name: myapp
    app.kubernetes.io/part-of: homelab
    app.kubernetes.io/managed-by: argocd
EOF
```

#### 3. Create Deployment

```bash
cat > apps/${APP_NAME}/deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
  namespace: myapp
  labels:
    app.kubernetes.io/name: myapp
    app.kubernetes.io/component: server
    app.kubernetes.io/part-of: homelab
    app.kubernetes.io/managed-by: argocd
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: myapp
  template:
    metadata:
      labels:
        app.kubernetes.io/name: myapp
        app.kubernetes.io/component: server
        app.kubernetes.io/part-of: homelab
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: myapp
          image: myapp:latest
          ports:
            - containerPort: 8080
              name: http
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
          livenessProbe:
            httpGet:
              path: /health
              port: http
            initialDelaySeconds: 30
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /health
              port: http
            initialDelaySeconds: 10
            periodSeconds: 5
EOF
```

#### 4. Create Service

```bash
cat > apps/${APP_NAME}/service.yaml << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: myapp
  namespace: myapp
  labels:
    app.kubernetes.io/name: myapp
    app.kubernetes.io/component: server
    app.kubernetes.io/part-of: homelab
    app.kubernetes.io/managed-by: argocd
spec:
  type: ClusterIP
  ports:
    - port: 8080
      targetPort: http
      protocol: TCP
      name: http
  selector:
    app.kubernetes.io/name: myapp
EOF
```

#### 5. Create Certificate

```bash
cat > apps/${APP_NAME}/certificate.yaml << 'EOF'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: myapp-tls
  namespace: myapp
  labels:
    app.kubernetes.io/name: myapp
    app.kubernetes.io/component: tls
    app.kubernetes.io/part-of: homelab
    app.kubernetes.io/managed-by: argocd
spec:
  secretName: myapp-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - myapp.lab.axiomlayer.com
EOF
```

#### 6. Create Ingress

```bash
cat > apps/${APP_NAME}/ingress.yaml << 'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp
  namespace: myapp
  labels:
    app.kubernetes.io/name: myapp
    app.kubernetes.io/component: ingress
    app.kubernetes.io/part-of: homelab
    app.kubernetes.io/managed-by: argocd
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
    traefik.ingress.kubernetes.io/router.middlewares: authentik-ak-outpost-forward-auth-outpost@kubernetescrd
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - myapp.lab.axiomlayer.com
      secretName: myapp-tls
  rules:
    - host: myapp.lab.axiomlayer.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: myapp
                port:
                  number: 8080
EOF
```

#### 7. Create Network Policies

```bash
cat > apps/${APP_NAME}/networkpolicy.yaml << 'EOF'
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: myapp-default-deny
  namespace: myapp
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: myapp-allow-ingress
  namespace: myapp
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: myapp
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              app.kubernetes.io/name: traefik
      ports:
        - port: 8080
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: myapp-allow-egress
  namespace: myapp
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: myapp
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector: {}
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
EOF
```

#### 8. Create Kustomization

```bash
cat > apps/${APP_NAME}/kustomization.yaml << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - deployment.yaml
  - service.yaml
  - certificate.yaml
  - ingress.yaml
  - networkpolicy.yaml
EOF
```

#### 9. Create ArgoCD Application

```bash
cat > apps/argocd/applications/myapp.yaml << 'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/jasencdev/axiomlayer.git
    targetRevision: main
    path: apps/myapp
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

# Add to kustomization
echo "  - myapp.yaml" >> apps/argocd/applications/kustomization.yaml
```

#### 10. Validate and Deploy

```bash
# Validate kustomization
kubectl kustomize apps/myapp

# Commit and push
git add apps/myapp apps/argocd/applications/myapp.yaml apps/argocd/applications/kustomization.yaml
git commit -m "Add myapp application"
git push

# Watch deployment
kubectl get application myapp -n argocd -w
```

---

## Upgrading Applications

### Update Container Image

```bash
# Edit deployment.yaml
# Change image tag

# Commit and push
git add apps/{app}/deployment.yaml
git commit -m "Upgrade {app} to version X.Y.Z"
git push

# Watch rollout
kubectl rollout status deployment/{app} -n {app}
```

### Rollback

```bash
# Via ArgoCD (recommended)
# Go to ArgoCD UI → Application → History → Rollback

# Or via kubectl
kubectl rollout undo deployment/{app} -n {namespace}
```

---

## Node Operations

### Drain Node for Maintenance

```bash
# Cordon (prevent new pods)
kubectl cordon {node}

# Drain (evict pods)
kubectl drain {node} --ignore-daemonsets --delete-emptydir-data

# Perform maintenance...

# Uncordon
kubectl uncordon {node}
```

### Add New Node

```bash
# 1. Install prerequisites
ssh {new-node}
# Install Tailscale
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up

# 2. Get join token from existing server
ssh neko sudo cat /var/lib/rancher/k3s/server/node-token

# 3. Join cluster
curl -sfL https://get.k3s.io | sh -s - agent \
  --server https://100.67.134.110:6443 \
  --token {TOKEN} \
  --flannel-iface=tailscale0

# 4. Verify
kubectl get nodes
```

### Remove Node

```bash
# 1. Drain node
kubectl drain {node} --ignore-daemonsets --delete-emptydir-data

# 2. Delete from cluster
kubectl delete node {node}

# 3. On the node itself
ssh {node} sudo /usr/local/bin/k3s-uninstall.sh
# or for agent
ssh {node} sudo /usr/local/bin/k3s-agent-uninstall.sh
```

---

## Backup and Restore

For comprehensive backup documentation, see **[docs/BACKUPS.md](BACKUPS.md)**.

### Backup Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         BACKUP FLOW                                      │
│                                                                          │
│  ┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐   │
│  │ Longhorn Volume │────▶│  Local Snapshot │     │   2:00 AM       │   │
│  │    (any node)   │     │  (cluster nodes)│     │   7 day retain  │   │
│  └─────────────────┘     └─────────────────┘     └─────────────────┘   │
│           │                                                              │
│           │              ┌─────────────────┐     ┌─────────────────┐   │
│           └─────────────▶│ Remote Backup   │────▶│   UniFi NAS     │   │
│                          │  (2:30 AM)      │     │ 192.168.1.234   │   │
│                          └─────────────────┘     └─────────────────┘   │
│                                                                          │
│  ┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐   │
│  │ PostgreSQL DBs  │────▶│   pg_dump       │────▶│   UniFi NAS     │   │
│  │  (CNPG pods)    │     │   (4:00 AM)     │     │   SQL files     │   │
│  └─────────────────┘     └─────────────────┘     └─────────────────┘   │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### Backup Schedule

| Job | Type | Schedule | Retention | Target |
|-----|------|----------|-----------|--------|
| daily-snapshot | Longhorn snapshot | 2:00 AM daily | 7 | Cluster nodes |
| weekly-snapshot | Longhorn snapshot | 3:00 AM Sunday | 4 | Cluster nodes |
| daily-backup | Longhorn backup | 2:30 AM daily | 7 | NAS |
| weekly-backup | Longhorn backup | 3:30 AM Sunday | 4 | NAS |
| homelab-backup | SQL dumps | 4:00 AM daily | 7 | NAS |

### Backup Target

All nodes can mount the NAS directly (no proxy needed):

| Property | Value |
|----------|-------|
| NAS IP | 192.168.1.234 |
| NFS Path | /var/nfs/shared/Shared_Drive_Example/k8s-backup |
| Protocol | NFSv3 |

### Volume Reference

Current volumes and their Longhorn IDs (for restore operations):

| Application | PVC | Longhorn Volume |
|-------------|-----|-----------------|
| n8n | n8n/n8n-data | pvc-5de7aa5b-2d45-467b-8a4c-ffc5e92d813e |
| n8n | n8n/n8n-db-1 | pvc-0a260809-b635-456e-b384-543ffc5f6eb3 |
| Outline | outline/outline-data | pvc-9756bc85-cb36-4bc4-9c7f-f00a9b26a554 |
| Outline | outline/outline-db-1 | pvc-0058a340-5ce8-45de-a576-f2f9702aaab2 |
| Open WebUI | open-webui/open-webui-data | pvc-06a1e2bd-0df8-4ee5-8cda-80083848b467 |
| Open WebUI | open-webui/open-webui-db-1 | pvc-acd7bca6-9465-4c29-8469-398017128a6a |
| Campfire | campfire/campfire-storage | pvc-e8a29df4-cae8-4136-a617-6f18e169c780 |
| Authentik | authentik/authentik-db-1 | pvc-6aeea1d0-7173-4942-802f-9c7ac4f48c28 |
| Plane | plane/pvc-plane-pgdb-vol-* | pvc-ba8acbfb-7a46-4667-b51b-dc8635caa1fa |
| Plane | plane/pvc-plane-minio-vol-* | pvc-9cf0ab57-9f2b-498f-b9a0-8aff5aadf77d |
| Loki | monitoring/storage-loki-0 | pvc-44507cad-3fea-457a-965f-490f199688d3 |

Generate current mapping:
```bash
kubectl get volumes -n longhorn-system -o json | \
  jq -r '.items[] | "\(.status.kubernetesStatus.namespace)/\(.status.kubernetesStatus.pvcName) → \(.metadata.name)"' | sort
```

### Check Backup Status

```bash
# Check Longhorn recurring jobs
kubectl get recurringjobs -n longhorn-system

# List recent Longhorn backups
kubectl get backups -n longhorn-system --sort-by=.metadata.creationTimestamp | tail -20

# Check backup target health
kubectl get settings backup-target -n longhorn-system -o jsonpath='{.value}'

# Check SQL dump CronJob
kubectl get cronjob homelab-backup -n longhorn-system

# Last successful SQL backup
kubectl get cronjob homelab-backup -n longhorn-system -o jsonpath='{.status.lastSuccessfulTime}'

# Test NFS connectivity
kubectl run nfs-test --rm -it --image=busybox --restart=Never -- sh -c \
  "mount -t nfs -o nfsvers=3 192.168.1.234:/var/nfs/shared/Shared_Drive_Example/k8s-backup /mnt && ls /mnt"
```

### Manual Longhorn Backup

```bash
# Via UI
# Go to Longhorn UI → Volumes → Select volume → Create Backup

# Via kubectl - first create a snapshot, then backup
VOLUME_NAME=pvc-xxxxx  # Get from: kubectl get volumes -n longhorn-system

kubectl -n longhorn-system create -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: Backup
metadata:
  name: manual-backup-$(date +%Y%m%d-%H%M%S)
  namespace: longhorn-system
spec:
  snapshotName: ""
  volumeName: ${VOLUME_NAME}
EOF

# Watch backup progress
kubectl get backups -n longhorn-system -w
```

---

### Restore Procedures

#### Method 1: Restore via Longhorn UI (Recommended)

Best for: Quick restores, exploring available backups

1. Access Longhorn UI at https://longhorn.lab.axiomlayer.com
2. Navigate to **Backup** tab
3. Find the volume you want to restore (volumes are named by PVC ID)
4. Click the backup you want to restore
5. Click **Restore Latest Backup** (or select specific backup)
6. Enter a **new volume name** (cannot match existing volume name)
7. Click **OK**
8. Wait for volume to become `detached` state
9. Create PV/PVC to use the restored volume (see Step 2 below)

#### Method 2: Restore for Regular Deployments

Use when: Restoring a single volume for a Deployment/StatefulSet with 1 replica

**Step 1: Restore the Volume**

```bash
# Via Longhorn UI (preferred) or identify the backup
kubectl get backupvolumes -n longhorn-system

# Note the volume name (e.g., pvc-5de7aa5b-2d45-467b-8a4c-ffc5e92d813e)
# Restore via UI → Backup → Select volume → Restore Latest Backup
# Name it something like: restored-n8n-data
```

**Step 2: Create PersistentVolume pointing to restored volume**

```bash
# Get the restored volume details
RESTORED_VOL=restored-n8n-data
NAMESPACE=n8n
PVC_NAME=n8n-data
SIZE=5Gi

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
    volumeAttributes:
      numberOfReplicas: "3"
      staleReplicaTimeout: "30"
EOF
```

**Step 3: Delete old PVC and create new one bound to restored PV**

```bash
# Scale down the deployment first
kubectl scale deployment/${APP_NAME} -n ${NAMESPACE} --replicas=0

# Delete the old PVC (this will delete the old Longhorn volume!)
kubectl delete pvc ${PVC_NAME} -n ${NAMESPACE}

# Create new PVC bound to the restored PV
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

# Scale deployment back up
kubectl scale deployment/${APP_NAME} -n ${NAMESPACE} --replicas=1
```

#### Method 3: Restore for StatefulSets (Multiple Replicas)

Use when: Restoring volumes for StatefulSets like PostgreSQL clusters

**Example: Restore a 2-replica PostgreSQL cluster**

```bash
# 1. Restore both volumes via Longhorn UI
#    - pvc-xxx (postgres-0) → restored-postgres-0
#    - pvc-yyy (postgres-1) → restored-postgres-1

# 2. Scale down StatefulSet
kubectl scale statefulset/postgres -n default --replicas=0

# 3. Delete old PVCs
kubectl delete pvc postgres-0 postgres-1 -n default

# 4. Create PVs for each restored volume
for i in 0 1; do
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: restored-postgres-${i}
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
    volumeHandle: restored-postgres-${i}
    volumeAttributes:
      numberOfReplicas: "3"
      staleReplicaTimeout: "30"
EOF
done

# 5. Create PVCs with exact names StatefulSet expects
for i in 0 1; do
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-postgres-${i}
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  volumeName: restored-postgres-${i}
  resources:
    requests:
      storage: 10Gi
EOF
done

# 6. Scale StatefulSet back up
kubectl scale statefulset/postgres -n default --replicas=2
```

#### Method 4: Restore to New Namespace (Migration/Testing)

Use when: Testing restore without affecting production, or migrating data

```bash
# 1. Restore volume via UI with new name: test-restore-n8n

# 2. Create PV and PVC in test namespace
kubectl create namespace restore-test

kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: test-restore-n8n
spec:
  capacity:
    storage: 5Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Delete
  storageClassName: longhorn
  csi:
    driver: driver.longhorn.io
    fsType: ext4
    volumeHandle: test-restore-n8n
    volumeAttributes:
      numberOfReplicas: "3"
      staleReplicaTimeout: "30"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-data
  namespace: restore-test
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  volumeName: test-restore-n8n
  resources:
    requests:
      storage: 5Gi
EOF

# 3. Create a test pod to verify data
kubectl run -n restore-test data-check --image=busybox --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"data-check","image":"busybox","command":["sleep","3600"],"volumeMounts":[{"name":"data","mountPath":"/data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"test-data"}}]}}'

# 4. Verify data
kubectl exec -n restore-test data-check -- ls -la /data
kubectl exec -n restore-test data-check -- cat /data/some-file

# 5. Cleanup
kubectl delete namespace restore-test
```

---

### Troubleshooting Restores

#### "Volume already exists" error

The restored volume name cannot match any existing volume.

```bash
# Check existing volumes
kubectl get volumes -n longhorn-system | grep {name}

# Use a unique name like: restored-{app}-{date}
```

#### Restored volume stuck in "Detached" state

This is normal. The volume attaches when a pod mounts it.

```bash
# Check volume state
kubectl get volumes -n longhorn-system {vol-name} -o jsonpath='{.status.state}'

# Create PV/PVC and start a pod to attach it
```

#### PVC stuck in "Pending"

```bash
# Check PVC events
kubectl describe pvc {name} -n {namespace}

# Common issues:
# - PV volumeName doesn't match
# - StorageClass mismatch
# - Size mismatch (PVC size must be <= PV size)
```

#### Data appears empty after restore

```bash
# Verify the backup has data
kubectl get backup {backup-name} -n longhorn-system -o jsonpath='{.status.size}'

# Check the restore completed
kubectl get volumes -n longhorn-system {vol-name} -o yaml | grep -A5 restoreStatus

# Verify mount inside pod
kubectl exec -n {namespace} {pod} -- df -h
kubectl exec -n {namespace} {pod} -- ls -la /path/to/mount
```

#### NFS mount not accessible

```bash
# Test NFS connectivity from cluster
kubectl run nfs-test --rm -it --image=busybox --restart=Never -- sh -c \
  "mount -t nfs -o nfsvers=3 192.168.1.234:/var/nfs/shared/Shared_Drive_Example/k8s-backup /mnt && ls /mnt"

# Check NAS is reachable
kubectl run ping-test --rm -it --image=busybox --restart=Never -- ping -c 3 192.168.1.234

# Check NFS exports from NAS
ssh neko "showmount -e 192.168.1.234"

# Check if node IP is in NAS allowed list
# NAS → Settings → NFS → Allowed IPs should include:
# 192.168.1.103, 192.168.1.117, 192.168.1.167, 192.168.1.49, 192.168.1.94
```

---

### Backup etcd

```bash
# On control plane node
ssh neko
sudo k3s etcd-snapshot save --name manual-backup-$(date +%Y%m%d)

# List snapshots
sudo k3s etcd-snapshot ls
```

### Restore etcd

```bash
# Stop K3s on all nodes first
# On control plane
sudo systemctl stop k3s

# Restore
sudo k3s server --cluster-reset --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/{snapshot-name}

# Restart K3s
sudo systemctl start k3s
```

---

## Secret Rotation

### Rotate Cloudflare API Token

```bash
# 1. Create new token in Cloudflare dashboard

# 2. Create new sealed secret
kubectl create secret generic cloudflare-api-token \
  --namespace cert-manager \
  --from-literal=api-token=NEW_TOKEN \
  --dry-run=client -o yaml | \
  kubeseal --controller-name=sealed-secrets --controller-namespace=kube-system --format yaml \
  > infrastructure/cert-manager/sealed-secret.yaml

# 3. Update external-dns too
kubectl create secret generic cloudflare-api-token \
  --namespace external-dns \
  --from-literal=api-token=NEW_TOKEN \
  --dry-run=client -o yaml | \
  kubeseal --controller-name=sealed-secrets --controller-namespace=kube-system --format yaml \
  > infrastructure/external-dns/sealed-secret.yaml

# 4. Commit and push
git add infrastructure/cert-manager/sealed-secret.yaml infrastructure/external-dns/sealed-secret.yaml
git commit -m "Rotate Cloudflare API token"
git push

# 5. Restart components
kubectl rollout restart deployment/cert-manager -n cert-manager
kubectl rollout restart deployment/external-dns -n external-dns
```

### Rotate GitHub Runner Token

```bash
# 1. Create new PAT in GitHub with required scopes

# 2. Create new sealed secret
kubectl create secret generic github-runner-token \
  --namespace actions-runner \
  --from-literal=github_token=NEW_PAT \
  --dry-run=client -o yaml | \
  kubeseal --controller-name=sealed-secrets --controller-namespace=kube-system --format yaml \
  > infrastructure/actions-runner/sealed-secret.yaml

# 3. Commit and deploy
git add infrastructure/actions-runner/sealed-secret.yaml
git commit -m "Rotate GitHub runner token"
git push

# 4. Restart controller
kubectl rollout restart deployment -n actions-runner
```

---

## Certificate Operations

### Force Certificate Renewal

```bash
# Delete certificate (ArgoCD will recreate)
kubectl delete certificate {name}-tls -n {namespace}

# Watch for new certificate
kubectl get certificate -n {namespace} -w
```

### Check All Certificate Expiry

```bash
kubectl get certificates -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.status.notAfter}{"\n"}{end}' | sort -k3
```

### Debug Certificate Issuance

```bash
# Full chain check
kubectl describe certificate {name} -n {namespace}
kubectl describe certificaterequest -n {namespace}
kubectl describe order -n {namespace}
kubectl describe challenge -n {namespace}
kubectl logs -n cert-manager -l app=cert-manager | grep {domain}
```

---

## Disaster Recovery

### Full Cluster Recovery

#### Prerequisites
- Backup of sealed-secrets keys
- Backup of etcd (or Longhorn backups)
- Access to Git repository

#### Steps

1. **Provision new nodes**
   ```bash
   # Use provisioning scripts
   ./scripts/provision-k3s-server.sh
   ./scripts/provision-k3s-agent.sh
   ```

2. **Restore sealed-secrets key**
   ```bash
   kubectl apply -f sealed-secrets-keys-backup.yaml
   ```

3. **Install core components**
   ```bash
   # Sealed Secrets
   helm install sealed-secrets sealed-secrets/sealed-secrets -n kube-system

   # cert-manager
   kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.4/cert-manager.yaml

   # Longhorn
   helm install longhorn longhorn/longhorn -n longhorn-system --create-namespace

   # ArgoCD
   kubectl create namespace argocd
   kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   ```

4. **Configure ArgoCD**
   ```bash
   kubectl apply -f apps/argocd/applications/root.yaml
   ```

5. **Restore Longhorn volumes from backup**
   - Access Longhorn UI
   - Go to Backup
   - Restore volumes

6. **Verify all applications**
   ```bash
   kubectl get applications -n argocd
   kubectl get pods -A
   ```

### Single Application Recovery

```bash
# 1. Check ArgoCD application status
kubectl get application {app} -n argocd

# 2. If deleted, recreate from Git
kubectl apply -f apps/argocd/applications/{app}.yaml

# 3. If data lost, restore from Longhorn backup
# Access Longhorn UI → Backup → Restore

# 4. Force sync
kubectl patch application {app} -n argocd --type merge \
  -p '{"operation":{"sync":{"force":true}}}'
```

---

## Emergency Contacts

| System | Contact | Access |
|--------|---------|--------|
| Cloudflare | Cloudflare Dashboard | DNS, SSL |
| Let's Encrypt | letsencrypt.org | Rate limits |
| Tailscale | Tailscale Admin | Network |
| GitHub | GitHub Settings | PATs, Runners |
