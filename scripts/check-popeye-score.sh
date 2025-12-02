#!/bin/bash
# check-popeye-score.sh - Pre-commit hook to check cluster health score
#
# Runs popeye scan and fails if score drops below threshold.
# Skips gracefully if popeye is not installed or cluster is not reachable.

set -euo pipefail

THRESHOLD=75

# Check if popeye is installed
if ! command -v popeye &> /dev/null; then
    echo "Popeye not installed, skipping cluster health check"
    echo "Install with: brew install derailed/popeye/popeye (macOS) or download from https://github.com/derailed/popeye/releases"
    exit 0
fi

# Check if kubectl can reach the cluster
if ! kubectl cluster-info &> /dev/null; then
    echo "Cannot reach Kubernetes cluster, skipping popeye scan"
    exit 0
fi

echo "Running Popeye cluster health scan..."

# Run popeye and capture output
REPORT_FILE=$(mktemp)
if ! popeye --all-namespaces --force-exit-zero -o json > "$REPORT_FILE" 2>/dev/null; then
    echo "Popeye scan failed, skipping"
    rm -f "$REPORT_FILE"
    exit 0
fi

# Extract score (popeye JSON structure: .popeye.score)
SCORE=$(jq -r '.popeye.score // 0' "$REPORT_FILE" 2>/dev/null || echo "0")
echo "Cluster health score: ${SCORE}%"

# Show summary of issues
echo ""
echo "=== Issue Summary ==="
jq -r '.popeye.sanitizers[] | select(.issues != null) | "\(.sanitizer): \(.issues | length) issues"' "$REPORT_FILE" 2>/dev/null || true

# Clean up
rm -f "$REPORT_FILE"

# Check threshold
if [ "${SCORE}" -lt "${THRESHOLD}" ]; then
    echo ""
    echo "ERROR: Cluster health score ${SCORE}% is below threshold of ${THRESHOLD}%"
    echo "Run 'popeye -A' locally for full report"
    exit 1
fi

echo ""
echo "Cluster health score ${SCORE}% meets threshold of ${THRESHOLD}%"
