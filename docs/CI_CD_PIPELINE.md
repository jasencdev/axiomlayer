# CI/CD Pipeline Documentation

This document provides a comprehensive overview of the GitHub Actions CI/CD pipeline for the Axiomlayer homelab repository.

**Pipeline File**: `.github/workflows/ci.yaml`

## Overview

The CI/CD pipeline automates validation, testing, deployment, and documentation synchronization for the homelab cluster.

```
PR → Validation → Merge → Main Branch → ArgoCD Sync → Integration Tests → Doc Sync
```

## Triggers

### Push to Main
```yaml
on:
  push:
    branches: [main]
```
- Triggers ArgoCD sync
- Runs integration tests
- Syncs documentation

### Pull Request
```yaml
on:
  pull_request:
    branches: [main]
```
- Validates manifests
- Runs security scans
- Lints Kubernetes resources

### Manual Trigger
```yaml
on:
  workflow_dispatch:
```
- Allows manual workflow execution
- Useful for re-running tests or syncs

## Pipeline Jobs

### Job Flow

```
┌─────────────────────────────────────────────────┐
│              Pull Request Flow                  │
├─────────────────────────────────────────────────┤
│                                                 │
│  validate-manifests ──┐                         │
│  lint               ──┼──► ci-passed ──► Merge  │
│  security           ──┘                         │
│                                                 │
└─────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────┐
│              Main Branch Flow                   │
├─────────────────────────────────────────────────┤
│                                                 │
│  ci-passed ──► ArgoCD Sync                      │
│       │                                         │
│       ├──► integration-tests ──┐               │
│       │    - smoke-test        │               │
│       │    - test-auth         │               │
│       │    - test-app-func     │               │
│       │    - test-monitoring   │               │
│       │                        │               │
│       ├──► extended-tests ─────┤               │
│       │    - test-backup       │               │
│       │    - test-netpol       │               │
│       │                        │               │
│       ├──► outline-sync ───────┤               │
│       │                        │               │
│       └──► rag-sync ───────────┘               │
│                                                 │
└─────────────────────────────────────────────────┘
```

### 1. validate-manifests

**Runs On**: Pull requests only
**Runner**: [self-hosted, homelab]
**Purpose**: Validates all Kustomize manifests can build successfully

**Steps**:
1. Checkout code
2. Install kubectl
3. Run `./tests/validate-manifests.sh`

**What It Validates**:
- All `kustomization.yaml` files are valid
- `kubectl kustomize` builds successfully for all components
- No YAML syntax errors
- No missing resources or invalid references

**Exit Criteria**: All manifests must build without errors

---

### 2. lint

**Runs On**: Pull requests only
**Runner**: [self-hosted, homelab]
**Purpose**: Lints Kubernetes manifests for best practices

**Steps**:
1. Checkout code
2. Install kube-linter (v0.7.6)
3. Lint `apps/` directory
4. Lint `infrastructure/` directory

**Tool**: [kube-linter](https://github.com/stackrox/kube-linter)
**Config**: `.kube-linter.yaml`

**What It Checks**:
- Resource limits and requests
- Security contexts
- Liveness and readiness probes
- Image pull policies
- Service account usage
- Network policies

**Note**: Linting failures do not block merges (informational only)

---

### 3. security

**Runs On**: Pull requests only
**Runner**: [self-hosted, homelab]
**Purpose**: Security scanning and secret detection

**Steps**:
1. Checkout code
2. Install Trivy (v0.58.0)
3. Scan for misconfigurations (HIGH, CRITICAL)
4. Scan for secrets
5. Check for plaintext Kubernetes Secrets

**Tool**: [Trivy](https://github.com/aquasecurity/trivy)

**What It Checks**:
- Kubernetes misconfigurations
- Embedded secrets in code/config
- Plaintext `kind: Secret` resources (must use SealedSecret)

**Exit Criteria**:
- No embedded secrets found
- No plaintext Secret resources
- Misconfigurations are informational only (exit code 0)

**Secret Check Logic**:
```bash
# Fails if any top-level "kind: Secret" found (not SealedSecret)
grep -rn '^kind: Secret$' --include="*.yaml" apps/ infrastructure/
```

---

### 4. ci-passed (Gate Job)

**Runs On**: All events (pull requests and main pushes)
**Runner**: [self-hosted, homelab]
**Purpose**: Acts as a gate for downstream jobs

**Behavior**:

**On Pull Requests**:
- Requires `validate-manifests` and `security` to pass
- Lint is informational only (not required)
- Blocks merge if validation or security fails

**On Main Push**:
- Skips validation (already validated in PR)
- Triggers ArgoCD sync
- Enables downstream jobs (integration tests, doc sync)

**ArgoCD Sync Trigger**:
```bash
curl -X POST \
  -H "Authorization: Bearer $ARGOCD_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  "https://argocd.lab.axiomlayer.com/api/v1/applications/applications/sync" \
  -d '{"prune": true}'
```
- Syncs the root Application (App of Apps)
- Uses `ARGOCD_AUTH_TOKEN` secret
- Prunes deleted resources

---

### 5. integration-tests

**Runs On**: Main branch pushes only (after ci-passed succeeds)
**Runner**: [self-hosted, homelab]
**Purpose**: Validates cluster health and application functionality

**Test Suite**:

1. **Smoke Tests** (`./tests/smoke-test.sh`)
   - 111 tests
   - Cluster health verification
   - Pod status checks
   - ArgoCD sync status
   - Certificate validation
   - Storage health

2. **Auth Tests** (`./tests/test-auth.sh`)
   - 27 tests
   - Authentik health
   - Forward auth outpost
   - OIDC providers
   - SSO flows

3. **App Functionality Tests** (`./tests/test-app-functionality.sh`)
   - ~30 tests
   - HTTP endpoint validation
   - Application health checks
   - API accessibility
   - Database connectivity

4. **Monitoring Tests** (`./tests/test-monitoring.sh`)
   - ~35 tests
   - Prometheus health
   - Grafana datasources
   - Loki ingestion
   - Alertmanager rules

**Execution Time**: ~5-7 minutes total

**Exit Criteria**: All tests must pass

---

### 6. extended-tests

**Runs On**: Main branch pushes, scheduled runs, or manual trigger
**Runner**: [self-hosted, homelab]
**Purpose**: Extended validation requiring more time or resources

**Test Suite**:

1. **Backup and Restore Tests** (`./tests/test-backup-restore.sh`)
   - ~25 tests
   - Backup CronJob validation
   - Manual backup trigger
   - Backup file verification
   - Dry-run restore tests
   - Environment variables:
     - `RUN_BACKUP_TEST=true`
     - `VERIFY_BACKUP_FILES=true`

2. **Network Policy Tests** (`./tests/test-network-policies.sh`)
   - ~40 tests
   - NetworkPolicy existence
   - Ingress rule enforcement
   - Egress rule enforcement
   - Isolation testing with test pods

**Execution Time**: ~10 minutes total

**Why Extended?**:
- Tests create Kubernetes resources (requires cleanup)
- Backup tests can be slow
- Network policy tests create temporary namespaces
- Not required for every commit

---

### 7. outline-sync

**Runs On**: Main branch pushes only (after ci-passed succeeds)
**Runner**: [self-hosted, homelab]
**Purpose**: Syncs markdown documentation to Outline wiki

**Configuration**:
- **Config**: `outline_sync/config.json`
- **State**: `outline_sync/state.json`
- **Marker**: `.outline-sync-commit`

**Environment Variables**:
- `OUTLINE_API_TOKEN` (from GitHub Secrets)

**What It Syncs**:
- README.md → Home
- CONTRIBUTING.md → Contributing Guidelines
- docs/*.md → Various documentation pages
- scripts/README.md → Scripts Documentation
- tests/README.md → Test Suite Documentation

**How It Works**:
1. Checks git diff since last sync (`.outline-sync-commit`)
2. For each changed file:
   - If document exists in Outline → Update
   - If document doesn't exist → Create
3. Updates `.outline-sync-commit` marker

**Destination**: https://docs.lab.axiomlayer.com

**Script**: `./scripts/sync-outline.sh`

---

### 8. rag-sync

**Runs On**: Main branch pushes only (after ci-passed succeeds)
**Runner**: [self-hosted, homelab]
**Purpose**: Syncs repository files to Open WebUI RAG knowledge base

**Environment Variables**:
- `OPEN_WEBUI_URL=http://open-webui.open-webui.svc.cluster.local:8080` (internal URL, bypasses auth)
- `OPEN_WEBUI_API_KEY` (from GitHub Secrets)
- `OPEN_WEBUI_KNOWLEDGE_ID` (from GitHub Secrets)

**What It Syncs**:
- All `*.md` files
- `apps/**/*.yaml`
- `infrastructure/**/*.yaml`
- `.github/workflows/*.yaml`

**Exclusions**:
- `*sealed-secret*`
- `*.env*`
- `*AGENTS.md*`
- `node_modules/`
- `.git/`

**How It Works**:
1. Checks git history for changed files
2. For each changed file:
   - If file exists in knowledge base and content changed → Update
   - If file doesn't exist in knowledge base → Upload
   - If file unchanged → Skip
3. Updates sync marker

**Destination**: https://ai.lab.axiomlayer.com (Open WebUI knowledge base)

**Script**: `./scripts/sync-rag.sh`

---

## Concurrency Control

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

- Cancels in-progress runs when new commits are pushed
- Prevents CI pileup from rapid commits
- Saves runner resources

---

## Permissions

```yaml
permissions:
  contents: read
  statuses: write
```

- Minimal permissions following least-privilege principle
- `contents: read` - Read repository contents
- `statuses: write` - Update commit statuses

---

## GitHub Secrets

Required secrets in repository settings:

| Secret | Purpose | Used By |
|--------|---------|---------|
| `ARGOCD_AUTH_TOKEN` | ArgoCD API access for sync trigger | ci-passed job |
| `OUTLINE_API_TOKEN` | Outline wiki API access | outline-sync job |
| `OPEN_WEBUI_API_KEY` | Open WebUI API access | rag-sync job |
| `OPEN_WEBUI_KNOWLEDGE_ID` | RAG knowledge base UUID | rag-sync job |

### Creating Secrets

**ARGOCD_AUTH_TOKEN**:
```bash
# Create API token in ArgoCD UI: Settings → Accounts → admin → Generate Token
# Or via CLI:
argocd account generate-token --account admin
```

**OUTLINE_API_TOKEN**:
```bash
# Create in Outline: Settings → API → Create Token
# Required scopes: documents.write, collections.write
```

**OPEN_WEBUI_API_KEY**:
```bash
# Create in Open WebUI: Settings → Account → API Keys → Create
```

**OPEN_WEBUI_KNOWLEDGE_ID**:
```bash
# Get from Open WebUI: Workspace → Knowledge → Copy UUID from URL
# URL format: https://ai.lab.axiomlayer.com/workspace/knowledge/{uuid}
```

---

## Self-Hosted Runner

**Labels**: `[self-hosted, homelab]`

**Location**: Runs in `actions-runner` namespace in K8s cluster

**Configuration**:
- Managed by actions-runner-controller
- Auto-scales based on job demand
- 2 CPU cores, 2GB memory per runner
- Docker-in-Docker enabled
- kubectl access to cluster

**See**: `infrastructure/actions-runner/` for deployment manifests

---

## Pipeline Execution Time

**Pull Request** (validation only):
- validate-manifests: ~30 seconds
- lint: ~20 seconds
- security: ~40 seconds
- **Total**: ~1-2 minutes

**Main Push** (full pipeline):
- ci-passed + ArgoCD sync: ~30 seconds
- integration-tests: ~5-7 minutes
- extended-tests: ~10 minutes
- outline-sync: ~10 seconds
- rag-sync: ~30 seconds
- **Total**: ~15-20 minutes

---

## Troubleshooting

### Pipeline Failures

**validate-manifests fails**:
```bash
# Test locally
./tests/validate-manifests.sh

# Check specific component
kubectl kustomize apps/myapp
```

**security scan fails (secrets detected)**:
```bash
# Check for plaintext secrets
./scripts/check-no-plaintext-secrets.sh

# Convert to SealedSecret
kubectl create secret generic mysecret --dry-run=client -o yaml | \
  kubeseal --format yaml > sealed-secret.yaml
```

**integration-tests fail**:
```bash
# Run tests locally
./tests/smoke-test.sh
./tests/test-auth.sh
./tests/test-app-functionality.sh

# Check cluster health
kubectl get pods -A
kubectl get certificates -A
```

**ArgoCD sync fails**:
```bash
# Check ArgoCD applications
kubectl get applications -n argocd

# Check ArgoCD logs
kubectl logs -n argocd deployment/argocd-server

# Manual sync
argocd app sync applications
```

**outline-sync fails**:
```bash
# Check API token
curl -H "Authorization: Bearer $OUTLINE_API_TOKEN" \
  https://docs.lab.axiomlayer.com/api/auth.info

# Check config
cat outline_sync/config.json

# Run locally
bash -c 'source .env && ./scripts/sync-outline.sh'
```

**rag-sync fails**:
```bash
# Check API key
curl -H "Authorization: Bearer $OPEN_WEBUI_API_KEY" \
  https://ai.lab.axiomlayer.com/api/v1/auths

# Check knowledge base ID
curl -H "Authorization: Bearer $OPEN_WEBUI_API_KEY" \
  https://ai.lab.axiomlayer.com/api/v1/knowledge

# Run locally
bash -c 'source .env && ./scripts/sync-rag.sh'
```

### Runner Issues

**Jobs stuck in queue**:
```bash
# Check runner pods
kubectl get pods -n actions-runner

# Check runner registration
kubectl get runners -n actions-runner

# Scale runners
kubectl scale deployment actions-runner -n actions-runner --replicas=2
```

**Runner permissions**:
```bash
# Check RBAC
kubectl auth can-i list pods --as=system:serviceaccount:actions-runner:actions-runner

# See: infrastructure/actions-runner/rbac.yaml
```

---

## Best Practices

### For Contributors

1. **Always create PRs**: Don't push directly to main
2. **Wait for validation**: Let CI validate manifests before merge
3. **Review security scans**: Address any security findings
4. **Test locally first**: Run `./tests/validate-manifests.sh` before pushing

### For Operators

1. **Monitor pipeline health**: Check GitHub Actions regularly
2. **Review ArgoCD sync status**: Ensure applications are synced
3. **Check runner capacity**: Scale runners if jobs are queued
4. **Rotate secrets**: Rotate API tokens periodically
5. **Review extended test results**: Check backup and network policy tests

### For Debugging

1. **Use workflow_dispatch**: Manually trigger pipeline for testing
2. **Check runner logs**: View pod logs in actions-runner namespace
3. **Test scripts locally**: All test scripts can run locally
4. **Review job outputs**: GitHub Actions provides detailed logs

---

## Future Enhancements

- [ ] Add scheduled runs for extended tests (weekly)
- [ ] Add deployment previews for PRs
- [ ] Add performance testing
- [ ] Add chaos engineering tests
- [ ] Add compliance scanning
- [ ] Add cost analysis for resource usage
- [ ] Add notification integrations (Slack, Discord)

---

## See Also

- `tests/README.md` - Comprehensive test documentation
- `scripts/README.md` - Script documentation (sync scripts)
- `CONTRIBUTING.md` - Contribution guidelines
- `docs/TROUBLESHOOTING.md` - General troubleshooting guide
