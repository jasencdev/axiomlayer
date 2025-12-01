#!/bin/bash
# Check for plaintext Secret resources (should use SealedSecret)
# Only matches top-level kind: Secret (not indented references in ignoreDifferences, etc.)

set -euo pipefail
if grep -rn "^kind: Secret$" --include="*.yaml" apps/ infrastructure/ 2>/dev/null; then
    echo "ERROR: Found plaintext Secret. Use SealedSecret instead."
    exit 1
fi
exit 0
