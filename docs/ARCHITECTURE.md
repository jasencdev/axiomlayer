# Architecture Overview

This document provides a comprehensive technical overview of the homelab Kubernetes cluster architecture.

## Table of Contents

- [Cluster Topology](#cluster-topology)
- [Network Architecture](#network-architecture)
- [Storage Architecture](#storage-architecture)
- [Security Architecture](#security-architecture)
- [GitOps Architecture](#gitops-architecture)
- [High Availability](#high-availability)

---

## Cluster Topology

### Node Inventory

| Node | Role | Hardware | CPU | RAM | Storage | Tailscale IP | Local IP |
|------|------|----------|-----|-----|---------|--------------|----------|
| neko | control-plane, etcd, master | Mini PC | AMD Ryzen | 32GB | 462GB NVMe | 100.67.134.110 | 192.168.1.167 |
| neko2 | control-plane, etcd, master | Mini PC | AMD Ryzen | 32GB | 462GB NVMe | 100.106.35.14 | 192.168.1.103 |
| bobcat | agent | Raspberry Pi 5 | ARM64 | 8GB | 500GB SSD | 100.121.67.60 | 192.168.1.49 |

### External Resources

| Resource | Purpose | Location | Connection |
|----------|---------|----------|------------|
| siberian | GPU workstation (Ollama) | Local network | Tailscale mesh |
| UniFi NAS | Backup storage | 192.168.1.234 | NFS via proxy |

### Kubernetes Version

- **Distribution**: K3s v1.33.6+k3s1
- **Container Runtime**: containerd 2.1.5
- **CNI**: Flannel (over Tailscale interface)

---

## Network Architecture

### Network Layers

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Internet                                     │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Cloudflare DNS                                    │
│         *.lab.axiomlayer.com → Tailscale IPs                        │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Tailscale Mesh                                    │
│    neko (100.67.134.110) ←→ neko2 (100.106.35.14) ←→ bobcat         │
│                           ↕                                          │
│                   siberian (GPU workstation)                         │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Traefik Ingress                                   │
│              TLS termination + routing                               │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                 Authentik Forward Auth                               │
│              SSO verification middleware                             │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Application Pods                                  │
│              (receive X-Authentik-* headers)                         │
└─────────────────────────────────────────────────────────────────────┘
```

### DNS Configuration

| Record Type | Name | Value | Manager |
|-------------|------|-------|---------|
| A | *.lab.axiomlayer.com | 100.67.134.110 | External-DNS |
| A | *.lab.axiomlayer.com | 100.106.35.14 | External-DNS |
| A | *.lab.axiomlayer.com | 100.121.67.60 | External-DNS |
| TXT | _acme-challenge.*.lab.axiomlayer.com | (dynamic) | cert-manager |

### Service Mesh

The cluster uses Flannel CNI configured to use the Tailscale interface (`tailscale0`), enabling:

- Pod-to-pod communication across nodes via Tailscale
- Automatic encryption via WireGuard (Tailscale)
- No need for traditional VPN or overlay networks

### Load Balancing

K3s includes ServiceLB (formerly Klipper), which:

- Exposes LoadBalancer services on all node IPs
- Routes traffic to appropriate pods
- Used for Traefik ingress and Telnet demo service

---

## Storage Architecture

### Storage Classes

| Class | Provider | Replication | Use Case |
|-------|----------|-------------|----------|
| longhorn | Longhorn | 3 replicas | Production workloads |
| longhorn-2-replicas | Longhorn | 2 replicas | Large volumes |
| local-path | Rancher Local Path | None | Legacy/testing |

### Longhorn Configuration

```
┌─────────────────────────────────────────────────────────────────────┐
│                      Longhorn Manager                                │
│                    (longhorn-system namespace)                       │
└─────────────────────────────────────────────────────────────────────┘
                                │
                ┌───────────────┼───────────────┐
                ▼               ▼               ▼
         ┌──────────┐    ┌──────────┐    ┌──────────┐
         │   neko   │    │   neko2  │    │  bobcat  │
         │ 462GB    │    │ 462GB    │    │ 500GB    │
         │ NVMe     │    │ NVMe     │    │ SSD      │
         └──────────┘    └──────────┘    └──────────┘
```

### Volume Inventory

| Namespace | PVC | Size | Storage Class | Purpose |
|-----------|-----|------|---------------|---------|
| authentik | data-authentik-postgresql-0 | 8Gi | local-path | Authentik PostgreSQL |
| authentik | redis-data-authentik-redis-master-0 | 8Gi | local-path | Authentik Redis |
| campfire | campfire-storage | 5Gi | longhorn | Campfire data |
| default | postgres-1/2/3 | 10Gi each | longhorn | Shared PostgreSQL cluster |
| monitoring | storage-loki-0 | 10Gi | longhorn | Log storage |
| n8n | n8n-data | 5Gi | longhorn | n8n workflows |
| n8n | n8n-db-1 | 5Gi | longhorn | n8n PostgreSQL |
| open-webui | open-webui-data | 5Gi | longhorn | Open WebUI data |
| open-webui | open-webui-db-1 | 10Gi | longhorn | Open WebUI PostgreSQL |
| outline | outline-data | 5Gi | longhorn | Outline attachments |
| outline | outline-db-1 | 5Gi | longhorn | Outline PostgreSQL |
| plane | pvc-plane-* | various | longhorn | Plane components |

### Backup Architecture

```
┌──────────────────────┐     ┌──────────────────────┐     ┌──────────────────────┐
│   Longhorn Volume    │────▶│     NFS Proxy        │────▶│     UniFi NAS        │
│   (any node)         │     │     (neko only)      │     │  192.168.1.234       │
└──────────────────────┘     └──────────────────────┘     └──────────────────────┘
                                      │
                                      │ ClusterIP Service
                                      │ (accessible from all nodes)
                                      ▼
                             ┌──────────────────────┐
                             │   Longhorn Backup    │
                             │     Controller       │
                             └──────────────────────┘
```

**Why NFS Proxy?**

UniFi NAS NFS exports only allow a single client IP. The NFS proxy:
1. Runs on neko (192.168.1.167) - the allowed IP
2. Mounts the NAS share locally
3. Re-exports via Kubernetes ClusterIP service
4. All nodes can now access backups via the service

---

## Security Architecture

### Authentication Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                         User Request                                 │
│                    https://app.lab.axiomlayer.com                   │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      Traefik Ingress                                 │
│              Checks forward-auth middleware                          │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Authentik Outpost                                 │
│              /outpost.goauthentik.io/auth/nginx                     │
│                                                                      │
│    ┌─────────────────────────────────────────────────────────┐      │
│    │ Has valid session cookie?                                │      │
│    │   YES → Return 200 + X-Authentik-* headers              │      │
│    │   NO  → Return 401 + redirect to login                  │      │
│    └─────────────────────────────────────────────────────────┘      │
└─────────────────────────────────────────────────────────────────────┘
                                │
              ┌─────────────────┴─────────────────┐
              ▼                                   ▼
     ┌──────────────────┐              ┌──────────────────┐
     │   200 OK         │              │   401 Redirect   │
     │   Forward to app │              │   → Login page   │
     └──────────────────┘              └──────────────────┘
```

### SSO Headers

When authenticated, applications receive:

```
X-Authentik-Username: jasen
X-Authentik-Email: jasen@axiomlayer.com
X-Authentik-Groups: admins,users
X-Authentik-Uid: abc123def456
X-Authentik-Name: Jasen
```

### Network Policies

Default-deny network policies are applied to all namespaces:

```yaml
# Pattern: {app}-default-deny
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {app}-default-deny
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

Then explicit allow rules for:
- `{app}-allow-ingress`: Allow from Traefik
- `{app}-allow-egress`: Allow to DNS, specific services

### Sealed Secrets

All secrets are encrypted using Bitnami Sealed Secrets:

| Namespace | Secret | Purpose |
|-----------|--------|---------|
| actions-runner | github-runner-token | GitHub PAT for runners |
| campfire | campfire-secret | Rails secrets + VAPID keys |
| campfire | ghcr-pull-secret | GHCR image pull credentials |
| cert-manager | cloudflare-api-token | DNS-01 challenge |
| external-dns | cloudflare-api-token | DNS record management |
| monitoring | grafana-oidc-secret | Grafana SSO |
| n8n | n8n-secrets | n8n encryption keys |
| open-webui | open-webui-secret | API keys |
| outline | outline-secrets | Outline secrets |

### Pod Security

All deployments enforce:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  seccompProfile:
    type: RuntimeDefault
containers:
  - securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true  # where possible
      capabilities:
        drop: ["ALL"]
```

---

## GitOps Architecture

### App of Apps Pattern

```
┌─────────────────────────────────────────────────────────────────────┐
│                         GitHub Repository                            │
│                   jasencdev/axiomlayer (main branch)                │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         ArgoCD Server                                │
│                    (argocd namespace)                                │
│                                                                      │
│    ┌─────────────────────────────────────────────────────────┐      │
│    │              root.yaml (App of Apps)                     │      │
│    │         watches: apps/argocd/applications/              │      │
│    └─────────────────────────────────────────────────────────┘      │
│                                │                                     │
│         ┌──────────────────────┼──────────────────────┐             │
│         ▼                      ▼                      ▼             │
│    ┌──────────┐          ┌──────────┐          ┌──────────┐        │
│    │cert-mgr  │          │authentik │          │campfire  │        │
│    │.yaml     │          │.yaml     │          │.yaml     │        │
│    └──────────┘          └──────────┘          └──────────┘        │
│         │                      │                      │             │
│         ▼                      ▼                      ▼             │
│  infrastructure/        infrastructure/         apps/               │
│  cert-manager/          authentik/              campfire/           │
└─────────────────────────────────────────────────────────────────────┘
```

### Sync Flow

1. Developer pushes to `main` branch
2. ArgoCD polls repository (every 3 minutes) or receives webhook
3. `root.yaml` detects changes in `apps/argocd/applications/`
4. New Application manifests are applied
5. Each Application syncs its target path
6. Resources are created/updated in cluster

### Application Lifecycle

```
┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│   Unknown    │───▶│   OutOfSync  │───▶│   Syncing    │───▶│    Synced    │
└──────────────┘    └──────────────┘    └──────────────┘    └──────────────┘
                                                                    │
                                                                    ▼
                                                            ┌──────────────┐
                                                            │   Healthy    │
                                                            └──────────────┘
```

---

## High Availability

### Control Plane HA

- 2 control-plane nodes (neko, neko2)
- Embedded etcd with 2-node quorum
- K3s API server load balanced via Tailscale

### Application HA

| Component | Replicas | Strategy |
|-----------|----------|----------|
| ArgoCD Application Controller | 1 | StatefulSet |
| ArgoCD Server | 1 | Deployment |
| Traefik | 1 | DaemonSet-like |
| Authentik Server | 1 | Deployment |
| Longhorn Manager | 3 | DaemonSet |
| Most apps | 1 | Deployment |

### Storage HA

- Longhorn volumes replicated to 3 nodes (or 2 for large volumes)
- Automatic failover when node unavailable
- Backup to external NAS for disaster recovery

### Database HA

CloudNativePG clusters can be configured with multiple instances:

```yaml
spec:
  instances: 3  # For HA
  # or
  instances: 1  # For single-node (current setup for most apps)
```

Current PostgreSQL topology:
- `postgres` cluster: 3 instances (HA)
- Per-app databases: 1 instance each (via CloudNativePG)

---

## Diagrams

### Complete System Diagram

```
                                    ┌─────────────────────┐
                                    │      Internet       │
                                    └──────────┬──────────┘
                                               │
                                    ┌──────────▼──────────┐
                                    │    Cloudflare DNS   │
                                    │  *.lab.axiomlayer   │
                                    └──────────┬──────────┘
                                               │
                    ┌──────────────────────────┼──────────────────────────┐
                    │                  Tailscale Mesh                      │
                    │                                                      │
    ┌───────────────┼───────────────┬───────────────┬────────────────────┐│
    │               │               │               │                    ││
    ▼               ▼               ▼               ▼                    ││
┌───────┐      ┌───────┐      ┌───────┐      ┌──────────┐               ││
│ neko  │      │ neko2 │      │bobcat │      │ siberian │               ││
│control│◄────▶│control│◄────▶│ agent │      │  (GPU)   │               ││
│ plane │      │ plane │      │ (Pi5) │      │  Ollama  │               ││
└───┬───┘      └───┬───┘      └───┬───┘      └────┬─────┘               ││
    │              │              │               │                      ││
    └──────────────┴──────────────┴───────────────┘                      ││
                    │                                                     ││
         ┌──────────┴──────────┐                                         ││
         │    K3s Cluster      │                                         ││
         │  ┌──────────────┐   │                                         ││
         │  │   Traefik    │   │                                         ││
         │  │  (Ingress)   │   │                                         ││
         │  └──────┬───────┘   │                                         ││
         │         │           │                                         ││
         │  ┌──────▼───────┐   │                                         ││
         │  │  Authentik   │   │                                         ││
         │  │    (SSO)     │   │                                         ││
         │  └──────┬───────┘   │                                         ││
         │         │           │                                         ││
         │  ┌──────▼───────┐   │                                         ││
         │  │ Applications │   │                                         ││
         │  │ ┌─────────┐  │   │                                         ││
         │  │ │Campfire │  │   │                                         ││
         │  │ │Plane    │  │   │                                         ││
         │  │ │Outline  │  │   │                                         ││
         │  │ │n8n      │  │   │                                         ││
         │  │ │Open WebUI│─┼───┼─────────────────────────────────────────┘│
         │  │ │...      │  │   │                                          │
         │  │ └─────────┘  │   │                                          │
         │  └──────────────┘   │                                          │
         │         │           │                                          │
         │  ┌──────▼───────┐   │                                          │
         │  │  Longhorn    │   │                                          │
         │  │  (Storage)   │   │                                          │
         │  └──────┬───────┘   │                                          │
         └─────────┼───────────┘                                          │
                   │                                                      │
         ┌─────────▼───────────┐                                          │
         │    NFS Proxy        │                                          │
         │    (on neko)        │                                          │
         └─────────┬───────────┘                                          │
                   │                                                      │
         ┌─────────▼───────────┐                                          │
         │    UniFi NAS        │──────────────────────────────────────────┘
         │  192.168.1.234      │
         │   /k8s-backup/      │
         └─────────────────────┘
```
