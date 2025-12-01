# Developer Guide: Deploying Apps to Axiomlayer

## The Experience

You build a containerized app. You push it. The platform does the rest.

```
Code → Docker → Push → GitOps → Live
```

No kubectl. No SSH. No manual deploys. Just git push and watch it deploy.

---

## Quick Start: Deploy Your First App

### 1. Build Your Container

```dockerfile
FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --production
COPY . .
EXPOSE 3000
CMD ["node", "server.js"]
```

Build and push to GitHub Container Registry:

```bash
docker build -t ghcr.io/jasencdev/myapp:latest .
docker push ghcr.io/jasencdev/myapp:latest
```

### 2. Create the Manifests

Create a new directory in the repo:

```
apps/myapp/
├── namespace.yaml
├── deployment.yaml
├── service.yaml
├── ingress.yaml
├── certificate.yaml
├── networkpolicy.yaml
└── kustomization.yaml
```

**namespace.yaml**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: myapp
  labels:
    app.kubernetes.io/name: myapp
    app.kubernetes.io/component: server
    app.kubernetes.io/part-of: homelab
    app.kubernetes.io/managed-by: argocd
```

**deployment.yaml**
```yaml
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
          image: ghcr.io/jasencdev/myapp:latest
          ports:
            - containerPort: 3000
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              memory: 256Mi
          livenessProbe:
            httpGet:
              path: /health
              port: 3000
            initialDelaySeconds: 10
            periodSeconds: 30
          readinessProbe:
            httpGet:
              path: /health
              port: 3000
            initialDelaySeconds: 5
            periodSeconds: 10
```

**service.yaml**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: myapp
  namespace: myapp
  labels:
    app.kubernetes.io/name: myapp
    app.kubernetes.io/component: service
    app.kubernetes.io/part-of: homelab
    app.kubernetes.io/managed-by: argocd
spec:
  selector:
    app.kubernetes.io/name: myapp
  ports:
    - port: 80
      targetPort: 3000
      name: http
```

**certificate.yaml**
```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: myapp-tls
  namespace: myapp
spec:
  secretName: myapp-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - myapp.lab.axiomlayer.com
```

**ingress.yaml**
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp
  namespace: myapp
  labels:
    app.kubernetes.io/name: myapp
    app.kubernetes.io/component: server
    app.kubernetes.io/part-of: homelab
    app.kubernetes.io/managed-by: argocd
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
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
                  number: 80
```

**networkpolicy.yaml**
```yaml
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
        - protocol: TCP
          port: 3000
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
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

**kustomization.yaml**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - deployment.yaml
  - service.yaml
  - certificate.yaml
  - ingress.yaml
  - networkpolicy.yaml
```

### 3. Register with ArgoCD

Create `apps/argocd/applications/myapp.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "5"
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
```

Add to `apps/argocd/applications/kustomization.yaml`:

```yaml
resources:
  # ... existing apps ...
  - myapp.yaml
```

### 4. Configure SSO (Optional)

If using forward auth (the ingress annotation above), create a provider in Authentik:

1. Go to https://auth.lab.axiomlayer.com
2. Admin → Applications → Providers → Create
3. Type: Proxy Provider
4. Name: myapp
5. Authorization flow: default-provider-authorization-implicit-consent
6. Forward auth (single application)
7. External host: https://myapp.lab.axiomlayer.com
8. Create Application linked to provider
9. Add provider to forward-auth-outpost

### 5. Push and Watch

```bash
git add apps/myapp apps/argocd/applications/myapp.yaml
git commit -m "Add myapp"
git push origin feature/myapp
```

Open a PR. CI validates. Merge to main. ArgoCD syncs.

Within 3 minutes:
- Namespace created
- Deployment running
- TLS certificate issued
- DNS record created (external-dns)
- SSO protecting the endpoint
- App live at https://myapp.lab.axiomlayer.com

---

## What the Platform Does For You

| You Do | Platform Does |
|--------|---------------|
| Write code | — |
| Build container | — |
| Push to registry | — |
| Create manifests | — |
| Open PR | CI validates manifests |
| Merge | ArgoCD detects change |
| — | Syncs to cluster |
| — | cert-manager issues TLS |
| — | external-dns creates DNS |
| — | Authentik enforces SSO |
| — | Traefik routes traffic |
| — | Prometheus scrapes metrics |
| — | Loki collects logs |

---

## Adding a Database

Need PostgreSQL? Use CloudNativePG:

**database.yaml**
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: myapp-db
  namespace: myapp
spec:
  instances: 1
  storage:
    size: 5Gi
    storageClass: longhorn
  bootstrap:
    initdb:
      database: myapp
      owner: myapp
```

Connection string available at:
```
myapp-db-rw.myapp.svc:5432
```

Add network policy to allow your app to reach the database:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: myapp-allow-db
  namespace: myapp
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: myapp
  policyTypes:
    - Egress
  egress:
    - to:
        - podSelector:
            matchLabels:
              cnpg.io/cluster: myapp-db
      ports:
        - protocol: TCP
          port: 5432
```

---

## Secrets

Never commit plaintext secrets. Use Sealed Secrets:

```bash
# Create a secret
kubectl create secret generic myapp-secrets \
  --namespace myapp \
  --from-literal=API_KEY=supersecret \
  --dry-run=client -o yaml | \
  kubeseal --format yaml > apps/myapp/sealed-secret.yaml
```

Reference in deployment:

```yaml
env:
  - name: API_KEY
    valueFrom:
      secretKeyRef:
        name: myapp-secrets
        key: API_KEY
```

---

## Updating Your App

1. Build new container version
2. Push to registry with new tag
3. Update image tag in deployment.yaml
4. Commit and push
5. ArgoCD syncs the change
6. Rolling update, zero downtime


---

## Break Glass: Emergency Operations

> **Warning:** The following is **not** the recommended workflow and should only be used in exceptional circumstances. Using `kubectl rollout restart` requires direct cluster access and bypasses the GitOps workflow. This approach is not aligned with the platform's philosophy ("No kubectl. No SSH. No manual deploys. Just git push and watch it ride."). The recommended GitOps-friendly method is to update the image tag in your manifest and push the change, letting ArgoCD handle the rollout.
```bash
kubectl rollout restart deployment/myapp -n myapp
```

---

## Monitoring

Your app automatically gets:

- **Metrics**: Prometheus scrapes any `/metrics` endpoint
- **Logs**: Loki collects stdout/stderr via Promtail
- **Dashboards**: Grafana at https://grafana.lab.axiomlayer.com

Query your logs:

```
{namespace="myapp"}
```

---

## The Flow

```
┌─────────────┐
│   You       │
│  git push   │
└──────┬──────┘
       │
       ▼
┌─────────────┐
│   GitHub    │
│  PR + CI    │
└──────┬──────┘
       │ merge
       ▼
┌─────────────┐
│   ArgoCD    │
│  detects    │
│  syncs      │
└──────┬──────┘
       │
       ▼
┌─────────────────────────────────────────────┐
│              Kubernetes                      │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐        │
│  │ Deploy  │ │ Service │ │ Ingress │        │
│  └────┬────┘ └────┬────┘ └────┬────┘        │
│       │           │           │              │
│       ▼           ▼           ▼              │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐        │
│  │   Pod   │ │ TLS/DNS │ │   SSO   │        │
│  └─────────┘ └─────────┘ └─────────┘        │
└─────────────────────────────────────────────┘
       │
       ▼
┌─────────────┐
│   User      │
│  browser    │
│  https://myapp.lab.axiomlayer.com           │
└─────────────┘
```

---

## Checklist for New Apps

- [ ] Container builds and runs locally
- [ ] Health endpoint at `/health`
- [ ] Runs as non-root user
- [ ] No hardcoded secrets
- [ ] Manifests in `apps/myapp/`
- [ ] ArgoCD Application created
- [ ] Added to kustomization.yaml
- [ ] SSO provider configured (if needed)
- [ ] Network policies defined
- [ ] PR opened, CI passes
- [ ] Merged to main

---

## That's It

No servers to SSH into. No configs to edit on prod. No "it works on my machine."

Build. Push. Merge. Live.

The platform handles the rest.
