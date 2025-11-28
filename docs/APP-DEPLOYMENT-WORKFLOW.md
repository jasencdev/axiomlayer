# App Deployment Workflow

This guide covers the complete workflow for adding new applications to the homelab GitOps cluster.

## Prerequisites

- Access to the K3s cluster (`kubectl` configured)
- `kubeseal` CLI installed for creating sealed secrets
- Cloudflare API token stored in `cert-manager` namespace (already configured)

## Step-by-Step Workflow

### 1. Create the App Directory Structure

```bash
mkdir -p apps/{app-name}
```

Create the following files:

```
apps/{app-name}/
├── namespace.yaml
├── deployment.yaml
├── service.yaml
├── certificate.yaml
├── ingress.yaml
├── sealed-secret.yaml    # If secrets are needed
├── pvc.yaml              # If persistent storage is needed
├── postgres-cluster.yaml # If PostgreSQL is needed
└── kustomization.yaml
```

### 2. Create the Namespace

```yaml
# namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: {app-name}
  labels:
    app.kubernetes.io/name: {app-name}
    app.kubernetes.io/part-of: homelab
    app.kubernetes.io/managed-by: argocd
```

### 3. Create the Certificate (TLS)

```yaml
# certificate.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: {app-name}-tls
  namespace: {app-name}
  labels:
    app.kubernetes.io/name: {app-name}
    app.kubernetes.io/component: tls
    app.kubernetes.io/part-of: homelab
    app.kubernetes.io/managed-by: argocd
spec:
  secretName: {app-name}-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - {app-name}.lab.axiomlayer.com
```

### 4. Create the Ingress

```yaml
# ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {app-name}
  namespace: {app-name}
  labels:
    app.kubernetes.io/name: {app-name}
    app.kubernetes.io/component: ingress
    app.kubernetes.io/part-of: homelab
    app.kubernetes.io/managed-by: argocd
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    # Include this line to require SSO authentication:
    traefik.ingress.kubernetes.io/router.middlewares: authentik-ak-outpost-forward-auth-outpost@kubernetescrd
spec:
  ingressClassName: traefik
  tls:
  - hosts:
    - {app-name}.lab.axiomlayer.com
    secretName: {app-name}-tls
  rules:
  - host: {app-name}.lab.axiomlayer.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: {app-name}
            port:
              number: {port}
```

### 5. Create the Deployment

```yaml
# deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {app-name}
  namespace: {app-name}
  labels:
    app.kubernetes.io/name: {app-name}
    app.kubernetes.io/component: server
    app.kubernetes.io/part-of: homelab
    app.kubernetes.io/managed-by: argocd
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: {app-name}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: {app-name}
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
      - name: {app-name}
        image: {image}:{tag}  # Always pin to specific version
        imagePullPolicy: IfNotPresent
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true  # Set false if app needs to write
          capabilities:
            drop:
              - ALL
        ports:
        - containerPort: {port}
          name: http
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
```

### 6. Create the Service

```yaml
# service.yaml
apiVersion: v1
kind: Service
metadata:
  name: {app-name}
  namespace: {app-name}
  labels:
    app.kubernetes.io/name: {app-name}
    app.kubernetes.io/component: server
    app.kubernetes.io/part-of: homelab
    app.kubernetes.io/managed-by: argocd
spec:
  type: ClusterIP
  ports:
  - port: {port}
    targetPort: http
    protocol: TCP
    name: http
  selector:
    app.kubernetes.io/name: {app-name}
```

### 7. Create the Kustomization

```yaml
# kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - deployment.yaml
  - service.yaml
  - certificate.yaml
  - ingress.yaml
  # Add these if needed:
  # - sealed-secret.yaml
  # - pvc.yaml
  # - postgres-cluster.yaml
```

### 8. Create the ArgoCD Application

```yaml
# apps/argocd/applications/{app-name}.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: {app-name}
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/jasencarroll/homelab-gitops.git
    targetRevision: main
    path: apps/{app-name}
  destination:
    server: https://kubernetes.default.svc
    namespace: {app-name}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### 9. Create Sealed Secrets (if needed)

```bash
# Create the secret and seal it
kubectl create secret generic {app-name}-secrets -n {app-name} \
  --from-literal=key1=value1 \
  --from-literal=key2=value2 \
  --dry-run=client -o yaml | \
  kubeseal --format yaml > apps/{app-name}/sealed-secret.yaml
```

### 10. Commit and Deploy

```bash
git add apps/{app-name} apps/argocd/applications/{app-name}.yaml
git commit -m "Add {app-name} application"
git push
```

ArgoCD will automatically sync and deploy the application.

---

## TLS Certificate Management with cert-manager

### How It Works

1. The `Certificate` resource tells cert-manager to obtain a TLS certificate
2. cert-manager uses the `letsencrypt-prod` ClusterIssuer
3. The ClusterIssuer uses Cloudflare DNS-01 challenge for validation
4. cert-manager automatically creates the `_acme-challenge` TXT record in Cloudflare
5. Let's Encrypt validates domain ownership via the TXT record
6. Certificate is stored in the specified secret (e.g., `{app-name}-tls`)
7. Ingress uses this secret for TLS termination

### Monitoring Certificate Status

```bash
# Check certificate status
kubectl get certificates -A

# Check certificate details
kubectl describe certificate {app-name}-tls -n {app-name}

# Check challenges (during issuance)
kubectl get challenges -A

# Check challenge details
kubectl describe challenge -n {app-name}
```

### Troubleshooting TLS Issues

#### Certificate Stuck in "Pending" State

1. **Check the challenge status:**
   ```bash
   kubectl get challenges -n {app-name}
   kubectl describe challenge -n {app-name}
   ```

2. **Verify DNS propagation:**
   ```bash
   dig TXT _acme-challenge.{app-name}.lab.axiomlayer.com @aurora.ns.cloudflare.com +norecurse +short
   ```

3. **If DNS doesn't resolve but challenge exists:**

   **DO NOT manually create TXT records via Cloudflare API.**

   Instead, delete the challenge and let cert-manager recreate it:
   ```bash
   kubectl delete challenge -n {app-name} --all
   ```

   Wait 30 seconds and verify:
   ```bash
   dig TXT _acme-challenge.{app-name}.lab.axiomlayer.com @aurora.ns.cloudflare.com +norecurse +short
   ```

4. **If still not working, delete and recreate the certificate:**
   ```bash
   kubectl delete certificate {app-name}-tls -n {app-name}
   # ArgoCD will recreate it from Git
   ```

5. **Check cert-manager logs:**
   ```bash
   kubectl logs -n cert-manager -l app=cert-manager --tail=100 | grep {app-name}
   ```

#### Important: Never Manually Create ACME Challenge Records

When troubleshooting DNS-01 challenges, **never manually create TXT records** via the Cloudflare API or dashboard. Records created manually via the API may appear in API responses but fail to sync to Cloudflare's authoritative DNS servers.

Always let cert-manager create and manage the `_acme-challenge` TXT records through its Cloudflare webhook integration.

#### Traefik Not Picking Up New TLS Secret

If the certificate is ready but Traefik shows TLS errors:

```bash
# Restart Traefik to pick up new secrets
kubectl rollout restart daemonset/traefik -n kube-system
```

---

## Optional Components

### PostgreSQL Database (CloudNativePG)

```yaml
# postgres-cluster.yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: {app-name}-db
  namespace: {app-name}
  labels:
    app.kubernetes.io/name: {app-name}
    app.kubernetes.io/component: database
    app.kubernetes.io/part-of: homelab
    app.kubernetes.io/managed-by: argocd
spec:
  instances: 1  # Use 3 for HA
  storage:
    size: 5Gi
    storageClass: longhorn
  bootstrap:
    initdb:
      database: {app-name}
      owner: {app-name}
      secret:
        name: {app-name}-secrets  # Must contain 'password' key
```

Connect using: `{app-name}-db-rw.{app-name}.svc:5432`

### Persistent Volume Claim

```yaml
# pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {app-name}-data
  namespace: {app-name}
  labels:
    app.kubernetes.io/name: {app-name}
    app.kubernetes.io/component: storage
    app.kubernetes.io/part-of: homelab
    app.kubernetes.io/managed-by: argocd
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 5Gi
```

---

## Verification Checklist

After deployment, verify:

- [ ] `kubectl get pods -n {app-name}` - All pods Running
- [ ] `kubectl get certificate -n {app-name}` - Certificate Ready=True
- [ ] `kubectl get ingress -n {app-name}` - Ingress has address
- [ ] `curl -I https://{app-name}.lab.axiomlayer.com` - Returns 200/302
- [ ] ArgoCD UI shows app as "Synced" and "Healthy"

---

## Quick Reference Commands

```bash
# Validate kustomization before commit
kubectl kustomize apps/{app-name}

# Check ArgoCD sync status
kubectl get applications -n argocd

# Force ArgoCD sync
kubectl patch application {app-name} -n argocd --type merge -p '{"operation":{"sync":{}}}'

# View app logs
kubectl logs -n {app-name} -l app.kubernetes.io/name={app-name} -f

# Check all certificates
kubectl get certificates -A

# Check all challenges
kubectl get challenges -A
```
