# CLAUDE.md - GitOps Repository

## Overview

GitOps-managed K3s cluster with ArgoCD, lightweight SSO, and TLS.

## Stack

| Component | Technology | Purpose |
|-----------|------------|---------|
| Cluster | K3s | Lightweight Kubernetes |
| GitOps | ArgoCD | Continuous deployment |
| Config | Kustomize | Manifest management |
| Ingress | Cloudflare Tunnel | External access |
| TLS | cert-manager + Let's Encrypt | Automatic certificates |
| DNS | external-dns + Cloudflare | DNS management |
| Auth | Authelia | Lightweight SSO |
| Storage | local-path-provisioner | Node-local storage |
| Object Storage | MinIO | S3-compatible storage |
| Secrets | Sealed Secrets | Encrypted secrets in Git |

## Structure

```
apps/
├── argocd/           # GitOps + Application CRDs
│   └── applications/ # ArgoCD Application manifests
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

## Applications

| App | Purpose | Database |
|-----|---------|----------|
| Open WebUI | AI chat interface | SQLite |
| Outline | Documentation wiki | PostgreSQL + Redis |

## Key Commands

```bash
# Validate manifests
./tests/validate-manifests.sh

# Check ArgoCD status
kubectl get applications -n argocd

# Bootstrap cluster
./scripts/bootstrap-argocd.sh
```

## Secrets Management

Use Sealed Secrets only - no plaintext secrets in Git.

```bash
# Create sealed secret
kubectl create secret generic {name} -n {namespace} \
  --from-literal=key=value --dry-run=client -o yaml | \
  kubeseal --format yaml > sealed-secret.yaml
```

## Adding a Service

1. Create `apps/{service}/` or `infrastructure/{service}/` with manifests
2. Create ArgoCD Application in `apps/argocd/applications/`
3. Add to `apps/argocd/applications/kustomization.yaml`
4. Commit and push - ArgoCD syncs automatically

## Required Secrets

- `cloudflare-tunnel-credentials`: CF Tunnel credentials
- `authelia-secrets`: JWT, session, storage keys
- `outline-secrets`: Database URL, OIDC credentials
- `open-webui-secret`: Application secret
