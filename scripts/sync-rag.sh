#!/bin/bash
# sync-rag.sh - Sync repository files to Open WebUI RAG knowledge base
#
# Hash-based smart sync: Files are only uploaded if their content has changed.
# This avoids wasteful embedding of duplicate content.
#
# Usage: ./sync-rag.sh
#
# Required environment variables:
#   OPEN_WEBUI_API_KEY - API key from Open WebUI Settings > Account
#   OPEN_WEBUI_KNOWLEDGE_ID - Knowledge base ID to sync files to
#
# Optional environment variables:
#   FORCE_FULL_SYNC - Set to "true" to sync all files regardless of changes

set -euo pipefail

# Configuration
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
export KUBECONFIG="${KUBECONFIG:-/home/jasen/.kube/config}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_skip() { echo -e "${BLUE}[SKIP]${NC} $1"; }

# Parse command line arguments
for arg in "$@"; do
    case $arg in
        --help|-h)
            echo "Usage: $0"
            echo ""
            echo "Hash-based smart sync to Open WebUI RAG knowledge base."
            echo "Files are only uploaded if their content hash differs from"
            echo "what's already in the knowledge base."
            echo ""
            echo "Environment variables:"
            echo "  OPEN_WEBUI_API_KEY      - API key (required)"
            echo "  OPEN_WEBUI_KNOWLEDGE_ID - Knowledge base ID (required)"
            echo "  FORCE_FULL_SYNC         - Set to 'true' to re-upload all files"
            exit 0
            ;;
    esac
done

# Get Open WebUI pod name
get_pod() {
    kubectl get pods -n open-webui -l app.kubernetes.io/name=open-webui -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# Convert path to safe filename (matches Open WebUI naming)
# Example: apps/dashboard/configmap.yaml -> apps__dashboard__configmap.yaml
path_to_safe_name() {
    local path="$1"
    echo "$path" | sed 's|/|__|g'
}

# Check if file should be excluded
is_excluded() {
    local file="$1"
    case "$file" in
        *sealed-secret*|*.env*|*AGENTS.md*) return 0 ;;
    esac
    case "$(basename "$file")" in
        *sealed-secret*|*.env*|*AGENTS.md*) return 0 ;;
    esac
    return 1
}

# Compute SHA256 hash of a file (same algorithm as Open WebUI)
compute_hash() {
    local file="$1"
    sha256sum "$file" | cut -d' ' -f1
}

# Get all files matching sync patterns
get_all_matching_files() {
    cd "$REPO_ROOT" || return 1
    find . -type f \( -name "*.md" -o -name "*.yaml" \) \
        ! -path "./.git/*" \
        ! -name "*sealed-secret*" \
        ! -name "*.env*" \
        ! -name "*AGENTS.md*" \
        | sed 's|^\./||' | sort
}

# Fetch existing files from knowledge base with their hashes
fetch_kb_files() {
    local result
    result=$(cat <<FETCH_SCRIPT | kubectl exec -i -n open-webui "$POD" -- bash 2>/dev/null
curl -s -H 'Authorization: Bearer $OPEN_WEBUI_API_KEY' \
    'http://localhost:8080/api/v1/knowledge/$OPEN_WEBUI_KNOWLEDGE_ID'
FETCH_SCRIPT
)
    echo "$result"
}

# Parse KB response to get filename -> hash mapping
# Outputs: filename<TAB>hash per line
parse_kb_files() {
    local kb_json="$1"
    echo "$kb_json" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    files = d.get("files", [])
    for f in files:
        name = f.get("meta", {}).get("name", "")
        h = f.get("hash", "")
        if name and h:
            print(f"{name}\t{h}")
except:
    pass
'
}

# Upload a file
upload_file() {
    local file_path="$1"
    local safe_name="$2"

    # Copy file to pod
    kubectl cp "$file_path" "open-webui/$POD:/tmp/sync-file" 2>/dev/null

    # Upload and add to KB inside the pod
    local result
    result=$(cat <<UPLOAD_SCRIPT | kubectl exec -i -n open-webui "$POD" -- bash
RESP=\$(curl -s -X POST -H 'Authorization: Bearer $OPEN_WEBUI_API_KEY' -F "file=@/tmp/sync-file;filename=$safe_name" http://localhost:8080/api/v1/files/)
FID=\$(echo "\$RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null)
if [ -n "\$FID" ] && [ "\$FID" != "None" ]; then
    ADD_RESP=\$(curl -s -X POST -H 'Authorization: Bearer $OPEN_WEBUI_API_KEY' -H 'Content-Type: application/json' -d "{\"file_id\":\"\$FID\"}" 'http://localhost:8080/api/v1/knowledge/$OPEN_WEBUI_KNOWLEDGE_ID/file/add')
    if echo "\$ADD_RESP" | python3 -c 'import sys,json;d=json.load(sys.stdin);exit(0 if "files" in d else 1)' 2>/dev/null; then
        echo 'OK'
    else
        # Failed to add to KB - delete the orphaned file
        curl -s -X DELETE -H 'Authorization: Bearer $OPEN_WEBUI_API_KEY' "http://localhost:8080/api/v1/files/\$FID" >/dev/null 2>&1
        echo 'FAIL_KB'
    fi
else
    echo 'FAIL_UPLOAD'
fi
rm -f /tmp/sync-file
UPLOAD_SCRIPT
)

    case "$result" in
        OK*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Main sync function
sync_to_rag() {
    log_info "Starting RAG sync (hash-based smart sync)"
    log_info "Knowledge base ID: $OPEN_WEBUI_KNOWLEDGE_ID"
    log_info "Repository root: $REPO_ROOT"
    echo ""

    # Get pod
    POD=$(get_pod)
    if [[ -z "$POD" ]]; then
        log_error "Could not find Open WebUI pod"
        exit 1
    fi
    log_info "Using pod: $POD"

    # Fetch existing KB files
    log_info "Fetching existing files from knowledge base..."
    local kb_json
    kb_json=$(fetch_kb_files)

    # Build hash lookup (associative array)
    declare -A KB_HASHES=()
    while IFS=$'\t' read -r name hash; do
        [[ -n "$name" ]] && KB_HASHES["$name"]="$hash"
    done < <(parse_kb_files "$kb_json")

    local kb_count="${#KB_HASHES[@]}"
    log_info "Found $kb_count existing files in knowledge base"
    echo ""

    local uploaded=0
    local skipped=0
    local unchanged=0
    local failed=0
    declare -a FAILED_FILES=()

    log_info "Processing local files..."
    echo ""

    cd "$REPO_ROOT" || { log_error "Cannot access repo root"; exit 1; }

    # Process all matching files
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue

        # Check exclusions
        if is_excluded "$file"; then
            continue
        fi

        local full_path="$REPO_ROOT/$file"

        # Skip if file doesn't exist or is empty
        if [[ ! -f "$full_path" ]] || [[ ! -s "$full_path" ]]; then
            continue
        fi

        # Skip files larger than 500KB
        local size
        size=$(stat -c%s "$full_path" 2>/dev/null || stat -f%z "$full_path" 2>/dev/null || echo "0")
        if [[ "$size" -gt 512000 ]]; then
            log_warn "Skipping $file (${size} bytes > 500KB limit)"
            skipped=$((skipped + 1))
            continue
        fi

        # Generate safe filename
        local safe_name
        safe_name=$(path_to_safe_name "$file")

        # Compute local file hash
        local local_hash
        local_hash=$(compute_hash "$full_path")

        # Check if file exists in KB with same hash
        local kb_hash="${KB_HASHES[$safe_name]:-}"

        if [[ -n "$kb_hash" ]] && [[ "$kb_hash" == "$local_hash" ]] && [[ "${FORCE_FULL_SYNC:-}" != "true" ]]; then
            # File unchanged - skip
            log_skip "$file (unchanged)"
            unchanged=$((unchanged + 1))
            continue
        fi

        # File is new or changed - upload it
        if [[ -n "$kb_hash" ]]; then
            log_info "Updating: $file (hash changed)"
        else
            log_info "Adding: $file (new file)"
        fi

        if upload_file "$full_path" "$safe_name"; then
            log_info "  ✓ Uploaded successfully"
            uploaded=$((uploaded + 1))
        else
            log_error "  ✗ Upload failed"
            failed=$((failed + 1))
            FAILED_FILES+=("$file")
        fi

    done < <(get_all_matching_files)

    echo ""
    log_info "===== Sync Summary ====="
    log_info "  Files in KB:  $kb_count"
    log_info "  Unchanged:    $unchanged (skipped - no embedding needed)"
    log_info "  Uploaded:     $uploaded"
    log_info "  Skipped:      $skipped (too large)"
    log_info "  Failed:       $failed"

    if [[ $failed -gt 0 ]]; then
        log_error "Sync completed with $failed failures:"
        for file in "${FAILED_FILES[@]}"; do
            log_error "  - $file"
        done
        exit 1
    fi

    if [[ $unchanged -gt 0 ]] && [[ $uploaded -eq 0 ]]; then
        log_info "All files unchanged - no embeddings needed!"
    fi

    log_info "Sync completed successfully"
}

# Run
sync_to_rag
