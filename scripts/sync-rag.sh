#!/bin/bash
# sync-rag.sh - Sync repository files to Open WebUI RAG knowledge base
#
# Uses git to detect changed files and intelligently syncs only what's needed:
# - New files: Upload and add to knowledge base
# - Changed files: Delete old version, upload new, add to knowledge base
# - Unchanged files: Skip
#
# Required environment variables:
#   OPEN_WEBUI_API_KEY - API key from Open WebUI Settings > Account
#   OPEN_WEBUI_KNOWLEDGE_ID - Knowledge base ID to sync files to
#
# Optional environment variables:
#   OPEN_WEBUI_URL - Base URL (default: internal cluster URL)
#   LAST_SYNC_COMMIT - Previous sync commit SHA (default: uses marker file or HEAD~1)
#   FORCE_FULL_SYNC - Set to "true" to sync all files regardless of changes

set -euo pipefail

# Configuration
OPEN_WEBUI_URL="${OPEN_WEBUI_URL:-http://open-webui.open-webui.svc.cluster.local:8080}"
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
SYNC_MARKER_FILE="$REPO_ROOT/.rag-sync-commit"

# Files to sync (relative to repo root)
SYNC_PATTERNS=(
    "*.md"
    "apps/**/kustomization.yaml"
    "apps/**/*.yaml"
    "infrastructure/**/kustomization.yaml"
    "infrastructure/**/*.yaml"
    ".github/workflows/*.yaml"
)

# Files to exclude
EXCLUDE_PATTERNS=(
    "*sealed-secret*"
    "*.env*"
    "*AGENTS.md*"
)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_debug() { echo -e "${BLUE}[DEBUG]${NC} $1"; }

# Associative arrays to track KB state
declare -A KB_FILES_BY_NAME  # filename -> file_id
declare -A KB_FILES_BY_HASH  # hash -> file_id

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

    if [[ $missing -eq 1 ]]; then
        echo ""
        echo "Required environment variables:"
        echo "  OPEN_WEBUI_API_KEY      - API key from Open WebUI Settings > Account"
        echo "  OPEN_WEBUI_KNOWLEDGE_ID - Knowledge base ID (from URL when viewing knowledge base)"
        echo ""
        echo "Optional:"
        echo "  OPEN_WEBUI_URL          - Base URL (default: internal cluster URL)"
        echo "  LAST_SYNC_COMMIT        - Previous sync commit SHA"
        echo "  FORCE_FULL_SYNC         - Set to 'true' to sync all files"
        exit 1
    fi
}

# Load existing files from knowledge base into associative arrays
load_kb_files() {
    log_info "Loading existing knowledge base files..."

    local response
    response=$(curl -s -H "Authorization: Bearer $OPEN_WEBUI_API_KEY" \
        "$OPEN_WEBUI_URL/api/v1/knowledge/$OPEN_WEBUI_KNOWLEDGE_ID" 2>&1)

    if echo "$response" | jq -e '.files' > /dev/null 2>&1; then
        local count=0
        while IFS= read -r line; do
            local file_id name hash
            file_id=$(echo "$line" | jq -r '.id')
            name=$(echo "$line" | jq -r '.meta.name // .filename')
            hash=$(echo "$line" | jq -r '.hash')

            if [[ -n "$file_id" && "$file_id" != "null" ]]; then
                KB_FILES_BY_NAME["$name"]="$file_id"
                KB_FILES_BY_HASH["$hash"]="$file_id"
                count=$((count + 1))
            fi
        done < <(echo "$response" | jq -c '.files[]' 2>/dev/null)
        log_info "  Found $count files in knowledge base"
    else
        log_warn "  Could not load knowledge base files (may be empty or first sync)"
    fi
}

# Get the last synced commit
get_last_sync_commit() {
    # Priority: env var > marker file > HEAD~1
    if [[ -n "${LAST_SYNC_COMMIT:-}" ]]; then
        echo "$LAST_SYNC_COMMIT"
    elif [[ -f "$SYNC_MARKER_FILE" ]]; then
        cat "$SYNC_MARKER_FILE"
    else
        # First sync or no marker - compare against parent commit
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

# Check if file matches sync patterns
matches_sync_patterns() {
    local file="$1"

    for pattern in "${SYNC_PATTERNS[@]}"; do
        # Convert glob pattern to regex-like matching
        case "$file" in
            $pattern) return 0 ;;
        esac

        # Handle ** patterns
        if [[ "$pattern" == *"**"* ]]; then
            local prefix="${pattern%%\*\**}"
            local suffix="${pattern##*\*\*}"
            suffix="${suffix#/}"
            if [[ "$file" == "$prefix"* && "$file" == *"$suffix" ]]; then
                return 0
            fi
        fi
    done
    return 1
}

# Check if file should be excluded
is_excluded() {
    local file="$1"

    for exclude in "${EXCLUDE_PATTERNS[@]}"; do
        case "$file" in
            $exclude) return 0 ;;
        esac
        # Also check basename
        case "$(basename "$file")" in
            $exclude) return 0 ;;
        esac
    done
    return 1
}

# Get list of changed files since last sync
get_changed_files() {
    local last_commit="$1"

    cd "$REPO_ROOT" || { log_error "Cannot access repo root: $REPO_ROOT"; return 1; }

    if [[ -z "$last_commit" ]] || [[ "${FORCE_FULL_SYNC:-}" == "true" ]]; then
        log_info "Full sync mode - scanning all matching files"
        # Full sync - find all matching files
        for pattern in "${SYNC_PATTERNS[@]}"; do
            find . -path "./$pattern" -type f 2>/dev/null | sed 's|^\./||' || true
        done | sort -u
    else
        log_info "Incremental sync - finding changes since $last_commit"
        # Get changed files (Added, Modified, Renamed)
        git diff --name-only --diff-filter=AMR "$last_commit" HEAD 2>/dev/null | sort -u
    fi
}

# Get list of deleted files since last sync
get_deleted_files() {
    local last_commit="$1"

    if [[ -z "$last_commit" ]] || [[ "${FORCE_FULL_SYNC:-}" == "true" ]]; then
        return
    fi

    cd "$REPO_ROOT" || return
    git diff --name-only --diff-filter=D "$last_commit" HEAD 2>/dev/null || true
}

# Delete a file from Open WebUI
delete_file() {
    local file_id="$1"
    local filename="$2"

    log_info "  Deleting old version: $filename (ID: ${file_id:0:8}...)"

    local response
    response=$(curl -s -X DELETE \
        -H "Authorization: Bearer $OPEN_WEBUI_API_KEY" \
        "$OPEN_WEBUI_URL/api/v1/files/$file_id" 2>&1)

    if echo "$response" | grep -q "success\|deleted" 2>/dev/null; then
        return 0
    else
        log_warn "  Delete may have failed: $response"
        return 1
    fi
}

# Upload a file to Open WebUI
upload_file() {
    local file_path="$1"
    local relative_path="${file_path#$REPO_ROOT/}"
    local filename
    filename=$(basename "$file_path")

    # Check if file with same name exists - delete it first
    if [[ -n "${KB_FILES_BY_NAME[$filename]:-}" ]]; then
        delete_file "${KB_FILES_BY_NAME[$filename]}" "$filename" || true
    fi

    log_info "  Uploading: $relative_path"

    # Upload file
    local response
    response=$(curl -s -X POST \
        -H "Authorization: Bearer $OPEN_WEBUI_API_KEY" \
        -H "Accept: application/json" \
        -F "file=@$file_path" \
        "$OPEN_WEBUI_URL/api/v1/files/" 2>&1) || {
        log_error "  Failed to upload $relative_path"
        return 1
    }

    # Extract file ID from response
    local file_id
    file_id=$(echo "$response" | jq -r '.id // empty' 2>/dev/null)

    if [[ -z "$file_id" ]]; then
        log_error "  Failed to get file ID: $response"
        return 1
    fi

    # Add file to knowledge base
    local add_response
    add_response=$(curl -s -X POST \
        -H "Authorization: Bearer $OPEN_WEBUI_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"file_id\": \"$file_id\"}" \
        "$OPEN_WEBUI_URL/api/v1/knowledge/$OPEN_WEBUI_KNOWLEDGE_ID/file/add" 2>&1) || {
        log_warn "  Failed to add to knowledge base"
        return 1
    }

    log_info "  ✓ Added to knowledge base (ID: ${file_id:0:8}...)"

    # Update tracking
    KB_FILES_BY_NAME["$filename"]="$file_id"

    return 0
}

# Main sync function
sync_to_rag() {
    log_info "Starting RAG sync to $OPEN_WEBUI_URL"
    log_info "Knowledge base ID: $OPEN_WEBUI_KNOWLEDGE_ID"
    log_info "Repository root: $REPO_ROOT"
    echo ""

    # Load existing KB state
    load_kb_files
    echo ""

    # Get last sync point
    local last_commit
    last_commit=$(get_last_sync_commit)

    local uploaded=0
    local skipped=0
    local deleted=0
    local failed=0

    # Handle deleted files first
    log_info "Checking for deleted files..."
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue

        local filename
        filename=$(basename "$file")

        if [[ -n "${KB_FILES_BY_NAME[$filename]:-}" ]]; then
            if delete_file "${KB_FILES_BY_NAME[$filename]}" "$filename"; then
                deleted=$((deleted + 1))
                unset "KB_FILES_BY_NAME[$filename]"
            fi
        fi
    done < <(get_deleted_files "$last_commit")

    echo ""
    log_info "Processing changed files..."

    # Process changed/new files
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue

        # Check if file matches our patterns
        if ! matches_sync_patterns "$file"; then
            continue
        fi

        # Check exclusions
        if is_excluded "$file"; then
            log_debug "Excluded: $file"
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

        # Upload the file
        if upload_file "$full_path"; then
            uploaded=$((uploaded + 1))
        else
            failed=$((failed + 1))
        fi

    done < <(get_changed_files "$last_commit")

    echo ""
    log_info "===== Sync Summary ====="
    log_info "  Uploaded: $uploaded"
    log_info "  Deleted:  $deleted"
    log_info "  Skipped:  $skipped"
    log_info "  Failed:   $failed"

    # Save sync marker on success
    if [[ $failed -eq 0 ]]; then
        save_sync_commit
    else
        log_warn "Sync completed with errors - marker not updated"
        exit 1
    fi
}

# Run
check_requirements
sync_to_rag
