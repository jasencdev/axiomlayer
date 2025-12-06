# Secrets Management

All secrets are managed via Sealed Secrets. Never commit plaintext secrets.

## Required Secrets

### Cloudflare Tunnel
- `cloudflare-tunnel-credentials`: Tunnel credentials JSON

### Authelia
- `authelia-secrets`: JWT secret, session secret, storage encryption key

### Outline
- `outline-secrets`: Database URL, OIDC credentials, secret keys

### Open WebUI
- `open-webui-secret`: Application secret key

## Creating Sealed Secrets

```bash
# Create and seal a secret
kubectl create secret generic <name> -n <namespace> \
  --from-literal=key=value --dry-run=client -o yaml | \
  kubeseal --format yaml > sealed-secret.yaml
```
