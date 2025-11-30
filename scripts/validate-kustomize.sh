#!/bin/bash
# Validate all kustomize builds
set -euo pipefail

for dir in $(find apps/ infrastructure/ -name "kustomization.yaml" -exec dirname {} \;); do
    echo "Validating $dir"
    kubectl kustomize "$dir" > /dev/null || exit 1
done
exit 0
