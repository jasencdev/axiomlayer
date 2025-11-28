# Homelab GitOps

GitOps-managed K3s homelab with ArgoCD, SSO, TLS, and observability.

- **Domain**: `*.lab.axiomlayer.com`
- **Cluster**: 3-node K3s over Tailscale mesh

---

## Live Services

| Service | URL | Description |
|---------|-----|-------------|
| Alertmanager | https://alerts.lab.axiomlayer.com | Alert management and routing |
| ArgoCD | https://argocd.lab.axiomlayer.com | GitOps continuous delivery |
| Authentik | https://auth.lab.axiomlayer.com | SSO/OIDC identity provider |
| Grafana | https://grafana.lab.axiomlayer.com | Metrics dashboards |
| Longhorn | https://longhorn.lab.axiomlayer.com | Distributed storage UI |
| n8n (autom8) | https://autom8.lab.axiomlayer.com | Workflow automation |
| Outline | https://docs.lab.axiomlayer.com | Documentation wiki |
| Plane | https://plane.lab.axiomlayer.com | Project management |
| Telnet Server | https://telnet.lab.axiomlayer.com | Demo app with SSO |

## Architecture

### Cluster Nodes

| Node | Role | Tailscale IP |
|------|------|--------------|
| neko | control-plane | 100.67.134.110 |
| neko2 | control-plane | 100.121.67.60 |
| bobcat | agent | 100.106.35.14 |

### Technology Stack

#### Infrastructure Layer

| Component | Purpose | Namespace |
|-----------|---------|-----------|
| K3s | Lightweight Kubernetes | - |
| Tailscale | Mesh networking | - |
| Traefik | Ingress controller, TLS termination | kube-system |
| cert-manager | Let's Encrypt certificates (Cloudflare DNS-01) | cert-manager |
| Sealed Secrets | GitOps-safe secret management | kube-system |
| Longhorn | Distributed block storage | longhorn-system |
| CloudNativePG | PostgreSQL operator | cnpg-system |
| External-DNS | Automatic Cloudflare DNS records | external-dns |
| Loki + Promtail | Log aggregation | monitoring |
| Prometheus + Grafana | Metrics and dashboards | monitoring |

#### Platform Layer

| Component | Purpose | Namespace |
|-----------|---------|-----------|
| Authentik | SSO + OIDC + forward auth | authentik |
| ArgoCD | GitOps continuous delivery | argocd |

#### Application Layer

| Application | Purpose | Namespace |
|-------------|---------|-----------|
| n8n | Workflow automation | n8n |
| Outline | Documentation wiki | outline |
| Plane | Project management | plane |
| Telnet Server | Demo application | telnet-server |

---

## Directory Structure

```
homelab-gitops/
├── apps/                              # Applications
│   ├── argocd/
│   │   └── applications/             # ArgoCD Application manifests
│   │       ├── authentik.yaml
│   │       ├── cert-manager.yaml
│   │       ├── cloudnative-pg.yaml
│   │       ├── external-dns.yaml
│   │       ├── loki.yaml
│   │       ├── longhorn.yaml
│   │       ├── n8n.yaml
│   │       ├── outline.yaml
│   │       ├── plane.yaml
│   │       ├── plane-extras.yaml
│   │       └── telnet-server.yaml
│   ├── n8n/                          # Workflow automation
│   ├── outline/                      # Documentation wiki
│   ├── plane/                        # Project management (extras)
│   └── telnet-server/                # Demo app
├── infrastructure/                    # Core infrastructure
│   ├── cert-manager/                 # TLS certificates
│   ├── cloudnative-pg/               # PostgreSQL operator
│   ├── external-dns/                 # Automatic DNS management
│   ├── longhorn/                     # Distributed storage
│   └── loki/                         # Log aggregation
└── clusters/lab/                     # Root kustomization
```

---

## How It Works

### GitOps Workflow

```
Developer → git push → GitHub → ArgoCD detects change → Syncs to cluster
```

1. All configuration lives in this Git repository
2. ArgoCD watches the repo and automatically syncs changes
3. No manual `kubectl apply` needed after initial bootstrap

### DNS + TLS Flow

```
Request to *.lab.axiomlayer.com
    │
    ▼
Cloudflare DNS (A record → Tailscale IPs)
    │
    ▼
Traefik Ingress (TLS termination)
    │
    ▼
Authentik Forward Auth (SSO verification)
    │
    ▼
Application (receives X-Authentik-* headers)
```

### Automatic DNS Management

External-DNS watches Ingress resources and automatically creates/updates Cloudflare DNS records:

1. Create an Ingress with a host
2. External-DNS creates the A record in Cloudflare
3. cert-manager requests a TLS certificate via DNS-01 challenge
4. Traefik serves the application with HTTPS

### Certificate Issuance

cert-manager uses Cloudflare DNS-01 challenges:

1. cert-manager creates a TXT record via Cloudflare API
2. Let's Encrypt verifies the record
3. Certificate is issued and stored as a Kubernetes Secret
4. Traefik uses the secret for TLS termination

**Important**: cert-manager is configured to use public DNS servers (1.1.1.1, 8.8.8.8) for DNS-01 validation to avoid local DNS resolver issues.

---

## SSO Integration

All applications are protected by Authentik forward auth. Applications receive user context via HTTP headers:

```
X-Authentik-Username: jasen
X-Authentik-Email: jasen@axiomlayer.com
X-Authentik-Groups: admins,engineers
X-Authentik-Uid: abc123
```

### Ingress Configuration for SSO

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: authentik-ak-outpost-forward-auth-outpost@kubernetescrd
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - myapp.lab.axiomlayer.com
      secretName: myapp-tls
```

---

## Adding a New Application

### 1. Create Application Directory

```
apps/myapp/
├── namespace.yaml
├── deployment.yaml
├── service.yaml
├── certificate.yaml
├── ingress.yaml
├── pdb.yaml              # If replicas > 1
└── kustomization.yaml
```

### 2. Required Labels

```yaml
labels:
  app.kubernetes.io/name: myapp
  app.kubernetes.io/component: server
  app.kubernetes.io/part-of: homelab
  app.kubernetes.io/managed-by: argocd
```

### 3. Security Context (Required)

```yaml
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: myapp
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
          port: 8080
      readinessProbe:
        httpGet:
          path: /ready
          port: 8080
```

### 4. Certificate

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

### 5. Create ArgoCD Application

Create `apps/argocd/applications/myapp.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/jasencarroll/homelab-gitops.git
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
```

### 6. Add to Kustomization

Edit `apps/argocd/applications/kustomization.yaml`:

```yaml
resources:
  - myapp.yaml
```

### 7. Commit and Push

ArgoCD will automatically sync the new application.

---

## Infrastructure Components

### cert-manager

Handles TLS certificate issuance via Let's Encrypt.

**ClusterIssuer**: `letsencrypt-prod`
- Uses Cloudflare DNS-01 challenge
- API token stored in Sealed Secret
- Configured to use public DNS servers for validation

**Files**:
- `infrastructure/cert-manager/cluster-issuer.yaml`
- `infrastructure/cert-manager/sealed-secret.yaml`

### External-DNS

Automatically manages Cloudflare DNS records based on Ingress resources.

**Configuration**:
- Watches: Ingress resources
- Domain filter: `lab.axiomlayer.com`
- Policy: `upsert-only` (won't delete records)
- TXT registry for ownership tracking

**Files**:
- `infrastructure/external-dns/deployment.yaml`
- `infrastructure/external-dns/rbac.yaml`
- `infrastructure/external-dns/sealed-secret.yaml`

### Longhorn

Distributed block storage across all nodes.

**Features**:
- 3-way replication
- Backup to external storage (configurable)
- Volume snapshots
- UI at https://longhorn.lab.axiomlayer.com

**Storage Class**: `longhorn` (default)

### CloudNativePG

PostgreSQL operator for running HA PostgreSQL clusters.

**Namespace**: `cnpg-system`

Used by:
- Authentik
- Outline
- Plane (uses local PostgreSQL in Helm chart)

### Loki + Promtail

Centralized log aggregation.

- **Loki**: Log storage and querying
- **Promtail**: Log collection from all pods
- **Grafana**: Query interface via Explore

---

## Secrets Management

All secrets are managed via Sealed Secrets. **Never commit plaintext secrets.**

### Create a Sealed Secret

```bash
# Create the secret manifest
kubectl create secret generic my-secret \
  --namespace my-namespace \
  --dry-run=client \
  --from-literal=api-token=YOUR_TOKEN \
  -o yaml | kubeseal \
  --controller-name=sealed-secrets \
  --controller-namespace=kube-system \
  --format yaml > sealed-secret.yaml
```

### Sealed Secrets in Use

| Secret | Namespace | Purpose |
|--------|-----------|---------|
| cloudflare-api-token | cert-manager | DNS-01 challenge |
| cloudflare-api-token | external-dns | DNS record management |

---

## Common Commands

```bash
# Check ArgoCD application status
kubectl get applications -n argocd

# Force sync an application
kubectl patch application myapp -n argocd --type=merge \
  -p '{"operation":{"sync":{}}}'

# Check certificates
kubectl get certificates -A

# Check certificate requests
kubectl get certificaterequests -A

# View cert-manager logs
kubectl logs -n cert-manager deployment/cert-manager

# Check external-dns logs
kubectl logs -n external-dns deployment/external-dns

# Validate kustomization
kubectl kustomize apps/myapp

# Restart a deployment
kubectl rollout restart deployment/myapp -n myapp
```

---

## Troubleshooting

### Certificate Stuck in Pending

1. Check the CertificateRequest:
   ```bash
   kubectl describe certificaterequest -n <namespace>
   ```

2. Check the Challenge:
   ```bash
   kubectl describe challenge -n <namespace>
   ```

3. Verify DNS propagation:
   ```bash
   dig @1.1.1.1 _acme-challenge.myapp.lab.axiomlayer.com TXT
   ```

4. Check cert-manager logs:
   ```bash
   kubectl logs -n cert-manager deployment/cert-manager | grep myapp
   ```

### ArgoCD OutOfSync

1. Check what's different:
   ```bash
   kubectl get application myapp -n argocd -o yaml | grep -A20 "status:"
   ```

2. For immutable resources (Jobs), delete and let ArgoCD recreate:
   ```bash
   kubectl delete job <job-name> -n <namespace>
   ```

### External-DNS Not Creating Records

1. Check logs:
   ```bash
   kubectl logs -n external-dns deployment/external-dns
   ```

2. Verify Ingress has correct annotations and host

3. Check Cloudflare API token permissions (Zone:Read, DNS:Edit)

---

## Bootstrap (Fresh Cluster)

### Prerequisites

- 3 machines with Ubuntu 24.04 LTS
- Tailscale installed and connected
- Docker installed

### 1. Install K3s

**First control-plane (neko):**
```bash
curl -sfL https://get.k3s.io | sh -s - server \
  --cluster-init \
  --tls-san=neko \
  --flannel-iface=tailscale0
```

**Additional control-plane (neko2):**
```bash
curl -sfL https://get.k3s.io | sh -s - server \
  --server https://<neko-tailscale-ip>:6443 \
  --token <node-token> \
  --tls-san=neko2 \
  --flannel-iface=tailscale0
```

**Worker node (bobcat):**
```bash
curl -sfL https://get.k3s.io | sh -s - agent \
  --server https://<neko-tailscale-ip>:6443 \
  --token <node-token> \
  --flannel-iface=tailscale0
```

### 2. Install Core Components

```bash
# Sealed Secrets
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm install sealed-secrets sealed-secrets/sealed-secrets -n kube-system

# cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.4/cert-manager.yaml

# Longhorn
helm repo add longhorn https://charts.longhorn.io
helm install longhorn longhorn/longhorn -n longhorn-system --create-namespace

# CloudNativePG
kubectl apply --server-side -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.22/releases/cnpg-1.22.0.yaml

# Authentik (via Helm)
helm repo add authentik https://charts.goauthentik.io
helm install authentik authentik/authentik -n authentik --create-namespace -f values.yaml

# ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

### 3. Configure ArgoCD

```bash
# Apply ArgoCD applications
kubectl apply -k apps/argocd/applications
```

---

## Roadmap

- [x] K3s multi-node cluster
- [x] Tailscale mesh networking
- [x] GitOps with ArgoCD
- [x] SSO with Authentik
- [x] Automatic TLS (cert-manager + Cloudflare DNS-01)
- [x] Automatic DNS (external-dns + Cloudflare)
- [x] Sealed secrets
- [x] Forward auth middleware
- [x] Distributed storage (Longhorn)
- [x] PostgreSQL HA (CloudNativePG)
- [x] Logging (Loki + Promtail)
- [x] Monitoring (Prometheus + Grafana)
- [x] Workflow automation (n8n)
- [x] Documentation wiki (Outline)
- [x] Project management (Plane)
- [x] Alerting (Alertmanager)
- [ ] CI/CD pipelines (GitHub Actions self-hosted runners)
- [ ] Backup automation (Longhorn → NAS)

---

## Notes

- ArgoCD is excluded from self-management to prevent sync loops
- Helm charts are installed manually but managed via ArgoCD Applications
- TLS termination happens at Traefik; backend services run HTTP
- cert-manager uses `--dns01-recursive-nameservers=1.1.1.1:53,8.8.8.8:53` to avoid local DNS issues
- Cloudflare DNS caches negative responses; wait ~7 minutes if a record was previously missing

---

## License

MIT
