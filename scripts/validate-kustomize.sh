#!/bin/bash
# Validate all kustomize builds
set -euo pipefail

for dir in apps/*/; do
    if [ -f "$dir/kustomization.yaml" ]; then
        echo "Validating $dir"
        kubectl kustomize "$dir" > /dev/null || exit 1
    fi
done
exit 0
