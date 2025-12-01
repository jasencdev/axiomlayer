#!/bin/bash
# sync-rag.sh - Sync repository files to Open WebUI RAG knowledge base
#
# Usage: ./sync-rag.sh [--reset]
#
# Uses git to detect changed files and intelligently syncs only what's needed:
# - New files: Upload and add to knowledge base
# - Changed files: Delete old version, upload new, add to knowledge base
# - Unchanged files: Skip
#
# Options:
#   --reset  Clear ALL files from knowledge base before syncing (use to fix orphans)
#
# Required environment variables:
#   OPEN_WEBUI_API_KEY - API key from Open WebUI Settings > Account
#   OPEN_WEBUI_KNOWLEDGE_ID - Knowledge base ID to sync files to
#
# Optional environment variables:
#   OPEN_WEBUI_URL - Base URL (default: internal cluster URL)
#   LAST_SYNC_COMMIT - Previous sync commit SHA (default: uses marker file or HEAD~1)
#   FORCE_FULL_SYNC - Set to "true" to sync all files regardless of changes
#   CLEANUP_LEGACY_BASENAME - If "true", purge old KB entries stored by basename

set -euo pipefail

# Parse command line arguments
RESET_KB=false
for arg in "$@"; do
    case $arg in
        --reset)
            RESET_KB=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--reset]"
            echo ""
            echo "Options:"
            echo "  --reset  Clear ALL files from knowledge base before syncing"
            echo "           Use this to fix orphaned files/embeddings"
            echo ""
            echo "Environment variables:"
            echo "  OPEN_WEBUI_API_KEY      - API key (required)"
            echo "  OPEN_WEBUI_KNOWLEDGE_ID - Knowledge base ID (required)"
            echo "  OPEN_WEBUI_URL          - Base URL (optional)"
            echo "  FORCE_FULL_SYNC         - Set to 'true' to sync all files"
            exit 0
            ;;
    esac
done

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
declare -A KB_FILES_BY_PATH=()  # path-like name in KB -> file_id
declare -A KB_FILES_BY_HASH=()  # hash -> file_id
declare -a KB_ENTRIES=()        # raw entries as "id|name"

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
                # Track by the name Open WebUI stores (prefer meta.name if present)
                KB_FILES_BY_PATH["$name"]="$file_id"
                KB_FILES_BY_HASH["$hash"]="$file_id"
                KB_ENTRIES+=("$file_id|$name")
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

    log_info "  Deleting: $filename (ID: ${file_id:0:8}...)"

    local response
    response=$(curl -s -X DELETE \
        -H "Authorization: Bearer $OPEN_WEBUI_API_KEY" \
        "$OPEN_WEBUI_URL/api/v1/files/$file_id" 2>&1)

    # Check for success - the API returns the deleted file object on success
    if echo "$response" | jq -e '.id' > /dev/null 2>&1; then
        return 0
    elif echo "$response" | grep -q "success\|deleted" 2>/dev/null; then
        return 0
    else
        log_warn "  Delete may have failed: $response"
        return 1
    fi
}

# Purge ALL files from user's file storage (removes orphaned embeddings)
purge_all_files() {
    log_warn "Purging ALL files from Open WebUI file storage..."

    local response
    response=$(curl -s -H "Authorization: Bearer $OPEN_WEBUI_API_KEY" \
        "$OPEN_WEBUI_URL/api/v1/files/" 2>&1)

    # Check if we got an array of files
    if ! echo "$response" | jq -e 'type == "array"' > /dev/null 2>&1; then
        log_warn "Could not list files (may need different permissions): $response"
        return 1
    fi

    local file_ids
    file_ids=$(echo "$response" | jq -r '.[].id' 2>/dev/null)

    if [[ -z "$file_ids" ]]; then
        log_info "No files found in storage"
        return 0
    fi

    local deleted=0
    local total=0
    while IFS= read -r file_id; do
        [[ -z "$file_id" ]] && continue
        total=$((total + 1))

        local del_response
        del_response=$(curl -s -X DELETE \
            -H "Authorization: Bearer $OPEN_WEBUI_API_KEY" \
            "$OPEN_WEBUI_URL/api/v1/files/$file_id" 2>&1)

        if echo "$del_response" | jq -e '.id' > /dev/null 2>&1; then
            deleted=$((deleted + 1))
            log_info "  Deleted file: ${file_id:0:8}..."
        else
            log_warn "  Failed to delete ${file_id:0:8}...: $del_response"
        fi
    done <<< "$file_ids"

    log_info "Purged $deleted/$total files from storage"
}

# Reset knowledge base - remove all files and clear the sync marker
reset_knowledge_base() {
    log_warn "=== RESETTING KNOWLEDGE BASE ==="
    log_warn "This will delete ALL files from the knowledge base and file storage"

    # First, purge all files from storage (clears orphaned embeddings)
    purge_all_files

    # Load current KB files
    load_kb_files

    local total=${#KB_FILES_BY_PATH[@]}
    if [[ $total -eq 0 ]]; then
        log_info "Knowledge base is already empty"
    else
        log_info "Deleting $total files from knowledge base..."
        local deleted=0
        for path in "${!KB_FILES_BY_PATH[@]}"; do
            local file_id="${KB_FILES_BY_PATH[$path]}"
            if delete_file "$file_id" "$path"; then
                deleted=$((deleted + 1))
            fi
        done
        log_info "Deleted $deleted/$total files"
    fi

    # Clear the tracking arrays
    KB_FILES_BY_PATH=()
    KB_FILES_BY_HASH=()
    KB_ENTRIES=()

    # Remove sync marker to force full sync
    if [[ -f "$SYNC_MARKER_FILE" ]]; then
        rm -f "$SYNC_MARKER_FILE"
        log_info "Removed sync marker file"
    fi

    log_info "Knowledge base reset complete"
    echo ""
}

# Upload a file to Open WebUI
upload_file() {
    local file_path="$1"
    local relative_path="${file_path#$REPO_ROOT/}"
    local filename
    filename=$(basename "$file_path")

    # If a file with the same path-like name exists in KB, delete it first (update)
    if [[ -n "${KB_FILES_BY_PATH[$relative_path]:-}" ]]; then
        delete_file "${KB_FILES_BY_PATH[$relative_path]}" "$relative_path" || true
    fi

    log_info "  Uploading: $relative_path"

    # Upload file with retry logic
    local response
    local retry_count=0
    local max_retries=3

    while [[ $retry_count -lt $max_retries ]]; do
        response=$(curl -s --max-time 30 -X POST \
            -H "Authorization: Bearer $OPEN_WEBUI_API_KEY" \
            -H "Accept: application/json" \
            -F "file=@$file_path;filename=$relative_path" \
            "$OPEN_WEBUI_URL/api/v1/files/" 2>&1)

        # Check if response looks valid (contains "id" field or error)
        if echo "$response" | jq -e '.id or .detail' > /dev/null 2>&1; then
            break
        fi

        retry_count=$((retry_count + 1))
        if [[ $retry_count -lt $max_retries ]]; then
            log_warn "  Retrying upload ($retry_count/$max_retries)..."
            sleep 1
        fi
    done

    # Extract file ID from response
    local file_id
    file_id=$(echo "$response" | jq -r '.id // empty' 2>/dev/null)

    if [[ -z "$file_id" ]]; then
        log_error "  Failed to get file ID: $response"
        return 1
    fi

    # Small delay to prevent overwhelming the API
    sleep 0.2

    # Add file to knowledge base
    local add_response
    add_response=$(curl -s --max-time 60 -X POST \
        -H "Authorization: Bearer $OPEN_WEBUI_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"file_id\": \"$file_id\"}" \
        "$OPEN_WEBUI_URL/api/v1/knowledge/$OPEN_WEBUI_KNOWLEDGE_ID/file/add" 2>&1)

    # Validate the response - check for error indicators
    if echo "$add_response" | jq -e '.detail' > /dev/null 2>&1; then
        local error_detail
        error_detail=$(echo "$add_response" | jq -r '.detail')
        log_error "  Failed to add to knowledge base: $error_detail"
        # Clean up orphaned file
        log_warn "  Cleaning up orphaned file: $file_id"
        curl -s -X DELETE \
            -H "Authorization: Bearer $OPEN_WEBUI_API_KEY" \
            "$OPEN_WEBUI_URL/api/v1/files/$file_id" > /dev/null 2>&1
        return 1
    fi

    # Verify the file appears in the response
    if ! echo "$add_response" | jq -e '.files' > /dev/null 2>&1; then
        log_error "  Unexpected response from knowledge base: $add_response"
        # Clean up orphaned file
        log_warn "  Cleaning up orphaned file: $file_id"
        curl -s -X DELETE \
            -H "Authorization: Bearer $OPEN_WEBUI_API_KEY" \
            "$OPEN_WEBUI_URL/api/v1/files/$file_id" > /dev/null 2>&1
        return 1
    fi

    log_info "  ✓ Added to knowledge base (ID: ${file_id:0:8}...)"

    # Update tracking
    KB_FILES_BY_PATH["$relative_path"]="$file_id"

    return 0
}

# Get all files matching sync patterns
get_all_matching_files() {
    cd "$REPO_ROOT" || { log_error "Cannot access repo root: $REPO_ROOT"; return 1; }

    for pattern in "${SYNC_PATTERNS[@]}"; do
        find . -path "./$pattern" -type f 2>/dev/null | sed 's|^\./||' || true
    done | sort -u
}

# Cleanup legacy KB entries that used only basenames (pre-path fix)
# Logic: For KB entries whose name contains no '/', delete them if they do not correspond
# to an actual top-level file in the repo but there are matching files with that basename
# in nested paths. This preserves legitimate top-level files (e.g., README.md).
cleanup_legacy_basename_entries() {
    [[ "${CLEANUP_LEGACY_BASENAME:-false}" == "true" ]] || return 0

    log_info "Cleanup: scanning for legacy basename-only KB entries..."

    declare -A REPO_TOPLEVEL_SET=()
    declare -A REPO_BASENAME_COUNT=()

    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        local base
        base=$(basename "$f")
        REPO_BASENAME_COUNT["$base"]=$(( ${REPO_BASENAME_COUNT["$base"]:-0} + 1 ))
        # Top-level file has no '/'
        if [[ "$f" != */* ]]; then
            REPO_TOPLEVEL_SET["$f"]=1
        fi
    done < <(get_all_matching_files)

    local purged=0 kept=0 checked=0
    for entry in "${KB_ENTRIES[@]}"; do
        local id name
        id=${entry%%|*}
        name=${entry#*|}
        checked=$((checked + 1))

        # Only consider names without path separators
        if [[ "$name" == */* ]]; then
            kept=$((kept + 1))
            continue
        fi

        # Preserve if an actual top-level file exists with this name
        if [[ -n "${REPO_TOPLEVEL_SET["$name"]:-}" ]]; then
            kept=$((kept + 1))
            continue
        fi

        # If the basename exists in repo but only in nested paths -> purge legacy entry
        if [[ ${REPO_BASENAME_COUNT["$name"]:-0} -gt 0 ]]; then
            log_info "  Purging legacy basename entry: $name (ID: ${id:0:8}...)"
            delete_file "$id" "$name" || true
            unset "KB_FILES_BY_PATH[$name]"
            purged=$((purged + 1))
        else
            kept=$((kept + 1))
        fi
    done

    log_info "Cleanup summary: checked=$checked, purged=$purged, kept=$kept"
}

# Check if file changed since last sync
file_changed_since() {
    local file="$1"
    local last_commit="$2"

    # If no last commit, consider everything changed
    [[ -z "$last_commit" ]] && return 0

    # Check if file was modified since last commit
    git diff --name-only "$last_commit" HEAD -- "$file" 2>/dev/null | grep -q .
}

# Main sync function
sync_to_rag() {
    log_info "Starting RAG sync to $OPEN_WEBUI_URL"
    log_info "Knowledge base ID: $OPEN_WEBUI_KNOWLEDGE_ID"
    log_info "Repository root: $REPO_ROOT"
    echo ""

    # Handle --reset flag
    if [[ "$RESET_KB" == "true" ]]; then
        reset_knowledge_base
        # Force full sync after reset
        FORCE_FULL_SYNC="true"
    fi

    # Load existing KB state
    load_kb_files
    local kb_file_count=${#KB_FILES_BY_PATH[@]}
    echo ""

    # Optional: purge legacy basename-only entries
    cleanup_legacy_basename_entries

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

    # Handle deleted files first (only if we have a last commit)
    if [[ -n "$last_commit" ]]; then
        log_info "Checking for deleted files..."
        while IFS= read -r file; do
            [[ -z "$file" ]] && continue

            # Look up by full relative path (how files are stored in KB)
            if [[ -n "${KB_FILES_BY_PATH[$file]:-}" ]]; then
                if delete_file "${KB_FILES_BY_PATH[$file]}" "$file"; then
                    deleted=$((deleted + 1))
                    unset "KB_FILES_BY_PATH[$file]"
                fi
            fi
        done < <(get_deleted_files "$last_commit")
    fi

    echo ""
    log_info "Processing files..."

    cd "$REPO_ROOT" || { log_error "Cannot access repo root"; exit 1; }

    # Process ALL matching files
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue

        # Check exclusions
        if is_excluded "$file"; then
            continue
        fi

        local full_path="$REPO_ROOT/$file"
        local filename
        filename=$(basename "$file")

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

        # Decision logic:
        # 1. If file NOT in KB -> upload it
        # 2. If file IS in KB -> only upload if changed since last sync (or force sync)
        local file_in_kb=false
        if [[ -n "${KB_FILES_BY_PATH[$file]:-}" ]]; then
            file_in_kb=true
        fi

        if [[ "$file_in_kb" == "false" ]]; then
            # File not in KB - upload it
            log_info "New file: $file"
            if upload_file "$full_path"; then
                uploaded=$((uploaded + 1))
            else
                failed=$((failed + 1))
            fi
        elif [[ "${FORCE_FULL_SYNC:-}" == "true" ]]; then
            # Force sync - upload regardless
            log_info "Force sync: $file"
            if upload_file "$full_path"; then
                uploaded=$((uploaded + 1))
            else
                failed=$((failed + 1))
            fi
        elif file_changed_since "$file" "$last_commit"; then
            # File in KB but changed - update it
            log_info "Changed: $file"
            if upload_file "$full_path"; then
                uploaded=$((uploaded + 1))
            else
                failed=$((failed + 1))
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
