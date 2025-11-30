#!/bin/bash
# Check for plaintext Secret resources (should use SealedSecret)

set -euo pipefail
if grep -rn "kind: Secret" --include="*.yaml" apps/ infrastructure/ 2>/dev/null | grep -v SealedSecret; then
    echo "ERROR: Found plaintext Secret. Use SealedSecret instead."
    exit 1
fi
exit 0
