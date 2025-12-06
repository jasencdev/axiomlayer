#!/bin/bash
# Validate Kustomize manifests for core MVP stack
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

FAILED=0
PASSED=0

pass() { echo -e "${GREEN}[PASS]${NC} $1"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; FAILED=$((FAILED + 1)); }

echo "=== Validating Kustomize Manifests ==="

# Find all kustomization directories
KUSTOMIZE_DIRS=$(find "$REPO_ROOT/apps" "$REPO_ROOT/infrastructure" -name "kustomization.yaml" -exec dirname {} \; 2>/dev/null | sort)

for dir in $KUSTOMIZE_DIRS; do
    REL_PATH="${dir#$REPO_ROOT/}"
    if kubectl kustomize "$dir" > /dev/null 2>&1; then
        pass "Kustomize build: $REL_PATH"
    else
        fail "Kustomize build: $REL_PATH"
        kubectl kustomize "$dir" 2>&1 | head -3
    fi
done

echo ""
echo "Results: $PASSED passed, $FAILED failed"

if [ "$FAILED" -gt 0 ]; then
    echo -e "${RED}Validation failed!${NC}"
    exit 1
fi

echo -e "${GREEN}Validation passed!${NC}"
