# Contributing to Axiomlayer

Thank you for contributing to the Axiomlayer homelab GitOps repository!

## Prerequisites

- **Shell**: zsh 5.9+ (all commands must be zsh-compatible)
- **kubectl**: Latest stable version
- **kubeseal**: For Sealed Secrets
- **helm**: For managing Helm charts
- **git**: For version control
- **Access**: Cluster access configured in `~/.kube/config`

## Shell Compatibility Requirements

**CRITICAL**: This project uses **zsh** as the default shell. All contributions MUST be zsh-compatible.

### Interactive Commands

- All commands in documentation must work in zsh 5.9+
- Test every command example in zsh before documenting
- Use POSIX-compatible syntax where possible
- If bash-specific syntax is needed, wrap in `bash -c '...'`

### Shell Scripts

- All `.sh` scripts MUST have `#!/bin/bash` shebang
- Scripts run in bash mode for portability across different hosts (cluster nodes may use bash)
- Use `set -euo pipefail` for safety
- Test scripts in both bash and zsh environments

### Environment Variables

- The `.env` file uses bash-style `export VAR=value` syntax
- In zsh, source with: `source <(grep -v '^#' .env | sed 's/^/export /')`
- Or wrap commands that need `.env`: `bash -c 'source .env && command'`
- Never commit `.env` (it's in `.gitignore`)

### Common zsh Gotchas to Avoid

- **Arrays**: zsh arrays are 1-indexed, bash is 0-indexed
- **Globbing**: zsh has extended globbing by default
- **Word splitting**: `$var` doesn't split on whitespace in zsh
- **Conditionals**: Prefer `[[ ]]` over `[ ]` for compatibility

## Code Style

### Directory Structure

```
apps/{service}/              # User-facing applications
infrastructure/{service}/    # Infrastructure components
```

### Naming Conventions

- **Directories**: lowercase-kebab-case (e.g., `open-webui`, `cert-manager`)
- **Files**: lowercase-kebab-case (e.g., `deployment.yaml`, `sealed-secret.yaml`)
- **Scripts**: lowercase-kebab-case with `.sh` extension (e.g., `bootstrap-argocd.sh`)
- **Namespaces**: Match directory name (e.g., `open-webui` → namespace `open-webui`)

### Required Files for New Applications

Every application in `apps/` or `infrastructure/` must have:

```
{service}/
├── namespace.yaml           # Namespace definition
├── deployment.yaml          # Main workload (or statefulset.yaml)
├── service.yaml             # ClusterIP or LoadBalancer service
├── certificate.yaml         # cert-manager Certificate
├── ingress.yaml             # Traefik Ingress with TLS
├── networkpolicy.yaml       # Default deny + explicit allow rules
├── pdb.yaml                 # PodDisruptionBudget (if replicas > 1)
├── sealed-secret.yaml       # Sealed secrets (if needed)
└── kustomization.yaml       # Kustomize manifest
```

### Required Labels

All Kubernetes resources MUST have these labels:

```yaml
labels:
  app.kubernetes.io/name: {service-name}
  app.kubernetes.io/component: {component}  # server, database, cache, etc.
  app.kubernetes.io/part-of: homelab
  app.kubernetes.io/managed-by: argocd
```

### Security Requirements

#### Pod Security Context

```yaml
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
```

#### Container Security Context

```yaml
containers:
  - name: app
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true  # Use false only if absolutely required
      capabilities:
        drop: ["ALL"]
```

#### Probes

All containers MUST have:

```yaml
livenessProbe:
  httpGet:
    path: /health  # or appropriate health endpoint
    port: 8080
  initialDelaySeconds: 30
  periodSeconds: 10

readinessProbe:
  httpGet:
    path: /ready   # or appropriate readiness endpoint
    port: 8080
  initialDelaySeconds: 5
  periodSeconds: 5
```

#### Resource Limits

All containers MUST have resource requests and limits:

```yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

### Network Policies

Every namespace MUST have network policies:

1. **Default deny** (deny all ingress and egress)
2. **Explicit allow** rules for:
   - Traefik ingress (from `kube-system` namespace)
   - DNS (to `kube-system/kube-dns`)
   - External egress (if needed)
   - Database access (if using CNPG)

Example:

```yaml
# Default deny all
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: myapp
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress

---
# Allow ingress from Traefik
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-traefik-ingress
  namespace: myapp
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: myapp
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              app.kubernetes.io/name: traefik
      ports:
        - protocol: TCP
          port: 8080

---
# Allow egress to DNS
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: myapp
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
```

### Ingress Configuration

All Ingresses must:

1. Use `ingressClassName: traefik`
2. Have TLS configuration
3. Reference a cert-manager Certificate
4. Include forward auth annotation (unless using native OIDC)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp
  namespace: myapp
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: authentik-ak-outpost-forward-auth-outpost@kubernetescrd
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - myapp.lab.axiomlayer.com
      secretName: myapp-tls
  rules:
    - host: myapp.lab.axiomlayer.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: myapp
                port:
                  number: 8080
```

### Certificate Configuration

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: myapp-tls
  namespace: myapp
spec:
  secretName: myapp-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - myapp.lab.axiomlayer.com
```

## Adding a New Application

### 1. Create Application Directory Structure

```bash
mkdir -p apps/myapp
cd apps/myapp
```

### 2. Create Required Manifests

Use `templates/` directory as reference or copy from existing similar app.

### 3. Validate with Kustomize

```bash
kubectl kustomize apps/myapp
```

### 4. Create ArgoCD Application

Create `apps/argocd/applications/myapp.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"  # Adjust based on dependencies
spec:
  project: default
  source:
    repoURL: https://github.com/jasencdev/axiomlayer.git
    targetRevision: main
    path: apps/myapp
  destination:
    server: https://kubernetes.default.svc
    namespace: myapp
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### 5. Add to Kustomization

Edit `apps/argocd/applications/kustomization.yaml`:

```yaml
resources:
  # ... existing resources ...
  - myapp.yaml
```

### 6. Configure Authentik (if using forward auth)

1. Go to https://auth.lab.axiomlayer.com
2. Create Provider (Type: Proxy Provider, Mode: Forward auth)
3. Create Application linked to the provider
4. Add provider to `forward-auth-outpost`

### 7. Test Locally

```bash
# Validate all manifests
./tests/validate-manifests.sh

# If changes affect auth
./tests/test-auth.sh

# Full smoke test
./tests/smoke-test.sh
```

### 8. Commit and Push

```bash
git add apps/myapp apps/argocd/applications/myapp.yaml
git commit -m "feat: add myapp application"
git push origin feature/add-myapp
```

CI will:
1. Validate manifests
2. Run security scans (Trivy)
3. Run tests
4. Trigger ArgoCD sync (on merge to main)

## Secrets Management

**NEVER commit plaintext secrets.** Use Sealed Secrets exclusively.

### Creating a Sealed Secret

```bash
# Create secret manifest (dry-run)
kubectl create secret generic myapp-secret \
  --namespace myapp \
  --from-literal=api-key=YOUR_KEY \
  --from-literal=db-password=YOUR_PASSWORD \
  --dry-run=client -o yaml | \
  kubeseal \
    --controller-name=sealed-secrets \
    --controller-namespace=kube-system \
    --format yaml > apps/myapp/sealed-secret.yaml
```

### Storing Secrets for Re-sealing

Add secrets to `.env` file (never committed):

```bash
# In .env
export MYAPP_API_KEY="your-api-key"
export MYAPP_DB_PASSWORD="your-password"
```

### Re-sealing After Cluster Rebuild

After a cluster rebuild, Sealed Secrets controller generates new keys. All secrets must be re-sealed:

```bash
# Fetch new public key
kubeseal --fetch-cert > sealed-secrets-pub.pem

# Re-seal all secrets using .env values
# (Add script to automate this in scripts/reseal-all-secrets.sh)
```

## Testing

### Local Validation

```bash
# Validate all Kustomize manifests
./tests/validate-manifests.sh

# Run smoke tests
./tests/smoke-test.sh

# Test authentication flows
./tests/test-auth.sh

# Test application functionality
./tests/test-app-functionality.sh

# Test network policies
./tests/test-network-policies.sh

# Test monitoring
./tests/test-monitoring.sh

# Test backup/restore
./tests/test-backup-restore.sh
```

### CI/CD Testing

The CI pipeline automatically runs:

1. **Manifest validation** - Kustomize build on all apps/infrastructure
2. **Linting** - YAML lint, shellcheck on scripts
3. **Security scanning** - Trivy vulnerability scans
4. **Integration tests** - Smoke tests + auth tests

All tests must pass before merge to `main`.

## Documentation

### Documentation Sync

Documentation is automatically synced on push to `main`:

1. **Outline Wiki Sync** (`scripts/sync-outline.sh`)
   - Syncs markdown files to https://docs.lab.axiomlayer.com
   - Configuration: `outline_sync/config.json`
   - State tracking: `outline_sync/state.json`

2. **RAG Sync** (`scripts/sync-rag.sh`)
   - Syncs codebase to Open WebUI knowledge base
   - Includes: `*.md`, `apps/**/*.yaml`, `infrastructure/**/*.yaml`
   - State tracking: `.rag-sync-commit`

### Documentation Requirements

- All new features MUST be documented
- Update `README.md` for user-facing changes
- Update `CLAUDE.md` for operator/maintainer instructions
- Update `docs/` for architecture/design documentation
- Add entries to `outline_sync/config.json` for new docs

### Code Comments

- Comment non-obvious logic
- Don't comment what code does (code should be self-documenting)
- Comment *why* code does something (especially workarounds)

Example:

```yaml
# Bad
# This sets the replica count to 2
replicas: 2

# Good
# Run 2 replicas for HA during node maintenance
replicas: 2
```

## Git Workflow

### Branch Naming

- `feat/short-description` - New features
- `fix/short-description` - Bug fixes
- `chore/short-description` - Maintenance tasks
- `docs/short-description` - Documentation updates

### Commit Messages

Follow Conventional Commits:

```
<type>: <description>

[optional body]

[optional footer]
```

Types:
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `chore`: Maintenance tasks
- `refactor`: Code refactoring
- `test`: Test additions/changes
- `ci`: CI/CD changes

Examples:

```
feat: add Open WebUI application with CNPG database

Deploys Open WebUI for AI chat interface with PostgreSQL backend
managed by CloudNativePG operator. Includes network policies,
TLS certificate, and forward auth integration.
```

```
fix: correct Authentik outpost PostgreSQL connection string

The forward-auth-outpost requires PostgreSQL env vars in
Authentik 2025.10+. Added AUTHENTIK_POSTGRESQL__* variables
to outpost deployment.
```

### Pull Requests

1. Create feature branch from `main`
2. Make changes and test locally
3. Push to GitHub
4. Create PR with description:
   - What changed
   - Why it changed
   - How to test
   - Any breaking changes
5. Wait for CI to pass
6. Request review (if working in team)
7. Merge to `main`

## Code Review Checklist

Before requesting review, ensure:

- [ ] All commands tested in zsh
- [ ] Shell scripts have `#!/bin/bash` shebang
- [ ] Kustomize validation passes
- [ ] Security contexts configured
- [ ] Resource limits defined
- [ ] Network policies created
- [ ] Probes configured
- [ ] Secrets use Sealed Secrets
- [ ] TLS certificate defined
- [ ] Ingress configured correctly
- [ ] ArgoCD Application created
- [ ] Documentation updated
- [ ] Tests pass locally
- [ ] Commit messages follow convention
- [ ] No plaintext secrets in Git

## Getting Help

- **Documentation**: See `CLAUDE.md` for comprehensive operator guide
- **Architecture**: See `docs/ARCHITECTURE.md`
- **Troubleshooting**: See `docs/TROUBLESHOOTING.md`
- **Issues**: Open issue on GitHub with:
  - What you tried
  - What happened
  - What you expected
  - Relevant logs/error messages
  - Environment details

## License

MIT
