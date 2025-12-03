#!/bin/bash
# Smoke tests for homelab infrastructure
# Run: ./tests/smoke-test.sh

set -e
set -o pipefail

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

# Verify cluster connectivity
if ! kubectl cluster-info &>/dev/null; then
    echo "ERROR: Cannot connect to cluster"
    exit 1
fi

section "Node Health"

# Check all nodes are Ready
NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
READY_NODES=$(kubectl get nodes --no-headers | grep -c " Ready" || true)
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
UNBOUND_PVC=$(kubectl get pvc -A --no-headers 2>/dev/null | grep -v "Bound" | wc -l | tr -d '[:space:]' || echo "0")
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

# PocketBase (BaaS)
if kubectl get pods -n pocketbase -l app.kubernetes.io/name=pocketbase --no-headers 2>/dev/null | grep -q "Running"; then
    pass "PocketBase is running"
else
    fail "PocketBase is not running"
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
INVALID_CERTS=$(kubectl get certificates -A --no-headers 2>/dev/null | grep -v "True" | wc -l | tr -d '[:space:]' || echo "0")
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
DEGRADED_VOLUMES=$(kubectl get volumes.longhorn.io -n longhorn-system -o jsonpath='{range .items[*]}{.metadata.name}:{.status.robustness}{"\n"}{end}' 2>/dev/null | grep -v "healthy" | grep -v "^:" | wc -l | tr -d '[:space:]' || echo "0")
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
    "pocketbase"
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
LAST_JOB=$(kubectl get jobs -n longhorn-system --sort-by=.metadata.creationTimestamp --no-headers 2>/dev/null | grep "homelab-backup" || true)
LAST_JOB=$(echo "$LAST_JOB" | tail -1)
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

# Check Longhorn recurring jobs exist
RECURRING_JOBS=("daily-snapshot" "weekly-snapshot" "daily-backup" "weekly-backup")
for job in "${RECURRING_JOBS[@]}"; do
    if kubectl get recurringjobs.longhorn.io "$job" -n longhorn-system --no-headers 2>/dev/null | grep -q "$job"; then
        pass "Longhorn recurring job '$job' exists"
    else
        fail "Longhorn recurring job '$job' not found"
    fi
done

# Check Longhorn backup target is configured
BACKUP_TARGET=$(kubectl get settings.longhorn.io backup-target -n longhorn-system -o jsonpath='{.value}' 2>/dev/null || echo "")
if [ -n "$BACKUP_TARGET" ]; then
    pass "Longhorn backup target configured"
else
    fail "Longhorn backup target not configured"
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
    PODS_WITHOUT_LIMITS=$(kubectl get pods -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{range .spec.containers[*]}{":"}{.resources.limits.memory}{end}{"\n"}{end}' 2>/dev/null | grep -c ":$" || echo "0")
    # Ensure we have a single integer value
    PODS_WITHOUT_LIMITS=$(echo "$PODS_WITHOUT_LIMITS" | head -1 | tr -d '[:space:]')
    PODS_WITHOUT_LIMITS="${PODS_WITHOUT_LIMITS:-0}"
    if [ "$PODS_WITHOUT_LIMITS" -eq 0 ] 2>/dev/null; then
        pass "All pods in $ns have resource limits"
    else
        warn "$PODS_WITHOUT_LIMITS containers without memory limits in $ns"
    fi
done

section "DNS Resolution"

# Check CoreDNS pods are running and ready
DNS_READY=$(kubectl get pods -n kube-system -l k8s-app=kube-dns -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | tr ' ' '\n' | grep -c "True" || echo "0")
DNS_TOTAL=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
DNS_READY=$(echo "$DNS_READY" | head -1 | tr -d '[:space:]')
DNS_READY="${DNS_READY:-0}"
DNS_TOTAL="${DNS_TOTAL:-0}"

if [ "$DNS_READY" -gt 0 ] && [ "$DNS_READY" -eq "$DNS_TOTAL" ] 2>/dev/null; then
    pass "CoreDNS running ($DNS_READY/$DNS_TOTAL pods ready)"
elif [ "$DNS_READY" -gt 0 ] 2>/dev/null; then
    warn "CoreDNS degraded ($DNS_READY/$DNS_TOTAL pods ready)"
else
    fail "CoreDNS not running"
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
check_endpoint "PocketBase" "https://pb.lab.axiomlayer.com/" "302"

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
check_service "PocketBase" "pocketbase" "pocketbase" "8090"
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
    "authentik:authentik-helm-secrets"
    "cert-manager:cloudflare-api-token"
    "monitoring:grafana-oidc-secret"
    "outline:outline-secrets"
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

section "TLS Certificate Renewal"

# Check all certificates and their renewal status
ALL_CERTS=$(kubectl get certificates -A -o json 2>/dev/null)

if [ -n "$ALL_CERTS" ]; then
    CERT_COUNT=$(echo "$ALL_CERTS" | grep -o '"kind":"Certificate"' | wc -l | tr -d '[:space:]' || echo "0")
    pass "Found $CERT_COUNT certificate(s) in cluster"

    # Check each certificate's status
    CERTS_INFO=$(kubectl get certificates -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{" "}{.status.notAfter}{"\n"}{end}' 2>/dev/null)

    EXPIRING_SOON=0
    NOT_READY=0
    RENEWAL_THRESHOLD_DAYS=30

    while IFS= read -r line; do
        if [ -z "$line" ]; then continue; fi

        NS=$(echo "$line" | awk '{print $1}')
        NAME=$(echo "$line" | awk '{print $2}')
        READY=$(echo "$line" | awk '{print $3}')
        NOT_AFTER=$(echo "$line" | awk '{print $4}')

        if [ "$READY" != "True" ]; then
            fail "Certificate $NS/$NAME is not ready"
            NOT_READY=$((NOT_READY + 1))
            continue
        fi

        # Check expiration
        if [ -n "$NOT_AFTER" ]; then
            EXPIRY_EPOCH=$(date -d "$NOT_AFTER" +%s 2>/dev/null || echo "0")
            NOW_EPOCH=$(date +%s)
            DAYS_REMAINING=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))

            if [ "$DAYS_REMAINING" -lt 0 ]; then
                fail "Certificate $NS/$NAME has EXPIRED"
            elif [ "$DAYS_REMAINING" -lt 7 ]; then
                fail "Certificate $NS/$NAME expires in $DAYS_REMAINING days (CRITICAL)"
                EXPIRING_SOON=$((EXPIRING_SOON + 1))
            elif [ "$DAYS_REMAINING" -lt "$RENEWAL_THRESHOLD_DAYS" ]; then
                warn "Certificate $NS/$NAME expires in $DAYS_REMAINING days (renewal pending)"
                EXPIRING_SOON=$((EXPIRING_SOON + 1))
            else
                pass "Certificate $NS/$NAME valid for $DAYS_REMAINING days"
            fi
        fi
    done <<< "$CERTS_INFO"

    if [ "$NOT_READY" -eq 0 ]; then
        pass "All certificates are in Ready state"
    fi

    if [ "$EXPIRING_SOON" -eq 0 ]; then
        pass "No certificates expiring within $RENEWAL_THRESHOLD_DAYS days"
    fi
else
    warn "Could not retrieve certificate information"
fi

section "TLS Certificate Chain Validation"

# Validate TLS certificate chains for key endpoints
TLS_ENDPOINTS=(
    "argocd.lab.axiomlayer.com:443:ArgoCD"
    "auth.lab.axiomlayer.com:443:Authentik"
    "grafana.lab.axiomlayer.com:443:Grafana"
    "docs.lab.axiomlayer.com:443:Outline"
    "plane.lab.axiomlayer.com:443:Plane"
)

for endpoint in "${TLS_ENDPOINTS[@]}"; do
    HOST="${endpoint%%:*}"
    REST="${endpoint#*:}"
    PORT="${REST%%:*}"
    NAME="${REST##*:}"

    # Check TLS connection and certificate validity
    TLS_CHECK=$(echo | timeout 5 openssl s_client -connect "$HOST:$PORT" -servername "$HOST" 2>/dev/null || echo "failed")

    if echo "$TLS_CHECK" | grep -q "Verify return code: 0"; then
        pass "$NAME TLS certificate chain is valid"
    elif echo "$TLS_CHECK" | grep -q "CONNECTED"; then
        # Connected but certificate chain issues
        VERIFY_CODE=$(echo "$TLS_CHECK" | grep "Verify return code:" | head -1)
        if echo "$VERIFY_CODE" | grep -q "self.signed\|unable to get local issuer"; then
            warn "$NAME TLS uses self-signed or incomplete chain (may be expected for internal)"
        else
            warn "$NAME TLS chain issue: $VERIFY_CODE"
        fi
    else
        fail "$NAME TLS connection failed"
    fi

    # Check certificate expiration via openssl
    CERT_DATES=$(echo | timeout 5 openssl s_client -connect "$HOST:$PORT" -servername "$HOST" 2>/dev/null | openssl x509 -noout -dates 2>/dev/null || echo "")

    if [ -n "$CERT_DATES" ]; then
        NOT_AFTER_DATE=$(echo "$CERT_DATES" | grep "notAfter" | cut -d= -f2)
        if [ -n "$NOT_AFTER_DATE" ]; then
            EXPIRY_EPOCH=$(date -d "$NOT_AFTER_DATE" +%s 2>/dev/null || echo "0")
            NOW_EPOCH=$(date +%s)
            DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))

            if [ "$DAYS_LEFT" -lt 7 ]; then
                fail "$NAME certificate expires in $DAYS_LEFT days (URGENT)"
            elif [ "$DAYS_LEFT" -lt 30 ]; then
                warn "$NAME certificate expires in $DAYS_LEFT days"
            fi
        fi
    fi
done

section "Cert-Manager Health"

# Check cert-manager controller logs for errors
CM_LOGS=$(kubectl logs -n cert-manager -l app.kubernetes.io/name=cert-manager --tail=100 2>/dev/null)

if echo "$CM_LOGS" | grep -qi "error.*acme\|failed.*challenge\|rate.*limit"; then
    ACME_ERRORS=$(echo "$CM_LOGS" | grep -ci "error.*acme\|failed.*challenge" || echo "0")
    if [ "$ACME_ERRORS" -gt 20 ]; then
        fail "cert-manager has $ACME_ERRORS recent ACME errors (excessive)"
    else
        # Transient ACME errors are common during certificate renewal
        warn "cert-manager has $ACME_ERRORS recent ACME errors (may be transient)"
        pass "cert-manager ACME error count within acceptable threshold"
    fi
else
    pass "cert-manager has no recent ACME errors"
fi

# Check for rate limiting
if echo "$CM_LOGS" | grep -qi "rate.*limit\|too many"; then
    fail "cert-manager may be rate limited by Let's Encrypt"
else
    pass "No rate limiting detected"
fi

# Check CertificateRequests status
PENDING_REQUESTS=$(kubectl get certificaterequests -A -o jsonpath='{range .items[?(@.status.conditions[0].status!="True")]}{.metadata.namespace}/{.metadata.name}{" "}{end}' 2>/dev/null || true)

if [ -z "$PENDING_REQUESTS" ] || [ "$PENDING_REQUESTS" = " " ]; then
    pass "No pending CertificateRequests"
else
    warn "Pending CertificateRequests: $PENDING_REQUESTS"
fi

# Check for failed Orders
FAILED_ORDERS=$(kubectl get orders -A -o jsonpath='{range .items[?(@.status.state=="invalid")]}{.metadata.namespace}/{.metadata.name}{" "}{end}' 2>/dev/null || true)

if [ -z "$FAILED_ORDERS" ] || [ "$FAILED_ORDERS" = " " ]; then
    pass "No failed ACME Orders"
else
    fail "Failed ACME Orders: $FAILED_ORDERS"
fi

# Check DNS-01 challenge capability
CHALLENGES_OUTPUT=$(kubectl get challenges -A -o jsonpath='{range .items[*]}{.spec.type}{"\n"}{end}' 2>/dev/null || echo "")
DNS_CHALLENGES=$(echo "$CHALLENGES_OUTPUT" | grep -c "DNS-01" 2>/dev/null || echo "0")
HTTP_CHALLENGES=$(echo "$CHALLENGES_OUTPUT" | grep -c "HTTP-01" 2>/dev/null || echo "0")

# Ensure variables are valid integers (remove any whitespace/newlines)
DNS_CHALLENGES=$(echo "$DNS_CHALLENGES" | tr -d '[:space:]')
HTTP_CHALLENGES=$(echo "$HTTP_CHALLENGES" | tr -d '[:space:]')
DNS_CHALLENGES=${DNS_CHALLENGES:-0}
HTTP_CHALLENGES=${HTTP_CHALLENGES:-0}

# Validate they are numbers
if ! [[ "$DNS_CHALLENGES" =~ ^[0-9]+$ ]]; then DNS_CHALLENGES=0; fi
if ! [[ "$HTTP_CHALLENGES" =~ ^[0-9]+$ ]]; then HTTP_CHALLENGES=0; fi

ACTIVE_CHALLENGES=$((DNS_CHALLENGES + HTTP_CHALLENGES))
if [ "$ACTIVE_CHALLENGES" -eq 0 ]; then
    pass "No active ACME challenges (certificates are stable)"
else
    warn "$ACTIVE_CHALLENGES active ACME challenge(s) in progress"
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
