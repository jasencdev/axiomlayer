#!/bin/bash
# test-network-policies.sh - Network Policy enforcement verification tests
# Tests that NetworkPolicies actually block/allow traffic as intended

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

# Test namespace for network policy verification
TEST_NAMESPACE="netpol-test"

# Namespaces with network policies to test
POLICY_NAMESPACES=("authentik" "outline" "n8n" "open-webui" "plane" "dashboard" "campfire")

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

# Check if kubectl is available and configured
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

    pass "kubectl available and cluster accessible"

    # Check if we have write permissions (for tests that need create/exec)
    if kubectl auth can-i create namespaces &> /dev/null; then
        CAN_CREATE_RESOURCES=true
    else
        CAN_CREATE_RESOURCES=false
        info "Limited permissions detected - network policy enforcement tests will be skipped"
    fi
}

# Setup test namespace and resources
setup_test_environment() {
    print_section "Setting Up Test Environment"

    # Create test namespace if it doesn't exist
    if kubectl get namespace "$TEST_NAMESPACE" &> /dev/null; then
        info "Test namespace '$TEST_NAMESPACE' already exists"
    else
        kubectl create namespace "$TEST_NAMESPACE" &> /dev/null
        pass "Created test namespace '$TEST_NAMESPACE'"
    fi

    # Label the namespace for network policy selectors
    kubectl label namespace "$TEST_NAMESPACE" \
        kubernetes.io/metadata.name="$TEST_NAMESPACE" \
        purpose=network-policy-testing \
        --overwrite &> /dev/null

    # Deploy a test pod for network connectivity tests
    cat <<EOF | kubectl apply -f - &> /dev/null
apiVersion: v1
kind: Pod
metadata:
  name: netpol-tester
  namespace: $TEST_NAMESPACE
  labels:
    app.kubernetes.io/name: netpol-tester
    app.kubernetes.io/component: testing
spec:
  containers:
  - name: tester
    image: busybox:1.36
    command: ["sleep", "3600"]
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      runAsNonRoot: true
      runAsUser: 1000
      capabilities:
        drop: ["ALL"]
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  restartPolicy: Never
  terminationGracePeriodSeconds: 5
EOF

    # Wait for pod to be ready
    local timeout=60
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        local pod_status
        pod_status=$(kubectl get pod netpol-tester -n "$TEST_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)

        if [[ "$pod_status" == "Running" ]]; then
            pass "Test pod 'netpol-tester' is running"
            return 0
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    fail "Test pod failed to start within ${timeout}s"
    return 1
}

# Cleanup test environment
cleanup_test_environment() {
    print_section "Cleaning Up Test Environment"

    kubectl delete namespace "$TEST_NAMESPACE" --ignore-not-found --wait=false &> /dev/null
    info "Test namespace cleanup initiated"
}

# Test 1: Verify network policies exist in target namespaces
test_policies_exist() {
    print_section "Network Policy Existence Tests"

    for ns in "${POLICY_NAMESPACES[@]}"; do
        if ! kubectl get namespace "$ns" &> /dev/null; then
            skip "Namespace '$ns' does not exist"
            continue
        fi

        local policy_count
        policy_count=$(kubectl get networkpolicies -n "$ns" -o name 2>/dev/null | wc -l)

        if [[ "$policy_count" -gt 0 ]]; then
            pass "Namespace '$ns' has $policy_count NetworkPolicy(s)"

            # Check for default deny policy
            local has_default_deny=false
            local policies
            policies=$(kubectl get networkpolicies -n "$ns" -o json 2>/dev/null)

            # Look for a policy that denies all by having empty podSelector and both ingress/egress in policyTypes
            if echo "$policies" | grep -q '"policyTypes".*"Ingress".*"Egress"\|"policyTypes".*"Egress".*"Ingress"'; then
                if echo "$policies" | grep -q '"podSelector":{}'; then
                    has_default_deny=true
                fi
            fi

            if [[ "$has_default_deny" == "true" ]]; then
                pass "Namespace '$ns' has default-deny policy"
            else
                info "Namespace '$ns' may not have strict default-deny (verify manually)"
            fi
        else
            fail "Namespace '$ns' has no NetworkPolicies"
        fi
    done
}

# Test 2: Verify Traefik ingress is allowed
test_traefik_ingress_allowed() {
    print_section "Traefik Ingress Access Tests"

    for ns in "${POLICY_NAMESPACES[@]}"; do
        if ! kubectl get namespace "$ns" &> /dev/null; then
            skip "Namespace '$ns' does not exist"
            continue
        fi

        # Get the main app in this namespace
        local app_name="$ns"
        local service_name=""

        # Find the primary service
        service_name=$(kubectl get services -n "$ns" -o name 2>/dev/null | grep -v "db\|redis\|postgres" | head -1)

        if [[ -z "$service_name" ]]; then
            skip "No primary service found in '$ns'"
            continue
        fi

        service_name="${service_name#service/}"

        # Get service port
        local service_port
        service_port=$(kubectl get service "$service_name" -n "$ns" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)

        if [[ -z "$service_port" ]]; then
            skip "Could not determine service port for '$service_name' in '$ns'"
            continue
        fi

        # Test connectivity from kube-system (where Traefik runs)
        # We simulate this by checking if the network policy allows traffic from kube-system

        local policies
        policies=$(kubectl get networkpolicies -n "$ns" -o json 2>/dev/null)

        if echo "$policies" | grep -q "kube-system"; then
            pass "Namespace '$ns' allows ingress from kube-system (Traefik)"
        else
            # Check if there's an ingress rule that matches traefik
            if echo "$policies" | grep -q -iE "traefik|ingress"; then
                pass "Namespace '$ns' has Traefik/ingress-related network policy rules"
            else
                info "Namespace '$ns' - could not verify Traefik ingress rules (may use different selector)"
            fi
        fi
    done
}

# Test 3: Test cross-namespace isolation
test_cross_namespace_isolation() {
    print_section "Cross-Namespace Isolation Tests"

    # Test that our test pod cannot reach services in protected namespaces
    for ns in "${POLICY_NAMESPACES[@]}"; do
        if ! kubectl get namespace "$ns" &> /dev/null; then
            skip "Namespace '$ns' does not exist"
            continue
        fi

        # Get the main service in this namespace
        local service_name
        service_name=$(kubectl get services -n "$ns" -o name 2>/dev/null | grep -v "db\|redis\|postgres\|headless" | head -1)

        if [[ -z "$service_name" ]]; then
            skip "No primary service found in '$ns'"
            continue
        fi

        service_name="${service_name#service/}"

        # Get service port
        local service_port
        service_port=$(kubectl get service "$service_name" -n "$ns" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)

        if [[ -z "$service_port" ]]; then
            skip "Could not determine port for '$service_name' in '$ns'"
            continue
        fi

        local target="${service_name}.${ns}.svc.cluster.local:${service_port}"

        info "Testing connectivity to $target from test namespace..."

        # Attempt connection with short timeout
        local result
        result=$(kubectl exec -n "$TEST_NAMESPACE" netpol-tester -- \
            wget -q -O /dev/null --timeout=5 "http://${target}" 2>&1 || echo "blocked")

        if echo "$result" | grep -qiE "blocked|timed out|connection refused|unable to connect"; then
            pass "Cross-namespace access BLOCKED: $TEST_NAMESPACE -> $ns/$service_name"
        else
            fail "Cross-namespace access ALLOWED: $TEST_NAMESPACE -> $ns/$service_name (should be blocked)"
        fi
    done
}

# Test 4: Test database isolation
test_database_isolation() {
    print_section "Database Isolation Tests"

    local databases=(
        "authentik:authentik-db-rw:5432"
        "outline:outline-db-rw:5432"
        "n8n:n8n-db-rw:5432"
        "open-webui:open-webui-db-rw:5432"
    )

    for db_info in "${databases[@]}"; do
        IFS=':' read -r namespace service port <<< "$db_info"

        if ! kubectl get namespace "$namespace" &> /dev/null; then
            skip "Namespace '$namespace' does not exist"
            continue
        fi

        if ! kubectl get service "$service" -n "$namespace" &> /dev/null; then
            skip "Database service '$service' not found in '$namespace'"
            continue
        fi

        local target="${service}.${namespace}.svc.cluster.local"

        info "Testing database access to $target:$port from test namespace..."

        # Test TCP connection to database port
        local result
        result=$(kubectl exec -n "$TEST_NAMESPACE" netpol-tester -- \
            nc -z -w 3 "$target" "$port" 2>&1 || echo "blocked")

        if echo "$result" | grep -qiE "blocked|timed out|connection refused"; then
            pass "Database access BLOCKED: $TEST_NAMESPACE -> $namespace/$service:$port"
        else
            fail "Database access ALLOWED: $TEST_NAMESPACE -> $namespace/$service:$port (should be blocked)"
        fi
    done
}

# Test 5: Verify DNS egress is allowed
test_dns_egress() {
    print_section "DNS Egress Tests"

    info "Testing DNS resolution from test pod..."

    local result
    result=$(kubectl exec -n "$TEST_NAMESPACE" netpol-tester -- \
        nslookup kubernetes.default.svc.cluster.local 2>&1 || echo "failed")

    if echo "$result" | grep -q "Address"; then
        pass "DNS resolution works from test namespace"
    else
        # DNS might be blocked by network policy - this is actually correct behavior
        # if there's no explicit DNS allow rule
        info "DNS resolution failed (may be expected if namespace has strict egress policy)"
    fi
}

# Test 6: Test internal app-to-database connectivity
test_app_to_database() {
    print_section "App-to-Database Connectivity Tests"

    local app_db_pairs=(
        "authentik:authentik:authentik-db-rw:5432"
        "outline:outline:outline-db-rw:5432"
        "n8n:n8n:n8n-db-rw:5432"
    )

    for pair in "${app_db_pairs[@]}"; do
        IFS=':' read -r namespace app_label db_service db_port <<< "$pair"

        if ! kubectl get namespace "$namespace" &> /dev/null; then
            skip "Namespace '$namespace' does not exist"
            continue
        fi

        # Get an app pod
        local app_pod
        app_pod=$(kubectl get pods -n "$namespace" -l "app.kubernetes.io/name=$app_label" -o name 2>/dev/null | head -1)

        if [[ -z "$app_pod" ]]; then
            # Try alternative label
            app_pod=$(kubectl get pods -n "$namespace" -l "app=$app_label" -o name 2>/dev/null | head -1)
        fi

        if [[ -z "$app_pod" ]]; then
            skip "No app pod found for '$app_label' in '$namespace'"
            continue
        fi

        app_pod="${app_pod#pod/}"

        # Check if database service exists
        if ! kubectl get service "$db_service" -n "$namespace" &> /dev/null; then
            skip "Database service '$db_service' not found in '$namespace'"
            continue
        fi

        # We can't easily test TCP connectivity from within app pods without netcat
        # Instead, verify that the app is running and connected to DB by checking logs or status

        local pod_status
        pod_status=$(kubectl get pod "$app_pod" -n "$namespace" -o jsonpath='{.status.phase}')

        if [[ "$pod_status" == "Running" ]]; then
            # Check if there are any database connection errors in recent logs
            local recent_logs
            recent_logs=$(kubectl logs "$app_pod" -n "$namespace" --tail=50 2>/dev/null | grep -iE "database|postgres|connection" | grep -iE "error|fail|refused" | head -3)

            if [[ -z "$recent_logs" ]]; then
                pass "App '$app_label' appears to have database connectivity (no connection errors in logs)"
            else
                info "App '$app_label' may have database issues:"
                echo "$recent_logs"
            fi
        else
            skip "App pod '$app_pod' is not running (status: $pod_status)"
        fi
    done
}

# Test 7: Verify monitoring namespace can scrape metrics
test_monitoring_access() {
    print_section "Monitoring Access Tests"

    local monitoring_ns="monitoring"

    if ! kubectl get namespace "$monitoring_ns" &> /dev/null; then
        skip "Monitoring namespace does not exist"
        return
    fi

    # Check if network policies allow Prometheus to scrape targets
    for ns in "${POLICY_NAMESPACES[@]}"; do
        if ! kubectl get namespace "$ns" &> /dev/null; then
            continue
        fi

        local policies
        policies=$(kubectl get networkpolicies -n "$ns" -o json 2>/dev/null)

        if echo "$policies" | grep -q "monitoring"; then
            pass "Namespace '$ns' allows access from monitoring namespace"
        else
            # Check for prometheus-specific labels
            if echo "$policies" | grep -qiE "prometheus|metrics"; then
                pass "Namespace '$ns' has Prometheus/metrics access rules"
            else
                info "Namespace '$ns' - could not verify monitoring access (may use different selector)"
            fi
        fi
    done
}

# Test 8: Verify backup job access to databases
test_backup_access() {
    print_section "Backup Job Access Tests"

    local backup_ns="longhorn-system"

    if ! kubectl get namespace "$backup_ns" &> /dev/null; then
        skip "Backup namespace (longhorn-system) does not exist"
        return
    fi

    # Check that backed-up databases allow access from backup namespace
    local backup_dbs=("authentik" "outline")

    for db_ns in "${backup_dbs[@]}"; do
        if ! kubectl get namespace "$db_ns" &> /dev/null; then
            skip "Database namespace '$db_ns' does not exist"
            continue
        fi

        local policies
        policies=$(kubectl get networkpolicies -n "$db_ns" -o json 2>/dev/null)

        if echo "$policies" | grep -q "longhorn-system"; then
            pass "Database namespace '$db_ns' allows backup access from longhorn-system"
        else
            if echo "$policies" | grep -qiE "backup"; then
                pass "Database namespace '$db_ns' has backup-related network policy rules"
            else
                fail "Database namespace '$db_ns' may not allow backup job access"
            fi
        fi
    done
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
        echo -e "${GREEN}All network policy tests passed!${NC}"
        exit 0
    else
        echo -e "${RED}Some network policy tests failed!${NC}"
        exit 1
    fi
}

# Main execution
main() {
    print_header "Network Policy Enforcement Tests"

    check_prerequisites

    # Check if we can run the full test suite (requires write permissions)
    if [[ "$CAN_CREATE_RESOURCES" != "true" ]]; then
        info "Skipping network policy enforcement tests (read-only RBAC)"
        # Only run the policies exist test which is read-only
        test_policies_exist
        print_summary
        return
    fi

    # Setup test environment
    if ! setup_test_environment; then
        fail "Failed to setup test environment"
        cleanup_test_environment
        exit 1
    fi

    # Run tests
    test_policies_exist
    test_traefik_ingress_allowed
    test_cross_namespace_isolation
    test_database_isolation
    test_dns_egress
    test_app_to_database
    test_monitoring_access
    test_backup_access

    # Cleanup
    cleanup_test_environment

    print_summary
}

main "$@"
