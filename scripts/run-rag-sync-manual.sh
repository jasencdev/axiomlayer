#!/bin/bash
cd /home/jasen/axiomlayer
export KUBECONFIG=/home/jasen/.kube/config
POD=$(kubectl get pods -n open-webui -l app.kubernetes.io/name=open-webui -o jsonpath='{.items[0].metadata.name}')

API_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpZCI6IjkwMjFkMGI4LWI3NWYtNDRiYS1hOWU3LTFmZTkwMDc2Y2EyNiIsImV4cCI6MTc2Njg3NTk5NCwianRpIjoiZDRjN2VjOWUtMmRkYy00OGY0LThmYTctNTY3YzBhZTRiMWIxIn0.ylWg_yiAP4lKiv5DkYBXX4b6oOU1HBSW4fpTiVLc-p8"
KB_ID="7bb980fa-2963-4b42-a037-f1202a8a415b"

echo "Using pod: $POD"
COUNT=0
TOTAL=$(find . -type f \( -name "*.md" -o -name "*.yaml" \) ! -path "./.git/*" ! -name "*sealed-secret*" ! -name "*.env*" ! -name "*AGENTS.md*" | wc -l)
echo "Total files: $TOTAL"

find . -type f \( -name "*.md" -o -name "*.yaml" \) ! -path "./.git/*" ! -name "*sealed-secret*" ! -name "*.env*" ! -name "*AGENTS.md*" | while read file; do
    COUNT=$((COUNT + 1))
    echo "[$COUNT/$TOTAL] $file"
    kubectl cp "$file" "open-webui/$POD:/tmp/sync-file" 2>/dev/null
    kubectl exec -n open-webui $POD -- sh -c "
        RESP=\$(curl -s -X POST -H 'Authorization: Bearer $API_KEY' -F 'file=@/tmp/sync-file;filename=$file' http://localhost:8080/api/v1/files/)
        FID=\$(echo \"\$RESP\" | python3 -c 'import sys,json;print(json.load(sys.stdin).get(\"id\",\"\"))' 2>/dev/null)
        if [ -n \"\$FID\" ]; then
            curl -s -X POST -H 'Authorization: Bearer $API_KEY' -H 'Content-Type: application/json' -d \"{\\\"file_id\\\":\\\"\$FID\\\"}\" 'http://localhost:8080/api/v1/knowledge/$KB_ID/file/add' >/dev/null
            echo '  ✓'
        else
            echo '  ✗'
        fi
        rm -f /tmp/sync-file
    " 2>/dev/null
done
echo "Done!"
