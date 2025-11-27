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
- **sealed-secrets**: GitOps-safe secret management
- **Authentik**: SSO/Identity provider with forward auth

### Apps
- **ArgoCD**: GitOps continuous delivery
- **telnet-server**: Demo app with Prometheus metrics (SSO protected)

## URLs

| Service | URL | Auth |
|---------|-----|------|
| Authentik | https://auth.lab.axiomlayer.com | - |
| ArgoCD | https://argocd.lab.axiomlayer.com | OIDC via Authentik |
| Telnet Metrics | https://telnet.lab.axiomlayer.com/metrics | Forward Auth |

## Node Provisioning

### 1. Install Ubuntu 24.04 LTS

### 2. Install Tailscale
```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --ssh
```

### 3. Install Docker
```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
newgrp docker
```

### 4. Install K3s

**First control-plane node (neko):**
```bash
curl -sfL https://get.k3s.io | sh -s - server \
  --cluster-init \
  --tls-san=neko \
  --flannel-iface=tailscale0
```

**Additional control-plane nodes:**
```bash
curl -sfL https://get.k3s.io | sh -s - server \
  --server https://<first-node-tailscale-ip>:6443 \
  --token <node-token> \
  --tls-san=<hostname> \
  --flannel-iface=tailscale0
```

**Worker nodes:**
```bash
curl -sfL https://get.k3s.io | sh -s - agent \
  --server https://<control-plane-tailscale-ip>:6443 \
  --token <node-token> \
  --flannel-iface=tailscale0
```

### 5. Fix kubeconfig permissions
```bash
sudo chmod 644 /etc/rancher/k3s/k3s.yaml
```

## Bootstrap

### 1. Install sealed-secrets controller
```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm install sealed-secrets sealed-secrets/sealed-secrets -n kube-system
```

### 2. Install cert-manager
```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.4/cert-manager.yaml
```

### 3. Create Cloudflare sealed secret
```bash
kubectl create secret generic cloudflare-api-token \
  --namespace cert-manager \
  --dry-run=client \
  --from-literal=api-token=YOUR_TOKEN \
  -o yaml | kubeseal --format yaml > infrastructure/cert-manager/sealed-secret.yaml
```

### 4. Apply infrastructure
```bash
kubectl apply -k infrastructure/cert-manager
```

### 5. Install Authentik
```bash
kubectl create namespace authentik
helm repo add authentik https://charts.goauthentik.io
helm install authentik authentik/authentik -n authentik \
  --set authentik.secret_key=$(openssl rand -hex 32) \
  --set authentik.postgresql.password=$(openssl rand -base64 16) \
  --set postgresql.enabled=true \
  --set redis.enabled=true \
  -f infrastructure/authentik/values.yaml
```

### 6. Install ArgoCD
```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl apply -k apps/argocd
```

### 7. Configure Authentik Forward Auth

In Authentik UI:
1. Create Provider: Proxy Provider, Forward auth (domain level)
2. Cookie domain: `lab.axiomlayer.com`
3. External host: `https://auth.lab.axiomlayer.com`
4. Create Application linking to provider
5. Create Outpost: Proxy type, select application

### 8. Deploy apps via ArgoCD
```bash
argocd app create telnet-server \
  --repo https://github.com/jasencarroll/homelab-gitops.git \
  --path apps/telnet-server \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace telnet-server
```

## Directory Structure

```
homelab-gitops/
├── apps/
│   ├── argocd/           # ArgoCD configuration
│   └── telnet-server/    # Demo app with SSO
├── clusters/
│   └── lab/              # Cluster-specific config
└── infrastructure/
    ├── authentik/        # SSO provider
    └── cert-manager/     # TLS certificates
```

## Secrets Management

All secrets are managed via sealed-secrets. To create a new sealed secret:

```bash
kubectl create secret generic my-secret \
  --namespace my-namespace \
  --dry-run=client \
  --from-literal=key=value \
  -o yaml | kubeseal \
  --controller-name=sealed-secrets \
  --controller-namespace=kube-system \
  --format yaml > path/to/sealed-secret.yaml
```

## Adding a New App with SSO

1. Create namespace, deployment, service
2. Create Certificate referencing `letsencrypt-prod` ClusterIssuer
3. Create Ingress with forward auth annotation:
   ```yaml
   annotations:
     traefik.ingress.kubernetes.io/router.middlewares: authentik-ak-outpost-forward-auth-outpost@kubernetescrd
   ```
4. Add to ArgoCD

Your app receives user context via headers:
- `X-Authentik-Username`
- `X-Authentik-Email`
- `X-Authentik-Groups`

Zero auth code required.

## License

MIT
