#!/bin/bash
# test-monitoring.sh - Monitoring and observability stack verification tests
# Tests Prometheus, Grafana, Loki, and alerting functionality

set -uo pipefail
# Note: not using -e because some commands may fail in expected ways

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
PASSED=0
FAILED=0
SKIPPED=0

# Test results array
declare -a TEST_RESULTS=()

# Monitoring configuration
MONITORING_NAMESPACE="monitoring"
GRAFANA_URL="${GRAFANA_URL:-https://grafana.lab.axiomlayer.com}"
ALERTMANAGER_URL="${ALERTMANAGER_URL:-https://alerts.lab.axiomlayer.com}"

print_header() {
    echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}\n"
}

print_section() {
    echo -e "\n${YELLOW}─── $1 ───${NC}\n"
}

pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
    PASSED=$((PASSED + 1))
    TEST_RESULTS+=("PASS: $1")
}

fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    FAILED=$((FAILED + 1))
    TEST_RESULTS+=("FAIL: $1")
}

skip() {
    echo -e "${YELLOW}○ SKIP${NC}: $1"
    SKIPPED=$((SKIPPED + 1))
    TEST_RESULTS+=("SKIP: $1")
}

info() {
    echo -e "${BLUE}ℹ INFO${NC}: $1"
}

# Permission flags
CAN_EXEC_PODS=false

# Check prerequisites
check_prerequisites() {
    print_section "Checking Prerequisites"

    if ! command -v kubectl &> /dev/null; then
        fail "kubectl not found in PATH"
        exit 1
    fi

    if ! kubectl cluster-info &> /dev/null; then
        fail "Cannot connect to Kubernetes cluster"
        exit 1
    fi

    if ! kubectl get namespace "$MONITORING_NAMESPACE" &> /dev/null; then
        fail "Monitoring namespace '$MONITORING_NAMESPACE' does not exist"
        exit 1
    fi

    # Check if we have exec permissions
    if kubectl auth can-i create pods/exec -n "$MONITORING_NAMESPACE" &> /dev/null; then
        CAN_EXEC_PODS=true
    else
        info "Limited permissions detected - tests requiring kubectl exec will be skipped"
    fi

    pass "Prerequisites met"
}

# Test 1: Prometheus Stack Health
test_prometheus_health() {
    print_section "Prometheus Stack Health Tests"

    # Check Prometheus pods
    local prometheus_pods
    prometheus_pods=$(kubectl get pods -n "$MONITORING_NAMESPACE" -l "app.kubernetes.io/name=prometheus" --field-selector=status.phase=Running -o name 2>/dev/null | wc -l)

    if [[ "$prometheus_pods" -gt 0 ]]; then
        pass "Prometheus has $prometheus_pods running pod(s)"
    else
        # Try alternative label
        prometheus_pods=$(kubectl get pods -n "$MONITORING_NAMESPACE" -l "app=prometheus" --field-selector=status.phase=Running -o name 2>/dev/null | wc -l)
        if [[ "$prometheus_pods" -gt 0 ]]; then
            pass "Prometheus has $prometheus_pods running pod(s)"
        else
            fail "Prometheus has no running pods"
            return
        fi
    fi

    # Check Prometheus Operator
    local operator_pods
    operator_pods=$(kubectl get pods -n "$MONITORING_NAMESPACE" -l "app.kubernetes.io/name=prometheus-operator" --field-selector=status.phase=Running -o name 2>/dev/null | wc -l)

    if [[ "$operator_pods" -gt 0 ]]; then
        pass "Prometheus Operator is running"
    else
        info "Prometheus Operator pod check inconclusive"
    fi

    # Check kube-state-metrics
    local ksm_pods
    ksm_pods=$(kubectl get pods -n "$MONITORING_NAMESPACE" -l "app.kubernetes.io/name=kube-state-metrics" --field-selector=status.phase=Running -o name 2>/dev/null | wc -l)

    if [[ "$ksm_pods" -gt 0 ]]; then
        pass "kube-state-metrics is running"
    else
        fail "kube-state-metrics not running"
    fi

    # Check node-exporter
    local node_exporter_pods
    node_exporter_pods=$(kubectl get pods -n "$MONITORING_NAMESPACE" -l "app.kubernetes.io/name=prometheus-node-exporter" --field-selector=status.phase=Running -o name 2>/dev/null | wc -l)

    if [[ "$node_exporter_pods" -gt 0 ]]; then
        pass "Node exporter has $node_exporter_pods running pod(s)"
    else
        # Alternative: check daemonset
        local ds_ready
        ds_ready=$(kubectl get daemonset -n "$MONITORING_NAMESPACE" -l "app.kubernetes.io/name=prometheus-node-exporter" -o jsonpath='{.items[0].status.numberReady}' 2>/dev/null || echo "0")
        if [[ "$ds_ready" -gt 0 ]]; then
            pass "Node exporter has $ds_ready ready pod(s)"
        else
            fail "Node exporter not running"
        fi
    fi
}

# Test 2: Prometheus Scrape Targets
test_prometheus_targets() {
    print_section "Prometheus Scrape Target Tests"

    # Skip if we don't have exec permissions
    if [[ "$CAN_EXEC_PODS" != "true" ]]; then
        skip "Prometheus targets test requires kubectl exec permissions"
        return
    fi

    # Get Prometheus pod for port-forward
    local prometheus_pod
    prometheus_pod=$(kubectl get pods -n "$MONITORING_NAMESPACE" -l "app.kubernetes.io/name=prometheus,prometheus=kube-prometheus-stack-prometheus" -o name 2>/dev/null | head -1)

    if [[ -z "$prometheus_pod" ]]; then
        # Try alternative selector
        prometheus_pod=$(kubectl get pods -n "$MONITORING_NAMESPACE" -l "app=prometheus" -o name 2>/dev/null | head -1)
    fi

    if [[ -z "$prometheus_pod" ]]; then
        skip "Could not find Prometheus pod for target verification"
        return
    fi

    prometheus_pod="${prometheus_pod#pod/}"

    # Check targets via kubectl exec
    local targets_response
    targets_response=$(kubectl exec -n "$MONITORING_NAMESPACE" "$prometheus_pod" -c prometheus -- \
        wget -q -O - "http://localhost:9090/api/v1/targets" 2>/dev/null) || targets_response="failed"

    if [[ "$targets_response" == "failed" ]] || [[ -z "$targets_response" ]]; then
        fail "Prometheus targets API not responding"
        return
    fi

    if echo "$targets_response" | grep -q '"status":"success"' 2>/dev/null; then
        pass "Prometheus targets API is responding"

        # Count active targets (use grep -c to avoid SIGPIPE)
        local active_targets
        active_targets=$(echo "$targets_response" | grep -c '"health":"up"' 2>/dev/null || echo "0")

        local total_targets
        total_targets=$(echo "$targets_response" | grep -c '"health":' 2>/dev/null || echo "0")

        if [[ "$active_targets" -gt 0 ]]; then
            pass "Prometheus has $active_targets of $total_targets targets UP"
        else
            fail "Prometheus has no active targets"
        fi

        # Check for specific important targets
        if echo "$targets_response" | grep -q "kubernetes-apiservers\|apiserver" 2>/dev/null; then
            pass "Kubernetes API server target configured"
        else
            info "Kubernetes API server target not found (may use different name)"
        fi

        if echo "$targets_response" | grep -q "kubernetes-nodes\|kubelet" 2>/dev/null; then
            pass "Kubernetes nodes/kubelet target configured"
        else
            info "Kubernetes nodes target not found (may use different name)"
        fi
    else
        fail "Prometheus targets API not responding properly"
    fi
}

# Test 3: Prometheus Service Monitors
test_service_monitors() {
    print_section "ServiceMonitor Tests"

    # Get all ServiceMonitors
    local service_monitors
    service_monitors=$(kubectl get servicemonitors -A -o name 2>/dev/null | wc -l | tr -d '[:space:]')

    if [[ "$service_monitors" -gt 0 ]]; then
        pass "Found $service_monitors ServiceMonitor(s) in cluster"
    else
        fail "No ServiceMonitors found"
        return
    fi

    # List ServiceMonitors by namespace
    info "ServiceMonitors by namespace:"
    kubectl get servicemonitors -A --no-headers 2>/dev/null | awk '{print "  " $1 ": " $2}'

    # Check for critical ServiceMonitors
    local critical_monitors=("kube-prometheus-stack-apiserver" "kube-prometheus-stack-kubelet" "kube-prometheus-stack-prometheus")

    for monitor in "${critical_monitors[@]}"; do
        if kubectl get servicemonitor "$monitor" -n "$MONITORING_NAMESPACE" &> /dev/null; then
            pass "Critical ServiceMonitor '$monitor' exists"
        else
            info "ServiceMonitor '$monitor' not found (may have different name)"
        fi
    done
}

# Test 4: Grafana Datasources
test_grafana_datasources() {
    print_section "Grafana Datasource Tests"

    # Check Grafana pod
    local grafana_pod
    grafana_pod=$(kubectl get pods -n "$MONITORING_NAMESPACE" -l "app.kubernetes.io/name=grafana" --field-selector=status.phase=Running -o name 2>/dev/null | head -1)

    if [[ -z "$grafana_pod" ]]; then
        fail "Grafana pod not running"
        return
    fi

    pass "Grafana pod is running"
    grafana_pod="${grafana_pod#pod/}"

    # Check datasource configuration via API (using kubectl exec) if we have permissions
    local datasources="[]"
    if [[ "$CAN_EXEC_PODS" == "true" ]]; then
        datasources=$(kubectl exec -n "$MONITORING_NAMESPACE" "$grafana_pod" -- \
            wget -q -O - "http://localhost:3000/api/datasources" \
            --header="Authorization: Basic $(echo -n 'admin:admin' | base64)" 2>/dev/null || echo "[]")
    fi

    if echo "$datasources" | grep -q "Prometheus\|prometheus"; then
        pass "Prometheus datasource configured in Grafana"
    else
        # Check via provisioned datasources (doesn't require exec)
        local provisioned_ds
        provisioned_ds=$(kubectl get configmaps -n "$MONITORING_NAMESPACE" -o name 2>/dev/null | grep -i "grafana.*datasource" | wc -l)
        if [[ "$provisioned_ds" -gt 0 ]]; then
            pass "Grafana has $provisioned_ds provisioned datasource ConfigMap(s)"
        else
            info "Could not verify Prometheus datasource (may need authentication)"
        fi
    fi

    # Check for Loki datasource
    if echo "$datasources" | grep -qi "loki"; then
        pass "Loki datasource configured in Grafana"
    else
        info "Loki datasource not found (may not be configured)"
    fi
}

# Test 5: Alertmanager Configuration
test_alertmanager() {
    print_section "Alertmanager Tests"

    # Check Alertmanager pods
    local alertmanager_pods
    alertmanager_pods=$(kubectl get pods -n "$MONITORING_NAMESPACE" -l "app.kubernetes.io/name=alertmanager" --field-selector=status.phase=Running -o name 2>/dev/null | wc -l)

    if [[ "$alertmanager_pods" -gt 0 ]]; then
        pass "Alertmanager has $alertmanager_pods running pod(s)"
    else
        fail "Alertmanager not running"
        return
    fi

    # Check Alertmanager URL
    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -L "$ALERTMANAGER_URL" 2>/dev/null || echo "000")

    if [[ "$status" == "200" ]] || [[ "$status" == "302" ]]; then
        pass "Alertmanager UI accessible (status: $status)"
    else
        info "Alertmanager UI returned status: $status"
    fi

    # Check Alertmanager config secret
    local config_secret
    config_secret=$(kubectl get secrets -n "$MONITORING_NAMESPACE" -o name 2>/dev/null | grep -i "alertmanager" | head -1)

    if [[ -n "$config_secret" ]]; then
        pass "Alertmanager configuration secret exists"
    else
        info "Could not find Alertmanager configuration secret"
    fi

    # Check for active alerts via Alertmanager API (requires exec permissions)
    if [[ "$CAN_EXEC_PODS" == "true" ]]; then
        local alertmanager_pod
        alertmanager_pod=$(kubectl get pods -n "$MONITORING_NAMESPACE" -l "app.kubernetes.io/name=alertmanager" -o name 2>/dev/null | head -1)

        if [[ -n "$alertmanager_pod" ]]; then
            alertmanager_pod="${alertmanager_pod#pod/}"

            local alerts
            alerts=$(kubectl exec -n "$MONITORING_NAMESPACE" "$alertmanager_pod" -- \
                wget -q -O - "http://localhost:9093/api/v2/alerts" 2>/dev/null || echo "[]")

            local alert_count
            alert_count=$(echo "$alerts" | grep -o '"fingerprint"' | wc -l)

            info "Alertmanager currently has $alert_count active alert(s)"
        fi
    fi
}

# Test 6: PrometheusRules
test_prometheus_rules() {
    print_section "PrometheusRule Tests"

    # Get all PrometheusRules
    local prom_rules
    prom_rules=$(kubectl get prometheusrules -A -o name 2>/dev/null | wc -l)

    if [[ "$prom_rules" -gt 0 ]]; then
        pass "Found $prom_rules PrometheusRule(s) in cluster"
    else
        info "No PrometheusRules found (alerts may be configured differently)"
        return
    fi

    # List rules by namespace
    info "PrometheusRules by namespace:"
    kubectl get prometheusrules -A --no-headers 2>/dev/null | awk '{print "  " $1 ": " $2}' | head -10

    # Check for critical alerting rules
    local has_critical_rules=false

    if kubectl get prometheusrules -n "$MONITORING_NAMESPACE" -o yaml 2>/dev/null | grep -qi "KubeNodeNotReady\|KubePodCrashLooping\|KubePodNotReady"; then
        has_critical_rules=true
    fi

    if [[ "$has_critical_rules" == "true" ]]; then
        pass "Critical Kubernetes alerting rules are configured"
    else
        info "Could not verify critical alerting rules"
    fi
}

# Test 7: Loki Log Aggregation
test_loki() {
    print_section "Loki Log Aggregation Tests"

    # Check Loki pods
    local loki_pods
    loki_pods=$(kubectl get pods -n "$MONITORING_NAMESPACE" -l "app=loki" --field-selector=status.phase=Running -o name 2>/dev/null | wc -l)

    if [[ "$loki_pods" -eq 0 ]]; then
        # Try alternative labels
        loki_pods=$(kubectl get pods -n "$MONITORING_NAMESPACE" -l "app.kubernetes.io/name=loki" --field-selector=status.phase=Running -o name 2>/dev/null | wc -l)
    fi

    if [[ "$loki_pods" -gt 0 ]]; then
        pass "Loki has $loki_pods running pod(s)"
    else
        skip "Loki not found or not running"
        return
    fi

    # Check Promtail pods
    local promtail_pods
    promtail_pods=$(kubectl get pods -n "$MONITORING_NAMESPACE" -l "app=promtail" --field-selector=status.phase=Running -o name 2>/dev/null | wc -l)

    if [[ "$promtail_pods" -eq 0 ]]; then
        promtail_pods=$(kubectl get pods -n "$MONITORING_NAMESPACE" -l "app.kubernetes.io/name=promtail" --field-selector=status.phase=Running -o name 2>/dev/null | wc -l)
    fi

    if [[ "$promtail_pods" -gt 0 ]]; then
        pass "Promtail has $promtail_pods running pod(s)"
    else
        info "Promtail not found (may use different log collector)"
    fi

    # Check Loki service
    if kubectl get service loki -n "$MONITORING_NAMESPACE" &> /dev/null; then
        pass "Loki service exists"
    else
        # Try with stack suffix
        if kubectl get service loki-stack -n "$MONITORING_NAMESPACE" &> /dev/null; then
            pass "Loki-stack service exists"
        else
            info "Loki service not found with expected name"
        fi
    fi
}

# Test 8: Metrics Collection Verification
test_metrics_collection() {
    print_section "Metrics Collection Verification Tests"

    # Skip if we don't have exec permissions
    if [[ "$CAN_EXEC_PODS" != "true" ]]; then
        skip "Metrics collection test requires kubectl exec permissions"
        return
    fi

    # Get Prometheus pod
    local prometheus_pod
    prometheus_pod=$(kubectl get pods -n "$MONITORING_NAMESPACE" -l "app.kubernetes.io/name=prometheus" -o name 2>/dev/null | head -1)

    if [[ -z "$prometheus_pod" ]]; then
        prometheus_pod=$(kubectl get pods -n "$MONITORING_NAMESPACE" -l "app=prometheus" -o name 2>/dev/null | head -1)
    fi

    if [[ -z "$prometheus_pod" ]]; then
        skip "Could not find Prometheus pod for metrics verification"
        return
    fi

    prometheus_pod="${prometheus_pod#pod/}"

    # Check if we can query metrics
    local query_test
    query_test=$(kubectl exec -n "$MONITORING_NAMESPACE" "$prometheus_pod" -c prometheus -- \
        wget -q -O - "http://localhost:9090/api/v1/query?query=up" 2>/dev/null || echo "failed")

    if echo "$query_test" | grep -q '"status":"success"'; then
        pass "Prometheus query API is working"
    else
        fail "Prometheus query API not responding"
        return
    fi

    # Test specific metrics
    local metrics_to_check=(
        "up:Container/target availability"
        "node_cpu_seconds_total:Node CPU metrics"
        "container_memory_usage_bytes:Container memory metrics"
        "kube_pod_status_phase:Kubernetes pod status"
    )

    for metric_info in "${metrics_to_check[@]}"; do
        IFS=':' read -r metric description <<< "$metric_info"

        local result
        result=$(kubectl exec -n "$MONITORING_NAMESPACE" "$prometheus_pod" -c prometheus -- \
            wget -q -O - "http://localhost:9090/api/v1/query?query=${metric}" 2>/dev/null || echo "failed")

        if echo "$result" | grep -q '"result":\[' && ! echo "$result" | grep -q '"result":\[\]'; then
            pass "Metric '$metric' is being collected ($description)"
        else
            info "Metric '$metric' not found or empty ($description)"
        fi
    done
}

# Test 9: Pod Disruption Budgets for Monitoring
test_monitoring_pdb() {
    print_section "Monitoring PodDisruptionBudget Tests"

    local components=("prometheus" "alertmanager" "grafana")

    for component in "${components[@]}"; do
        local pdb
        pdb=$(kubectl get pdb -n "$MONITORING_NAMESPACE" -o name 2>/dev/null | grep -i "$component" | head -1)

        if [[ -n "$pdb" ]]; then
            pass "PodDisruptionBudget exists for $component"
        else
            info "No PodDisruptionBudget found for $component"
        fi
    done
}

# Test 10: Monitoring Resource Utilization
test_monitoring_resources() {
    print_section "Monitoring Resource Utilization Tests"

    # Check Prometheus resource usage
    local prometheus_pod
    prometheus_pod=$(kubectl get pods -n "$MONITORING_NAMESPACE" -l "app.kubernetes.io/name=prometheus" -o name 2>/dev/null | head -1)

    if [[ -n "$prometheus_pod" ]]; then
        prometheus_pod="${prometheus_pod#pod/}"

        # Get resource metrics if metrics-server is available
        local resources
        resources=$(kubectl top pod "$prometheus_pod" -n "$MONITORING_NAMESPACE" 2>/dev/null || echo "")

        if [[ -n "$resources" ]]; then
            info "Prometheus resource usage:"
            echo "$resources"
            pass "Resource metrics available for Prometheus"
        else
            info "metrics-server not available or Prometheus metrics not ready"
        fi
    fi

    # Check Prometheus storage
    local pvc
    pvc=$(kubectl get pvc -n "$MONITORING_NAMESPACE" -l "app.kubernetes.io/name=prometheus" -o name 2>/dev/null | head -1)

    if [[ -n "$pvc" ]]; then
        local pvc_status
        pvc_status=$(kubectl get "$pvc" -n "$MONITORING_NAMESPACE" -o jsonpath='{.status.phase}')

        if [[ "$pvc_status" == "Bound" ]]; then
            pass "Prometheus PVC is bound"

            local pvc_capacity
            pvc_capacity=$(kubectl get "$pvc" -n "$MONITORING_NAMESPACE" -o jsonpath='{.status.capacity.storage}')
            info "Prometheus storage capacity: $pvc_capacity"
        else
            fail "Prometheus PVC status: $pvc_status"
        fi
    else
        info "Prometheus PVC not found (may use emptyDir or hostPath)"
    fi
}

# Print summary
print_summary() {
    print_header "Test Summary"

    echo -e "Total tests: $((PASSED + FAILED + SKIPPED))"
    echo -e "${GREEN}Passed${NC}: $PASSED"
    echo -e "${RED}Failed${NC}: $FAILED"
    echo -e "${YELLOW}Skipped${NC}: $SKIPPED"

    if [[ $FAILED -gt 0 ]]; then
        echo -e "\n${RED}Failed tests:${NC}"
        for result in "${TEST_RESULTS[@]}"; do
            if [[ "$result" == FAIL:* ]]; then
                echo "  - ${result#FAIL: }"
            fi
        done
    fi

    echo ""

    if [[ $FAILED -eq 0 ]]; then
        echo -e "${GREEN}All monitoring tests passed!${NC}"
        exit 0
    else
        echo -e "${RED}Some monitoring tests failed!${NC}"
        exit 1
    fi
}

# Main execution
main() {
    print_header "Monitoring and Observability Tests"

    check_prerequisites

    test_prometheus_health
    test_prometheus_targets
    test_service_monitors
    test_grafana_datasources
    test_alertmanager
    test_prometheus_rules
    test_loki
    test_metrics_collection
    test_monitoring_pdb
    test_monitoring_resources

    print_summary
}

main "$@"
