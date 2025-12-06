# Documentation

Minimal documentation for the core MVP GitOps stack.

## Stack Overview

- **GitOps**: ArgoCD
- **TLS**: cert-manager + Let's Encrypt
- **DNS**: external-dns + Cloudflare
- **Secrets**: Sealed Secrets
- **Auth**: Authelia (lightweight SSO)
- **Ingress**: Cloudflare Tunnel
- **Storage**: MinIO (S3-compatible)

## Applications

- **Open WebUI**: AI chat interface (SQLite backend)
- **Outline**: Documentation wiki (PostgreSQL + Redis)

## Quick Start

1. Install K3s on your cluster
2. Run `scripts/bootstrap-argocd.sh`
3. Configure secrets (see SECRETS.md)
4. ArgoCD syncs all applications automatically

## Directory Structure

```
apps/           # Application manifests
infrastructure/ # Core infrastructure
scripts/        # Bootstrap scripts
tests/          # Validation tests
```
