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

### Manual Longhorn Backup

```bash
# Via UI
# Go to Longhorn UI → Volumes → Select volume → Create Backup

# Via kubectl
kubectl -n longhorn-system create -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: Backup
metadata:
  name: manual-backup-$(date +%Y%m%d-%H%M%S)
  namespace: longhorn-system
spec:
  snapshotName: ""
  volumeName: {pvc-xxx-xxx}
EOF
```

### Restore from Backup

```bash
# 1. Go to Longhorn UI
# 2. Backup → Select backup → Restore
# 3. Create new PVC from restored volume

# Or create PVC referencing backup
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: restored-pvc
  namespace: {namespace}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 5Gi
  dataSource:
    name: {backup-name}
    kind: Backup
    apiGroup: longhorn.io
EOF
```

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
