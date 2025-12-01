#!/bin/bash
# run-rag-sync-manual.sh - Complete RAG cleanup and re-sync
#
# This script:
# 1. Deletes ALL orphaned files (files not in the knowledge base)
# 2. Deletes ALL files from the knowledge base
# 3. Re-syncs all matching files to the knowledge base
#
# Usage: ./scripts/run-rag-sync-manual.sh

set -euo pipefail

cd /home/jasen/axiomlayer
export KUBECONFIG=/home/jasen/.kube/config

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Load from .env file
if [ -f .env ]; then
    source <(grep -E '^(OPEN_WEBUI_API_KEY|OPEN_WEBUI_KNOWLEDGE_ID)=' .env)
fi

API_KEY="${OPEN_WEBUI_API_KEY:?Error: OPEN_WEBUI_API_KEY not set}"
KB_ID="${OPEN_WEBUI_KNOWLEDGE_ID:?Error: OPEN_WEBUI_KNOWLEDGE_ID not set}"

# Get pod for in-cluster API calls
POD=$(kubectl get pods -n open-webui -l app.kubernetes.io/name=open-webui -o jsonpath='{.items[0].metadata.name}')
log_info "Using pod: $POD"

# Helper to call Open WebUI API from within the cluster
# Uses bash -c to properly handle JWT tokens with special characters
api_call() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"

    if [[ -n "$data" ]]; then
        echo "curl -s -X '$method' -H 'Authorization: Bearer $API_KEY' -H 'Content-Type: application/json' -d '$data' 'http://localhost:8080$endpoint'" | \
            kubectl exec -i -n open-webui "$POD" -- bash
    else
        echo "curl -s -X '$method' -H 'Authorization: Bearer $API_KEY' 'http://localhost:8080$endpoint'" | \
            kubectl exec -i -n open-webui "$POD" -- bash
    fi
}

echo ""
log_warn "========================================="
log_warn "  COMPLETE RAG CLEANUP AND RE-SYNC"
log_warn "========================================="
echo ""

# ============================================
# PHASE 1: Delete orphaned files (not in any KB)
# ============================================
log_info "PHASE 1: Finding and deleting orphaned files..."

# Get all files in user's file storage
ALL_FILES=$(api_call GET "/api/v1/files/")

if ! echo "$ALL_FILES" | jq -e 'type == "array"' > /dev/null 2>&1; then
    log_error "Could not list files: $ALL_FILES"
    exit 1
fi

TOTAL_FILES=$(echo "$ALL_FILES" | jq 'length')
log_info "  Total files in storage: $TOTAL_FILES"

# Get files that are in the knowledge base
KB_DATA=$(api_call GET "/api/v1/knowledge/$KB_ID")
KB_FILE_IDS=$(echo "$KB_DATA" | jq -r '.files[].id // empty' 2>/dev/null | sort -u)

# Find orphaned files (in storage but not in KB)
ORPHANED_COUNT=0
ORPHANED_DELETED=0

while IFS= read -r file_entry; do
    [[ -z "$file_entry" ]] && continue

    FILE_ID=$(echo "$file_entry" | jq -r '.id')
    FILE_NAME=$(echo "$file_entry" | jq -r '.meta.name // .filename // "unknown"')

    # Check if this file is in the KB
    if ! echo "$KB_FILE_IDS" | grep -q "^${FILE_ID}$"; then
        ORPHANED_COUNT=$((ORPHANED_COUNT + 1))
        log_warn "  Orphaned: $FILE_NAME (${FILE_ID:0:8}...)"

        # Delete the orphaned file
        DEL_RESP=$(api_call DELETE "/api/v1/files/$FILE_ID")
        if echo "$DEL_RESP" | jq -e '.id' > /dev/null 2>&1; then
            ORPHANED_DELETED=$((ORPHANED_DELETED + 1))
            log_info "    ✓ Deleted"
        else
            log_error "    ✗ Failed to delete: $DEL_RESP"
        fi
    fi
done < <(echo "$ALL_FILES" | jq -c '.[]')

log_info "  Orphaned files found: $ORPHANED_COUNT"
log_info "  Orphaned files deleted: $ORPHANED_DELETED"
echo ""

# ============================================
# PHASE 2: Clear the knowledge base
# ============================================
log_info "PHASE 2: Clearing knowledge base..."

# Re-fetch KB data after orphan cleanup
KB_DATA=$(api_call GET "/api/v1/knowledge/$KB_ID")
KB_FILES=$(echo "$KB_DATA" | jq -c '.files[]' 2>/dev/null || echo "")

KB_COUNT=0
KB_DELETED=0

while IFS= read -r file_entry; do
    [[ -z "$file_entry" ]] && continue

    FILE_ID=$(echo "$file_entry" | jq -r '.id')
    FILE_NAME=$(echo "$file_entry" | jq -r '.meta.name // .filename // "unknown"')
    KB_COUNT=$((KB_COUNT + 1))

    log_info "  Deleting from KB: $FILE_NAME"
    DEL_RESP=$(api_call DELETE "/api/v1/files/$FILE_ID")
    if echo "$DEL_RESP" | jq -e '.id' > /dev/null 2>&1; then
        KB_DELETED=$((KB_DELETED + 1))
    else
        log_warn "    Failed: $DEL_RESP"
    fi
done < <(echo "$KB_FILES")

log_info "  KB files found: $KB_COUNT"
log_info "  KB files deleted: $KB_DELETED"
echo ""

# ============================================
# PHASE 3: Re-sync all files
# ============================================
log_info "PHASE 3: Re-syncing files to knowledge base..."

# Find all matching files
FILES=$(find . -type f \( -name "*.md" -o -name "*.yaml" \) \
    ! -path "./.git/*" \
    ! -name "*sealed-secret*" \
    ! -name "*.env*" \
    ! -name "*AGENTS.md*" \
    | sort)

TOTAL=$(echo "$FILES" | wc -l)
COUNT=0
UPLOADED=0
FAILED=0

while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    COUNT=$((COUNT + 1))

    # Skip files larger than 500KB
    SIZE=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo "0")
    if [[ "$SIZE" -gt 512000 ]]; then
        log_warn "[$COUNT/$TOTAL] Skipping (too large): $file"
        continue
    fi

    echo -n "[$COUNT/$TOTAL] $file "

    # Copy file to pod
    kubectl cp "$file" "open-webui/$POD:/tmp/sync-file" 2>/dev/null

    # Upload and add to KB (pipe through bash for proper JWT handling)
    RESULT=$(cat <<UPLOAD_SCRIPT | kubectl exec -i -n open-webui "$POD" -- bash
RESP=\$(curl -s -X POST -H 'Authorization: Bearer $API_KEY' -F 'file=@/tmp/sync-file;filename=$file' http://localhost:8080/api/v1/files/)
FID=\$(echo "\$RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null)
if [ -n "\$FID" ] && [ "\$FID" != "None" ]; then
    ADD_RESP=\$(curl -s -X POST -H 'Authorization: Bearer $API_KEY' -H 'Content-Type: application/json' -d "{\"file_id\":\"\$FID\"}" 'http://localhost:8080/api/v1/knowledge/$KB_ID/file/add')
    if echo "\$ADD_RESP" | python3 -c 'import sys,json;d=json.load(sys.stdin);exit(0 if "files" in d else 1)' 2>/dev/null; then
        echo 'OK'
    else
        # Failed to add to KB - delete the orphaned file
        curl -s -X DELETE -H 'Authorization: Bearer $API_KEY' "http://localhost:8080/api/v1/files/\$FID" >/dev/null 2>&1
        echo 'FAIL_KB'
    fi
else
    echo 'FAIL_UPLOAD'
fi
rm -f /tmp/sync-file
UPLOAD_SCRIPT
)

    case "$RESULT" in
        OK*)
            echo -e "${GREEN}✓${NC}"
            UPLOADED=$((UPLOADED + 1))
            ;;
        FAIL_KB*)
            echo -e "${RED}✗ (KB add failed, cleaned up)${NC}"
            FAILED=$((FAILED + 1))
            ;;
        *)
            echo -e "${RED}✗ (upload failed)${NC}"
            FAILED=$((FAILED + 1))
            ;;
    esac
done <<< "$FILES"

echo ""
log_info "========================================="
log_info "  SYNC COMPLETE"
log_info "========================================="
log_info "  Orphaned files cleaned: $ORPHANED_DELETED"
log_info "  KB files cleared: $KB_DELETED"
log_info "  Files uploaded: $UPLOADED"
log_info "  Files failed: $FAILED"
log_info "========================================="

# Update sync marker
git rev-parse HEAD > .rag-sync-commit
log_info "Updated sync marker to $(cat .rag-sync-commit)"
