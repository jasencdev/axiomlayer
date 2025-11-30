#!/bin/bash
# Validate Kubernetes manifests
# Run: ./tests/validate-manifests.sh

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

FAILED=0
PASSED=0
WARNINGS=0

pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    PASSED=$((PASSED + 1))
}

fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    FAILED=$((FAILED + 1))
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    WARNINGS=$((WARNINGS + 1))
}

section() {
    echo ""
    echo "========================================"
    echo "$1"
    echo "========================================"
}

section "Kustomization Build Validation"

# Find all kustomization directories
KUSTOMIZE_DIRS=$(find "$REPO_ROOT/apps" "$REPO_ROOT/infrastructure" -name "kustomization.yaml" -exec dirname {} \; 2>/dev/null | sort)

for dir in $KUSTOMIZE_DIRS; do
    REL_PATH="${dir#$REPO_ROOT/}"

    # Try to build the kustomization
    if kubectl kustomize "$dir" > /dev/null 2>&1; then
        pass "Kustomize build: $REL_PATH"
    else
        fail "Kustomize build: $REL_PATH"
        kubectl kustomize "$dir" 2>&1 | head -5
    fi
done

section "Security Context Validation"

# Check deployments for security contexts
for dir in $KUSTOMIZE_DIRS; do
    REL_PATH="${dir#$REPO_ROOT/}"

    # Skip ArgoCD applications directory (contains Application CRDs, not Deployments)
    if [[ "$REL_PATH" == *"argocd/applications"* ]]; then
        continue
    fi

    MANIFEST=$(kubectl kustomize "$dir" 2>/dev/null || echo "")
    if [ -z "$MANIFEST" ]; then
        continue
    fi

    # Check for Deployments without securityContext
    DEPLOYMENTS=$(echo "$MANIFEST" | grep -A1 "^kind: Deployment" | grep "^  name:" | awk '{print $2}' || true)
    for deploy in $DEPLOYMENTS; do
        if echo "$MANIFEST" | grep -A50 "name: $deploy" | grep -q "securityContext"; then
            pass "Security context: $deploy ($REL_PATH)"
        else
            warn "No security context: $deploy ($REL_PATH)"
        fi
    done
done

section "Required Labels Validation"

REQUIRED_LABELS="app.kubernetes.io/name"

for dir in $KUSTOMIZE_DIRS; do
    REL_PATH="${dir#$REPO_ROOT/}"

    # Skip ArgoCD applications directory
    if [[ "$REL_PATH" == *"argocd/applications"* ]]; then
        continue
    fi

    MANIFEST=$(kubectl kustomize "$dir" 2>/dev/null || echo "")
    if [ -z "$MANIFEST" ]; then
        continue
    fi

    # Check Deployments for required labels
    DEPLOYMENTS=$(echo "$MANIFEST" | grep -B1 "^kind: Deployment" -A20 | grep "name:" | head -5 || true)
    for deploy in $DEPLOYMENTS; do
        if echo "$MANIFEST" | grep -A30 "kind: Deployment" | grep -q "$REQUIRED_LABELS"; then
            pass "Required labels present in $REL_PATH"
            break
        else
            warn "Missing $REQUIRED_LABELS in $REL_PATH"
            break
        fi
    done
done

section "Resource Limits Validation"

for dir in $KUSTOMIZE_DIRS; do
    REL_PATH="${dir#$REPO_ROOT/}"

    # Skip non-app directories
    if [[ "$REL_PATH" != apps/* ]]; then
        continue
    fi
    # Skip ArgoCD applications directory
    if [[ "$REL_PATH" == *"argocd/applications"* ]]; then
        continue
    fi

    MANIFEST=$(kubectl kustomize "$dir" 2>/dev/null || echo "")
    if [ -z "$MANIFEST" ]; then
        continue
    fi

    # Check for resource limits in Deployments
    if echo "$MANIFEST" | grep -q "kind: Deployment"; then
        if echo "$MANIFEST" | grep -A100 "kind: Deployment" | grep -q "resources:"; then
            if echo "$MANIFEST" | grep -A100 "kind: Deployment" | grep -A20 "resources:" | grep -q "limits:"; then
                pass "Resource limits defined: $REL_PATH"
            else
                warn "Resource requests but no limits: $REL_PATH"
            fi
        else
            warn "No resource configuration: $REL_PATH"
        fi
    fi
done

section "Probe Validation"

for dir in $KUSTOMIZE_DIRS; do
    REL_PATH="${dir#$REPO_ROOT/}"

    # Skip non-app directories
    if [[ "$REL_PATH" != apps/* ]]; then
        continue
    fi
    # Skip ArgoCD applications directory
    if [[ "$REL_PATH" == *"argocd/applications"* ]]; then
        continue
    fi

    MANIFEST=$(kubectl kustomize "$dir" 2>/dev/null || echo "")
    if [ -z "$MANIFEST" ]; then
        continue
    fi

    # Check for health probes in Deployments
    if echo "$MANIFEST" | grep -q "kind: Deployment"; then
        HAS_LIVENESS=$(echo "$MANIFEST" | grep -c "livenessProbe:" || echo 0)
        HAS_READINESS=$(echo "$MANIFEST" | grep -c "readinessProbe:" || echo 0)

        if [ "$HAS_LIVENESS" -gt 0 ] && [ "$HAS_READINESS" -gt 0 ]; then
            pass "Health probes defined: $REL_PATH"
        elif [ "$HAS_LIVENESS" -gt 0 ] || [ "$HAS_READINESS" -gt 0 ]; then
            warn "Partial health probes: $REL_PATH"
        else
            warn "No health probes: $REL_PATH"
        fi
    fi
done

section "Certificate Validation"

CERT_FILES=$(find "$REPO_ROOT/apps" "$REPO_ROOT/infrastructure" -name "certificate.yaml" 2>/dev/null || true)
for cert_file in $CERT_FILES; do
    REL_PATH="${cert_file#$REPO_ROOT/}"

    # Check for required issuer reference
    if grep -q "issuerRef:" "$cert_file" && grep -q "letsencrypt-prod" "$cert_file"; then
        pass "Certificate uses prod issuer: $REL_PATH"
    elif grep -q "issuerRef:" "$cert_file"; then
        warn "Certificate may use non-prod issuer: $REL_PATH"
    else
        fail "Certificate missing issuerRef: $REL_PATH"
    fi
done

section "Ingress Validation"

INGRESS_FILES=$(find "$REPO_ROOT/apps" "$REPO_ROOT/infrastructure" -name "ingress.yaml" 2>/dev/null || true)
for ingress_file in $INGRESS_FILES; do
    REL_PATH="${ingress_file#$REPO_ROOT/}"

    # Check for TLS configuration
    if grep -q "tls:" "$ingress_file"; then
        pass "Ingress has TLS: $REL_PATH"
    else
        warn "Ingress missing TLS: $REL_PATH"
    fi

    # Check for ingressClassName
    if grep -q "ingressClassName:" "$ingress_file"; then
        pass "Ingress has className: $REL_PATH"
    else
        warn "Ingress missing ingressClassName: $REL_PATH"
    fi
done

section "Namespace Validation"

NAMESPACE_FILES=$(find "$REPO_ROOT/apps" "$REPO_ROOT/infrastructure" -name "namespace.yaml" 2>/dev/null || true)
for ns_file in $NAMESPACE_FILES; do
    REL_PATH="${ns_file#$REPO_ROOT/}"

    # Check namespace has labels
    if grep -q "labels:" "$ns_file"; then
        pass "Namespace has labels: $REL_PATH"
    else
        warn "Namespace missing labels: $REL_PATH"
    fi
done

section "Service Validation"

SERVICE_FILES=$(find "$REPO_ROOT/apps" "$REPO_ROOT/infrastructure" -name "service.yaml" 2>/dev/null || true)
for svc_file in $SERVICE_FILES; do
    REL_PATH="${svc_file#$REPO_ROOT/}"

    # Check service has selector
    if grep -q "selector:" "$svc_file"; then
        pass "Service has selector: $REL_PATH"
    else
        warn "Service missing selector: $REL_PATH"
    fi

    # Check service has port defined
    if grep -q "port:" "$svc_file"; then
        pass "Service has port: $REL_PATH"
    else
        fail "Service missing port: $REL_PATH"
    fi
done

section "Network Policy Validation"

NETPOL_FILES=$(find "$REPO_ROOT/apps" "$REPO_ROOT/infrastructure" -name "networkpolicy.yaml" -o -name "network-policy.yaml" 2>/dev/null || true)
for netpol_file in $NETPOL_FILES; do
    REL_PATH="${netpol_file#$REPO_ROOT/}"

    # Check network policy has podSelector
    if grep -q "podSelector:" "$netpol_file"; then
        pass "NetworkPolicy has podSelector: $REL_PATH"
    else
        fail "NetworkPolicy missing podSelector: $REL_PATH"
    fi
done

section "ArgoCD Application Validation"

ARGOCD_APP_FILES=$(find "$REPO_ROOT/apps/argocd/applications" -name "*.yaml" ! -name "kustomization.yaml" 2>/dev/null || true)
for app_file in $ARGOCD_APP_FILES; do
    REL_PATH="${app_file#$REPO_ROOT/}"
    FILENAME=$(basename "$app_file")

    # Check it's an Application resource
    if grep -q "kind: Application" "$app_file"; then
        pass "ArgoCD Application valid: $FILENAME"

        # Check it has a destination
        if grep -q "destination:" "$app_file"; then
            pass "ArgoCD Application has destination: $FILENAME"
        else
            fail "ArgoCD Application missing destination: $FILENAME"
        fi

        # Check it has a source
        if grep -q "source:" "$app_file" || grep -q "sources:" "$app_file"; then
            pass "ArgoCD Application has source: $FILENAME"
        else
            fail "ArgoCD Application missing source: $FILENAME"
        fi

        # Check for syncPolicy
        if grep -q "syncPolicy:" "$app_file"; then
            pass "ArgoCD Application has syncPolicy: $FILENAME"
        else
            warn "ArgoCD Application missing syncPolicy: $FILENAME"
        fi
    fi
done

section "Deployment Validation"

DEPLOYMENT_FILES=$(find "$REPO_ROOT/apps" "$REPO_ROOT/infrastructure" -name "deployment.yaml" 2>/dev/null || true)
for deploy_file in $DEPLOYMENT_FILES; do
    REL_PATH="${deploy_file#$REPO_ROOT/}"

    # Check deployment has replicas
    if grep -q "replicas:" "$deploy_file"; then
        pass "Deployment has replicas: $REL_PATH"
    else
        warn "Deployment missing replicas (defaults to 1): $REL_PATH"
    fi

    # Check deployment has selector
    if grep -q "selector:" "$deploy_file"; then
        pass "Deployment has selector: $REL_PATH"
    else
        fail "Deployment missing selector: $REL_PATH"
    fi

    # Check for image
    if grep -q "image:" "$deploy_file"; then
        pass "Deployment has image: $REL_PATH"
    else
        fail "Deployment missing image: $REL_PATH"
    fi
done

section "YAML Syntax Validation"

# Validate all YAML files have valid syntax
YAML_FILES=$(find "$REPO_ROOT/apps" "$REPO_ROOT/infrastructure" -name "*.yaml" -o -name "*.yml" 2>/dev/null || true)
YAML_ERRORS=0
for yaml_file in $YAML_FILES; do
    REL_PATH="${yaml_file#$REPO_ROOT/}"

    # Skip Authentik blueprints (use custom YAML tags like !Find, !KeyOf)
    if [[ "$REL_PATH" == *"blueprints"* ]]; then
        continue
    fi

    # Use python to validate YAML if available, otherwise skip
    # Use safe_load_all for multi-document YAML files
    if command -v python3 &> /dev/null; then
        if python3 -c "import yaml; list(yaml.safe_load_all(open('$yaml_file')))" 2>/dev/null; then
            : # Valid YAML, don't output anything to reduce noise
        else
            fail "Invalid YAML syntax: $REL_PATH"
            YAML_ERRORS=$((YAML_ERRORS + 1))
        fi
    fi
done
if [ "$YAML_ERRORS" -eq 0 ]; then
    pass "All YAML files have valid syntax"
fi

section "PodDisruptionBudget Validation"

PDB_FILES=$(find "$REPO_ROOT/apps" "$REPO_ROOT/infrastructure" -name "pdb.yaml" -o -name "poddisruptionbudget.yaml" 2>/dev/null || true)
for pdb_file in $PDB_FILES; do
    REL_PATH="${pdb_file#$REPO_ROOT/}"

    if grep -q "minAvailable:" "$pdb_file" || grep -q "maxUnavailable:" "$pdb_file"; then
        pass "PDB has availability constraint: $REL_PATH"
    else
        fail "PDB missing availability constraint: $REL_PATH"
    fi
done

section "Sealed Secret Validation"

SEALED_SECRET_FILES=$(find "$REPO_ROOT/apps" "$REPO_ROOT/infrastructure" -name "*sealed*.yaml" -o -name "*-secret.yaml" 2>/dev/null | grep -i seal || true)
for ss_file in $SEALED_SECRET_FILES; do
    REL_PATH="${ss_file#$REPO_ROOT/}"

    if grep -q "kind: SealedSecret" "$ss_file"; then
        pass "SealedSecret resource: $REL_PATH"

        # Check it has encryptedData
        if grep -q "encryptedData:" "$ss_file"; then
            pass "SealedSecret has encryptedData: $REL_PATH"
        else
            fail "SealedSecret missing encryptedData: $REL_PATH"
        fi
    fi
done

section "Summary"

TOTAL=$((PASSED + FAILED))
echo ""
echo "Results: $PASSED passed, $FAILED failed, $WARNINGS warnings"
echo ""

if [ "$FAILED" -gt 0 ]; then
    echo -e "${RED}Validation failed!${NC}"
    exit 1
else
    echo -e "${GREEN}Validation passed!${NC}"
    exit 0
fi
