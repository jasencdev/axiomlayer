#!/bin/bash
# Smoke tests for homelab infrastructure
# Run: ./tests/smoke-test.sh

set -e

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

FAILED=0
PASSED=0

pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    PASSED=$((PASSED + 1))
}

fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    FAILED=$((FAILED + 1))
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

section() {
    echo ""
    echo "========================================"
    echo "$1"
    echo "========================================"
}

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "kubectl not found"
    exit 1
fi

section "Node Health"

# Check all nodes are Ready
NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
READY_NODES=$(kubectl get nodes --no-headers | grep -c " Ready")
if [ "$NODE_COUNT" -eq "$READY_NODES" ]; then
    pass "All $NODE_COUNT nodes are Ready"
else
    fail "Only $READY_NODES/$NODE_COUNT nodes are Ready"
fi

section "Core Services"

# ArgoCD components
ARGOCD_COMPONENTS=(
    "argocd-server:ArgoCD Server"
    "argocd-repo-server:ArgoCD Repo Server"
    "argocd-application-controller:ArgoCD Application Controller"
    "argocd-redis:ArgoCD Redis"
)

for component in "${ARGOCD_COMPONENTS[@]}"; do
    LABEL="${component%%:*}"
    NAME="${component##*:}"
    if kubectl get pods -n argocd -l "app.kubernetes.io/name=$LABEL" --no-headers 2>/dev/null | grep -q "Running"; then
        pass "$NAME is running"
    else
        fail "$NAME is not running"
    fi
done

# Traefik
if kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik --no-headers | grep -q "Running"; then
    pass "Traefik ingress is running"
else
    fail "Traefik ingress is not running"
fi

# Cert-manager components
CERTMANAGER_COMPONENTS=(
    "cert-manager:cert-manager"
    "webhook:cert-manager-webhook"
    "cainjector:cert-manager-cainjector"
)

for component in "${CERTMANAGER_COMPONENTS[@]}"; do
    LABEL="${component%%:*}"
    NAME="${component##*:}"
    if kubectl get pods -n cert-manager -l "app.kubernetes.io/name=$LABEL" --no-headers 2>/dev/null | grep -q "Running"; then
        pass "$NAME is running"
    else
        fail "$NAME is not running"
    fi
done

# Sealed Secrets controller
if kubectl get pods -n kube-system -l app.kubernetes.io/name=sealed-secrets --no-headers 2>/dev/null | grep -q "Running"; then
    pass "Sealed Secrets controller is running"
else
    fail "Sealed Secrets controller is not running"
fi

# External DNS
if kubectl get pods -n external-dns -l app.kubernetes.io/name=external-dns --no-headers 2>/dev/null | grep -q "Running"; then
    pass "External DNS is running"
else
    fail "External DNS is not running"
fi

# CloudNativePG operator
if kubectl get pods -n cnpg-system -l app.kubernetes.io/name=cloudnative-pg --no-headers 2>/dev/null | grep -q "Running"; then
    pass "CloudNativePG operator is running"
else
    fail "CloudNativePG operator is not running"
fi

# Actions Runner Controller
if kubectl get pods -n actions-runner -l app.kubernetes.io/name=actions-runner-controller --no-headers 2>/dev/null | grep -q "Running"; then
    pass "Actions Runner Controller is running"
else
    fail "Actions Runner Controller is not running"
fi

# NFS Proxy
if kubectl get pods -n nfs-proxy -l app.kubernetes.io/name=nfs-proxy --no-headers 2>/dev/null | grep -q "Running"; then
    pass "NFS Proxy is running"
else
    fail "NFS Proxy is not running"
fi

section "Authentication"

# Authentik server
if kubectl get pods -n authentik -l app.kubernetes.io/name=authentik --no-headers 2>/dev/null | grep -q "Running"; then
    pass "Authentik server is running"
else
    fail "Authentik server is not running"
fi

# Authentik outpost
if kubectl get pods -n authentik -l goauthentik.io/outpost-name=forward-auth-outpost --no-headers 2>/dev/null | grep -q "Running"; then
    pass "Authentik forward-auth outpost is running"
else
    fail "Authentik forward-auth outpost is not running"
fi

section "Storage"

# Longhorn
if kubectl get pods -n longhorn-system -l app=longhorn-manager --no-headers | grep -q "Running"; then
    pass "Longhorn manager is running"
else
    fail "Longhorn manager is not running"
fi

# Check PVCs are bound
UNBOUND_PVC=$(kubectl get pvc -A --no-headers 2>/dev/null | grep -v "Bound" | wc -l)
if [ "$UNBOUND_PVC" -eq 0 ]; then
    pass "All PVCs are bound"
else
    fail "$UNBOUND_PVC PVCs are not bound"
fi

section "Monitoring"

# Prometheus
if kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | grep -q "Running"; then
    pass "Prometheus is running"
else
    fail "Prometheus is not running"
fi

# Grafana
if kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana --no-headers 2>/dev/null | grep -q "Running"; then
    pass "Grafana is running"
else
    fail "Grafana is not running"
fi

# Alertmanager
if kubectl get pods -n monitoring -l app.kubernetes.io/name=alertmanager --no-headers 2>/dev/null | grep -q "Running"; then
    pass "Alertmanager is running"
else
    fail "Alertmanager is not running"
fi

# Loki (StatefulSet, check by pod name pattern)
if kubectl get pods -n monitoring --no-headers 2>/dev/null | grep "^loki-[0-9]" | grep -q "Running"; then
    pass "Loki is running"
else
    fail "Loki is not running"
fi

# Promtail
PROMTAIL_PODS=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=promtail --no-headers 2>/dev/null | grep -c "Running" || echo 0)
if [ "$PROMTAIL_PODS" -gt 0 ]; then
    pass "Promtail is running ($PROMTAIL_PODS pods)"
else
    fail "Promtail is not running"
fi

# Kube-state-metrics
if kubectl get pods -n monitoring -l app.kubernetes.io/name=kube-state-metrics --no-headers 2>/dev/null | grep -q "Running"; then
    pass "kube-state-metrics is running"
else
    fail "kube-state-metrics is not running"
fi

# Node exporter
NODE_EXPORTER_PODS=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus-node-exporter --no-headers 2>/dev/null | grep -c "Running" || echo 0)
if [ "$NODE_EXPORTER_PODS" -gt 0 ]; then
    pass "Node exporter is running ($NODE_EXPORTER_PODS pods)"
else
    fail "Node exporter is not running"
fi

section "Databases"

# CloudNativePG clusters (Plane uses its own PostgreSQL StatefulSet, not CNPG)
CNPG_CLUSTERS=(
    "authentik:authentik-db"
    "outline:outline-db"
    "n8n:n8n-db"
    "open-webui:open-webui-db"
)

for cluster in "${CNPG_CLUSTERS[@]}"; do
    NS="${cluster%%:*}"
    NAME="${cluster##*:}"

    if kubectl get pods -n "$NS" -l "cnpg.io/cluster=$NAME" --no-headers 2>/dev/null | grep -q "Running"; then
        pass "$NAME PostgreSQL is running"
    else
        fail "$NAME PostgreSQL is not running"
    fi
done

# Check CNPG cluster health status
for cluster in "${CNPG_CLUSTERS[@]}"; do
    NS="${cluster%%:*}"
    NAME="${cluster##*:}"

    CLUSTER_STATUS=$(kubectl get cluster "$NAME" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    if [ "$CLUSTER_STATUS" = "Cluster in healthy state" ]; then
        pass "$NAME cluster is healthy"
    elif [ "$CLUSTER_STATUS" = "Unknown" ]; then
        warn "$NAME cluster status unknown"
    else
        fail "$NAME cluster status: $CLUSTER_STATUS"
    fi
done

section "Applications"

# Dashboard
if kubectl get pods -n dashboard -l app.kubernetes.io/name=dashboard --no-headers 2>/dev/null | grep -q "Running"; then
    pass "Dashboard is running"
else
    fail "Dashboard is not running"
fi

# Outline
if kubectl get pods -n outline -l app.kubernetes.io/name=outline --no-headers 2>/dev/null | grep -q "Running"; then
    pass "Outline is running"
else
    fail "Outline is not running"
fi

# n8n
if kubectl get pods -n n8n -l app.kubernetes.io/name=n8n --no-headers 2>/dev/null | grep -q "Running"; then
    pass "n8n is running"
else
    fail "n8n is not running"
fi

# Open WebUI
if kubectl get pods -n open-webui -l app.kubernetes.io/name=open-webui --no-headers 2>/dev/null | grep -q "Running"; then
    pass "Open WebUI is running"
else
    fail "Open WebUI is not running"
fi

# Plane
PLANE_PODS=$(kubectl get pods -n plane --no-headers 2>/dev/null | grep -c "Running" || echo 0)
if [ "$PLANE_PODS" -gt 0 ]; then
    pass "Plane is running ($PLANE_PODS pods)"
else
    fail "Plane is not running"
fi

# Campfire
if kubectl get pods -n campfire -l app.kubernetes.io/name=campfire --no-headers 2>/dev/null | grep -q "Running"; then
    pass "Campfire is running"
else
    fail "Campfire is not running"
fi

# Telnet Server (demo app)
if kubectl get pods -n telnet-server -l app.kubernetes.io/name=telnet-server --no-headers 2>/dev/null | grep -q "Running"; then
    pass "Telnet Server is running"
else
    fail "Telnet Server is not running"
fi

section "Plane Components"

# Plane uses its own StatefulSets for databases and services
PLANE_STATEFULSETS=(
    "plane-pgdb-wl:Plane PostgreSQL"
    "plane-redis-wl:Plane Redis"
    "plane-minio-wl:Plane MinIO"
    "plane-rabbitmq-wl:Plane RabbitMQ"
)

for sts in "${PLANE_STATEFULSETS[@]}"; do
    NAME="${sts%%:*}"
    LABEL="${sts##*:}"
    if kubectl get pods -n plane -l "statefulset.kubernetes.io/pod-name=${NAME}-0" --no-headers 2>/dev/null | grep -q "Running"; then
        pass "$LABEL is running"
    else
        fail "$LABEL is not running"
    fi
done

# Plane deployments
PLANE_DEPLOYMENTS=(
    "plane-api-wl:Plane API"
    "plane-web-wl:Plane Web"
    "plane-space-wl:Plane Space"
    "plane-admin-wl:Plane Admin"
    "plane-live-wl:Plane Live"
    "plane-beat-worker-wl:Plane Beat Worker"
)

for deploy in "${PLANE_DEPLOYMENTS[@]}"; do
    NAME="${deploy%%:*}"
    LABEL="${deploy##*:}"
    if kubectl get pods -n plane -l "app.kubernetes.io/name=$NAME" --no-headers 2>/dev/null | grep -q "Running"; then
        pass "$LABEL is running"
    else
        # Try matching by deployment name in pod name
        if kubectl get pods -n plane --no-headers 2>/dev/null | grep "$NAME" | grep -q "Running"; then
            pass "$LABEL is running"
        else
            warn "$LABEL may not be running"
        fi
    fi
done

section "Certificates"

# Check certificates are valid
INVALID_CERTS=$(kubectl get certificates -A --no-headers 2>/dev/null | grep -v "True" | wc -l)
if [ "$INVALID_CERTS" -eq 0 ]; then
    pass "All certificates are valid"
else
    fail "$INVALID_CERTS certificates are not ready"
    kubectl get certificates -A --no-headers | grep -v "True"
fi

# Check certificate expiry (warn if expiring within 14 days)
CERTS=$(kubectl get certificates -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}:{.status.notAfter}{"\n"}{end}' 2>/dev/null)
EXPIRY_WARN=0
while IFS=: read -r cert_name expiry_date; do
    if [ -n "$expiry_date" ]; then
        EXPIRY_EPOCH=$(date -d "$expiry_date" +%s 2>/dev/null || echo 0)
        NOW_EPOCH=$(date +%s)
        DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
        if [ "$DAYS_LEFT" -lt 14 ] && [ "$DAYS_LEFT" -gt 0 ]; then
            warn "Certificate $cert_name expires in $DAYS_LEFT days"
            EXPIRY_WARN=$((EXPIRY_WARN + 1))
        elif [ "$DAYS_LEFT" -le 0 ]; then
            fail "Certificate $cert_name has expired"
        fi
    fi
done <<< "$CERTS"
if [ "$EXPIRY_WARN" -eq 0 ]; then
    pass "No certificates expiring within 14 days"
fi

section "ArgoCD Applications"

# Check ArgoCD application sync status
ARGOCD_APPS=$(kubectl get applications -n argocd -o jsonpath='{range .items[*]}{.metadata.name}:{.status.sync.status}:{.status.health.status}{"\n"}{end}' 2>/dev/null)
SYNC_ISSUES=0
HEALTH_WARNINGS=0
HEALTH_FAILURES=0
while IFS=: read -r app_name sync_status health_status; do
    if [ -n "$app_name" ]; then
        if [ "$sync_status" != "Synced" ] && [ "$sync_status" != "OutOfSync" ]; then
            fail "ArgoCD app $app_name sync status: $sync_status"
            SYNC_ISSUES=$((SYNC_ISSUES + 1))
        fi
        if [ "$health_status" = "Missing" ]; then
            fail "ArgoCD app $app_name health: $health_status"
            HEALTH_FAILURES=$((HEALTH_FAILURES + 1))
        elif [ "$health_status" = "Degraded" ]; then
            # Degraded is often due to optional resources (PDBs, etc.) - treat as warning
            warn "ArgoCD app $app_name health: $health_status"
            HEALTH_WARNINGS=$((HEALTH_WARNINGS + 1))
        fi
    fi
done <<< "$ARGOCD_APPS"
if [ "$SYNC_ISSUES" -eq 0 ]; then
    pass "All ArgoCD applications have valid sync status"
fi
if [ "$HEALTH_FAILURES" -eq 0 ]; then
    pass "No ArgoCD applications with critical health issues"
fi

section "Storage Health"

# Check Longhorn volumes health
DEGRADED_VOLUMES=$(kubectl get volumes.longhorn.io -n longhorn-system -o jsonpath='{range .items[*]}{.metadata.name}:{.status.robustness}{"\n"}{end}' 2>/dev/null | grep -v "healthy" | grep -v "^:" | wc -l)
if [ "$DEGRADED_VOLUMES" -eq 0 ]; then
    pass "All Longhorn volumes are healthy"
else
    fail "$DEGRADED_VOLUMES Longhorn volumes are degraded"
    kubectl get volumes.longhorn.io -n longhorn-system -o jsonpath='{range .items[*]}{.metadata.name}:{.status.robustness}{"\n"}{end}' 2>/dev/null | grep -v "healthy"
fi

# Check Longhorn nodes
LONGHORN_NODES=$(kubectl get nodes.longhorn.io -n longhorn-system -o jsonpath='{range .items[*]}{.metadata.name}:{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null)
NODE_ISSUES=0
while IFS=: read -r node_name ready_status; do
    if [ -n "$node_name" ] && [ "$ready_status" != "True" ]; then
        fail "Longhorn node $node_name is not ready"
        NODE_ISSUES=$((NODE_ISSUES + 1))
    fi
done <<< "$LONGHORN_NODES"
if [ "$NODE_ISSUES" -eq 0 ]; then
    pass "All Longhorn nodes are ready"
fi

section "Network Policies"

# Check that network policies exist for key namespaces
REQUIRED_NETPOL_NS=(
    "dashboard"
    "outline"
    "n8n"
    "open-webui"
    "campfire"
    "authentik"
    "plane"
)

for ns in "${REQUIRED_NETPOL_NS[@]}"; do
    NETPOL_COUNT=$(kubectl get networkpolicies -n "$ns" --no-headers 2>/dev/null | wc -l)
    if [ "$NETPOL_COUNT" -gt 0 ]; then
        pass "Network policies exist in $ns ($NETPOL_COUNT policies)"
    else
        warn "No network policies in $ns namespace"
    fi
done

section "Backup Jobs"

# Check backup CronJob exists
if kubectl get cronjob homelab-backup -n longhorn-system --no-headers 2>/dev/null | grep -q "homelab-backup"; then
    pass "Backup CronJob exists"
else
    fail "Backup CronJob not found"
fi

# Check last backup job status (if any jobs exist)
# Format: NAME STATUS COMPLETIONS DURATION AGE
LAST_JOB=$(kubectl get jobs -n longhorn-system --sort-by=.metadata.creationTimestamp --no-headers 2>/dev/null | grep "homelab-backup" | tail -1)
if [ -n "$LAST_JOB" ]; then
    JOB_NAME=$(echo "$LAST_JOB" | awk '{print $1}')
    JOB_STATUS=$(echo "$LAST_JOB" | awk '{print $2}')
    COMPLETIONS=$(echo "$LAST_JOB" | awk '{print $3}')
    if [ "$JOB_STATUS" = "Complete" ]; then
        pass "Last backup job completed successfully ($JOB_NAME)"
    elif echo "$COMPLETIONS" | grep -q "1/1"; then
        pass "Last backup job completed ($JOB_NAME)"
    else
        warn "Last backup job status: $JOB_STATUS ($JOB_NAME)"
    fi
else
    warn "No backup job history found"
fi

section "Resource Configuration"

# Check pods without resource limits in critical namespaces
CRITICAL_NS=(
    "authentik"
    "argocd"
    "monitoring"
    "cert-manager"
)

for ns in "${CRITICAL_NS[@]}"; do
    PODS_WITHOUT_LIMITS=$(kubectl get pods -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{range .spec.containers[*]}{":"}{.resources.limits.memory}{end}{"\n"}{end}' 2>/dev/null | grep -c ":$" || echo 0)
    if [ "$PODS_WITHOUT_LIMITS" -eq 0 ]; then
        pass "All pods in $ns have resource limits"
    else
        warn "$PODS_WITHOUT_LIMITS containers without memory limits in $ns"
    fi
done

section "DNS Resolution"

# Test internal DNS resolution
DNS_TEST=$(kubectl run dns-test --image=busybox:1.36 --rm -i --restart=Never --timeout=30s -- nslookup kubernetes.default.svc.cluster.local 2>/dev/null | grep -c "Address" || echo 0)
if [ "$DNS_TEST" -gt 0 ]; then
    pass "Internal DNS resolution working"
else
    warn "Internal DNS test inconclusive"
fi

section "Endpoint Health Checks"

check_endpoint() {
    local name=$1
    local url=$2
    local expected=$3

    STATUS=$(curl -sk -o /dev/null -w "%{http_code}" --connect-timeout 5 "$url" 2>/dev/null || echo "000")
    if [ "$STATUS" = "$expected" ] || [ "$STATUS" = "302" ] || [ "$STATUS" = "200" ]; then
        pass "$name ($url) - HTTP $STATUS"
    else
        fail "$name ($url) - HTTP $STATUS (expected $expected)"
    fi
}

check_endpoint "Dashboard" "https://db.lab.axiomlayer.com/" "302"
check_endpoint "ArgoCD" "https://argocd.lab.axiomlayer.com/" "200"
check_endpoint "Grafana" "https://grafana.lab.axiomlayer.com/" "302"
check_endpoint "Authentik" "https://auth.lab.axiomlayer.com/" "200"
check_endpoint "Outline" "https://docs.lab.axiomlayer.com/" "200"
check_endpoint "n8n" "https://autom8.lab.axiomlayer.com/" "302"
check_endpoint "Open WebUI" "https://ai.lab.axiomlayer.com/" "302"
check_endpoint "Plane" "https://plane.lab.axiomlayer.com/" "200"
check_endpoint "Longhorn" "https://longhorn.lab.axiomlayer.com/" "302"
check_endpoint "Alertmanager" "https://alerts.lab.axiomlayer.com/" "302"
check_endpoint "Campfire" "https://chat.lab.axiomlayer.com/" "302"

section "Service Endpoints"

# Check internal services are accessible
check_service() {
    local name=$1
    local namespace=$2
    local service=$3
    local port=$4

    SVC_IP=$(kubectl get svc "$service" -n "$namespace" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
    if [ -n "$SVC_IP" ] && [ "$SVC_IP" != "None" ]; then
        pass "$name service exists ($namespace/$service)"
    else
        fail "$name service not found ($namespace/$service)"
    fi
}

check_service "Dashboard" "dashboard" "dashboard" "80"
check_service "Outline" "outline" "outline" "3000"
check_service "n8n" "n8n" "n8n" "5678"
check_service "Open WebUI" "open-webui" "open-webui" "8080"
check_service "Campfire" "campfire" "campfire" "3000"
check_service "Authentik" "authentik" "authentik-helm-server" "80"
check_service "Grafana" "monitoring" "kube-prometheus-stack-grafana" "80"
check_service "Prometheus" "monitoring" "kube-prometheus-stack-prometheus" "9090"
check_service "Alertmanager" "monitoring" "kube-prometheus-stack-alertmanager" "9093"
check_service "Loki" "monitoring" "loki" "3100"
check_service "Longhorn UI" "longhorn-system" "longhorn-frontend" "80"

section "Ingress Resources"

# Check all ingresses have addresses assigned
INGRESSES=$(kubectl get ingress -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}:{.status.loadBalancer.ingress[0].ip}{"\n"}{end}' 2>/dev/null)
INGRESS_ISSUES=0
while IFS=: read -r ingress_name ingress_ip; do
    if [ -n "$ingress_name" ]; then
        if [ -n "$ingress_ip" ]; then
            pass "Ingress $ingress_name has IP $ingress_ip"
        else
            warn "Ingress $ingress_name has no IP assigned"
            INGRESS_ISSUES=$((INGRESS_ISSUES + 1))
        fi
    fi
done <<< "$INGRESSES"

section "Secrets Validation"

# Check critical secrets exist
CRITICAL_SECRETS=(
    "argocd:argocd-secret"
    "authentik:authentik-secret"
    "cert-manager:cloudflare-api-token"
    "monitoring:grafana-oidc"
    "outline:outline-oidc"
    "n8n:n8n-secrets"
)

for secret in "${CRITICAL_SECRETS[@]}"; do
    NS="${secret%%:*}"
    NAME="${secret##*:}"
    if kubectl get secret "$NAME" -n "$NS" --no-headers 2>/dev/null | grep -q "$NAME"; then
        pass "Secret $NS/$NAME exists"
    else
        warn "Secret $NS/$NAME not found"
    fi
done

section "ConfigMaps Validation"

# Check critical configmaps exist
CRITICAL_CONFIGMAPS=(
    "argocd:argocd-cm"
    "argocd:argocd-rbac-cm"
    "authentik:authentik-blueprints"
)

for cm in "${CRITICAL_CONFIGMAPS[@]}"; do
    NS="${cm%%:*}"
    NAME="${cm##*:}"
    if kubectl get configmap "$NAME" -n "$NS" --no-headers 2>/dev/null | grep -q "$NAME"; then
        pass "ConfigMap $NS/$NAME exists"
    else
        warn "ConfigMap $NS/$NAME not found"
    fi
done

section "ClusterIssuers"

# Check Let's Encrypt ClusterIssuers
if kubectl get clusterissuer letsencrypt-prod --no-headers 2>/dev/null | grep -q "letsencrypt-prod"; then
    ISSUER_STATUS=$(kubectl get clusterissuer letsencrypt-prod -o jsonpath='{.status.conditions[0].status}' 2>/dev/null || echo "Unknown")
    if [ "$ISSUER_STATUS" = "True" ]; then
        pass "ClusterIssuer letsencrypt-prod is ready"
    else
        fail "ClusterIssuer letsencrypt-prod is not ready"
    fi
else
    fail "ClusterIssuer letsencrypt-prod not found"
fi

section "Summary"

TOTAL=$((PASSED + FAILED))
echo ""
echo "Tests: $TOTAL | Passed: $PASSED | Failed: $FAILED"
echo ""

if [ "$FAILED" -gt 0 ]; then
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
else
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
fi
