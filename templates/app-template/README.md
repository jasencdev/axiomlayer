# {{APP_NAME}}

## Quick Start

### Local Development

```bash
# Copy environment file
cp .env.example .env

# Start with hot reload
docker compose up

# Access at http://localhost:3000
```

### Deploy to Axiom Layer

1. **Push to GitHub** — CI builds and pushes image to ghcr.io

2. **Copy k8s manifests to axiomlayer repo:**
   ```bash
   cp -r k8s/ /path/to/axiomlayer/apps/{{APP_NAME}}/
   ```

3. **Create ArgoCD Application:**
   ```bash
   cat <<EOF > /path/to/axiomlayer/apps/argocd/applications/{{APP_NAME}}.yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: {{APP_NAME}}
     namespace: argocd
   spec:
     project: default
     source:
       repoURL: https://github.com/jasencdev/axiomlayer.git
       targetRevision: main
       path: apps/{{APP_NAME}}
     destination:
       server: https://kubernetes.default.svc
       namespace: {{APP_NAME}}
     syncPolicy:
       automated:
         prune: true
         selfHeal: true
   EOF
   ```

4. **Add to kustomization:**
   ```bash
   # Edit apps/argocd/applications/kustomization.yaml
   # Add: - {{APP_NAME}}.yaml
   ```

5. **Push axiomlayer repo** — ArgoCD auto-syncs

### Update Deployment

```bash
# Tag a release
git tag v1.0.1
git push origin v1.0.1

# CI builds new image, then either:
# A) Manually update image digest in k8s/deployment.yaml
# B) Let Renovate auto-PR the update
```

## Project Structure

```
{{APP_NAME}}/
├── .github/workflows/
│   └── build.yaml          # CI: build & push to ghcr.io
├── k8s/                    # Kubernetes manifests (copy to axiomlayer)
│   ├── namespace.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── certificate.yaml
│   ├── ingress.yaml
│   ├── networkpolicy.yaml
│   ├── pdb.yaml
│   ├── sealed-secret.yaml  # Create with kubeseal
│   └── kustomization.yaml
├── src/                    # Your application code
├── Dockerfile
├── docker-compose.yml
├── .env.example
└── README.md
```

## Creating Secrets

```bash
# Generate sealed secret for axiomlayer cluster
kubectl create secret generic {{APP_NAME}}-secret \
  -n {{APP_NAME}} \
  --from-literal=DATABASE_URL=postgres://... \
  --from-literal=SECRET_KEY=$(openssl rand -hex 32) \
  --dry-run=client -o yaml | \
  kubeseal --format yaml > k8s/sealed-secret.yaml
```

## Checklist

- [ ] Replace all `{{APP_NAME}}` with your app name
- [ ] Replace `{{PORT}}` with your app's port
- [ ] Update Dockerfile for your stack
- [ ] Create sealed secrets
- [ ] Update health check endpoints in deployment.yaml
- [ ] Adjust resource limits based on app requirements
