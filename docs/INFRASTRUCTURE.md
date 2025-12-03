# Infrastructure Components

Detailed documentation for all infrastructure components in the homelab cluster.

## Table of Contents

- [Traefik (Ingress)](#traefik-ingress)
- [cert-manager](#cert-manager)
- [Sealed Secrets](#sealed-secrets)
- [Authentik (SSO)](#authentik-sso)
- [ArgoCD (GitOps)](#argocd-gitops)
- [Longhorn (Storage)](#longhorn-storage)
- [Backups](#backups)
- [CloudNativePG](#cloudnativepg)
- [External-DNS](#external-dns)
- [Loki + Promtail](#loki--promtail)
- [Prometheus + Grafana](#prometheus--grafana)
- [Alertmanager](#alertmanager)
- [Actions Runner Controller](#actions-runner-controller)

---

## Traefik (Ingress)

**Kubernetes Ingress Controller and TLS Termination**

### Overview

| Property | Value |
|----------|-------|
| Namespace | kube-system |
| Deployment | Bundled with K3s |
| Service | LoadBalancer |
| Ports | 80 (HTTP), 443 (HTTPS) |

### Configuration

Traefik is installed by K3s by default. Key configurations:

```yaml
# Entrypoints
entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"
```

### Middleware

The cluster uses Authentik forward auth middleware:

```yaml
apiVersion: traefik.containo.us/v1alpha1
kind: Middleware
metadata:
  name: ak-outpost-forward-auth-outpost
  namespace: authentik
spec:
  forwardAuth:
    address: http://ak-outpost-forward-auth-outpost.authentik.svc:9000/outpost.goauthentik.io/auth/traefik
    trustForwardHeader: true
    authResponseHeaders:
      - X-Authentik-Username
      - X-Authentik-Email
      - X-Authentik-Groups
      - X-Authentik-Uid
```

### Usage in Ingress

```yaml
metadata:
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: authentik-ak-outpost-forward-auth-outpost@kubernetescrd
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
```

### Commands

```bash
# Check Traefik pods
kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik

# View Traefik logs
kubectl logs -n kube-system -l app.kubernetes.io/name=traefik -f

# Restart Traefik
kubectl rollout restart deployment/traefik -n kube-system
```

---

## cert-manager

**Automatic TLS Certificate Management**

### Overview

| Property | Value |
|----------|-------|
| Namespace | cert-manager |
| Version | v1.14.4 |
| Issuer | letsencrypt-prod (ClusterIssuer) |
| Challenge | DNS-01 via Cloudflare |

### Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         cert-manager                                 │
│                                                                      │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐          │
│  │ cert-manager │    │  cainjector  │    │   webhook    │          │
│  │   (main)     │    │              │    │              │          │
│  └──────┬───────┘    └──────────────┘    └──────────────┘          │
│         │                                                           │
│         ▼                                                           │
│  ┌──────────────────────────────────────────────────────────┐      │
│  │                   ClusterIssuer                           │      │
│  │                   letsencrypt-prod                        │      │
│  │                                                           │      │
│  │   solver: dns01                                           │      │
│  │   provider: cloudflare                                    │      │
│  │   apiTokenSecretRef: cloudflare-api-token                │      │
│  └──────────────────────────────────────────────────────────┘      │
└─────────────────────────────────────────────────────────────────────┘
```

### ClusterIssuer Configuration

```yaml
# infrastructure/cert-manager/cluster-issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: jasen@axiomlayer.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
```

### DNS-01 Challenge Flow

1. Certificate resource created
2. cert-manager creates CertificateRequest
3. CertificateRequest creates Order
4. Order creates Challenge
5. Challenge creates TXT record: `_acme-challenge.{domain}`
6. Let's Encrypt verifies TXT record
7. Certificate issued and stored in Secret
8. Challenge and TXT record cleaned up

### Important Configuration

```yaml
# Use public DNS servers for validation
spec:
  acme:
    solvers:
      - dns01:
          cloudflare:
            # ...
        selector:
          dnsZones:
            - "lab.axiomlayer.com"
# In cert-manager deployment args:
- --dns01-recursive-nameservers=1.1.1.1:53,8.8.8.8:53
- --dns01-recursive-nameservers-only
```

### Commands

```bash
# Check all certificates
kubectl get certificates -A

# Check certificate details
kubectl describe certificate {name} -n {namespace}

# Check challenges (during issuance)
kubectl get challenges -A
kubectl describe challenge -n {namespace}

# Check certificate requests
kubectl get certificaterequests -A

# View cert-manager logs
kubectl logs -n cert-manager -l app=cert-manager -f

# Force certificate renewal
kubectl delete certificate {name} -n {namespace}
# ArgoCD will recreate it
```

---

## Sealed Secrets

**GitOps-Safe Secret Management**

### Overview

| Property | Value |
|----------|-------|
| Namespace | kube-system |
| Controller | sealed-secrets |
| CLI | kubeseal |

### How It Works

```
┌─────────────────────────────────────────────────────────────────────┐
│                                                                      │
│   kubectl create secret ... | kubeseal > sealed-secret.yaml         │
│                                │                                     │
│                                ▼                                     │
│                    ┌─────────────────────┐                          │
│                    │   SealedSecret      │                          │
│                    │   (encrypted)       │                          │
│                    │   safe for Git      │                          │
│                    └──────────┬──────────┘                          │
│                               │                                      │
│                               ▼                                      │
│                    ┌─────────────────────┐                          │
│                    │  Sealed Secrets     │                          │
│                    │  Controller         │                          │
│                    │  (decrypts)         │                          │
│                    └──────────┬──────────┘                          │
│                               │                                      │
│                               ▼                                      │
│                    ┌─────────────────────┐                          │
│                    │   Secret            │                          │
│                    │   (plaintext)       │                          │
│                    │   in cluster only   │                          │
│                    └─────────────────────┘                          │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### Creating Sealed Secrets

```bash
# Create and seal a secret
kubectl create secret generic my-secret \
  --namespace my-namespace \
  --from-literal=api-key=supersecret \
  --dry-run=client -o yaml | \
  kubeseal \
    --controller-name=sealed-secrets \
    --controller-namespace=kube-system \
    --format yaml > sealed-secret.yaml
```

### Sealed Secret Structure

```yaml
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: my-secret
  namespace: my-namespace
spec:
  encryptedData:
    api-key: AgBy8hCG...  # Encrypted value
  template:
    metadata:
      name: my-secret
      namespace: my-namespace
```

### Commands

```bash
# Check controller status
kubectl get pods -n kube-system -l name=sealed-secrets

# Verify a sealed secret
kubeseal --validate < sealed-secret.yaml

# Get controller logs
kubectl logs -n kube-system -l name=sealed-secrets

# Re-encrypt with new key (after key rotation)
kubeseal --re-encrypt < old-sealed-secret.yaml > new-sealed-secret.yaml
```

---

## Authentik (SSO)

**Identity Provider and Single Sign-On**

### Overview

| Property | Value |
|----------|-------|
| Namespace | authentik |
| URL | https://auth.lab.axiomlayer.com |
| Deployment | Helm chart |
| Database | PostgreSQL (local-path) |

### Components

| Component | Purpose |
|-----------|---------|
| authentik-server | Main web UI and API |
| authentik-worker | Background tasks |
| authentik-postgresql | Database |
| authentik-redis | Cache and sessions |
| ak-outpost-forward-auth | Forward auth proxy |

### GitOps Assets

- `infrastructure/authentik/outpost.yaml` defines the `ak-outpost-forward-auth-outpost` Deployment, Service, and Traefik middleware so the forward-auth proxy is version-controlled.
- `infrastructure/authentik/rbac.yaml` grants the Authentik service account the cluster-scoped permissions the outpost needs (Deployments, Traefik CRDs, Secrets).
- `infrastructure/authentik/outpost-token-sealed-secret.yaml` stores the outpost API token that Authentik issues.
- `infrastructure/authentik/sealed-secret.yaml` keeps the Helm chart secrets (PostgreSQL password, secret key) encrypted.

### Forward Auth Flow

```
User Request → Traefik → Authentik Outpost → Decision
                                ↓
                    ┌───────────┴───────────┐
                    ▼                       ▼
            Authenticated            Not Authenticated
                    ↓                       ↓
            Forward to App           Redirect to Login
            + X-Authentik headers
```

### Outpost Configuration

Authentik still owns the outpost definition, but everything needed to run it inside Kubernetes is declarative:

1. Create/refresh the outpost token in the Authentik UI, then update `infrastructure/authentik/outpost-token-sealed-secret.yaml` via `kubeseal`.
2. `apps/argocd/applications/authentik.yaml` syncs the Deployment/Middleware/RBAC from this repo.
3. In Authentik → Applications → Outposts, target the `ak-outpost-forward-auth-outpost` deployment (type `Proxy`, integration `Embedded`).

### Provider Types

| Type | Use Case | Example |
|------|----------|---------|
| Proxy (Forward Auth) | Web apps without native SSO | Dashboard, Grafana |
| OAuth2/OIDC | Apps with native OIDC | Outline, ArgoCD |
| LDAP | Legacy apps | - |

### Commands

```bash
# Check Authentik pods
kubectl get pods -n authentik

# Get admin password (initial setup)
kubectl get secret authentik -n authentik -o jsonpath='{.data.authentik-bootstrap-password}' | base64 -d

# View server logs
kubectl logs -n authentik -l app.kubernetes.io/name=authentik-server

# Restart outpost
kubectl rollout restart deployment/ak-outpost-forward-auth-outpost -n authentik
```

---

## ArgoCD (GitOps)

**GitOps Continuous Delivery**

### Overview

| Property | Value |
|----------|-------|
| Namespace | argocd |
| URL | https://argocd.lab.axiomlayer.com |
| Repo | github.com/jasencdev/axiomlayer |
| Branch | main |
| Auth | Dex OIDC → Authentik |

### Components

| Component | Purpose | Replicas |
|-----------|---------|----------|
| argocd-server | Web UI and API | 2 |
| argocd-application-controller | Sync engine | 2 |
| argocd-repo-server | Git operations | 2 |
| argocd-redis | Cache | 1 |
| argocd-dex-server | OIDC via Authentik | 2 |
| argocd-applicationset-controller | ApplicationSets | 2 |
| argocd-notifications-controller | Notifications | 1 |

### App of Apps

The cluster uses App of Apps pattern via `root.yaml`:

```yaml
# apps/argocd/applications/root.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: applications
  namespace: argocd
spec:
  source:
    repoURL: https://github.com/jasencdev/axiomlayer.git
    targetRevision: main
    path: apps/argocd/applications
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### Configuration

ArgoCD runs in insecure mode (TLS handled by Traefik):

```yaml
# ArgoCD ConfigMap
data:
  server.insecure: "true"
```

### Single Sign-On (Dex OIDC)

ArgoCD uses Dex as an OIDC intermediary that connects to Authentik:

```
User → ArgoCD Login → Dex (/api/dex/auth) → Authentik → Back to ArgoCD
```

**Configuration:**
- Dex config is in `configs.cm.dex.config` within the Helm values
- Callback URL: `https://argocd.lab.axiomlayer.com/api/dex/callback`
- Authentik issuer: `https://auth.lab.axiomlayer.com/application/o/argocd/`

**Secrets:**
- `apps/argocd/sealed-secret.yaml` stores the Authentik OIDC client secret under `oidc.authentik.clientSecret`
- Dex references this via `$oidc.authentik.clientSecret` in the connector config

### Commands

```bash
# List all applications
kubectl get applications -n argocd

# Get application details
kubectl get application {name} -n argocd -o yaml

# Force sync
kubectl patch application {name} -n argocd --type merge \
  -p '{"operation":{"sync":{}}}'

# Hard refresh
kubectl patch application {name} -n argocd --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

# Get admin password
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d
```

---

## Longhorn (Storage)

**Distributed Block Storage with Integrated Backups**

### Overview

| Property | Value |
|----------|-------|
| Namespace | longhorn-system |
| URL | https://longhorn.lab.axiomlayer.com |
| Default Replicas | 2 |
| Storage Class | longhorn (default) |
| Backup Target | NAS at 192.168.1.234 |

### Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                      Longhorn System                                 │
│                                                                      │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐            │
│  │ Manager  │  │ Manager  │  │ Manager  │  │ Manager  │            │
│  │ (neko)   │  │ (neko2)  │  │ (panther)│  │ (bobcat) │            │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘            │
│       │             │             │             │                   │
│       └─────────────┴──────┬──────┴─────────────┘                   │
│                            │                                        │
│                     ┌──────▼──────┐                                 │
│                     │   Volume    │                                 │
│                     │ (2 replicas)│                                 │
│                     └──────┬──────┘                                 │
│                            │                                        │
│         ┌──────────────────┼──────────────────┐                    │
│         ▼                  ▼                  ▼                    │
│    ┌───────┐          ┌───────┐          ┌───────┐                │
│    │Replica│          │Replica│          │ Backup │               │
│    │(node1)│          │(node2)│          │ (NAS)  │               │
│    └───────┘          └───────┘          └───────┘                │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Storage Classes

```yaml
# Default (2 replicas - balances redundancy and storage)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn
provisioner: driver.longhorn.io
parameters:
  numberOfReplicas: "2"
  staleReplicaTimeout: "2880"
```

### Backup Configuration

Longhorn is configured to backup all volumes to the UniFi NAS:

```yaml
# apps/argocd/applications/longhorn-helm.yaml
defaultSettings:
  defaultReplicaCount: 2
  backupTarget: nfs://192.168.1.234:/var/nfs/shared/Shared_Drive_Example/k8s-backup
```

### Recurring Backup Jobs

Defined in `infrastructure/backups/longhorn-recurring-jobs.yaml`:

| Job | Type | Schedule | Retention | Purpose |
|-----|------|----------|-----------|---------|
| daily-snapshot | snapshot | 2:00 AM daily | 7 | Fast local rollback |
| weekly-snapshot | snapshot | 3:00 AM Sunday | 4 | Weekly local checkpoint |
| daily-backup | backup | 2:30 AM daily | 7 | Daily disaster recovery |
| weekly-backup | backup | 3:30 AM Sunday | 4 | Weekly archive |

**Snapshots vs Backups:**
- **Snapshots**: Local, fast, stored on cluster nodes
- **Backups**: Remote, stored on NAS, survive cluster loss

### Commands

```bash
# List volumes
kubectl get volumes -n longhorn-system

# Check volume health
kubectl get volumes -n longhorn-system \
  -o custom-columns=NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness

# Check backup target
kubectl get settings backup-target -n longhorn-system -o jsonpath='{.value}'

# List recurring jobs
kubectl get recurringjobs -n longhorn-system

# List recent backups
kubectl get backups -n longhorn-system --sort-by=.metadata.creationTimestamp | tail -10

# View manager logs
kubectl logs -n longhorn-system -l app=longhorn-manager -f
```

### Accessing Longhorn UI

1. Go to https://longhorn.lab.axiomlayer.com
2. Authenticate via Authentik (forward auth)
3. **Dashboard**: Overview of cluster storage health
4. **Volume**: Manage individual volumes, create snapshots/backups
5. **Backup**: View and restore from backups
6. **Recurring Job**: Configure backup schedules

---

## Backups

**Two-layer backup strategy: Longhorn volume backups + SQL dumps**

For comprehensive backup documentation, see **[docs/BACKUPS.md](BACKUPS.md)**.

### Summary

| Layer | What | Schedule | Retention | Purpose |
|-------|------|----------|-----------|---------|
| Longhorn Snapshots | All PVCs | 2:00 AM daily | 7 days | Fast local rollback |
| Longhorn Backups | All PVCs | 2:30 AM daily | 7 days | Disaster recovery (to NAS) |
| SQL Dumps | Authentik, Outline | 4:00 AM daily | 7 days | Portable database backups |

### Files

| File | Purpose |
|------|---------|
| `infrastructure/backups/longhorn-recurring-jobs.yaml` | Snapshot and backup schedules |
| `infrastructure/backups/backup-cronjob.yaml` | Database SQL dump CronJob |
| `infrastructure/backups/backup-db-credentials-sealed.yaml` | Database passwords (sealed) |
| `apps/argocd/applications/backups.yaml` | ArgoCD Application |

### Backup Target

All backups go to the UniFi NAS via direct NFS mount:

| Property | Value |
|----------|-------|
| NAS IP | 192.168.1.234 |
| NFS Path | /var/nfs/shared/Shared_Drive_Example/k8s-backup |
| Protocol | NFSv3 |

### Commands

```bash
# Check Longhorn recurring jobs
kubectl get recurringjobs -n longhorn-system

# Check SQL dump CronJob
kubectl get cronjob homelab-backup -n longhorn-system

# List recent Longhorn backups
kubectl get backups -n longhorn-system --sort-by=.metadata.creationTimestamp | tail -10

# Trigger manual SQL dump
kubectl create job --from=cronjob/homelab-backup homelab-backup-manual-$(date +%s) -n longhorn-system

# View backup job logs
kubectl logs -n longhorn-system -l app.kubernetes.io/name=homelab-backup --tail=50
```

---

## CloudNativePG

**PostgreSQL Operator**

### Overview

| Property | Value |
|----------|-------|
| Namespace | cnpg-system |
| Version | 1.22.0 |
| CRD | Cluster (postgresql.cnpg.io/v1) |

### Creating a PostgreSQL Cluster

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: myapp-db
  namespace: myapp
spec:
  instances: 1        # or 3 for HA
  storage:
    size: 5Gi
    storageClass: longhorn
  bootstrap:
    initdb:
      database: myapp
      owner: myapp
      secret:
        name: myapp-db-credentials
```

### Connection Details

CloudNativePG creates services automatically:

| Service | Purpose |
|---------|---------|
| {cluster}-rw | Read-write (primary) |
| {cluster}-ro | Read-only (replicas) |
| {cluster}-r | Any replica |

**Connection string:**
```
postgresql://{user}:{pass}@{cluster}-rw.{namespace}.svc:5432/{database}
```

### Commands

```bash
# List clusters
kubectl get clusters -A

# Check cluster status
kubectl describe cluster {name} -n {namespace}

# Get connection secret
kubectl get secret {cluster}-app -n {namespace} -o yaml

# Connect to PostgreSQL
kubectl exec -it {cluster}-1 -n {namespace} -- psql

# View operator logs
kubectl logs -n cnpg-system -l app.kubernetes.io/name=cloudnative-pg
```

---

## External-DNS

**Automatic DNS Record Management**

### Overview

| Property | Value |
|----------|-------|
| Namespace | external-dns |
| Provider | Cloudflare |
| Domain Filter | lab.axiomlayer.com |
| Policy | upsert-only |

### How It Works

```
┌─────────────────────────────────────────────────────────────────────┐
│                        External-DNS                                  │
│                                                                      │
│   ┌──────────────┐                      ┌──────────────┐            │
│   │   Ingress    │                      │  Cloudflare  │            │
│   │   Resource   │─────────────────────▶│     DNS      │            │
│   │              │    creates/updates   │              │            │
│   │ host: app.lab│    A record          │ A app.lab → │            │
│   │ .axiomlayer  │                      │ 100.x.x.x   │            │
│   └──────────────┘                      └──────────────┘            │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### Configuration

```yaml
# deployment args
- --source=ingress
- --domain-filter=lab.axiomlayer.com
- --provider=cloudflare
- --cloudflare-proxied=false
- --policy=upsert-only  # Won't delete records
- --txt-owner-id=k3s-homelab
- --txt-prefix=external-dns-
```

### Commands

```bash
# View logs
kubectl logs -n external-dns -l app.kubernetes.io/name=external-dns -f

# Check what records it would manage
kubectl get ingress -A -o jsonpath='{range .items[*]}{.spec.rules[*].host}{"\n"}{end}'
```

---

## Loki + Promtail

**Log Aggregation**

### Overview

| Component | Namespace | Purpose |
|-----------|-----------|---------|
| Loki | monitoring | Log storage and querying |
| Promtail | monitoring | Log collection (DaemonSet) |

### Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                                                                      │
│   ┌─────────┐    ┌─────────┐    ┌─────────┐                        │
│   │ Pod     │    │ Pod     │    │ Pod     │                        │
│   │ logs    │    │ logs    │    │ logs    │                        │
│   └────┬────┘    └────┬────┘    └────┬────┘                        │
│        │              │              │                              │
│        └──────────────┼──────────────┘                              │
│                       │                                              │
│                ┌──────▼──────┐                                       │
│                │  Promtail   │  (DaemonSet - each node)             │
│                │  (scrapes)  │                                       │
│                └──────┬──────┘                                       │
│                       │                                              │
│                ┌──────▼──────┐                                       │
│                │    Loki     │                                       │
│                │  (stores)   │                                       │
│                └──────┬──────┘                                       │
│                       │                                              │
│                ┌──────▼──────┐                                       │
│                │   Grafana   │                                       │
│                │  (queries)  │                                       │
│                └─────────────┘                                       │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### Querying Logs

In Grafana → Explore → Loki:

```logql
# All logs from a namespace
{namespace="campfire"}

# Errors only
{namespace="campfire"} |= "error"

# JSON parsing
{namespace="open-webui"} | json | level="error"
```

---

## Prometheus + Grafana

**Metrics and Visualization**

### Overview

| Component | Namespace | URL |
|-----------|-----------|-----|
| Prometheus | monitoring | (internal) |
| Grafana | monitoring | https://grafana.lab.axiomlayer.com |

### Grafana Data Sources

| Source | Type | Purpose |
|--------|------|---------|
| Prometheus | prometheus | Metrics |
| Loki | loki | Logs |

### Authentication

Grafana uses Authentik OIDC:

```yaml
GF_AUTH_GENERIC_OAUTH_ENABLED: "true"
GF_AUTH_GENERIC_OAUTH_NAME: "Authentik"
GF_AUTH_GENERIC_OAUTH_CLIENT_ID: grafana
GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET: ${secret}
GF_AUTH_GENERIC_OAUTH_AUTH_URL: https://auth.lab.axiomlayer.com/application/o/authorize/
GF_AUTH_GENERIC_OAUTH_TOKEN_URL: https://auth.lab.axiomlayer.com/application/o/token/
GF_AUTH_GENERIC_OAUTH_API_URL: https://auth.lab.axiomlayer.com/application/o/userinfo/
```

### Monitoring Extras Application

- `apps/argocd/applications/monitoring-extras.yaml` syncs the `infrastructure/monitoring` kustomization so Grafana has its own namespace bootstrap and TLS certificate (`grafana-certificate.yaml`) independent of the Helm chart defaults.
- The Application runs with `sync-wave: 4`, which means it lands before Grafana tries to read the TLS secret referenced by the ingress.
- Keep `infrastructure/grafana/sealed-secret.yaml` (OIDC client) and the monitoring extras Application in lockstep whenever you rotate Authentik credentials.

---

## Alertmanager

**Alert Management and Routing**

### Overview

| Property | Value |
|----------|-------|
| Namespace | alertmanager |
| URL | https://alerts.lab.axiomlayer.com |
| Receivers | (configurable) |

### Alert Rules

Defined in `infrastructure/alertmanager/prometheus-rules.yaml`:

| Alert | Severity | Trigger |
|-------|----------|---------|
| NodeNotReady | critical | Node unready 5+ min |
| NodeHighCPU | warning | CPU > 80% for 10 min |
| NodeHighMemory | warning | Memory > 85% for 10 min |
| NodeDiskPressure | critical | Disk > 90% |
| PodCrashLooping | warning | Multiple restarts |
| CertificateExpiringSoon | warning | Expires in < 30 days |
| LonghornVolumeHealthCritical | critical | Volume faulted |

---

## Actions Runner Controller

**Self-Hosted GitHub Actions Runners**

### Overview

| Property | Value |
|----------|-------|
| Namespace | actions-runner |
| Target | jasencdev organization |
| Labels | self-hosted, homelab |

### Components

| Component | Purpose |
|-----------|---------|
| arc-actions-runner-controller | Manages runner lifecycle |
| Runner pods | Execute GitHub Actions jobs |

### Usage

In any jasencdev org repo:

```yaml
jobs:
  build:
    runs-on: [self-hosted, homelab]
    steps:
      - uses: actions/checkout@v4
      - run: echo "Running on homelab!"
```

### Commands

```bash
# Check runners
kubectl get runners -n actions-runner

# Check controller
kubectl get pods -n actions-runner -l app.kubernetes.io/name=actions-runner-controller

# View runner logs
kubectl logs -n actions-runner -l actions.github.com/scale-set-name=homelab-runner
```

