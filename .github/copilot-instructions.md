# Copilot Instructions - Homelab GitOps Repository

## Project Overview

This is a GitOps-managed K3s homelab cluster repository. Changes are automatically deployed via ArgoCD when pushed to main.

- **Domain**: `*.lab.axiomlayer.com`
- **Cluster**: 4-node K3s over Tailscale mesh (2 control-plane, 2 workers)
- **K3s Version**: v1.33.6+k3s1

## Repository Structure

```
axiomlayer/
├── apps/                      # User-facing applications
│   ├── argocd/applications/   # ArgoCD Application CRDs
│   └── {app}/                 # Individual app manifests
├── infrastructure/            # Core infrastructure components
│   └── {component}/           # Component manifests
├── tests/                     # Test scripts
│   ├── validate-manifests.sh  # Kustomize validation
│   ├── smoke-test.sh          # Infrastructure health checks
│   └── test-auth.sh           # Authentication flow tests
├── scripts/                   # Provisioning and bootstrap scripts
└── .github/workflows/         # CI/CD pipeline
```

## Tech Stack

- **Orchestration**: K3s, ArgoCD
- **Configuration**: Kustomize (no Helm for custom apps)
- **Ingress**: Traefik with TLS termination
- **TLS**: cert-manager + Let's Encrypt (DNS-01 via Cloudflare)
- **Auth**: Authentik (OIDC + forward auth)
- **Storage**: Longhorn (distributed block storage)
- **Database**: CloudNativePG (PostgreSQL operator)
- **Secrets**: Sealed Secrets (encrypted secrets in Git)
- **Monitoring**: Prometheus, Grafana, Loki

## Coding Standards

### Manifest Structure

Each component should follow this structure:

```
{component}/
├── namespace.yaml
├── deployment.yaml
├── service.yaml
├── certificate.yaml
├── ingress.yaml
├── networkpolicy.yaml
└── kustomization.yaml
```

### Required Labels

All resources must include these labels:

```yaml
labels:
  app.kubernetes.io/name: {name}
  app.kubernetes.io/component: {component}
  app.kubernetes.io/part-of: homelab
  app.kubernetes.io/managed-by: argocd
```

### Security Requirements

All deployments must include:

```yaml
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
  - securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
    livenessProbe: {...}
    readinessProbe: {...}
    resources:
      requests: {...}
      limits: {...}
```

### Secrets Management

- **Never commit plaintext secrets** - use Sealed Secrets only
- Store secret values in `.env` file (not committed)
- Create sealed secrets using `kubeseal`

### Network Policies

Every namespace should have:
1. Default deny policy
2. Explicit allow rules for required traffic

## Validation Commands

```bash
# Validate kustomization
kubectl kustomize apps/{service}

# Run manifest validation
./tests/validate-manifests.sh

# Run linting (kube-linter)
kube-linter lint apps/ --config .kube-linter.yaml
kube-linter lint infrastructure/ --config .kube-linter.yaml
```

## Adding a New Service

1. Create directory under `apps/{service}/` or `infrastructure/{service}/`
2. Add required manifests (namespace, deployment, service, certificate, ingress, networkpolicy, kustomization.yaml)
3. Create ArgoCD Application in `apps/argocd/applications/{service}.yaml`
4. Add to `apps/argocd/applications/kustomization.yaml`
5. If using forward auth, add Authentik provider
6. Validate with `kubectl kustomize` before committing

## CI/CD Pipeline

The CI pipeline runs on every push:
1. **validate-manifests**: Runs `./tests/validate-manifests.sh`
2. **lint**: Runs kube-linter on apps/ and infrastructure/
3. **security**: Runs Trivy for misconfigurations and secrets
4. **ci-passed**: Gate job that triggers ArgoCD sync on main branch

## Key Patterns

### Ingress with Forward Auth

```yaml
annotations:
  traefik.ingress.kubernetes.io/router.middlewares: authentik-ak-outpost-forward-auth-outpost@kubernetescrd
spec:
  ingressClassName: traefik
```

### Cross-Namespace Database Access

Add network policy rules for backup jobs:

```yaml
- from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: longhorn-system
      podSelector:
        matchLabels:
          app.kubernetes.io/name: homelab-backup
  ports:
    - protocol: TCP
      port: 5432
```

## Boundaries

- **Do not** commit plaintext secrets to the repository
- **Do not** modify the `.env` file (it contains sensitive data)
- **Do not** remove security contexts from deployments
- **Do not** disable network policies
- **Always** validate changes with `kubectl kustomize` before committing
- **Always** include proper labels on all resources

## Testing

Run tests locally before pushing:

```bash
./tests/validate-manifests.sh  # Kustomize validation
./tests/smoke-test.sh          # Infrastructure health
./tests/test-auth.sh           # Authentication flows
```
