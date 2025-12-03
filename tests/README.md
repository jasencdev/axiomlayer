# Test Suite Documentation

This directory contains automated tests for verifying homelab cluster health, security, and functionality.

**Shell Compatibility**: All test scripts use `#!/bin/bash` and are tested on Ubuntu 24.04 LTS with zsh 5.9.

## Test Categories

- [Infrastructure Tests](#infrastructure-tests) - Cluster health and core services
- [Application Tests](#application-tests) - Application functionality verification
- [Security Tests](#security-tests) - Network policies and access control
- [Backup Tests](#backup-tests) - Backup automation and restore validation
- [Monitoring Tests](#monitoring-tests) - Observability stack verification
- [Validation Tests](#validation-tests) - Manifest and configuration validation

---

## Quick Start

```bash
# Run all tests (basic health check)
./tests/smoke-test.sh
./tests/validate-manifests.sh

# Run comprehensive tests
./tests/test-auth.sh
./tests/test-app-functionality.sh
./tests/test-monitoring.sh
./tests/test-network-policies.sh
./tests/test-backup-restore.sh
```

---

## Infrastructure Tests

### smoke-test.sh

**Purpose**: Comprehensive cluster health verification - the primary smoke test.

**Test Count**: 111 tests

**What it tests**:
1. **Prerequisites** (kubectl, cluster access)
2. **Core Components**:
   - All namespaces exist
   - All pods are Running/Succeeded
   - No CrashLoopBackOff pods
   - No ImagePullBackOff pods
   - Services have endpoints
3. **GitOps Health**:
   - ArgoCD Applications synced
   - No OutOfSync or degraded apps
4. **Networking**:
   - Ingress controllers running
   - TLS certificates valid
   - DNS resolution working
5. **Storage**:
   - Longhorn health
   - PVCs bound
   - StorageClasses available
6. **Databases**:
   - CloudNativePG clusters healthy
   - Authentik DB accessible
   - Outline DB accessible
7. **Auth & SSO**:
   - Authentik pods healthy
   - Forward auth outpost running
8. **Monitoring**:
   - Prometheus/Grafana running
   - Alertmanager healthy
9. **Backups**:
   - CronJob exists
   - Longhorn recurring jobs configured

**Usage**:
```bash
./tests/smoke-test.sh

# Expected output:
# ═══════════════════════════════════════════════════════════════
#   Axiomlayer Homelab - Infrastructure Smoke Tests
# ═══════════════════════════════════════════════════════════════
#
# ─── Prerequisites ───
# ✓ PASS: kubectl available and cluster accessible
# ...
# 111 tests completed
# Passed: 111
# Failed: 0
```

**Exit Codes**:
- `0`: All tests passed ✅
- `1`: At least one test failed ❌

**CI/CD**: Runs in GitHub Actions after every push to main.

**When to run**:
- After cluster changes
- Before/after maintenance
- Daily health checks
- Troubleshooting issues

**Troubleshooting**:
```bash
# If tests fail, get more details
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded

# Check ArgoCD Applications
kubectl get applications -n argocd

# Check certificate status
kubectl get certificates -A
```

---

### validate-manifests.sh

**Purpose**: Validates all Kustomize manifests can build successfully.

**Test Count**: 20+ checks (one per component)

**What it tests**:
- All `kustomization.yaml` files are valid
- `kubectl kustomize` builds successfully for each component
- No YAML syntax errors
- No missing resources
- No invalid cross-references

**Usage**:
```bash
./tests/validate-manifests.sh

# Expected output:
# Validating: apps/argocd
# ✓ apps/argocd builds successfully
# Validating: apps/campfire
# ✓ apps/campfire builds successfully
# ...
# All 20 manifests validated successfully
```

**Exit Codes**:
- `0`: All manifests valid ✅
- `1`: At least one manifest failed ❌

**Components Validated**:
- All apps in `apps/`
- All infrastructure in `infrastructure/`

**CI/CD**: Runs in GitHub Actions on every PR.

**When to run**:
- Before committing manifest changes
- Before PR creation
- As part of local development workflow

**Troubleshooting**:
```bash
# Manually validate specific component
kubectl kustomize apps/myapp

# Check for YAML syntax errors
yamllint apps/myapp/*.yaml

# Validate specific file
kubectl apply --dry-run=client -f apps/myapp/deployment.yaml
```

---

## Application Tests

### test-app-functionality.sh

**Purpose**: Verifies applications are not just running but actually functional.

**Test Count**: ~30 tests (varies by endpoint availability)

**What it tests**:
1. **HTTP Endpoints**:
   - Open WebUI (https://ai.lab.axiomlayer.com)
   - n8n (https://autom8.lab.axiomlayer.com)
   - Outline (https://docs.lab.axiomlayer.com)
   - Plane (https://plane.lab.axiomlayer.com)
   - Campfire (https://chat.lab.axiomlayer.com)
   - Dashboard (https://db.lab.axiomlayer.com)
   - ArgoCD (https://argocd.lab.axiomlayer.com)
   - Grafana (https://grafana.lab.axiomlayer.com)
   - Authentik (https://auth.lab.axiomlayer.com)

2. **Application Health**:
   - HTTP 200 OK responses
   - Redirect chains working
   - TLS certificates valid
   - Forward auth functioning
   - Application-specific health endpoints

3. **Database Connectivity**:
   - Apps can connect to CNPG databases
   - Connection pooling working
   - Database migrations completed

4. **API Functionality**:
   - Open WebUI API responds
   - Outline API accessible
   - Plane API responds
   - n8n webhooks functional

**Usage**:
```bash
./tests/test-app-functionality.sh

# Test specific app only
OPEN_WEBUI_URL=https://ai.lab.axiomlayer.com ./tests/test-app-functionality.sh

# Expected output:
# ═══════════════════════════════════════════════════════════════
#   Application Functionality Tests
# ═══════════════════════════════════════════════════════════════
#
# ─── Open WebUI Tests ───
# ✓ PASS: Open WebUI endpoint responds (HTTP 200)
# ✓ PASS: Open WebUI health endpoint responds
# ✓ PASS: Open WebUI API accessible
# ...
```

**Exit Codes**:
- `0`: All tests passed ✅
- `1`: At least one test failed ❌
- `2`: Prerequisites not met (curl/kubectl missing)

**Environment Variables**:
- `OPEN_WEBUI_URL` - Override Open WebUI URL (default: https://ai.lab.axiomlayer.com)
- `N8N_URL` - Override n8n URL
- `OUTLINE_URL` - Override Outline URL
- `PLANE_URL` - Override Plane URL
- etc.

**Prerequisites**:
- curl installed
- kubectl access
- Network access to *.lab.axiomlayer.com

**CI/CD**: Runs after smoke tests pass in GitHub Actions.

**When to run**:
- After deploying new applications
- After DNS/TLS changes
- After Authentik configuration changes
- When investigating user-reported issues

**Troubleshooting**:
```bash
# Test endpoint manually
curl -v https://ai.lab.axiomlayer.com

# Check ingress
kubectl get ingress -A

# Check forward auth middleware
kubectl logs -n authentik -l goauthentik.io/outpost-name=forward-auth-outpost

# Check certificate
kubectl get certificate -A
```

---

### test-auth.sh

**Purpose**: Validates authentication flows and SSO integration.

**Test Count**: 27 tests

**What it tests**:
1. **Authentik Health**:
   - Authentik pods running
   - Database connectivity
   - Redis connectivity
   - API responding

2. **Forward Auth Outpost**:
   - Outpost pods running
   - Outpost configuration valid
   - Middleware configured correctly
   - PostgreSQL connectivity (Authentik 2025.10+)

3. **OIDC Providers**:
   - ArgoCD Dex provider
   - Grafana OAuth2 provider
   - Outline OIDC provider
   - Plane OIDC provider

4. **Authentication Flow**:
   - Unauthenticated requests redirect to auth
   - Protected endpoints require authentication
   - SSO headers propagated correctly

5. **Authorization**:
   - RBAC policies enforced
   - Group memberships respected
   - Permission checks functioning

**Usage**:
```bash
./tests/test-auth.sh

# Expected output:
# ═══════════════════════════════════════════════════════════════
#   Authentication and SSO Tests
# ═══════════════════════════════════════════════════════════════
#
# ─── Authentik Health Tests ───
# ✓ PASS: Authentik pods running (3/3)
# ✓ PASS: Authentik database accessible
# ✓ PASS: Authentik API responds
#
# ─── Forward Auth Outpost Tests ───
# ✓ PASS: Forward auth outpost running
# ✓ PASS: Outpost middleware configured
# ...
# 27 tests completed
# Passed: 27
# Failed: 0
```

**Exit Codes**:
- `0`: All tests passed ✅
- `1`: At least one test failed ❌

**Prerequisites**:
- kubectl access
- Authentik namespace exists
- Forward auth outpost deployed

**CI/CD**: Runs in integration tests after deployment.

**When to run**:
- After Authentik updates
- After adding new OIDC providers
- After changing forward auth configuration
- When investigating SSO issues

**Troubleshooting**:
```bash
# Check Authentik logs
kubectl logs -n authentik -l app.kubernetes.io/name=authentik --tail=100

# Check outpost logs
kubectl logs -n authentik -l goauthentik.io/outpost-name=forward-auth-outpost --tail=100

# Test forward auth manually
curl -v https://ai.lab.axiomlayer.com -H "X-Forwarded-For: 1.2.3.4"

# Check OIDC provider config
kubectl exec -n authentik authentik-db-1 -- psql -U authentik -d authentik -c "SELECT name, client_id FROM authentik_providers_oauth2_oauth2provider;"
```

---

## Security Tests

### test-network-policies.sh

**Purpose**: Validates NetworkPolicy enforcement and isolation.

**Test Count**: ~40 tests (varies by namespaces tested)

**What it tests**:
1. **Policy Existence**:
   - Default deny policies exist
   - Allow policies exist for required traffic
   - Policies cover all namespaces

2. **Ingress Rules**:
   - Traefik can reach application pods
   - Cross-namespace access blocked by default
   - Explicit allows work correctly

3. **Egress Rules**:
   - DNS egress allowed
   - Database egress allowed (where needed)
   - External egress controlled
   - Unauthorized egress blocked

4. **Isolation Testing**:
   - Creates test pods in test namespace
   - Attempts connections that should fail
   - Verifies connections that should succeed
   - Cleans up test resources

**Namespaces Tested**:
- authentik
- outline
- n8n
- open-webui
- plane
- dashboard
- campfire

**Usage**:
```bash
./tests/test-network-policies.sh

# Skip enforcement tests (policy existence only)
SKIP_ENFORCEMENT_TESTS=true ./tests/test-network-policies.sh

# Expected output:
# ═══════════════════════════════════════════════════════════════
#   Network Policy Tests
# ═══════════════════════════════════════════════════════════════
#
# ─── Policy Existence Tests ───
# ✓ PASS: authentik has default-deny policy
# ✓ PASS: authentik has allow-traefik-ingress policy
#
# ─── Enforcement Tests ───
# ✓ PASS: Unauthorized ingress to authentik blocked
# ✓ PASS: Traefik can reach authentik pods
# ...
```

**Exit Codes**:
- `0`: All tests passed ✅
- `1`: At least one test failed ❌
- `2`: Prerequisites not met (kubectl missing)

**Prerequisites**:
- kubectl access
- Write permissions (for enforcement tests)
- NetworkPolicy CNI plugin enabled (Flannel in this case)

**Enforcement Tests**:
- Require `create` permission on namespaces/pods
- Create temporary test namespace (`netpol-test`)
- Launch test pods to probe connections
- Clean up after tests complete

**CI/CD**: Runs after application deployment in integration tests.

**When to run**:
- After adding new applications
- After modifying network policies
- After CNI changes
- When investigating connectivity issues

**Troubleshooting**:
```bash
# List all network policies
kubectl get networkpolicies -A

# Check specific policy
kubectl describe networkpolicy -n authentik

# Test connectivity manually
kubectl run test-pod --rm -it --image=busybox --namespace=netpol-test -- wget -O- http://authentik.authentik.svc:9000/

# Check CNI logs
kubectl logs -n kube-system -l k8s-app=kube-flannel
```

---

## Backup Tests

### test-backup-restore.sh

**Purpose**: Validates the two-layer backup strategy: Longhorn volume backups + SQL dumps.

**Test Count**: ~45 tests

**What it tests**:

1. **SQL Dump CronJob**:
   - Backup CronJob exists and configured
   - CronJob schedule correct (4:00 AM daily)
   - Last backup succeeded within 48 hours
   - Backup retention configured

2. **Database Connectivity**:
   - Authentik database service accessible
   - Outline database service accessible
   - Database pods running
   - Endpoints available

3. **Longhorn Recurring Jobs**:
   - daily-snapshot job exists (2:00 AM)
   - weekly-snapshot job exists (3:00 AM Sunday)
   - daily-backup job exists (2:30 AM)
   - weekly-backup job exists (3:30 AM Sunday)
   - All jobs have correct schedules and retention

4. **Longhorn Backup Target**:
   - Backup target configured to NAS (192.168.1.234)
   - NFS options configured correctly
   - Backup target is available/accessible

5. **Longhorn Backup History**:
   - Backups exist in the system
   - Recent backups within 48 hours
   - Completed backups found
   - Volumes have been backed up

6. **Longhorn Volume Health**:
   - All volumes healthy (affects backup reliability)
   - No degraded volumes
   - No faulted volumes (CRITICAL)

7. **Optional Tests** (enable via environment variables):
   - Manual backup execution test
   - Backup file verification via NFS

**Backup Schedule**:

| Job | Type | Schedule | Retention |
|-----|------|----------|-----------|
| daily-snapshot | Longhorn | 2:00 AM daily | 7 |
| weekly-snapshot | Longhorn | 3:00 AM Sunday | 4 |
| daily-backup | Longhorn | 2:30 AM daily | 7 |
| weekly-backup | Longhorn | 3:30 AM Sunday | 4 |
| homelab-backup | SQL dump | 4:00 AM daily | 7 |

**Usage**:
```bash
./tests/test-backup-restore.sh

# Expected output:
# ═══════════════════════════════════════════════════════════════
#   Backup and Restore Verification Tests
# ═══════════════════════════════════════════════════════════════
#
# ─── Backup CronJob Configuration Tests ───
# ✓ PASS: Backup CronJob 'homelab-backup' exists
# ✓ PASS: Backup CronJob has schedule configured: 0 4 * * *
#
# ─── Longhorn Recurring Backup Job Tests ───
# ✓ PASS: Longhorn recurring job 'daily-snapshot' exists
# ✓ PASS: Job 'daily-snapshot' has schedule: 0 2 * * * (task: snapshot, retain: 7)
# ✓ PASS: Longhorn recurring job 'daily-backup' exists
# ✓ PASS: Job 'daily-backup' has schedule: 30 2 * * * (task: backup, retain: 7)
#
# ─── Longhorn Backup Target Tests ───
# ✓ PASS: Longhorn backup target configured
# ✓ PASS: Backup target points to NAS (192.168.1.234)
#
# ─── Longhorn Backup History Tests ───
# ✓ PASS: Found 156 Longhorn backup(s)
# ✓ PASS: Recent backup is 8 hours old (within 48h threshold)
# ...
```

**Exit Codes**:
- `0`: All tests passed ✅
- `1`: At least one test failed ❌

**Environment Variables**:
- `RUN_BACKUP_TEST=true` - Run manual backup execution test
- `VERIFY_BACKUP_FILES=true` - Run NFS file verification test

**Prerequisites**:
- kubectl access
- longhorn-system namespace exists
- Longhorn installed with recurring jobs
- CloudNativePG databases healthy

**Backup Configuration Files**:
- **Longhorn recurring jobs**: `infrastructure/backups/longhorn-recurring-jobs.yaml`
- **SQL dump CronJob**: `infrastructure/backups/backup-cronjob.yaml`
- **Longhorn helm values**: `apps/argocd/applications/longhorn-helm.yaml`

**CI/CD**: Runs weekly (not on every push due to time requirements).

**When to run**:
- Weekly as part of regular maintenance
- Before cluster maintenance
- After backup configuration changes
- When investigating backup issues
- After Longhorn upgrades

**Triggering Manual Backups**:
```bash
# Manual SQL dump
kubectl create job --from=cronjob/homelab-backup homelab-backup-test -n longhorn-system
kubectl logs -n longhorn-system -l job-name=homelab-backup-test --follow

# Manual Longhorn backup (via UI recommended)
# Go to https://longhorn.lab.axiomlayer.com → Volume → Create Backup
```

**Troubleshooting**:
```bash
# Check Longhorn recurring jobs
kubectl get recurringjobs -n longhorn-system

# Check backup target
kubectl get settings backup-target -n longhorn-system -o jsonpath='{.value}'

# Check recent backups
kubectl get backups -n longhorn-system --sort-by=.metadata.creationTimestamp | tail -10

# Check SQL dump CronJob
kubectl get cronjob homelab-backup -n longhorn-system

# Test NFS connectivity
kubectl run nfs-test --rm -it --image=busybox --restart=Never -- sh -c \
  "mount -t nfs -o nfsvers=3 192.168.1.234:/var/nfs/shared/Shared_Drive_Example/k8s-backup /mnt && ls /mnt"
```

---

## Monitoring Tests

### test-monitoring.sh

**Purpose**: Validates monitoring and observability stack.

**Test Count**: ~35 tests

**What it tests**:
1. **Prometheus Stack**:
   - Prometheus pods running
   - ServiceMonitors configured
   - Targets being scraped
   - Metrics ingestion working

2. **Grafana**:
   - Grafana pods running
   - Datasources configured (Prometheus, Loki)
   - Dashboards loaded
   - OIDC authentication working

3. **Loki**:
   - Loki pods running
   - Promtail collecting logs
   - Logs ingested correctly
   - Log queries working

4. **Alertmanager**:
   - Alertmanager pods running
   - Alert rules loaded
   - Alert routing configured
   - Alerts firing appropriately

5. **Alert Rules**:
   - NodeNotReady alert configured
   - PodCrashLooping alert configured
   - CertificateExpiringSoon alert configured
   - Custom alerts loaded

6. **Metrics Availability**:
   - Node metrics available
   - Pod metrics available
   - Service metrics available
   - Custom metrics scraped

**Usage**:
```bash
./tests/test-monitoring.sh

# Expected output:
# ═══════════════════════════════════════════════════════════════
#   Monitoring Stack Tests
# ═══════════════════════════════════════════════════════════════
#
# ─── Prometheus Tests ───
# ✓ PASS: Prometheus pods running
# ✓ PASS: ServiceMonitors configured
# ✓ PASS: Targets being scraped
#
# ─── Grafana Tests ───
# ✓ PASS: Grafana pods running
# ✓ PASS: Prometheus datasource configured
# ✓ PASS: Loki datasource configured
# ...
```

**Exit Codes**:
- `0`: All tests passed ✅
- `1`: At least one test failed ❌

**Prerequisites**:
- kubectl access
- monitoring namespace exists
- kube-prometheus-stack deployed
- Loki stack deployed

**CI/CD**: Runs in integration tests after deployment.

**When to run**:
- After monitoring stack updates
- After adding new ServiceMonitors
- After alert rule changes
- When investigating monitoring issues

**Troubleshooting**:
```bash
# Check Prometheus targets
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
# Visit http://localhost:9090/targets

# Check Grafana datasources
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
# Visit http://localhost:3000

# Check Loki logs
kubectl logs -n monitoring -l app=loki

# Check Alertmanager
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093
# Visit http://localhost:9093
```

---

## Test Conventions

### All Test Scripts Follow These Standards

1. **Shebang**: `#!/bin/bash`
2. **Error handling**: `set -uo pipefail` (not `set -e` to allow expected failures)
3. **Output colors**: Green (pass), red (fail), yellow (skip), blue (info)
4. **Exit codes**: `0` = all pass, `1` = any fail, `2` = prerequisites not met
5. **Prerequisites check**: Validate kubectl, cluster access, permissions
6. **Permission awareness**: Skip tests requiring elevated permissions if not available
7. **Cleanup**: Clean up test resources after completion

### Test Result Format

```
✓ PASS: Test description
✗ FAIL: Test description
○ SKIP: Test description
ℹ INFO: Informational message
```

### Test Summary

```
═══════════════════════════════════════════════════════════════
Test Results
═══════════════════════════════════════════════════════════════
Passed: 50
Failed: 0
Skipped: 2
Total: 52
```

---

## Running Tests in CI/CD

Tests run automatically in GitHub Actions:

```yaml
# .github/workflows/ci.yaml
- name: Smoke Tests
  run: ./tests/smoke-test.sh

- name: Validate Manifests
  run: ./tests/validate-manifests.sh

- name: Auth Tests
  run: ./tests/test-auth.sh

- name: App Functionality Tests
  run: ./tests/test-app-functionality.sh
```

**Test Order** (fastest to slowest):
1. validate-manifests.sh (~30s)
2. smoke-test.sh (~2 min)
3. test-auth.sh (~1 min)
4. test-app-functionality.sh (~2 min)
5. test-network-policies.sh (~5 min with enforcement)
6. test-monitoring.sh (~2 min)
7. test-backup-restore.sh (~5 min with manual backup)

---

## Local Development Testing

```bash
# Fast feedback loop (before commit)
./tests/validate-manifests.sh

# Medium feedback (before PR)
./tests/smoke-test.sh
./tests/test-auth.sh

# Full validation (before merge)
./tests/smoke-test.sh && \
./tests/validate-manifests.sh && \
./tests/test-auth.sh && \
./tests/test-app-functionality.sh && \
./tests/test-network-policies.sh && \
./tests/test-monitoring.sh
```

---

## Troubleshooting Test Failures

### Common Issues

1. **kubectl not found**: Install kubectl
2. **Cannot connect to cluster**: Check `KUBECONFIG` and cluster status
3. **Permission denied**: Tests may skip permission-required checks in CI
4. **Timeout errors**: Cluster may be under load, re-run tests
5. **Flaky tests**: Some tests depend on external factors (DNS, network)

### Getting More Details

```bash
# Increase verbosity (if supported by test)
VERBOSE=true ./tests/smoke-test.sh

# Check cluster state manually
kubectl get pods -A
kubectl get nodes
kubectl get certificates -A

# Check specific component
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace>
```

---

## See Also

- `scripts/README.md` - Script documentation
- `CLAUDE.md` - Operator guide
- `CONTRIBUTING.md` - Contribution guidelines
- `README.md` - Project overview
- `docs/TROUBLESHOOTING.md` - Troubleshooting guide
