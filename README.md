# Axiomlayer

GitOps-managed K3s homelab with ArgoCD, SSO, TLS, and observability.

- **Domain**: `*.lab.axiomlayer.com`
- **Cluster**: 4-node K3s v1.33.6 over Tailscale mesh (2 control-plane, 2 workers)
- **CI/CD**: Self-hosted GitHub Actions runners (`jasencdev` org)
- **Repository**: `jasencdev/axiomlayer`
- **Shell**: zsh 5.9 (all commands are zsh-compatible)

> **⚠️ Shell Compatibility**: This project requires **zsh**. All documentation commands are tested with zsh 5.9. Scripts use `#!/bin/bash` shebangs and are portable, but interactive commands assume zsh. See `CLAUDE.md` for details.

---

## Live Services

| Service | URL | Description |
|---------|-----|-------------|
| Dashboard | https://db.lab.axiomlayer.com | Service portal |
| Alertmanager | https://alerts.lab.axiomlayer.com | Alert management and routing |
| ArgoCD | https://argocd.lab.axiomlayer.com | GitOps continuous delivery |
| Authentik | https://auth.lab.axiomlayer.com | SSO/OIDC identity provider |
| Campfire | https://chat.lab.axiomlayer.com | Team chat (37signals) |
| Grafana | https://grafana.lab.axiomlayer.com | Metrics dashboards |
| Longhorn | https://longhorn.lab.axiomlayer.com | Distributed storage UI |
| n8n (autom8) | https://autom8.lab.axiomlayer.com | Workflow automation |
| Open WebUI | https://ai.lab.axiomlayer.com | AI chat interface (Ollama backend) |
| Outline | https://docs.lab.axiomlayer.com | Documentation wiki |
| Plane | https://plane.lab.axiomlayer.com | Project management |
| Telnet Server | https://telnet.lab.axiomlayer.com | Demo app with SSO |

---

## Architecture

### Cluster Nodes

| Node | Role | Tailscale IP | Local IP | Storage |
|------|------|--------------|----------|---------|
| neko | control-plane | 100.67.134.110 | 192.168.1.167 | 462GB NVMe |
| neko2 | control-plane | 100.106.35.14 | 192.168.1.103 | 462GB NVMe |
| panther | agent | 100.79.124.94 | 192.168.1.x | 1TB SSD |
| bobcat | agent (Raspberry Pi 5) | 100.121.67.60 | 192.168.1.49 | 512GB NVMe |

### GPU Resources

| Node | Role | GPU | VRAM | Purpose |
|------|------|-----|------|---------|
| siberian | Ollama (generation) | NVIDIA RTX 5070 Ti | 16GB | LLM chat inference |
| panther | Ollama (embeddings) | NVIDIA RTX 3050 Ti | 4GB | RAG embeddings |

### Technology Stack

#### Infrastructure Layer

| Component | Purpose | Namespace |
|-----------|---------|-----------|
| K3s | Lightweight Kubernetes | - |
| Tailscale | Mesh networking | - |
| Traefik | Ingress controller, TLS termination | kube-system |
| cert-manager | Let's Encrypt certificates (Cloudflare DNS-01) | cert-manager |
| Sealed Secrets | GitOps-safe secret management | kube-system |
| Longhorn | Distributed block storage (3-way replication) | longhorn-system |
| CloudNativePG | PostgreSQL operator | cnpg-system |
| External-DNS | Automatic Cloudflare DNS records | external-dns |
| Loki + Promtail | Log aggregation | monitoring |
| Prometheus + Grafana | Metrics and dashboards | monitoring |
| Alertmanager | Alert routing and notifications | alertmanager |
| NFS Proxy | Backup proxy for UniFi NAS | nfs-proxy |

#### Platform Layer

| Component | Purpose | Namespace |
|-----------|---------|-----------|
| Authentik | SSO + OIDC + forward auth | authentik |
| ArgoCD | GitOps continuous delivery | argocd |
| Actions Runner Controller | Self-hosted GitHub Actions runners | actions-runner |

#### Application Layer

| Application | Purpose | Namespace |
|-------------|---------|-----------|
| Campfire | Team chat (37signals) | campfire |
| n8n | Workflow automation | n8n |
| Open WebUI | AI chat interface | open-webui |
| Outline | Documentation wiki | outline |
| Plane | Project management | plane |
| Telnet Server | Demo application | telnet-server |

---

## Directory Structure

```
axiomlayer/
├── .github/workflows/test-runner.yaml     # CI workflow for self-hosted runner
├── apps/
│   ├── argocd/
│   │   ├── applications/                  # App-of-Apps manifests (infra + apps)
│   │   │   ├── actions-runner-*.yaml
│   │   │   ├── authentik*.yaml
│   │   │   ├── backups.yaml               # Automates infrastructure/backups
│   │   │   ├── monitoring-extras.yaml     # Grafana cert + namespace bootstrap
│   │   │   ├── outline.yaml / plane*.yaml
│   │   │   ├── root.yaml                  # App of Apps (sync wave 0)
│   │   │   └── telnet-server.yaml
│   │   ├── sealed-secret.yaml             # Authentik OIDC client for ArgoCD
│   │   ├── configmaps.yaml                # Core settings (repo URL, RBAC)
│   │   └── ingress.yaml                   # https://argocd.lab.axiomlayer.com
│   ├── campfire/                          # 37signals Campfire deployment
│   ├── dashboard/                         # db.lab.axiomlayer.com portal (Nginx)
│   ├── n8n/                               # Workflow automation (CNPG + ingress)
│   ├── outline/                           # Wiki (CNPG, Redis, NetworkPolicy, PDB)
│   ├── plane/                             # Plane Helm overlays + extras
│   └── telnet-server/                     # Demo workload
├── clusters/lab/                          # Root kustomization entrypoint
├── docs/                                  # Architecture/runbooks for Outline/wiki
│   ├── ARCHITECTURE.md
│   ├── APPLICATIONS.md
│   └── ...
├── infrastructure/
│   ├── actions-runner/                    # Self-hosted GitHub runners + PAT
│   ├── alertmanager/                      # Routing + Prometheus rules
│   ├── authentik/                         # Helm values, blueprints, outpost, RBAC
│   ├── backups/                           # CronJob + Longhorn recurring jobs
│   ├── cert-manager/                      # ClusterIssuer + DNS token
│   ├── cloudnative-pg/                    # CNPG operator
│   ├── external-dns/                      # Cloudflare integration
│   ├── grafana/                           # OIDC secret
│   ├── longhorn/                          # Storage + backup target config
│   ├── monitoring/                        # Grafana TLS certificate
│   ├── nfs-proxy/                         # Single-IP NAS proxy for Longhorn
│   └── open-webui/                        # Ollama connectivity + ingress
├── scripts/                               # Provisioning & maintenance helpers
│   ├── backup-homelab.sh                  # Local backup helper
│   ├── provision-k3s-{server,agent}.sh    # Cluster bootstrap
│   ├── provision-k3s-ollama-agent.sh      # Lightweight GPU agent profile
│   └── provision-siberian.sh              # GPU workstation automation
├── templates/                             # Boilerplate for new apps
└── tests/test-auth.sh                     # Authentik ingress smoke test
```

### Documentation Sync

The CI pipeline automatically syncs documentation to two destinations on push to main:

**Outline Wiki Sync** (`scripts/sync-outline.sh`):
1. Set `OUTLINE_API_TOKEN` (create one in Outline with `documents.write` + `collections.write` scopes).
2. Adjust `outline_sync/config.json` to add/remove docs and set titles.
3. Run `./scripts/sync-outline.sh` to sync docs to the Outline collection.
4. State tracked in `outline_sync/state.json` (document IDs) and `.outline-sync-commit` (last sync point).

**Open WebUI RAG Sync** (`scripts/sync-rag.sh`):
1. Set `OPEN_WEBUI_API_KEY` and `OPEN_WEBUI_KNOWLEDGE_ID` environment variables.
2. Syncs `*.md`, `apps/**/*.yaml`, `infrastructure/**/*.yaml`, `.github/workflows/*.yaml`.
3. Uses git history for incremental sync - only uploads new/changed files.
4. State tracked in `.rag-sync-commit` (last sync point).

Both scripts accept `FORCE_FULL_SYNC=true` to re-sync all files regardless of change detection.

See `docs/OUTLINE_SYNC_PLAN.md` for the publishing hierarchy and API workflow.

---

## How It Works

### GitOps Workflow

```
Developer → git push → GitHub → ArgoCD detects change → Syncs to cluster
                            ↓
                   GitHub Actions (self-hosted runner)
                            ↓
                   Validates manifests, runs tests
```

1. All configuration lives in this Git repository
2. ArgoCD watches the repo and automatically syncs changes
3. GitHub Actions validate changes using self-hosted runners
4. No manual `kubectl apply` needed after initial bootstrap

### App of Apps Pattern

ArgoCD uses an "App of Apps" pattern for automatic Application management:

```
apps/argocd/applications/root.yaml (manages all other Applications)
         │
         ├── cert-manager.yaml → infrastructure/cert-manager/
         ├── authentik.yaml → infrastructure/authentik/
         ├── open-webui.yaml → infrastructure/open-webui/
         └── ... (all Application manifests)
```

**Adding a new application is fully automated:**
1. Create manifests in `apps/{name}/` or `infrastructure/{name}/`
2. Create `apps/argocd/applications/{name}.yaml`
3. Add to `apps/argocd/applications/kustomization.yaml`
4. Push to GitHub - ArgoCD auto-syncs everything

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

### Backup Architecture

```
Longhorn Volume
    │
    ▼
NFS Proxy (on neko) ─────► UniFi NAS (192.168.1.234)
    │                           │
    │                           └── /k8s-backup/
    │
    └── ClusterIP Service (10.43.x.x)
            │
            ▼
    All nodes can access via service
```

The NFS proxy solves the UniFi NAS single-IP NFS export limitation by:
1. Running on neko (192.168.1.167) which is allowed by NFS export
2. Re-exporting via Kubernetes Service so all nodes can access
3. Longhorn connects to the proxy service IP

**Backup Schedule**: Daily at 2:00 AM, retains 7 backups

### Backup Automation

- `infrastructure/backups/` defines the `homelab-backup` CronJob that runs on `neko` at 03:00, dumps Authentik and Outline Postgres databases via CNPG services, writes them to the NAS over the NFS proxy, and keeps only the seven newest archives.
- `infrastructure/backups/longhorn-recurring-jobs.yaml` codifies the Longhorn snapshot/backup cadence so application PVCs automatically land on the NAS target without manual UI edits.
- `scripts/backup-homelab.sh` is the operator workflow for ad-hoc backups: it copies the repo `.env`, exports Sealed Secret keys, takes fresh CNPG dumps, and captures Longhorn settings before risky maintenance.

---

## CI/CD with Self-Hosted Runners

### Overview

GitHub Actions runners are deployed in the cluster using [actions-runner-controller](https://github.com/actions/actions-runner-controller).

**Organization**: `jasencdev`
**Labels**: `self-hosted`, `homelab`
**Replicas**: 1 (auto-scales based on jobs)

### Using the Runner

In any repo under the `jasencdev` organization:

```yaml
name: Build
on: [push]
jobs:
  build:
    runs-on: [self-hosted, homelab]
    steps:
      - uses: actions/checkout@v4
      - run: echo "Running on homelab cluster!"
```

### Runner Features

- Docker-in-Docker enabled for container builds
- Access to cluster via kubectl (for deployment workflows)
- 2 CPU cores, 2GB memory per runner

### Checking Runner Status

```bash
# Check runner pods
kubectl get pods -n actions-runner

# Check runner registration
kubectl get runners -n actions-runner

# View runner logs
kubectl logs -n actions-runner -l app.kubernetes.io/name=actions-runner
```

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

## Alerting

### Alertmanager Configuration

Alertmanager receives alerts from Prometheus and routes them based on severity.

**URL**: https://alerts.lab.axiomlayer.com

### Alert Rules

| Alert | Severity | Description |
|-------|----------|-------------|
| NodeNotReady | critical | Node has been unready for 5+ minutes |
| NodeHighCPU | warning | Node CPU > 80% for 10+ minutes |
| NodeHighMemory | warning | Node memory > 85% for 10+ minutes |
| NodeDiskPressure | critical | Node disk > 90% |
| PodCrashLooping | warning | Pod restarting frequently |
| PodNotReady | warning | Pod not ready for 5+ minutes |
| CertificateExpiringSoon | warning | Certificate expires in < 30 days |
| CertificateExpired | critical | Certificate has expired |
| LonghornVolumeHealthCritical | critical | Longhorn volume faulted |
| LonghornVolumeDegraded | warning | Longhorn volume degraded |
| LonghornNodeDown | critical | Longhorn node offline |

### Customizing Alerts

Edit `infrastructure/alertmanager/prometheus-rules.yaml` to add or modify alert rules.

---

## Longhorn Storage

### Overview

Longhorn provides distributed block storage with automatic replication across nodes.

**UI**: https://longhorn.lab.axiomlayer.com
**Storage Class**: `longhorn` (default)
**Replication**: 3 replicas (or 2 for large volumes)

### Backup Configuration

- **Target**: UniFi NAS via NFS proxy
- **Schedule**: Daily at 2:00 AM
- **Retention**: 7 backups

### Managing Backups

```bash
# List backup targets
kubectl get backuptargets -n longhorn-system

# List recurring jobs
kubectl get recurringjobs -n longhorn-system

# Create manual backup (via UI or kubectl)
kubectl -n longhorn-system create -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: Backup
metadata:
  name: manual-backup-$(date +%Y%m%d)
spec:
  snapshotName: ""
EOF
```

### Checking Volume Health

```bash
# List all volumes
kubectl get volumes -n longhorn-system

# Check for degraded volumes
kubectl get volumes -n longhorn-system -o custom-columns=NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness | grep -v healthy
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
```

### 6. Add to Kustomization

Edit `apps/argocd/applications/kustomization.yaml`:

```yaml
resources:
  - myapp.yaml
```

### 7. Commit and Push

The App of Apps (`root.yaml`) will automatically detect the new Application manifest and deploy it. No manual `kubectl apply` needed.

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
- 3-way replication (2 for large volumes)
- Backup to UniFi NAS via NFS proxy
- Daily automated backups (7 retained)
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

### NFS Proxy

Solves UniFi NAS single-IP NFS export limitation.

**How it works**:
1. Runs `erichough/nfs-server` container on neko node
2. Mounts UniFi NAS share (neko's IP is allowed)
3. Re-exports via Kubernetes ClusterIP service
4. All nodes access backups via the service IP

**Requirement**: `nfsd` kernel module must be loaded on neko:
```bash
echo "nfsd" | sudo tee /etc/modules-load.d/nfsd.conf
sudo modprobe nfsd
```

### Open WebUI + Ollama

Local LLM inference using a dedicated GPU workstation.

**Architecture**:
```
Open WebUI (K8s cluster) ──► Ollama (siberian workstation)
     │                              │
     └── ai.lab.axiomlayer.com      └── RTX 5070 Ti (16GB VRAM)
                                         via Tailscale
```

**Components**:
- **Open WebUI**: Chat interface running in K8s (`open-webui` namespace)
- **Ollama**: LLM inference server on dedicated GPU workstation
- **Connection**: Via Tailscale mesh (configured in `configmap.yaml`)

**Recommended Models** (16GB VRAM):
| Model | VRAM | Use Case |
|-------|------|----------|
| `llama3.2:3b` | 2GB | Fast, general purpose |
| `llama3.1:8b` | 5GB | Good balance |
| `deepseek-r1:14b` | 9GB | Reasoning |
| `codellama:13b` | 8GB | Code assistance |
| `qwen2.5:14b` | 9GB | Multilingual |

**Provisioning the GPU workstation**:
```bash
# On fresh Ubuntu 24.04 install
sudo ./scripts/provision-siberian.sh jasen
# Reboot, then:
sudo tailscale up
sudo systemctl start ollama
ollama pull llama3.2:3b
```

---

## Secrets Management

All secrets are managed via Sealed Secrets. **Never commit plaintext secrets.**

### Create a Sealed Secret

```bash
# Create the secret manifest
KUBECONFIG=~/.kube/config kubectl create secret generic my-secret \
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
| github-runner-token | actions-runner | GitHub Actions runner registration |

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

# Check Longhorn volumes
kubectl get volumes -n longhorn-system

# Check backup target status
kubectl get backuptargets -n longhorn-system

# Check GitHub Actions runners
kubectl get runners -n actions-runner
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

5. **Note**: Cloudflare caches negative DNS responses for ~7 minutes. If a record was missing, wait before retrying.

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

### Longhorn Volume Degraded

1. Check volume status:
   ```bash
   kubectl describe volume <pvc-name> -n longhorn-system
   ```

2. Check node storage:
   ```bash
   kubectl get nodes.longhorn.io -n longhorn-system
   ```

3. If insufficient storage, extend LVM:
   ```bash
   sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
   sudo resize2fs /dev/ubuntu-vg/ubuntu-lv
   ```

4. Restart Longhorn managers to detect new space:
   ```bash
   kubectl delete pod -n longhorn-system -l app=longhorn-manager
   ```

### GitHub Actions Runner Not Picking Up Jobs

1. Check runner status:
   ```bash
   kubectl get runners -n actions-runner
   ```

2. Check controller logs:
   ```bash
   kubectl logs -n actions-runner -l app.kubernetes.io/name=actions-runner-controller
   ```

3. Verify PAT has correct scopes (`admin:org`, `repo`)

4. Delete and recreate runner:
   ```bash
   kubectl delete runners -n actions-runner --all
   ```

### NFS Proxy Not Working

1. Check nfsd module is loaded:
   ```bash
   lsmod | grep nfsd
   ```

2. Check proxy pod logs:
   ```bash
   kubectl logs -n nfs-proxy deployment/nfs-proxy
   ```

3. Verify UniFi NAS NFS export allows neko's IP (192.168.1.167)

---

## Bootstrap (Fresh Cluster)

### Prerequisites

- 3 machines with Ubuntu 24.04 LTS
- Tailscale installed and connected
- Docker installed
- LVM extended to use full disk (Ubuntu default only uses 100GB)

### 0. Extend LVM (if needed)

```bash
sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
sudo resize2fs /dev/ubuntu-vg/ubuntu-lv
```

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

# Actions Runner Controller (CRDs need server-side apply due to size)
helm repo add actions-runner-controller https://actions-runner-controller.github.io/actions-runner-controller
for crd in runnerdeployments runnerreplicasets runners runnersets; do
  curl -sL "https://raw.githubusercontent.com/actions/actions-runner-controller/master/charts/actions-runner-controller/crds/actions.summerwind.dev_${crd}.yaml" | kubectl apply --server-side -f -
done
```

### 3. Load nfsd Module (for NFS proxy)

```bash
# On neko only
echo "nfsd" | sudo tee /etc/modules-load.d/nfsd.conf
sudo modprobe nfsd
```

### 4. Configure ArgoCD

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
- [x] CI/CD pipelines (GitHub Actions self-hosted runners)
- [x] Backup automation (Longhorn → UniFi NAS via NFS proxy)
- [x] App of Apps pattern (auto-sync ArgoCD Applications)
- [x] Local LLM inference (Open WebUI + Ollama on GPU workstation)

---

## Notes

- ArgoCD is excluded from self-management to prevent sync loops
- Helm charts are installed manually but managed via ArgoCD Applications
- TLS termination happens at Traefik; backend services run HTTP
- cert-manager uses `--dns01-recursive-nameservers=1.1.1.1:53,8.8.8.8:53` to avoid local DNS issues
- Cloudflare DNS caches negative responses; wait ~7 minutes if a record was previously missing
- Ubuntu Server 24.04 defaults to 100GB LVM; extend manually for full disk
- UniFi NAS NFS exports only accept single IP; use NFS proxy for multi-node access
- Actions Runner Controller CRDs are too large for regular apply; use `--server-side`
- App of Apps (`root.yaml`) auto-syncs all Application manifests; no manual apply needed
- Ollama runs on dedicated GPU workstation (siberian) outside the K8s cluster, connected via Tailscale

---

## License

MIT
