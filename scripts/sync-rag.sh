#!/bin/bash
# sync-rag.sh - Sync repository files to Open WebUI RAG knowledge base
#
# Uploads key configuration files to Open WebUI's RAG system for AI-assisted
# queries about the homelab infrastructure.
#
# Required environment variables:
#   OPEN_WEBUI_URL - Base URL for Open WebUI (e.g., https://ai.lab.axiomlayer.com)
#   OPEN_WEBUI_API_KEY - API key from Open WebUI Settings > Account
#   OPEN_WEBUI_KNOWLEDGE_ID - Knowledge base ID to sync files to

set -euo pipefail

# Configuration
# Use internal cluster URL by default to bypass forward auth
# External URL can be used if API paths are excluded from auth
OPEN_WEBUI_URL="${OPEN_WEBUI_URL:-http://open-webui.open-webui.svc.cluster.local:8080}"
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

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
)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

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

    if [[ $missing -eq 1 ]]; then
        echo ""
        echo "Required environment variables:"
        echo "  OPEN_WEBUI_API_KEY      - API key from Open WebUI Settings > Account"
        echo "  OPEN_WEBUI_KNOWLEDGE_ID - Knowledge base ID (from URL when viewing knowledge base)"
        echo ""
        echo "Optional:"
        echo "  OPEN_WEBUI_URL          - Base URL (default: https://ai.lab.axiomlayer.com)"
        exit 1
    fi
}

# Upload a single file to Open WebUI
upload_file() {
    local file_path="$1"
    local relative_path="${file_path#$REPO_ROOT/}"

    log_info "Uploading: $relative_path"

    # Upload file
    local response
    response=$(curl -s -X POST \
        -H "Authorization: Bearer $OPEN_WEBUI_API_KEY" \
        -H "Accept: application/json" \
        -F "file=@$file_path" \
        "$OPEN_WEBUI_URL/api/v1/files/" 2>&1) || {
        log_error "Failed to upload $relative_path"
        return 1
    }

    # Extract file ID from response
    local file_id
    file_id=$(echo "$response" | jq -r '.id // empty' 2>/dev/null)

    if [[ -z "$file_id" ]]; then
        log_error "Failed to get file ID for $relative_path: $response"
        return 1
    fi

    # Add file to knowledge base
    local add_response
    add_response=$(curl -s -X POST \
        -H "Authorization: Bearer $OPEN_WEBUI_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"file_id\": \"$file_id\"}" \
        "$OPEN_WEBUI_URL/api/v1/knowledge/$OPEN_WEBUI_KNOWLEDGE_ID/file/add" 2>&1) || {
        log_warn "Failed to add $relative_path to knowledge base"
        return 1
    }

    log_info "  ✓ Added to knowledge base (ID: $file_id)"
    return 0
}

# Find files matching patterns
find_files() {
    local files=()

    cd "$REPO_ROOT"

    for pattern in "${SYNC_PATTERNS[@]}"; do
        while IFS= read -r -d '' file; do
            # Check exclusions
            local excluded=false
            for exclude in "${EXCLUDE_PATTERNS[@]}"; do
                if [[ "$file" == $exclude ]]; then
                    excluded=true
                    break
                fi
            done

            if [[ "$excluded" == "false" ]]; then
                files+=("$file")
            fi
        done < <(find . -path "./$pattern" -type f -print0 2>/dev/null || true)
    done

    # Deduplicate and sort
    printf '%s\n' "${files[@]}" | sort -u
}

# Main sync function
sync_to_rag() {
    log_info "Starting RAG sync to $OPEN_WEBUI_URL"
    log_info "Knowledge base ID: $OPEN_WEBUI_KNOWLEDGE_ID"
    log_info "Repository root: $REPO_ROOT"
    echo ""

    local total=0
    local success=0
    local failed=0

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue

        # Remove leading ./
        file="${file#./}"
        local full_path="$REPO_ROOT/$file"

        # Skip if file doesn't exist or is empty
        if [[ ! -f "$full_path" ]] || [[ ! -s "$full_path" ]]; then
            continue
        fi

        # Skip files larger than 500KB to avoid timeout issues
        local size
        size=$(stat -f%z "$full_path" 2>/dev/null || stat -c%s "$full_path" 2>/dev/null || echo "0")
        if [[ "$size" -gt 512000 ]]; then
            log_warn "Skipping $file (${size} bytes > 500KB limit)"
            continue
        fi

        total=$((total + 1))

        if upload_file "$full_path"; then
            success=$((success + 1))
        else
            failed=$((failed + 1))
        fi
    done < <(find_files)

    echo ""
    log_info "Sync complete: $success/$total files uploaded, $failed failed"

    if [[ $failed -gt 0 ]]; then
        exit 1
    fi
}

# Run
check_requirements
sync_to_rag
