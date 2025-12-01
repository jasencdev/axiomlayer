#!/bin/bash
# Check for plaintext Secret resources (should use SealedSecret)
# Ignores references to Secret in ignoreDifferences blocks

set -euo pipefail
if grep -rn "^\s*kind:\s*Secret\s*$" --include="*.yaml" apps/ infrastructure/ 2>/dev/null; then
    echo "ERROR: Found plaintext Secret. Use SealedSecret instead."
    exit 1
fi
exit 0
