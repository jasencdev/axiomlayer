# CLAUDE.md - Homelab GitOps Repository

## Overview

GitOps-managed K3s homelab with ArgoCD, SSO, TLS, observability, and automated backups.

- **Domain**: `*.lab.axiomlayer.com`
- **Cluster**: 3-node K3s over Tailscale mesh (2 control-plane, 1 worker)
- **Repository**: https://github.com/jasencdev/axiomlayer
- **K3s Version**: v1.33.6+k3s1
- **Shell**: zsh 5.9 (Ubuntu default on this workstation)

## Shell Compatibility

**CRITICAL**: The operator workstation uses **zsh 5.9** (not bash). All commands and scripts MUST be zsh-compatible.

### Requirements

- **Interactive commands**: All commands in documentation must work in zsh
- **Scripts**: All `.sh` scripts use `#!/bin/bash` shebang for portability (they run in bash mode)
- **Environment sourcing**: The `.env` file uses bash-style `export VAR=value` syntax
  - In zsh, source with: `source <(grep -v '^#' .env | sed 's/^/export /')`
  - Or wrap commands: `bash -c 'source .env && ./scripts/sync-rag.sh'`
- **Testing**: Test all commands in zsh before documenting
- **Contributions**: All new scripts/docs must be zsh-compatible

### Common zsh Gotchas

- **Arrays**: zsh arrays are 1-indexed (bash is 0-indexed)
- **Globbing**: zsh has extended glob by default
- **String splitting**: `$var` doesn't split on whitespace in zsh (use `$=var` or quote properly)
- **Conditionals**: `[[ ]]` works same as bash, but `[ ]` has subtle differences

## Nodes

| Node | Role | Tailscale IP | Purpose |
|------|------|--------------|---------|
| neko | control-plane, etcd, master | 100.67.134.110 | K3s server (primary, tainted NoSchedule) |
| neko2 | control-plane, etcd, master | 100.106.35.14 | K3s server (HA, tainted NoSchedule) |
| siberian | worker | 100.115.3.88 | K3s agent (main workloads, RTX 5070 Ti) |

### Offline Nodes (available for future use)
| Node | Role | Tailscale IP | Purpose |
|------|------|--------------|---------|
| panther | worker | 100.79.124.94 | K3s agent (RTX 3050 Ti for embeddings) |
| bobcat | worker | 100.121.67.60 | K3s agent (Raspberry Pi 5 + M.2 NVMe HAT) |

## Structure

```
homelab-gitops/
├── apps/                      # Applications
│   ├── argocd/               # GitOps + Application CRDs
│   │   └── applications/     # ArgoCD Application manifests
│   ├── campfire/             # Team chat (37signals)
│   ├── dashboard/            # Homelab dashboard
│   ├── n8n/                  # Workflow automation
│   ├── outline/              # Documentation wiki
│   ├── plane/                # Project management
│   ├── pocketbase/           # Backend as a Service
│   └── telnet-server/        # Demo app
├── infrastructure/           # Core infrastructure
│   ├── actions-runner/       # GitHub Actions self-hosted runners
│   ├── alertmanager/         # Alert routing
│   ├── authentik/            # SSO/OIDC provider
│   ├── backups/              # Automated database backup CronJob
│   ├── cert-manager/         # TLS certificates
│   ├── cloudnative-pg/       # PostgreSQL operator
│   ├── external-dns/         # DNS management (Cloudflare)
│   ├── longhorn/             # Distributed storage
│   ├── minio/                # Shared S3-compatible object storage
│   ├── monitoring/           # Prometheus/Grafana extras (OIDC, certs)
│   ├── open-webui/           # AI chat interface
│   └── sealed-secrets/       # Sealed Secrets controller
├── tests/                    # Test suite
│   ├── smoke-test.sh         # Infrastructure health (111 tests)
│   ├── test-auth.sh          # Authentication flows (27 tests)
│   └── validate-manifests.sh # Kustomize validation (20 checks)
├── scripts/                  # Provisioning scripts
│   ├── provision-k3s-server.sh  # K3s node setup
│   └── bootstrap-argocd.sh      # ArgoCD + GitOps bootstrap
├── .env                      # Secrets for sealed secrets (not committed)
└── .github/workflows/        # CI/CD pipeline
    └── ci.yaml               # Main workflow
```

## Stack

| Component | Technology | Purpose |
|-----------|------------|---------|
| Cluster | K3s v1.33.6 | Lightweight Kubernetes |
| GitOps | ArgoCD | Continuous deployment |
| Config | Kustomize | Manifest management |
| Ingress | Traefik | Load balancing, TLS termination |
| TLS | cert-manager + Let's Encrypt | Automatic certificates (DNS-01 via Cloudflare) |
| DNS | external-dns + Cloudflare | Automatic DNS record management |
| Auth | Authentik 2025.10 | OIDC + forward auth SSO |
| Storage | Longhorn | Distributed block storage |
| Database | CloudNativePG | PostgreSQL operator |
| Monitoring | Prometheus + Grafana | Metrics and dashboards |
| Logging | Loki + Promtail | Log aggregation |
| Network | Tailscale | Mesh VPN |
| AI/LLM | Open WebUI + Ollama | Chat interface |
| BaaS | PocketBase | Backend as a Service (SQLite) |
| Object Storage | MinIO | S3-compatible storage for Litestream |
| SQLite Replication | Litestream | Continuous SQLite backup to MinIO |
| Backups | Longhorn + CronJob + Litestream | Volume backups + SQL dumps + SQLite streaming |
| Secrets | Sealed Secrets | Encrypted secrets in Git |
| Doc Sync | scripts/sync-*.sh | Hash-based sync to Outline + RAG |

## Applications

| App | URL | Auth Type | Namespace | Database |
|-----|-----|-----------|-----------|----------|
| Dashboard | db.lab.axiomlayer.com | Forward Auth | dashboard | - |
| Open WebUI | ai.lab.axiomlayer.com | Forward Auth | open-webui | CNPG |
| Campfire | chat.lab.axiomlayer.com | Forward Auth | campfire | SQLite + Litestream |
| n8n | autom8.lab.axiomlayer.com | Forward Auth | n8n | CNPG |
| PocketBase | pb.lab.axiomlayer.com/_/ | Forward Auth | pocketbase | SQLite + Litestream |
| Alertmanager | alerts.lab.axiomlayer.com | Forward Auth | monitoring | - |
| Longhorn | longhorn.lab.axiomlayer.com | Forward Auth | longhorn-system | - |
| ArgoCD | argocd.lab.axiomlayer.com | Dex OIDC | argocd | - |
| Grafana | grafana.lab.axiomlayer.com | Native OIDC | monitoring | - |
| Outline | docs.lab.axiomlayer.com | Native OIDC | outline | CNPG |
| Plane | plane.lab.axiomlayer.com | Native OIDC | plane | CNPG |
| Authentik | auth.lab.axiomlayer.com | Native | authentik | CNPG |

## Databases

CloudNativePG manages PostgreSQL instances:

| Database | Namespace | Service | Backed Up |
|----------|-----------|---------|-----------|
| authentik-db | authentik | authentik-db-rw.authentik.svc:5432 | Yes |
| outline-db | outline | outline-db-rw.outline.svc:5432 | Yes |
| grafana-db | monitoring | grafana-db-rw.monitoring.svc:5432 | No |
| n8n-db | n8n | n8n-db-rw.n8n.svc:5432 | No |
| open-webui-db | open-webui | open-webui-db-rw.open-webui.svc:5432 | No |
| postgres | default | postgres-rw.default.svc:5432 | No |

## Automated Backups

Three-layer backup strategy protects all data:

### Layer 1: Longhorn Volume Backups (All PVCs)

| Job | Schedule | Retention | Type |
|-----|----------|-----------|------|
| daily-snapshot | 2:00 AM daily | 7 days | Local (in-cluster) |
| weekly-snapshot | 3:00 AM Sunday | 4 weeks | Local (in-cluster) |
| daily-backup | 2:30 AM daily | 7 days | Remote (to NAS) |
| weekly-backup | 3:30 AM Sunday | 4 weeks | Remote (to NAS) |

- **Location**: `infrastructure/backups/longhorn-recurring-jobs.yaml`
- **Backup Target**: `nfs://192.168.1.234:/var/nfs/shared/Shared_Drive_Example/k8s-backup`
- **Covers**: All application data, databases, logs

### Layer 2: Database SQL Dumps (Portable)

| Setting | Value |
|---------|-------|
| Schedule | 4:00 AM daily |
| Databases | Authentik (critical), Outline |
| Retention | 7 days |
| Location | `infrastructure/backups/backup-cronjob.yaml` |

```bash
# Test backup manually
kubectl create job --from=cronjob/homelab-backup homelab-backup-test -n longhorn-system

# View backup logs
kubectl logs -n longhorn-system -l job-name=homelab-backup-test

# Check Longhorn backups
kubectl get backups -n longhorn-system --sort-by=.metadata.creationTimestamp | tail -10
```

### Layer 3: Litestream SQLite Replication (Continuous)

| Setting | Value |
|---------|-------|
| Mode | Continuous streaming |
| Applications | PocketBase, Campfire |
| Target | MinIO (minio.minio.svc:9000) |
| Bucket | litestream-backups |
| RPO | Seconds (near real-time) |

Litestream runs as a sidecar container alongside PocketBase and Campfire, continuously replicating SQLite WAL changes to MinIO. This provides:
- Near-zero RPO (Recovery Point Objective)
- Point-in-time recovery capability
- Independent of Longhorn backup schedules

```bash
# Check Litestream replication status
kubectl logs -n pocketbase -l app.kubernetes.io/name=pocketbase -c litestream
kubectl logs -n campfire -l app.kubernetes.io/name=campfire -c litestream

# Check MinIO bucket contents (requires mc CLI in pod)
kubectl exec -n minio minio-0 -- mc ls local/litestream-backups/
```

**Full documentation**: See `docs/BACKUPS.md` for complete backup and recovery procedures.

## CI/CD Pipeline

### Flow
1. Push to main → GitHub Actions CI
2. Jobs: validate-manifests, lint, security scan (Trivy)
3. ci-passed gate → triggers ArgoCD sync
4. ArgoCD deploys → changes applied
5. integration-tests → smoke + auth tests

### GitHub Actions Secrets
| Secret | Purpose |
|--------|---------|
| ARGOCD_AUTH_TOKEN | ArgoCD API access for sync trigger |
| OUTLINE_API_TOKEN | Outline wiki sync |
| OPEN_WEBUI_API_KEY | Open WebUI RAG sync |
| OPEN_WEBUI_KNOWLEDGE_ID | RAG knowledge base ID |

### Documentation Sync

CI automatically syncs documentation on every push to main using **hash-based smart sync**:

**Outline Sync** (`scripts/sync-outline.sh`):
- Syncs markdown docs to Outline wiki at docs.lab.axiomlayer.com
- Config: `outline_sync/config.json` defines which files to sync
- State: `outline_sync/state.json` tracks document IDs + content hashes
- **Smart sync**: Compares SHA256 hashes, only updates changed documents

**RAG Sync** (`scripts/sync-rag.sh`):
- Syncs repo files to Open WebUI knowledge base for AI chat
- Patterns: `*.md`, `apps/**/*.yaml`, `infrastructure/**/*.yaml`, `.github/workflows/*.yaml`
- Excludes: `*sealed-secret*`, `*.env*`, `*AGENTS.md*`
- **Smart sync**: Queries KB for existing file hashes, only uploads new/changed files
- Avoids wasteful embedding of unchanged content

### Running Tests Locally
```bash
./tests/validate-manifests.sh  # Kustomize validation
./tests/smoke-test.sh          # Infrastructure health
./tests/test-auth.sh           # Authentication flows
```

## Patterns

### Component Structure
```
{component}/
├── namespace.yaml
├── deployment.yaml
├── service.yaml
├── certificate.yaml
├── ingress.yaml
├── networkpolicy.yaml    # Default deny + explicit allows
├── pdb.yaml              # PodDisruptionBudget (if replicas > 1)
└── kustomization.yaml
```

### Required Labels
```yaml
labels:
  app.kubernetes.io/name: {name}
  app.kubernetes.io/component: {component}
  app.kubernetes.io/part-of: homelab
  app.kubernetes.io/managed-by: argocd
```

### Deployment Security
```yaml
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
  - securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true  # Some apps need false (Campfire, n8n, Outline)
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

### Network Policy Pattern
```yaml
# Default deny
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {app}-default-deny
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
# Allow specific traffic
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {app}-allow-ingress
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: {app}
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchLabels:
          app.kubernetes.io/name: traefik
```

### Cross-Namespace Database Access
For backup jobs or cross-namespace access, add network policy rules:
```yaml
# Allow backup jobs from longhorn-system
- from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: longhorn-system
      podSelector:
        matchLabels:
          app.kubernetes.io/name: homelab-backup
  ports:
    - protocol: TCP
      port: 5432
```

## Secrets Management

**Use Sealed Secrets only** - no plaintext secrets in Git.

The Sealed Secrets controller runs in `kube-system` namespace and is now GitOps-managed via `infrastructure/sealed-secrets/`.

```bash
# Create sealed secret
kubectl create secret generic {name} -n {namespace} \
  --from-literal=key=value --dry-run=client -o yaml | \
  kubeseal --format yaml > sealed-secret.yaml

# Fetch public key (for offline sealing)
kubeseal --fetch-cert > sealed-secrets-pub.pem
```

### .env File Variables
The `.env` file stores secrets for re-sealing. Never commit this file.

| Variable | Purpose |
|----------|---------|
| AUTHENTIK_AUTH_TOKEN | Authentik API access |
| AUTHENTIK_POSTGRESQL_PASSWORD | Authentik DB password |
| AUTHENTIK_SECRET_KEY | Authentik encryption key |
| CLOUDFLARE_API_TOKEN | DNS-01 challenges |
| GITHUB_RUNNER_TOKEN | GitHub Actions runner PAT |
| GRAFANA_OIDC_CLIENT_ID/SECRET | Grafana OIDC |
| OUTLINE_OIDC_CLIENT_ID/SECRET | Outline OIDC |
| PLANE_OIDC_CLIENT_ID/SECRET | Plane OIDC |
| N8N_DB_PASSWORD | n8n database |
| N8N_ENCRYPTION_KEY | n8n encryption |
| OPEN_WEBUI_SECRET_KEY | Open WebUI encryption |
| CAMPFIRE_SECRET_KEY_BASE | Campfire Rails secret |
| GHCR_DOCKERCONFIGJSON | GitHub Container Registry pull secret |
| K3_JOIN_SERVER | K3s cluster join token |
| PLANE_API_KEY | Plane API access |
| OUTLINE_API_KEY | Outline API access (also accepted as OUTLINE_API_TOKEN) |
| OPEN_WEBUI_API_KEY | Open WebUI API access |
| OPEN_WEBUI_KNOWLEDGE_ID | RAG knowledge base ID |
| MINIO_ROOT_USER | MinIO admin username |
| MINIO_ROOT_PASSWORD | MinIO admin password |

## Key Commands

```bash
# Validate kustomization
kubectl kustomize apps/{service}

# Check ArgoCD status
kubectl get applications -n argocd

# Check certificates
kubectl get certificates -A

# Check pods across namespaces
kubectl get pods -A

# Check non-running pods
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded

# Drain node for maintenance
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data

# Uncordon node
kubectl uncordon <node>

# Restart deployment
kubectl rollout restart deployment/<name> -n <namespace>

# Check Authentik outpost
kubectl logs -n authentik -l goauthentik.io/outpost-name=forward-auth-outpost --tail=100

# Direct database access (Authentik example)
kubectl exec -it -n authentik authentik-db-1 -- psql -U authentik -d authentik

# Test backup job
kubectl create job --from=cronjob/homelab-backup homelab-backup-test -n longhorn-system

# Check Longhorn volumes
kubectl get volumes -n longhorn-system

# Check MinIO status
kubectl get pods -n minio
kubectl logs -n minio -l app.kubernetes.io/name=minio

# Check Litestream replication
kubectl logs -n pocketbase -l app.kubernetes.io/name=pocketbase -c litestream
kubectl logs -n campfire -l app.kubernetes.io/name=campfire -c litestream

# Git workflow (main branch is protected - requires PRs)
git checkout -b feat/your-feature     # Create feature branch
git add .                             # Stage changes
git commit -m "feat: description"    # Commit with conventional message
git push -u origin feat/your-feature # Push branch
gh pr create --fill                   # Create PR (or use GitHub UI)
gh pr merge                          # Merge after CI passes
```

**Note**: Direct pushes to `main` are blocked. All changes must go through pull requests.

## Adding a New Service

1. Create `apps/{service}/` or `infrastructure/{service}/` with:
   - `namespace.yaml`
   - `deployment.yaml` (with security context, probes, resources)
   - `service.yaml`
   - `certificate.yaml`
   - `ingress.yaml` (with forward auth annotation)
   - `networkpolicy.yaml`
   - `kustomization.yaml`

2. Create ArgoCD Application: `apps/argocd/applications/{service}.yaml`

3. Add to `apps/argocd/applications/kustomization.yaml`

4. If using forward auth, create Authentik provider and add to outpost

5. If using native OIDC:
   - Create OAuth2/OpenID Provider in Authentik
   - Add scope mappings (openid, email, profile)
   - Create Application linked to provider
   - Store client_id/secret in .env and create sealed secret

6. Commit and push - CI validates, then ArgoCD syncs

## ArgoCD Configuration

### Health Customizations
ArgoCD is configured with custom Lua health checks for resources that don't have built-in health status:
- `bitnami.com/SealedSecret` - Always healthy when synced
- `cert-manager.io/Certificate` - Checks Ready condition
- `cert-manager.io/ClusterIssuer` - Checks Ready condition
- `postgresql.cnpg.io/Cluster` - Checks phase == "Cluster in healthy state"
- `traefik.io/Middleware` - Always healthy when synced
- `networking.k8s.io/NetworkPolicy` - Always healthy when synced

These are defined in `apps/argocd/applications/argocd-helm.yaml` under `configs.cm.resource.customizations`.

### Dex OIDC
ArgoCD uses Dex as an OIDC intermediary which connects to Authentik:
- Dex config is in `configs.cm.dex.config`
- Dex redirects to Authentik for authentication
- Callback URL: `https://argocd.lab.axiomlayer.com/api/dex/callback`

### ignoreDifferences
The argocd-helm Application ignores runtime changes to certain ConfigMaps/Secrets:
- `argocd-secret` - Contains generated credentials
- `argocd-cmd-params-cm` - Runtime parameters
- `argocd-rbac-cm` - RBAC policies
- Note: `argocd-cm` is NOT ignored so health customizations sync from git

## Authentik Configuration

### Forward Auth Apps
Each app needs:
1. Provider (Proxy Provider, forward auth mode)
2. Application linked to provider
3. Provider added to forward-auth-outpost

### Native OIDC Apps
Each app needs:
1. Provider (OAuth2/OpenID Provider)
2. Scope mappings added to provider (openid, email, profile)
3. Application linked to provider
4. Client ID/Secret configured in app via sealed secret

### Outpost Configuration
The forward-auth-outpost requires PostgreSQL env vars (Authentik 2025.10+):
- AUTHENTIK_POSTGRESQL__HOST
- AUTHENTIK_POSTGRESQL__USER
- AUTHENTIK_POSTGRESQL__PASSWORD
- AUTHENTIK_POSTGRESQL__NAME

### Direct Authentik DB Access
```bash
# Connect to Authentik database
kubectl exec -it -n authentik authentik-db-1 -- psql -U authentik -d authentik

# Useful queries
SELECT name, client_id FROM authentik_providers_oauth2_oauth2provider;
SELECT name, slug FROM authentik_core_application;
SELECT id, name FROM authentik_flows_flow WHERE slug LIKE '%authorization%';
```

## Storage and NAS

### Longhorn (Distributed Block Storage)
- Default StorageClass for PVCs
- 2 replicas per volume (for node failure tolerance)
- UI at longhorn.lab.axiomlayer.com
- Backup target: NAS at 192.168.1.234

### NAS Direct Access
All cluster nodes mount the UniFi NAS directly (no proxy needed):

| Property | Value |
|----------|-------|
| NAS IP | 192.168.1.234 |
| NFS Path | /var/nfs/shared/Shared_Drive_Example/k8s-backup |
| Protocol | NFSv3 (NFSv4 not supported by UNAS) |
| Allowed IPs | 192.168.1.103, 192.168.1.117, 192.168.1.167, 192.168.1.49, 192.168.1.94 |

```bash
# Test NFS mount from pod
kubectl run nfs-test --rm -it --image=busybox --restart=Never -- sh -c \
  "mount -t nfs -o nfsvers=3 192.168.1.234:/var/nfs/shared/Shared_Drive_Example/k8s-backup /mnt && ls /mnt"
```

## Monitoring and Logging

### Grafana Datasources
- **Prometheus**: kube-prometheus-stack (auto-provisioned)
- **Loki**: loki-stack (disabled duplicate provisioning via sidecar)

### Loki Configuration
The loki-stack Helm chart has sidecar datasource disabled to avoid duplicate:
```yaml
grafana:
  sidecar:
    datasources:
      enabled: false  # Provisioned by kube-prometheus-stack
```

## Known Limitations

### Trivy Security Findings (Informational)
These are known and acceptable:
- **AVD-KSV-0109**: ConfigMaps storing secrets (argocd-cm, authentik-blueprints) - by design
- **AVD-KSV-0014**: readOnlyRootFilesystem not true (Campfire, n8n, Outline) - apps need writable fs

### Authentik Blueprints
- Blueprints don't update client_secret after initial creation
- Manual database update required for OIDC secret changes

## Disaster Recovery / Bootstrap

### Recovery Order
1. **K3s Cluster** - `scripts/provision-k3s-server.sh`
2. **ArgoCD + Sealed Secrets** - `scripts/bootstrap-argocd.sh`
3. **Sync root app** - ArgoCD UI or `argocd app sync applications`
4. **Re-seal secrets** - New Sealed Secrets controller = new keys

### Full Cluster Rebuild
```bash
# 1. Provision K3s nodes
sudo ./scripts/provision-k3s-server.sh jasen --init          # First node
sudo ./scripts/provision-k3s-server.sh jasen --join <IP>     # Additional nodes

# 2. Bootstrap ArgoCD (from any node with kubectl access)
./scripts/bootstrap-argocd.sh

# 3. Re-seal all secrets (new controller = new keys)
kubeseal --fetch-cert > sealed-secrets-pub.pem
# Update all sealed secrets using .env values

# 4. Sync root application in ArgoCD UI
# This deploys all child apps
```

### Important Notes
- **Sealed Secrets**: New cluster = new encryption keys. All sealed secrets must be re-sealed.
- **Database backups**: Restore from NAS at 192.168.1.234
- **ArgoCD self-management**: `argocd-helm` app has manual sync only to prevent chicken/egg

## Documentation

Full documentation in Outline at https://docs.lab.axiomlayer.com:
- Cluster Overview
- CI/CD Pipeline
- Monitoring and Observability
- Runbooks
- Security
- GitHub Actions Runners
- Dashboard
- GitOps Workflow
- Networking and TLS
- Application Catalog
- Authentik SSO Configuration
- Cloudflare DNS and ACME Challenges
- Storage and Databases

## Notes

- Root application (`applications`) uses manual sync - triggered by CI after tests pass
- Child applications use auto-sync with prune and selfHeal
- ArgoCD self-manages via `argocd-helm` app with **manual sync only** (prevents chicken/egg issues)
- Helm charts (ArgoCD, Authentik, Longhorn, kube-prometheus-stack, cert-manager, actions-runner-controller) installed via ArgoCD Helm source
- TLS termination at Traefik; internal services use HTTP
- Ollama for LLM generation and embeddings runs on siberian (RTX 5070 Ti) via Tailscale at 100.115.3.88:11434
- Open WebUI uses granite4:3b model for RAG embeddings
- GitHub Actions runners have read-only cluster RBAC for tests
- Backup CronJob runs from any node (direct NAS access)
- siberian is the primary worker node for all workloads (control-plane nodes are tainted NoSchedule)
- Sealed Secrets controller is GitOps-managed in infrastructure/sealed-secrets/
