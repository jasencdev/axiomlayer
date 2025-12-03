# Applications Reference

Comprehensive documentation for all applications deployed in the homelab cluster.

## Table of Contents

- [Application Inventory](#application-inventory)
- [Campfire](#campfire)
- [n8n (autom8)](#n8n-autom8)
- [Open WebUI](#open-webui)
- [Outline](#outline)
- [Plane](#plane)
- [PocketBase](#pocketbase)
- [Telnet Server](#telnet-server)
- [Dashboard](#dashboard)

---

## Application Inventory

| Application | URL | Namespace | SSO | Database | Storage |
|-------------|-----|-----------|-----|----------|---------|
| Campfire | chat.lab.axiomlayer.com | campfire | Yes | SQLite | 5Gi Longhorn |
| n8n | autom8.lab.axiomlayer.com | n8n | Yes | PostgreSQL (CNPG) | 5Gi Longhorn |
| Open WebUI | ai.lab.axiomlayer.com | open-webui | Yes | PostgreSQL (CNPG) | 5Gi Longhorn |
| Outline | docs.lab.axiomlayer.com | outline | Yes | PostgreSQL (CNPG) + Redis | 5Gi Longhorn |
| Plane | plane.lab.axiomlayer.com | plane | Yes | PostgreSQL (Helm) | 10Gi Longhorn |
| PocketBase | pb.lab.axiomlayer.com/_/ | pocketbase | Yes | SQLite (embedded) | 5Gi Longhorn |
| Telnet Server | telnet.lab.axiomlayer.com | telnet-server | Yes | None | None |
| Dashboard | db.lab.axiomlayer.com | dashboard | Yes | None | None |

---

## Campfire

**Team chat application by 37signals (Basecamp)**

### Overview

| Property | Value |
|----------|-------|
| URL | https://chat.lab.axiomlayer.com |
| Namespace | campfire |
| Image | ghcr.io/jasencdev/campfire |
| Port | 80 |
| Replicas | 1 |
| Architecture | amd64 only |

### Components

```
campfire/
├── namespace.yaml
├── deployment.yaml
├── service.yaml
├── certificate.yaml
├── ingress.yaml           # Main app + static bypass
├── pvc.yaml               # 5Gi for /rails/storage
├── configmap.yaml         # RAILS_ENV, etc.
├── sealed-secret.yaml     # SECRET_KEY_BASE, VAPID keys
├── sealed-pull-secret.yaml # GHCR credentials
├── networkpolicy.yaml
├── pdb.yaml
└── kustomization.yaml
```

### Configuration

**Environment Variables (ConfigMap):**
```yaml
DISABLE_SSL: "true"        # TLS handled by Traefik
RAILS_ENV: "production"
RAILS_LOG_TO_STDOUT: "true"
```

**Secrets (Sealed Secret):**
- `SECRET_KEY_BASE`: Rails secret key
- `VAPID_PUBLIC_KEY`: Web push public key
- `VAPID_PRIVATE_KEY`: Web push private key

### Ingress Routes

| Path | Auth | Purpose |
|------|------|---------|
| / | Yes | Main application |
| /webmanifest.json | No | PWA manifest |
| /service-worker.js | No | Push notifications |
| /cable | No | WebSocket (ActionCable) |
| /assets/* | No | Static assets |

### Push Notifications

Campfire uses VAPID (Voluntary Application Server Identification) for web push:

1. Generate keys: `npx web-push generate-vapid-keys`
2. Seal and deploy the keys in `sealed-secret.yaml`
3. Service worker at `/service-worker.js` handles subscriptions

### Troubleshooting

**Push notifications not working:**
```bash
# Check VAPID key is set correctly
kubectl get secret campfire-secret -n campfire -o jsonpath='{.data.VAPID_PUBLIC_KEY}' | base64 -d
```

**Image pull errors:**
```bash
# Verify GHCR pull secret
kubectl get secret ghcr-pull-secret -n campfire -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d
```

---

## n8n (autom8)

**Workflow automation platform**

### Overview

| Property | Value |
|----------|-------|
| URL | https://autom8.lab.axiomlayer.com |
| Namespace | n8n |
| Image | n8nio/n8n |
| Port | 5678 |
| Replicas | 1 |

### Components

```
n8n/
├── namespace.yaml
├── deployment.yaml
├── service.yaml
├── certificate.yaml
├── ingress.yaml
├── pvc.yaml               # 5Gi for workflows
├── postgres-cluster.yaml  # CloudNativePG
├── sealed-secret.yaml
├── networkpolicy.yaml
└── kustomization.yaml
```

### Database

Uses CloudNativePG for PostgreSQL:

```yaml
# postgres-cluster.yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: n8n-db
  namespace: n8n
spec:
  instances: 1
  storage:
    size: 5Gi
    storageClass: longhorn
```

**Connection string:**
```
postgresql://n8n:${password}@n8n-db-rw.n8n.svc:5432/n8n
```

### Configuration

**Key Environment Variables:**
```yaml
N8N_HOST: autom8.lab.axiomlayer.com
N8N_PROTOCOL: https
N8N_PORT: "5678"
WEBHOOK_URL: https://autom8.lab.axiomlayer.com/
DB_TYPE: postgresdb
DB_POSTGRESDB_HOST: n8n-db-rw.n8n.svc
```

### Webhooks

n8n webhooks are accessible at:
```
https://autom8.lab.axiomlayer.com/webhook/{workflow-id}
https://autom8.lab.axiomlayer.com/webhook-test/{workflow-id}
```

**Note:** Webhook paths bypass SSO authentication via ingress annotations.

---

## Open WebUI

**AI chat interface for Ollama**

### Overview

| Property | Value |
|----------|-------|
| URL | https://ai.lab.axiomlayer.com |
| Namespace | open-webui |
| Image | ghcr.io/open-webui/open-webui |
| Port | 8080 |
| Replicas | 1 |

### Architecture

```
┌─────────────────────┐     Tailscale      ┌─────────────────────┐
│    Open WebUI       │◄──────────────────▶│     siberian        │
│  (K8s cluster)      │                    │  (GPU workstation)  │
│                     │                    │                     │
│  ai.lab.axiomlayer  │                    │  Ollama server      │
│                     │                    │  RTX 5070 Ti 16GB   │
└─────────────────────┘                    └─────────────────────┘
```

### Components

```
open-webui/
├── namespace.yaml
├── deployment.yaml
├── service.yaml
├── certificate.yaml
├── ingress.yaml
├── pvc.yaml               # 5Gi for uploads
├── postgres-cluster.yaml  # CloudNativePG
├── configmap.yaml         # Ollama connection
├── sealed-secret.yaml
├── networkpolicy.yaml
└── kustomization.yaml
```

### Configuration

**ConfigMap:**
```yaml
OLLAMA_BASE_URL: "http://siberian:11434"  # Tailscale hostname
WEBUI_AUTH: "false"                        # Using Authentik SSO
```

### Ollama Connection

The Ollama estate currently uses two Tailscale endpoints:

| Purpose | Host | Tailscale IP | Notes |
|---------|------|--------------|-------|
| Generation (chat) | `siberian` | `100.115.3.88` | Primary RTX 5070 Ti workstation; referenced by `OLLAMA_BASE_URL` in the ConfigMap. |
| Embeddings | `panther` | `100.79.124.94` | Local node dedicated to embedding workloads; reachable directly for batch jobs. |

Both nodes sit on the Tailscale mesh and expose Ollama on port `11434`. Open WebUI talks to the generation endpoint, while tooling that needs dedicated embedding throughput can call the embedding node directly.

**Recommended Models (16GB VRAM):**

| Model | Size | VRAM | Use Case |
|-------|------|------|----------|
| llama3.2:3b | 2GB | 2GB | Fast, general |
| llama3.1:8b | 4.7GB | 5GB | Balanced |
| deepseek-r1:14b | 9GB | 9GB | Reasoning |
| codellama:13b | 7GB | 8GB | Code |
| qwen2.5:14b | 9GB | 9GB | Multilingual |

### WebSocket Configuration

Open WebUI uses WebSockets for streaming responses:

```yaml
# ingress.yaml - separate WebSocket ingress
metadata:
  name: open-webui-ws
  annotations:
    # No SSO for WebSocket upgrade
spec:
  rules:
    - host: ai.lab.axiomlayer.com
      http:
        paths:
          - path: /ws
            pathType: Prefix
```

---

## Outline

**Documentation and knowledge base wiki**

### Overview

| Property | Value |
|----------|-------|
| URL | https://docs.lab.axiomlayer.com |
| Namespace | outline |
| Image | outlinewiki/outline |
| Port | 3000 |
| Replicas | 1 |

### Components

```
outline/
├── namespace.yaml
├── deployment.yaml
├── service.yaml
├── certificate.yaml
├── ingress.yaml
├── pvc.yaml               # 5Gi for attachments
├── postgres-cluster.yaml  # CloudNativePG
├── redis.yaml             # Redis Deployment + Service (session cache)
├── sealed-secret.yaml
├── networkpolicy.yaml
├── pdb.yaml
└── kustomization.yaml
```

### Dependencies

1. **PostgreSQL** (CloudNativePG)
2. **Redis** (deployed in outline namespace)

### Configuration

**Key Environment Variables:**
```yaml
URL: https://docs.lab.axiomlayer.com
DATABASE_URL: postgres://outline:${pass}@outline-db-rw.outline.svc:5432/outline
REDIS_URL: redis://redis.outline.svc:6379
SECRET_KEY: ${from_sealed_secret}
UTILS_SECRET: ${from_sealed_secret}
```

### OIDC Integration

Outline uses Authentik OIDC directly (not forward auth):

```yaml
OIDC_CLIENT_ID: outline
OIDC_CLIENT_SECRET: ${from_sealed_secret}
OIDC_AUTH_URI: https://auth.lab.axiomlayer.com/application/o/authorize/
OIDC_TOKEN_URI: https://auth.lab.axiomlayer.com/application/o/token/
OIDC_USERINFO_URI: https://auth.lab.axiomlayer.com/application/o/userinfo/
```

### Redis Cache

- `apps/outline/redis.yaml` runs Redis with `runAsUser: 999`, probes, and an `emptyDir` volume (Outline only needs an in-memory cache).
- The service `redis.outline.svc:6379` lines up with `REDIS_URL` in the deployment.
- Network policies scope Redis ingress to the Outline pods while still allowing egress to Authentik and CNPG endpoints for sign-in callbacks.

---

## Plane

**Project management and issue tracking**

### Overview

| Property | Value |
|----------|-------|
| URL | https://plane.lab.axiomlayer.com |
| Namespace | plane |
| Deployment | Helm chart |
| Replicas | 1 (each component) |

### Architecture

Plane is a complex application with multiple components:

```
┌──────────────────────────────────────────────────────────────┐
│                         plane namespace                       │
│                                                              │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐    │
│  │   Web    │  │   API    │  │  Worker  │  │   Beat   │    │
│  │ (React)  │  │ (Django) │  │ (Celery) │  │ (Celery) │    │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘    │
│       │             │             │             │           │
│       └──────┬──────┴──────┬──────┴──────┬──────┘           │
│              │             │             │                   │
│       ┌──────▼─────┐ ┌─────▼─────┐ ┌─────▼─────┐           │
│       │ PostgreSQL │ │   Redis   │ │   MinIO   │           │
│       │ (Helm)     │ │  (Helm)   │ │  (Helm)   │           │
│       └────────────┘ └───────────┘ └───────────┘           │
└──────────────────────────────────────────────────────────────┘
```

### Components

Plane uses its own Helm chart with embedded dependencies:

| Component | Purpose | PVC Size |
|-----------|---------|----------|
| plane-web | React frontend | - |
| plane-api | Django API | - |
| plane-worker | Celery workers | - |
| plane-beat | Celery beat scheduler | - |
| plane-pgdb | PostgreSQL | 10Gi |
| plane-redis | Redis cache/queue | 1Gi |
| plane-minio | S3-compatible storage | 10Gi |
| plane-rabbitmq | Message queue | 1Gi |

### Extras

Additional manifests in `apps/plane/`:
- `certificate.yaml`: TLS certificate
- `ingress.yaml`: Custom ingress with SSO

---

## PocketBase

**Backend as a Service (BaaS) platform**

### Overview

| Property | Value |
|----------|-------|
| URL | https://pb.lab.axiomlayer.com/_/ |
| API Base | https://pb.lab.axiomlayer.com/api |
| Namespace | pocketbase |
| Image | ghcr.io/muchobien/pocketbase:latest |
| Port | 8090 |
| Replicas | 1 |

### Components

```
pocketbase/
├── namespace.yaml
├── deployment.yaml
├── service.yaml
├── certificate.yaml
├── ingress.yaml         # SSO protected
├── pvc.yaml             # 5Gi for /pb_data
├── networkpolicy.yaml
└── kustomization.yaml
```

### Database

PocketBase uses an embedded SQLite database stored in the persistent volume at `/pb_data`. This includes:
- Application data
- User authentication
- File uploads
- Logs

### Configuration

PocketBase is configured through its web admin interface at `/_/`. On first access:
1. Navigate to https://pb.lab.axiomlayer.com/_/
2. Create the initial admin account
3. Configure collections, API rules, and authentication providers

### API Access

**REST API:**
```
https://pb.lab.axiomlayer.com/api/collections/{collection}/records
```

**Realtime subscriptions (SSE):**
```
https://pb.lab.axiomlayer.com/api/realtime
```

### Authentication

PocketBase supports multiple auth methods:
- Email/password
- OAuth2 providers
- API keys

Note: The ingress is protected by Authentik forward auth, so users must authenticate via SSO before accessing PocketBase. Internal PocketBase authentication is separate and managed within the application.

### Use Cases

- Mobile/web app backends
- Rapid prototyping
- Simple CRUD APIs
- File storage with API access
- User authentication for client apps

### Network Policies

PocketBase has restricted network access:
- **Ingress:** Only from Traefik (port 8090)
- **Egress:** DNS resolution + HTTPS for OAuth providers/webhooks

### Backup Strategy

PocketBase data is backed up via Longhorn volume snapshots:
- Daily snapshots retained for 7 days
- Weekly snapshots retained for 4 weeks
- Remote backups to NAS

For point-in-time recovery or migration, the SQLite database can be exported directly:
```bash
kubectl cp pocketbase/$(kubectl get pod -n pocketbase -l app.kubernetes.io/name=pocketbase -o jsonpath='{.items[0].metadata.name}'):/pb_data/data.db ./pocketbase-backup.db
```

### Troubleshooting

**Admin UI not loading:**
```bash
# Check pod status
kubectl get pods -n pocketbase

# Check logs
kubectl logs -n pocketbase -l app.kubernetes.io/name=pocketbase
```

**API returning 403:**
- Verify collection API rules in admin UI
- Check if authentication is required for the endpoint

**Storage issues:**
```bash
# Check PVC status
kubectl get pvc -n pocketbase

# Check Longhorn volume health
kubectl get volumes.longhorn.io -n longhorn-system | grep pocketbase
```

---

## Telnet Server

**Demo application showcasing SSO integration**

### Overview

| Property | Value |
|----------|-------|
| URL | https://telnet.lab.axiomlayer.com |
| Namespace | telnet-server |
| Image | Custom telnet server |
| Ports | 2323 (telnet), 8080 (metrics) |
| Replicas | 1 |

### Purpose

This is a demonstration application that:
1. Shows SSO headers passed from Authentik
2. Exposes telnet service via LoadBalancer
3. Provides Prometheus metrics

### Services

| Service | Type | Port | Purpose |
|---------|------|------|---------|
| telnet-server | LoadBalancer | 2323 | Telnet access |
| telnet-metrics | ClusterIP | 8080 | Prometheus metrics |

### Access

```bash
# Via telnet (any node IP)
telnet 100.67.134.110 2323

# Via web (metrics)
https://telnet.lab.axiomlayer.com
```

---

## Dashboard

**Service portal for homelab applications**

### Overview

| Property | Value |
|----------|-------|
| URL | https://db.lab.axiomlayer.com |
| Namespace | dashboard |
| Image | nginx:alpine |
| Port | 80 |
| Replicas | 1 |

### Purpose

A simple static HTML dashboard listing all homelab services with:
- Service cards with descriptions
- Direct links to each application
- Status indicator
- Dark theme UI

### Configuration

The dashboard content is stored in a ConfigMap:

```yaml
# configmap.yaml
data:
  index.html: |
    <!DOCTYPE html>
    <html>
    <!-- Dashboard HTML -->
    </html>
```

### Updating

To add new applications to the dashboard:

1. Edit `apps/dashboard/configmap.yaml`
2. Add a new card in the appropriate section
3. Commit and push - ArgoCD syncs automatically

---

## Adding a New Application

See [APP-DEPLOYMENT-WORKFLOW.md](./APP-DEPLOYMENT-WORKFLOW.md) for detailed instructions on deploying new applications.

### Quick Checklist

- [ ] Create namespace with standard labels
- [ ] Create deployment with security context
- [ ] Create service (ClusterIP)
- [ ] Create certificate (Let's Encrypt)
- [ ] Create ingress with SSO middleware
- [ ] Create sealed secrets (if needed)
- [ ] Create PVC (if storage needed)
- [ ] Create network policies
- [ ] Create ArgoCD Application manifest
- [ ] Add to applications kustomization
- [ ] Update dashboard configmap
- [ ] Update README.md Live Services table
