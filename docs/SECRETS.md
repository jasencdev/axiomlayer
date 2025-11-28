# Secrets Management

Comprehensive guide for managing secrets in the homelab cluster using Sealed Secrets.

## Table of Contents

- [Overview](#overview)
- [Sealed Secrets Architecture](#sealed-secrets-architecture)
- [Creating Sealed Secrets](#creating-sealed-secrets)
- [Secret Inventory](#secret-inventory)
- [Rotating Secrets](#rotating-secrets)
- [Backup and Recovery](#backup-and-recovery)
- [Best Practices](#best-practices)

---

## Overview

### Principles

1. **Never commit plaintext secrets to Git**
2. **Use Sealed Secrets for all sensitive data**
3. **Secrets are namespace-scoped** (encrypted for specific namespace)
4. **Controller holds the private key** (only it can decrypt)

### Components

| Component | Purpose | Location |
|-----------|---------|----------|
| Sealed Secrets Controller | Decrypts SealedSecrets | kube-system namespace |
| kubeseal CLI | Encrypts secrets locally | Developer machine |
| SealedSecret CRD | Encrypted secret in Git | Repository |
| Secret | Decrypted secret in cluster | Target namespace |

---

## Sealed Secrets Architecture

### Encryption Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Secret Creation Flow                                 │
│                                                                              │
│   ┌─────────────────┐                                                       │
│   │  kubectl create │                                                       │
│   │  secret ...     │                                                       │
│   │  --dry-run      │                                                       │
│   └────────┬────────┘                                                       │
│            │                                                                 │
│            ▼                                                                 │
│   ┌─────────────────┐     Fetches public key     ┌─────────────────┐       │
│   │    kubeseal     │◄───────────────────────────│  Sealed Secrets │       │
│   │                 │                            │   Controller    │       │
│   └────────┬────────┘                            └─────────────────┘       │
│            │                                                                 │
│            │ Encrypts with public key                                        │
│            ▼                                                                 │
│   ┌─────────────────┐                                                       │
│   │  SealedSecret   │                                                       │
│   │  (YAML file)    │─────────────────────────────────┐                    │
│   │  Safe for Git   │                                 │                    │
│   └─────────────────┘                                 │                    │
│                                                       │                    │
│                                                       ▼                    │
│                                              ┌─────────────────┐           │
│                                              │    Git Repo     │           │
│                                              └────────┬────────┘           │
│                                                       │                    │
│                                                       │ ArgoCD syncs       │
│                                                       ▼                    │
│                                              ┌─────────────────┐           │
│                                              │  Kubernetes     │           │
│                                              │  Cluster        │           │
│                                              └────────┬────────┘           │
│                                                       │                    │
│                                                       ▼                    │
│                                              ┌─────────────────┐           │
│                                              │ Sealed Secrets  │           │
│                                              │ Controller      │           │
│                                              │ (decrypts)      │           │
│                                              └────────┬────────┘           │
│                                                       │                    │
│                                                       ▼                    │
│                                              ┌─────────────────┐           │
│                                              │    Secret       │           │
│                                              │  (plaintext)    │           │
│                                              │  in cluster     │           │
│                                              └─────────────────┘           │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Key Management

The Sealed Secrets controller generates a key pair:
- **Private key**: Stored as a Secret in `kube-system` namespace
- **Public key**: Used by `kubeseal` to encrypt

```bash
# View sealing keys
kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key

# The active key
kubectl get secret -n kube-system sealed-secrets-key -o yaml
```

---

## Creating Sealed Secrets

### Basic Workflow

```bash
# Step 1: Create a regular secret (dry-run)
kubectl create secret generic my-secret \
  --namespace my-namespace \
  --from-literal=username=admin \
  --from-literal=password=supersecret \
  --dry-run=client -o yaml > /tmp/secret.yaml

# Step 2: Seal the secret
kubeseal \
  --controller-name=sealed-secrets \
  --controller-namespace=kube-system \
  --format yaml \
  < /tmp/secret.yaml \
  > my-sealed-secret.yaml

# Step 3: Clean up plaintext
rm /tmp/secret.yaml

# Step 4: Commit the sealed secret
git add my-sealed-secret.yaml
git commit -m "Add my-secret sealed secret"
```

### Creating Different Secret Types

#### Generic Secret (key-value pairs)

```bash
kubectl create secret generic app-secret \
  --namespace app \
  --from-literal=API_KEY=abc123 \
  --from-literal=DB_PASSWORD=secret \
  --dry-run=client -o yaml | \
  kubeseal --controller-name=sealed-secrets --controller-namespace=kube-system --format yaml
```

#### Docker Registry Secret

```bash
kubectl create secret docker-registry ghcr-pull-secret \
  --namespace app \
  --docker-server=ghcr.io \
  --docker-username=USERNAME \
  --docker-password=TOKEN \
  --dry-run=client -o yaml | \
  kubeseal --controller-name=sealed-secrets --controller-namespace=kube-system --format yaml
```

#### TLS Secret

```bash
kubectl create secret tls app-tls \
  --namespace app \
  --cert=./tls.crt \
  --key=./tls.key \
  --dry-run=client -o yaml | \
  kubeseal --controller-name=sealed-secrets --controller-namespace=kube-system --format yaml
```

#### From File

```bash
kubectl create secret generic config-secret \
  --namespace app \
  --from-file=config.json=./config.json \
  --dry-run=client -o yaml | \
  kubeseal --controller-name=sealed-secrets --controller-namespace=kube-system --format yaml
```

### One-Liner for Quick Sealing

```bash
# Create, seal, and save in one command
kubectl create secret generic my-secret -n my-namespace \
  --from-literal=key=value \
  --dry-run=client -o yaml | \
  kubeseal --controller-name=sealed-secrets --controller-namespace=kube-system --format yaml \
  > apps/my-app/sealed-secret.yaml
```

---

## Secret Inventory

### Current Sealed Secrets

| Namespace | Secret Name | Purpose | Keys |
|-----------|-------------|---------|------|
| actions-runner | github-runner-token | GitHub PAT | `github_token` |
| campfire | campfire-secret | Rails secrets | `SECRET_KEY_BASE`, `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY` |
| campfire | ghcr-pull-secret | Image pull | `.dockerconfigjson` |
| cert-manager | cloudflare-api-token | DNS-01 challenge | `api-token` |
| external-dns | cloudflare-api-token | DNS records | `api-token` |
| monitoring | grafana-oidc-secret | SSO | `client_secret` |
| n8n | n8n-secrets | Encryption | `N8N_ENCRYPTION_KEY` |
| open-webui | open-webui-secret | API keys | Various |
| outline | outline-secrets | App secrets | `SECRET_KEY`, `UTILS_SECRET`, `OIDC_CLIENT_SECRET` |

### Secret Contents Reference

#### Cloudflare API Token

```yaml
# Required permissions:
# - Zone:Read (for all zones)
# - DNS:Edit (for lab.axiomlayer.com zone)
data:
  api-token: <cloudflare-api-token>
```

#### GitHub Runner Token

```yaml
# Required scopes:
# - repo (for repository runners)
# - admin:org (for organization runners)
data:
  github_token: <github-pat>
```

#### Rails Application Secrets

```yaml
# Generate with: rails secret
data:
  SECRET_KEY_BASE: <128-char-hex-string>
  VAPID_PUBLIC_KEY: <vapid-public-key>
  VAPID_PRIVATE_KEY: <vapid-private-key>
```

---

## Rotating Secrets

### Application Secret Rotation

1. **Generate new secret value**
2. **Create new sealed secret**
3. **Apply and verify**
4. **Restart dependent pods**

```bash
# Example: Rotate Cloudflare API token

# 1. Create new token in Cloudflare dashboard

# 2. Create new sealed secret
kubectl create secret generic cloudflare-api-token \
  --namespace cert-manager \
  --from-literal=api-token=NEW_TOKEN_HERE \
  --dry-run=client -o yaml | \
  kubeseal --controller-name=sealed-secrets --controller-namespace=kube-system --format yaml \
  > infrastructure/cert-manager/sealed-secret.yaml

# 3. Commit and push
git add infrastructure/cert-manager/sealed-secret.yaml
git commit -m "Rotate Cloudflare API token"
git push

# 4. Wait for ArgoCD sync, then restart cert-manager
kubectl rollout restart deployment/cert-manager -n cert-manager
```

### Controller Key Rotation

Sealed Secrets controller key rotation:

```bash
# 1. Generate new key (controller does this automatically every 30 days)
# New secrets will use new key, old secrets still work

# 2. Re-encrypt all secrets with new key (optional, for forward secrecy)
kubeseal --re-encrypt < old-sealed-secret.yaml > new-sealed-secret.yaml

# 3. Update all sealed secrets in repo
```

### Emergency Key Recovery

If you need to recover secrets from backup:

```bash
# 1. Get the sealing key from backup
kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealing-key-backup.yaml

# 2. In new cluster, apply the key before installing controller
kubectl apply -f sealing-key-backup.yaml

# 3. Install sealed-secrets controller
# It will use the existing key
```

---

## Backup and Recovery

### Backing Up Sealing Keys

**Critical**: Back up the sealing private key for disaster recovery!

```bash
# Export all sealing keys
kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-keys-backup.yaml

# Store securely (encrypted, offline)
gpg --symmetric --cipher-algo AES256 sealed-secrets-keys-backup.yaml
```

### Restoring Keys

```bash
# 1. Apply backed-up keys BEFORE installing controller
kubectl apply -f sealed-secrets-keys-backup.yaml

# 2. Install sealed-secrets controller
helm install sealed-secrets sealed-secrets/sealed-secrets -n kube-system

# 3. Verify existing sealed secrets work
kubectl get secrets -A | grep -v default-token
```

### What If Keys Are Lost?

If sealing keys are lost and not backed up:

1. All existing SealedSecrets become undecryptable
2. You must regenerate all secrets from source
3. Re-seal with new key
4. Deploy new sealed secrets

**Prevention**: Always backup sealing keys immediately after cluster creation!

---

## Best Practices

### DO

- **DO** backup sealing keys immediately after cluster creation
- **DO** use separate secrets for different applications
- **DO** use descriptive secret names
- **DO** document what each key contains
- **DO** rotate secrets regularly
- **DO** delete plaintext files after sealing
- **DO** verify sealed secrets work after creating

### DON'T

- **DON'T** commit plaintext secrets to Git
- **DON'T** share sealed secrets between namespaces (they're namespace-scoped)
- **DON'T** store sealing key backups in the same repo
- **DON'T** use the same secret value across environments
- **DON'T** put sensitive data in ConfigMaps

### Secret Naming Convention

```
{app}-secret          # Main application secrets
{app}-db-credentials  # Database credentials
{app}-api-token       # External API tokens
{app}-tls             # TLS certificates (managed by cert-manager)
ghcr-pull-secret      # Docker registry credentials
```

### Verification Commands

```bash
# Check if sealed secret was decrypted
kubectl get secret {name} -n {namespace}

# Check secret contents (base64 encoded)
kubectl get secret {name} -n {namespace} -o jsonpath='{.data}'

# Decode a specific key
kubectl get secret {name} -n {namespace} -o jsonpath='{.data.{key}}' | base64 -d

# Check sealed secrets controller logs
kubectl logs -n kube-system -l name=sealed-secrets

# Verify a sealed secret is valid
kubeseal --validate < sealed-secret.yaml
```

### Troubleshooting

#### Secret Not Being Created

```bash
# Check sealed secret status
kubectl describe sealedsecret {name} -n {namespace}

# Check controller logs
kubectl logs -n kube-system -l name=sealed-secrets | grep {name}
```

#### "Unable to decrypt" Error

Usually means:
1. Wrong namespace (secrets are namespace-scoped)
2. Sealed with different key
3. Corrupted sealed secret

```bash
# Verify namespace in sealed secret matches
cat sealed-secret.yaml | grep namespace

# Re-seal if needed
kubeseal --re-encrypt < sealed-secret.yaml > new-sealed-secret.yaml
```

#### Controller Not Running

```bash
# Check controller status
kubectl get pods -n kube-system -l name=sealed-secrets

# Check controller events
kubectl describe pod -n kube-system -l name=sealed-secrets
```
