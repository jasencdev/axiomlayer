# CLAUDE.md - Homelab GitOps Repository

## Overview

GitOps-managed K3s homelab with ArgoCD, SSO, TLS, observability, and automated backups.

- **Domain**: `*.lab.axiomlayer.com`
- **Cluster**: 4-node K3s over Tailscale mesh (2 control-plane, 2 workers)
- **Repository**: https://github.com/jasencdev/axiomlayer
- **K3s Version**: v1.33.6+k3s1

## Nodes

| Node | Role | Tailscale IP | Purpose |
|------|------|--------------|---------|
| neko | control-plane, etcd, master | 100.67.134.110 | K3s server (primary) |
| neko2 | control-plane, etcd, master | 100.106.35.14 | K3s server (HA) |
| panther | worker | 100.79.124.94 | K3s agent (main workloads) |
| bobcat | worker | 100.121.67.60 | K3s agent (Raspberry Pi) |
| siberian | external | - | GPU workstation (Ollama) |

**Note**: The old node names (leopard, bobcat, lynx) in documentation are outdated. Current nodes are neko, neko2, panther, bobcat.

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
│   ├── monitoring/           # Prometheus/Grafana extras (OIDC, certs)
│   ├── nfs-proxy/            # NFS access for Longhorn
│   ├── open-webui/           # AI chat interface
│   └── sealed-secrets/       # Sealed Secrets controller
├── tests/                    # Test suite
│   ├── smoke-test.sh         # Infrastructure health (29 tests)
│   ├── test-auth.sh          # Authentication flows (14 tests)
│   └── validate-manifests.sh # Kustomize validation (20 checks)
├── scripts/                  # Provisioning scripts
│   └── provision-k3s-server.sh
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
| Backups | CronJob + NFS | Daily database backups to NAS |
| Secrets | Sealed Secrets | Encrypted secrets in Git |

## Applications

| App | URL | Auth Type | Namespace | Database |
|-----|-----|-----------|-----------|----------|
| Dashboard | db.lab.axiomlayer.com | Forward Auth | dashboard | - |
| Open WebUI | ai.lab.axiomlayer.com | Forward Auth | open-webui | CNPG |
| Campfire | chat.lab.axiomlayer.com | Forward Auth | campfire | SQLite |
| n8n | autom8.lab.axiomlayer.com | Forward Auth | n8n | CNPG |
| Alertmanager | alerts.lab.axiomlayer.com | Forward Auth | monitoring | - |
| Longhorn | longhorn.lab.axiomlayer.com | Forward Auth | longhorn-system | - |
| ArgoCD | argocd.lab.axiomlayer.com | Native OIDC | argocd | - |
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
| n8n-db | n8n | n8n-db-rw.n8n.svc:5432 | No |
| open-webui-db | open-webui | open-webui-db-rw.open-webui.svc:5432 | No |
| plane-db | plane | plane-db-rw.plane.svc:5432 | No |

## Automated Backups

Daily backup CronJob runs at 3 AM:
- **Location**: `infrastructure/backups/backup-cronjob.yaml`
- **Namespace**: longhorn-system (for NFS access)
- **Target**: Unifi NAS at 192.168.1.234
- **Databases backed up**: Authentik, Outline
- **Retention**: 7 days

```bash
# Test backup manually
kubectl create job --from=cronjob/homelab-backup homelab-backup-test -n longhorn-system

# View backup logs
kubectl logs -n longhorn-system -l job-name=homelab-backup-test
```

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
| OUTLINE_API_KEY | Outline API access |

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
```

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

## NFS and Storage

### Longhorn
- Default StorageClass for PVCs
- Distributed across worker nodes
- UI at longhorn.lab.axiomlayer.com

### NFS Proxy
- Runs on neko node (nodeSelector)
- Proxies NFS from Unifi NAS (192.168.1.234)
- Used by backup CronJob

### Direct NAS Access
```
Server: 192.168.1.234
Path: /volume/e8e70d24-82e0-45f1-8ef6-f8ca399ad2d6/.srv/.unifi-drive/Shared_Drive_Example/.data
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
- Ollama for LLM generation runs on siberian (GPU workstation, RTX 5070 Ti) via Tailscale at 100.115.3.88:11434
- Ollama for embeddings runs on panther (RTX 3050 Ti) via Tailscale at 100.79.124.94:11434
- Open WebUI uses granite4:3b model for RAG embeddings
- GitHub Actions runners have read-only cluster RBAC for tests
- Backup jobs run on neko node (nodeSelector for NFS access)
- panther is the primary worker node for most workloads
- Sealed Secrets controller is GitOps-managed in infrastructure/sealed-secrets/
