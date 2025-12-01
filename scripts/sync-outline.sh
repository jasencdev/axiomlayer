#!/bin/bash
# sync-outline.sh - Sync markdown docs to Outline wiki
#
# Uses git to detect changed files and syncs only what's needed to Outline.
# Maintains state in outline_sync/state.json to track document IDs.
#
# Required environment variables:
#   OUTLINE_API_TOKEN - API token from Outline Settings
#
# Optional environment variables:
#   OUTLINE_API_URL - Base API URL (default: https://docs.lab.axiomlayer.com/api)
#   LAST_SYNC_COMMIT - Previous sync commit SHA
#   FORCE_FULL_SYNC - Set to "true" to sync all files

set -euo pipefail

# Configuration
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
CONFIG_FILE="$REPO_ROOT/outline_sync/config.json"
STATE_FILE="$REPO_ROOT/outline_sync/state.json"
SYNC_MARKER_FILE="$REPO_ROOT/.outline-sync-commit"
OUTLINE_API_URL="${OUTLINE_API_URL:-https://docs.lab.axiomlayer.com/api}"

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

# Check required tools and environment
check_requirements() {
    local missing=0

    # Accept either OUTLINE_API_TOKEN (CI) or OUTLINE_API_KEY (local .env)
    OUTLINE_API_TOKEN="${OUTLINE_API_TOKEN:-${OUTLINE_API_KEY:-}}"

    if [[ -z "${OUTLINE_API_TOKEN:-}" ]]; then
        log_error "OUTLINE_API_TOKEN (or OUTLINE_API_KEY) is not set"
        missing=1
    fi

    if ! command -v jq &> /dev/null; then
        log_error "jq is required but not installed"
        missing=1
    fi

    if ! command -v curl &> /dev/null; then
        log_error "curl is required but not installed"
        missing=1
    fi

    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Config file not found: $CONFIG_FILE"
        missing=1
    fi

    if [[ $missing -eq 1 ]]; then
        echo ""
        echo "Required environment variables:"
        echo "  OUTLINE_API_TOKEN - API token from Outline Settings"
        echo ""
        echo "Optional:"
        echo "  OUTLINE_API_URL   - Base API URL (default: https://docs.lab.axiomlayer.com/api)"
        echo "  FORCE_FULL_SYNC   - Set to 'true' to sync all files"
        exit 1
    fi
}

# Make an API request to Outline
outline_api() {
    local endpoint="$1"
    local payload="$2"

    local response
    response=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $OUTLINE_API_TOKEN" \
        -d "$payload" \
        "${OUTLINE_API_URL}/${endpoint}" 2>&1)

    # Check for errors
    if echo "$response" | jq -e '.error' > /dev/null 2>&1; then
        local error
        error=$(echo "$response" | jq -r '.error // .message // "Unknown error"')
        log_error "API error ($endpoint): $error"
        return 1
    fi

    echo "$response"
}

# Get or create collection ID
get_collection_id() {
    # Check state file first
    if [[ -f "$STATE_FILE" ]]; then
        local collection_id
        collection_id=$(jq -r '.collectionId // empty' "$STATE_FILE" 2>/dev/null)
        if [[ -n "$collection_id" ]]; then
            echo "$collection_id"
            return 0
        fi
    fi

    # Create new collection
    local collection_name
    collection_name=$(jq -r '.collectionName' "$CONFIG_FILE")
    log_info "Creating Outline collection '$collection_name'..."

    local response
    response=$(outline_api "collections.create" "{\"name\": \"$collection_name\"}")

    local collection_id
    collection_id=$(echo "$response" | jq -r '.data.id // empty')

    if [[ -z "$collection_id" ]]; then
        log_error "Failed to create collection"
        return 1
    fi

    # Save to state
    if [[ -f "$STATE_FILE" ]]; then
        local tmp
        tmp=$(mktemp)
        jq --arg id "$collection_id" '.collectionId = $id' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
    else
        echo "{\"collectionId\": \"$collection_id\", \"documents\": {}}" > "$STATE_FILE"
    fi

    echo "$collection_id"
}

# Get document ID from state
get_document_id() {
    local path="$1"

    if [[ -f "$STATE_FILE" ]]; then
        jq -r --arg path "$path" '.documents[$path].id // empty' "$STATE_FILE" 2>/dev/null
    fi
}

# Save document ID to state
save_document_id() {
    local path="$1"
    local doc_id="$2"

    if [[ ! -f "$STATE_FILE" ]]; then
        echo '{"documents": {}}' > "$STATE_FILE"
    fi

    local tmp
    tmp=$(mktemp)
    jq --arg path "$path" --arg id "$doc_id" '.documents[$path] = {"id": $id}' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# Convert file path to title
path_to_title() {
    local path="$1"
    local name
    name=$(basename "$path" .md)

    # Replace dashes and underscores with spaces, then title case
    echo "$name" | sed 's/[-_]/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1'
}

# Get title for a document from config or generate from path
get_doc_title() {
    local path="$1"

    # Check config for explicit title
    local title
    title=$(jq -r --arg path "$path" '.documents[] | select(.path == $path) | .title // empty' "$CONFIG_FILE" 2>/dev/null)

    if [[ -n "$title" ]]; then
        echo "$title"
    else
        path_to_title "$path"
    fi
}

# Escape content for JSON
escape_json() {
    python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || \
    jq -Rs '.' 2>/dev/null
}

# Sync a single document
sync_document() {
    local path="$1"
    local collection_id="$2"

    local full_path="$REPO_ROOT/$path"

    if [[ ! -f "$full_path" ]]; then
        log_warn "Skipping '$path' (file not found)"
        return 0
    fi

    local title
    title=$(get_doc_title "$path")

    local content
    content=$(cat "$full_path")

    local doc_id
    doc_id=$(get_document_id "$path")

    # Escape content for JSON
    local escaped_content
    escaped_content=$(echo "$content" | escape_json)

    if [[ -n "$doc_id" ]]; then
        # Update existing document
        log_info "Updating '$title'..."

        local payload
        payload=$(jq -n \
            --arg id "$doc_id" \
            --arg title "$title" \
            --argjson text "$escaped_content" \
            '{id: $id, title: $title, text: $text, publish: true}')

        local response
        response=$(outline_api "documents.update" "$payload")

        if echo "$response" | jq -e '.data.id' > /dev/null 2>&1; then
            log_info "  ✓ Updated"
            return 0
        else
            log_error "  Failed to update"
            return 1
        fi
    else
        # Create new document
        log_info "Creating '$title'..."

        local payload
        payload=$(jq -n \
            --arg collection_id "$collection_id" \
            --arg title "$title" \
            --argjson text "$escaped_content" \
            '{collectionId: $collection_id, title: $title, text: $text, publish: true}')

        local response
        response=$(outline_api "documents.create" "$payload")

        local new_id
        new_id=$(echo "$response" | jq -r '.data.id // empty')

        if [[ -n "$new_id" ]]; then
            save_document_id "$path" "$new_id"
            log_info "  ✓ Created (ID: ${new_id:0:8}...)"
            return 0
        else
            log_error "  Failed to create"
            return 1
        fi
    fi
}

# Get list of docs to sync from config
get_configured_docs() {
    jq -r '.documents[].path' "$CONFIG_FILE" 2>/dev/null
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

# Get changed files since last sync
get_changed_docs() {
    local last_commit="$1"

    cd "$REPO_ROOT" || return

    # Get all configured docs
    local configured_docs
    configured_docs=$(get_configured_docs)

    if [[ -z "$last_commit" ]] || [[ "${FORCE_FULL_SYNC:-}" == "true" ]]; then
        log_info "Full sync mode - syncing all configured documents" >&2
        echo "$configured_docs"
    else
        log_info "Incremental sync - finding changes since ${last_commit:0:8}..." >&2

        # Get changed files
        local changed_files
        changed_files=$(git diff --name-only "$last_commit" HEAD 2>/dev/null || echo "")

        # Filter to only configured docs that changed
        for doc in $configured_docs; do
            if echo "$changed_files" | grep -q "^$doc$"; then
                echo "$doc"
            fi
        done
    fi
}

# Main sync function
sync_to_outline() {
    log_info "Starting Outline sync"
    log_info "API URL: $OUTLINE_API_URL"
    log_info "Repository root: $REPO_ROOT"
    echo ""

    # Get collection ID
    local collection_id
    collection_id=$(get_collection_id)
    log_info "Collection ID: $collection_id"
    echo ""

    # Get last sync commit
    local last_commit
    last_commit=$(get_last_sync_commit)

    local synced=0
    local skipped=0
    local failed=0

    # Process documents
    while IFS= read -r doc; do
        [[ -z "$doc" ]] && continue

        if sync_document "$doc" "$collection_id"; then
            synced=$((synced + 1))
        else
            failed=$((failed + 1))
        fi
    done < <(get_changed_docs "$last_commit")

    echo ""
    log_info "===== Sync Summary ====="
    log_info "  Synced: $synced"
    log_info "  Failed: $failed"

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
sync_to_outline
