#!/bin/bash
# sync-rag.sh - Sync repository files to Open WebUI RAG knowledge base
#
# Usage: ./sync-rag.sh
#
# Uses git to detect changed files and intelligently syncs only what's needed:
# - New files: Upload and add to knowledge base
# - Changed files: Delete old version, upload new, add to knowledge base
# - Unchanged files: Skip
#
# For a complete reset/cleanup, use: ./scripts/run-rag-sync-manual.sh
#
# Required environment variables:
#   OPEN_WEBUI_API_KEY - API key from Open WebUI Settings > Account
#   OPEN_WEBUI_KNOWLEDGE_ID - Knowledge base ID to sync files to
#
# Optional environment variables:
#   LAST_SYNC_COMMIT - Previous sync commit SHA (default: uses marker file or HEAD~1)
#   FORCE_FULL_SYNC - Set to "true" to sync all files regardless of changes

set -euo pipefail

# Configuration
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
SYNC_MARKER_FILE="$REPO_ROOT/.rag-sync-commit"
export KUBECONFIG="${KUBECONFIG:-/home/jasen/.kube/config}"

# Known files that fail due to Open WebUI embedding bugs
# These are tracked and logged but don't cause CI failure
KNOWN_FAILING_FILES=(
    "README.md"
    "docs/RAG_KNOWLEDGE_BASE.md"
    "infrastructure/alertmanager/ingress.yaml"
)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if a file is in the known-failing list
is_known_failing() {
    local file="$1"
    for known in "${KNOWN_FAILING_FILES[@]}"; do
        if [[ "$file" == "$known" ]]; then
            return 0
        fi
    done
    return 1
}

# Parse command line arguments
for arg in "$@"; do
    case $arg in
        --help|-h)
            echo "Usage: $0"
            echo ""
            echo "Incrementally syncs repository files to Open WebUI RAG knowledge base."
            echo "For a complete reset/cleanup, use: ./scripts/run-rag-sync-manual.sh"
            echo ""
            echo "Environment variables:"
            echo "  OPEN_WEBUI_API_KEY      - API key (required)"
            echo "  OPEN_WEBUI_KNOWLEDGE_ID - Knowledge base ID (required)"
            echo "  FORCE_FULL_SYNC         - Set to 'true' to sync all files"
            exit 0
            ;;
    esac
done

# Check required environment variables
check_requirements() {
    local missing=0

    if [[ -z "${OPEN_WEBUI_API_KEY:-}" ]]; then
        log_error "OPEN_WEBUI_API_KEY is not set"
        missing=1
    fi

    if [[ -z "${OPEN_WEBUI_KNOWLEDGE_ID:-}" ]]; then
        log_error "OPEN_WEBUI_KNOWLEDGE_ID is not set"
        missing=1
    fi

    if ! command -v jq &> /dev/null; then
        log_error "jq is required but not installed"
        missing=1
    fi

    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is required but not installed"
        missing=1
    fi

    if [[ $missing -eq 1 ]]; then
        echo ""
        echo "Required environment variables:"
        echo "  OPEN_WEBUI_API_KEY      - API key from Open WebUI Settings > Account"
        echo "  OPEN_WEBUI_KNOWLEDGE_ID - Knowledge base ID (from URL when viewing knowledge base)"
        echo ""
        echo "Optional:"
        echo "  LAST_SYNC_COMMIT        - Previous sync commit SHA"
        echo "  FORCE_FULL_SYNC         - Set to 'true' to sync all files"
        exit 1
    fi
}

# Get Open WebUI pod name
get_pod() {
    kubectl get pods -n open-webui -l app.kubernetes.io/name=open-webui -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# Helper to call Open WebUI API from within the cluster
# Uses bash -c to properly handle JWT tokens with special characters
api_call() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"

    if [[ -n "$data" ]]; then
        echo "curl -s -X '$method' -H 'Authorization: Bearer $OPEN_WEBUI_API_KEY' -H 'Content-Type: application/json' -d '$data' 'http://localhost:8080$endpoint'" | \
            kubectl exec -i -n open-webui "$POD" -- bash
    else
        echo "curl -s -X '$method' -H 'Authorization: Bearer $OPEN_WEBUI_API_KEY' 'http://localhost:8080$endpoint'" | \
            kubectl exec -i -n open-webui "$POD" -- bash
    fi
}

# Get the last synced commit
get_last_sync_commit() {
    if [[ -n "${LAST_SYNC_COMMIT:-}" ]]; then
        echo "$LAST_SYNC_COMMIT"
    elif [[ -f "$SYNC_MARKER_FILE" ]]; then
        cat "$SYNC_MARKER_FILE"
    else
        git rev-parse HEAD~1 2>/dev/null || echo ""
    fi
}

# Save current commit as last synced
save_sync_commit() {
    local commit
    commit=$(git rev-parse HEAD)
    echo "$commit" > "$SYNC_MARKER_FILE"
    log_info "Saved sync marker: $commit"
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

# Check if file changed since last sync
file_changed_since() {
    local file="$1"
    local last_commit="$2"
    [[ -z "$last_commit" ]] && return 0
    git diff --name-only "$last_commit" HEAD -- "$file" 2>/dev/null | grep -q .
}

# Delete a file from Open WebUI
delete_file() {
    local file_id="$1"
    local filename="$2"

    log_info "  Deleting: $filename (ID: ${file_id:0:8}...)"
    local response
    response=$(api_call DELETE "/api/v1/files/$file_id")

    if echo "$response" | jq -e '.id' > /dev/null 2>&1; then
        return 0
    else
        log_warn "  Delete may have failed: $response"
        return 1
    fi
}

# Upload a file and add to KB (using same method as manual script)
# Uses piped bash to properly handle JWT tokens with special characters
upload_file() {
    local file_path="$1"
    local relative_path="${file_path#$REPO_ROOT/}"

    # Copy file to pod
    kubectl cp "$file_path" "open-webui/$POD:/tmp/sync-file" 2>/dev/null

    # Upload and add to KB inside the pod (pipe through bash for proper JWT handling)
    local result
    result=$(cat <<UPLOAD_SCRIPT | kubectl exec -i -n open-webui "$POD" -- bash
RESP=\$(curl -s -X POST -H 'Authorization: Bearer $OPEN_WEBUI_API_KEY' -F 'file=@/tmp/sync-file;filename=$relative_path' http://localhost:8080/api/v1/files/)
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
            log_info "  ✓ Added to knowledge base: $relative_path"
            return 0
            ;;
        FAIL_KB*)
            log_error "  ✗ KB add failed (cleaned up): $relative_path"
            return 1
            ;;
        *)
            log_error "  ✗ Upload failed: $relative_path"
            return 1
            ;;
    esac
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

# Get list of deleted files since last sync
get_deleted_files() {
    local last_commit="$1"
    [[ -z "$last_commit" ]] && return
    [[ "${FORCE_FULL_SYNC:-}" == "true" ]] && return
    cd "$REPO_ROOT" || return
    git diff --name-only --diff-filter=D "$last_commit" HEAD 2>/dev/null || true
}

# Load existing files from knowledge base
load_kb_files() {
    log_info "Loading existing knowledge base files..."
    local response
    response=$(api_call GET "/api/v1/knowledge/$OPEN_WEBUI_KNOWLEDGE_ID")

    if echo "$response" | jq -e '.files' > /dev/null 2>&1; then
        KB_FILE_COUNT=$(echo "$response" | jq '.files | length')
        # Build associative array of path -> file_id
        while IFS= read -r line; do
            local file_id name
            file_id=$(echo "$line" | jq -r '.id')
            name=$(echo "$line" | jq -r '.meta.name // .filename')
            if [[ -n "$file_id" && "$file_id" != "null" ]]; then
                KB_FILES["$name"]="$file_id"
            fi
        done < <(echo "$response" | jq -c '.files[]' 2>/dev/null)
        log_info "  Found $KB_FILE_COUNT files in knowledge base"
    else
        log_warn "  Could not load knowledge base files (may be empty or first sync)"
        KB_FILE_COUNT=0
    fi
}

# Main sync function
sync_to_rag() {
    log_info "Starting RAG sync"
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

    # Declare associative array for KB files
    declare -A KB_FILES=()
    local KB_FILE_COUNT=0

    # Load existing KB state
    load_kb_files
    echo ""

    # Get last sync point
    local last_commit
    last_commit=$(get_last_sync_commit)

    if [[ -n "$last_commit" ]]; then
        log_info "Last sync commit: ${last_commit:0:8}"
    else
        log_info "No previous sync marker found"
    fi

    local uploaded=0
    local skipped=0
    local deleted=0
    local failed=0
    local already_synced=0
    declare -a FAILED_FILES=()

    # Handle deleted files first
    if [[ -n "$last_commit" ]]; then
        log_info "Checking for deleted files..."
        while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            if [[ -n "${KB_FILES[$file]:-}" ]]; then
                if delete_file "${KB_FILES[$file]}" "$file"; then
                    deleted=$((deleted + 1))
                    unset "KB_FILES[$file]"
                fi
            fi
        done < <(get_deleted_files "$last_commit")
    fi

    echo ""
    log_info "Processing files..."

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

        # Decision logic
        local file_in_kb=false
        if [[ -n "${KB_FILES[$file]:-}" ]]; then
            file_in_kb=true
        fi

        if [[ "$file_in_kb" == "false" ]]; then
            # File not in KB - upload it
            log_info "New file: $file"
            if upload_file "$full_path"; then
                uploaded=$((uploaded + 1))
            else
                failed=$((failed + 1))
                FAILED_FILES+=("$file")
            fi
        elif [[ "${FORCE_FULL_SYNC:-}" == "true" ]]; then
            # Force sync - delete and re-upload
            log_info "Force sync: $file"
            delete_file "${KB_FILES[$file]}" "$file" || true
            if upload_file "$full_path"; then
                uploaded=$((uploaded + 1))
            else
                failed=$((failed + 1))
                FAILED_FILES+=("$file")
            fi
        elif file_changed_since "$file" "$last_commit"; then
            # File in KB but changed - delete old and upload new
            log_info "Changed: $file"
            delete_file "${KB_FILES[$file]}" "$file" || true
            if upload_file "$full_path"; then
                uploaded=$((uploaded + 1))
            else
                failed=$((failed + 1))
                FAILED_FILES+=("$file")
            fi
        else
            # File in KB and not changed - skip
            already_synced=$((already_synced + 1))
        fi

    done < <(get_all_matching_files)

    echo ""
    log_info "===== Sync Summary ====="
    log_info "  Uploaded:       $uploaded"
    log_info "  Already synced: $already_synced"
    log_info "  Deleted:        $deleted"
    log_info "  Skipped (size): $skipped"
    log_info "  Failed:         $failed"

    # Check for unexpected failures
    local unexpected_failures=0
    for file in "${FAILED_FILES[@]}"; do
        if ! is_known_failing "$file"; then
            log_error "Unexpected failure: $file"
            unexpected_failures=$((unexpected_failures + 1))
        else
            log_warn "Known failing file (Open WebUI bug): $file"
        fi
    done

    if [[ $unexpected_failures -gt 0 ]]; then
        log_error "Sync failed with $unexpected_failures unexpected failures"
        exit 1
    fi

    # Save marker even if only known files failed
    save_sync_commit
    if [[ ${#FAILED_FILES[@]} -gt 0 ]]; then
        log_info "Sync completed (${#FAILED_FILES[@]} known failures tolerated)"
    fi
}

# Run
check_requirements
sync_to_rag
