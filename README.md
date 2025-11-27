# Axiom Layer

**Sovereign software company. Democratized.**

A complete platform for developers who want to own their infrastructure end-to-end. Three machines, 30 minutes, zero vendors.

---

## What is this?

Axiom Layer is an open-source PaaS that gives you everything you need to run a software company—dev platform, business operations, identity management—on hardware you own.

No cloud bills. No vendor lock-in. No permission required.

## Live Services

| Service | URL | Status |
|---------|-----|--------|
| Authentik SSO | https://auth.lab.axiomlayer.com | Running |
| ArgoCD | https://argocd.lab.axiomlayer.com | Running |
| Telnet Metrics | https://telnet.lab.axiomlayer.com/metrics | Running |

## Architecture

### Cluster
- **K3s**: 3 nodes over Tailscale mesh
  - `neko` (control-plane)
  - `neko2` (control-plane)
  - `bobcat` (agent)
- **DNS**: `*.lab.axiomlayer.com` → Cloudflare → Tailscale IPs

### The Stack

#### Infrastructure Layer
| Component | Purpose |
|-----------|---------|
| K3s | Lightweight Kubernetes |
| Tailscale | Mesh networking, zero firewall config |
| Traefik | Ingress, automatic HTTPS |
| cert-manager | Let's Encrypt certificates (Cloudflare DNS-01) |
| Sealed Secrets | GitOps-safe secret management |
| Longhorn | Distributed storage |
| CloudNativePG | PostgreSQL (3-node HA) |
| Loki + Promtail | Log aggregation |

#### Platform Layer
| Component | Purpose |
|-----------|---------|
| Authentik | SSO + RBAC + forward auth |
| ArgoCD | GitOps continuous delivery |

### Workflow

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Developer                                    │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                │ git push
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│  GitHub                                                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                 │
│  │    Code     │→ │   Actions   │→ │    GHCR     │                 │
│  └─────────────┘  └─────────────┘  └─────────────┘                 │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                │ image pushed, manifest updated
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│  ArgoCD (GitOps)                                                     │
│  Watches repo → Syncs to cluster                                    │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                │ deploys
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│  K3s Cluster                                                         │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  Nodes: neko (control) + neko2 (control) + bobcat (worker)  │   │
│  │  Connected via Tailscale mesh                                │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                │ request
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Traefik Ingress + Authentik Forward Auth                           │
│  ┌────────────────────────────────────────────────────────────┐    │
│  │  myapp.lab.axiomlayer.com                                   │    │
│  │       │                                                     │    │
│  │       ▼                                                     │    │
│  │  ┌──────────┐    ┌──────────┐    ┌──────────┐             │    │
│  │  │ Traefik  │───▶│ Authentik│───▶│   App    │             │    │
│  │  │  (TLS)   │    │ (verify) │    │ (headers)│             │    │
│  │  └──────────┘    └──────────┘    └──────────┘             │    │
│  │                       │                                     │    │
│  │              X-Authentik-Username                           │    │
│  │              X-Authentik-Email                              │    │
│  │              X-Authentik-Groups                             │    │
│  └────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────┘
```

## Directory Structure

```
homelab-gitops/
├── apps/                         # Applications
│   ├── argocd/                  # GitOps UI + Application CRDs
│   │   └── applications/        # ArgoCD Application manifests
│   └── telnet-server/           # Demo app with SSO
├── infrastructure/              # Core infrastructure
│   ├── cert-manager/            # TLS (Let's Encrypt + Cloudflare)
│   ├── authentik/               # SSO/OIDC provider
│   ├── longhorn/                # Distributed storage
│   └── cloudnative-pg/          # PostgreSQL (3-node HA)
└── clusters/lab/                # Root kustomization
```

## SSO Everywhere

Every application is protected by Authentik forward auth. Your apps receive user context via headers:

```
X-Authentik-Username: jasen
X-Authentik-Email: jasen@company.com
X-Authentik-Groups: engineers,admins
```

**No OAuth libraries. No JWT validation. No session management. No auth code.**

Your app just reads headers. Authentik handles the rest.

## Node Provisioning

### 1. Install Ubuntu 24.04 LTS

### 2. Install Tailscale
```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --ssh
```

### 3. Install Docker
```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
newgrp docker
```

### 4. Install K3s

**First control-plane node (neko):**
```bash
curl -sfL https://get.k3s.io | sh -s - server \
  --cluster-init \
  --tls-san=neko \
  --flannel-iface=tailscale0
```

**Additional control-plane nodes:**
```bash
curl -sfL https://get.k3s.io | sh -s - server \
  --server https://<first-node-tailscale-ip>:6443 \
  --token <node-token> \
  --tls-san=<hostname> \
  --flannel-iface=tailscale0
```

**Worker nodes:**
```bash
curl -sfL https://get.k3s.io | sh -s - agent \
  --server https://<control-plane-tailscale-ip>:6443 \
  --token <node-token> \
  --flannel-iface=tailscale0
```

### 5. Fix kubeconfig permissions
```bash
sudo chmod 644 /etc/rancher/k3s/k3s.yaml
```

## Bootstrap

### 1. Install sealed-secrets controller
```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm install sealed-secrets sealed-secrets/sealed-secrets -n kube-system
```

### 2. Install cert-manager
```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.4/cert-manager.yaml
```

### 3. Create Cloudflare sealed secret
```bash
kubectl create secret generic cloudflare-api-token \
  --namespace cert-manager \
  --dry-run=client \
  --from-literal=api-token=YOUR_TOKEN \
  -o yaml | kubeseal --format yaml > infrastructure/cert-manager/sealed-secret.yaml
```

### 4. Apply infrastructure
```bash
kubectl apply -k infrastructure/cert-manager
```

### 5. Install Longhorn
```bash
helm repo add longhorn https://charts.longhorn.io
helm install longhorn longhorn/longhorn -n longhorn-system --create-namespace
```

### 6. Install CloudNativePG Operator
```bash
kubectl apply --server-side -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.22/releases/cnpg-1.22.0.yaml
kubectl apply -k infrastructure/cloudnative-pg
```

### 7. Install Authentik
```bash
kubectl create namespace authentik
helm repo add authentik https://charts.goauthentik.io
helm install authentik authentik/authentik -n authentik \
  --set authentik.secret_key=$(openssl rand -hex 32) \
  --set authentik.postgresql.password=$(openssl rand -base64 16) \
  --set postgresql.enabled=true \
  --set redis.enabled=true \
  -f infrastructure/authentik/values.yaml
```

### 8. Install ArgoCD
```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl apply -k apps/argocd
```

### 9. Configure Authentik Forward Auth

In Authentik UI:
1. Create Provider: Proxy Provider, Forward auth (domain level)
2. Cookie domain: `lab.axiomlayer.com`
3. External host: `https://auth.lab.axiomlayer.com`
4. Create Application linking to provider
5. Create Outpost: Proxy type, select application

## Secrets Management

**Use Sealed Secrets only** - no plaintext secrets in Git.

```bash
kubectl create secret generic my-secret \
  --namespace my-namespace \
  --dry-run=client \
  --from-literal=key=value \
  -o yaml | kubeseal \
  --controller-name=sealed-secrets \
  --controller-namespace=kube-system \
  --format yaml > path/to/sealed-secret.yaml
```

## Adding a New App with SSO

1. Create `apps/{service}/` directory with:
   - `namespace.yaml` (with standard labels)
   - `deployment.yaml` (with security context, probes, resources)
   - `service.yaml`
   - `certificate.yaml` (referencing `letsencrypt-prod` ClusterIssuer)
   - `ingress.yaml` (with forward auth annotation)
   - `pdb.yaml` (PodDisruptionBudget, if replicas > 1)
   - `kustomization.yaml`

2. Create ArgoCD Application in `apps/argocd/applications/{service}.yaml`

3. Commit and push - ArgoCD auto-syncs

### Required Labels
```yaml
labels:
  app.kubernetes.io/name: {name}
  app.kubernetes.io/component: {component}
  app.kubernetes.io/part-of: homelab
  app.kubernetes.io/managed-by: argocd
```

### Deployment Security Context
```yaml
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
  - securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
    livenessProbe: {...}
    readinessProbe: {...}
    resources:
      requests: {...}
      limits: {...}
```

### Ingress with Forward Auth
```yaml
annotations:
  traefik.ingress.kubernetes.io/router.middlewares: authentik-ak-outpost-forward-auth-outpost@kubernetescrd
spec:
  ingressClassName: traefik
```

Your app receives user context via headers:
- `X-Authentik-Username`
- `X-Authentik-Email`
- `X-Authentik-Groups`

## Common Commands

```bash
# Validate kustomization
kubectl kustomize apps/telnet-server

# Apply directly (testing)
kubectl apply -k infrastructure/cert-manager

# Check ArgoCD status
kubectl get applications -n argocd

# Check certificates
kubectl get certificates -A

# View logs (via Loki)
kubectl logs -n monitoring -l app=loki
```

## Why Self-Host?

### The Problem

Running a software company requires dozens of SaaS subscriptions:

| Service | Annual Cost |
|---------|-------------|
| Okta / Auth0 | $50,000+ |
| GitHub Enterprise | $20,000+ |
| Jira / Linear | $30,000+ |
| Slack | $20,000+ |
| Salesforce | $50,000+ |
| Datadog | $50,000+ |
| AWS / Azure | $200,000+ |
| **Total** | **$400,000+/year** |

Plus: vendor lock-in, data sovereignty concerns, compliance complexity, and zero ownership.

### The Solution

| Axiom Layer | Cost |
|-------------|------|
| 3x Mini PCs | $1,200 (one-time) |
| Electricity | ~$100/year |
| Domain | $12/year |
| **Total** | **$1,312 first year, $112 ongoing** |

Same capabilities. Same SSO. Same audit trails. You own it.

## Hardware Requirements

| Qty | Component | Specs | Est. Cost |
|-----|-----------|-------|-----------|
| 3 | Intel NUC / Mini PC | N100+, 16GB RAM, 512GB NVMe | $300-400 each |
| 1 | Network switch | Gigabit, 5+ ports | $30 |
| 1 | UPS (optional) | 600VA+ | $80 |

**Total: ~$1,000-1,400**

Any x86_64 or ARM64 machines with 8GB+ RAM work.

## Roadmap

- [x] K3s multi-node cluster
- [x] Tailscale mesh networking
- [x] GitOps with ArgoCD
- [x] SSO with Authentik
- [x] Automatic TLS (cert-manager + Cloudflare DNS-01)
- [x] Sealed secrets
- [x] Forward auth middleware (domain-level)
- [x] Container registry (GHCR integration)
- [x] First workload deployed with SSO (telnet-server)
- [x] Distributed storage (Longhorn)
- [x] PostgreSQL HA (CloudNativePG)
- [x] Logging (Loki + Promtail)
- [ ] Prometheus + Grafana (observability dashboards)
- [ ] GitHub Actions CI pipeline
- [ ] Business ops suite (Plane, Outline, etc.)
- [ ] CLI installer
- [ ] Documentation site

## Notes

- ArgoCD excluded from self-management to prevent loops
- Helm charts (Authentik, Longhorn) installed manually, managed via ArgoCD Applications
- TLS termination at Traefik; ArgoCD runs HTTP internally (`server.insecure: true`)
- Multi-arch images (amd64/arm64) required for mixed architecture clusters

## Philosophy

> You don't need permission to ship software.
>
> You don't need a credit card on file with AWS.
>
> You don't need to pay per seat, per build, per GB.
>
> Buy hardware once. Own it forever.
>
> **Platform company in a box.**

## License

MIT

---

**Axiom Layer** — Sovereign software company. Democratized.
