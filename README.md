# Axiomlayer

Minimal GitOps-managed K3s stack with ArgoCD, lightweight SSO, and Cloudflare Tunnel.

## Stack

| Component | Technology |
|-----------|------------|
| Cluster | K3s |
| GitOps | ArgoCD |
| Ingress | Cloudflare Tunnel |
| TLS | cert-manager + Let's Encrypt |
| DNS | external-dns + Cloudflare |
| Auth | Authelia |
| Storage | local-path-provisioner |
| Object Storage | MinIO |
| Secrets | Sealed Secrets |

## Applications

| App | Purpose |
|-----|---------|
| Open WebUI | AI chat interface (SQLite) |
| Outline | Documentation wiki (PostgreSQL + Redis) |

## Quick Start

1. Install K3s on your cluster
2. Run `./scripts/bootstrap-argocd.sh`
3. Configure secrets (see `docs/SECRETS.md`)
4. ArgoCD syncs all applications automatically

## Directory Structure

```
apps/
├── argocd/           # GitOps + Application CRDs
└── outline/          # Documentation wiki

infrastructure/
├── authelia/         # SSO provider
├── cert-manager/     # TLS certificates
├── cloudflare-tunnel/# External ingress
├── external-dns/     # DNS management
├── minio/            # Object storage
├── open-webui/       # AI chat interface
└── sealed-secrets/   # Secret management
```

## Adding an Application

1. Create `apps/{service}/` with manifests
2. Create ArgoCD Application in `apps/argocd/applications/`
3. Add to `apps/argocd/applications/kustomization.yaml`
4. Commit and push

## License

MIT
