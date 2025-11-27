# Homelab GitOps

Infrastructure as code for the Axiom Layer homelab.

## Architecture

- **K3s Cluster**: 3 nodes over Tailscale mesh
  - neko (control-plane)
  - neko2 (control-plane)
  - bobcat (agent)

- **DNS**: `*.lab.axiomlayer.com` → Cloudflare → Tailscale IPs

## Components

### Infrastructure
- **cert-manager**: Automatic TLS via Let's Encrypt DNS-01 challenge
- **Authentik**: SSO/Identity provider

### Apps
- **ArgoCD**: GitOps continuous delivery

## URLs

| Service | URL |
|---------|-----|
| Authentik | https://auth.lab.axiomlayer.com |
| ArgoCD | https://argocd.lab.axiomlayer.com |

## Bootstrap

### 1. Install cert-manager
```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.4/cert-manager.yaml
```

### 2. Create Cloudflare secret
```bash
kubectl create secret generic cloudflare-api-token \
  --namespace cert-manager \
  --from-literal=api-token=YOUR_TOKEN
```

### 3. Apply ClusterIssuer
```bash
kubectl apply -f infrastructure/cert-manager/cluster-issuer.yaml
```

### 4. Install Authentik
```bash
kubectl create namespace authentik
helm install authentik authentik/authentik -n authentik \
  --set authentik.secret_key=$(openssl rand -hex 32) \
  --set authentik.postgresql.password=$(openssl rand -base64 16) \
  --set postgresql.enabled=true \
  --set redis.enabled=true \
  -f infrastructure/authentik/values.yaml
```

### 5. Install ArgoCD
```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl apply -f apps/argocd/
```

## Secrets Management

Secrets in this repo are placeholders. Replace `REPLACE_ME` values manually or implement sealed-secrets.
# homelab-gitops
# homelab-gitops
