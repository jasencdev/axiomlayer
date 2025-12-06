# CLAUDE.md - GitOps Repository

## Overview

K3s cluster deployed via GitHub Actions. Push to main triggers deploy.

## Stack

| Component | Technology | Purpose |
|-----------|------------|---------|
| Cluster | K3s | Lightweight Kubernetes |
| Deploy | GitHub Actions | Push-based deploys via Tailscale |
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

## Deploy Flow

1. Push to `main` branch
2. GitHub Actions validates manifests
3. Actions connects to cluster via Tailscale
4. `kubectl apply -k` deploys changes

## Key Commands

```bash
# Validate manifests locally
./tests/validate-manifests.sh

# Manual deploy (from cluster)
kubectl apply -k infrastructure/sealed-secrets/
kubectl apply -k infrastructure/cert-manager/
kubectl apply -k infrastructure/external-dns/
kubectl apply -k infrastructure/minio/
kubectl apply -k infrastructure/authelia/
kubectl apply -k infrastructure/cloudflare-tunnel/
kubectl apply -k infrastructure/open-webui/
kubectl apply -k apps/outline/
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
2. Add to deploy step in `.github/workflows/ci.yaml`
3. Commit and push - deploys automatically

## GitHub Secrets Required

| Secret | Purpose |
|--------|---------|
| `TS_OAUTH_CLIENT_ID` | Tailscale OAuth client ID |
| `TS_OAUTH_SECRET` | Tailscale OAuth secret |
| `KUBECONFIG` | Base64-encoded kubeconfig |
