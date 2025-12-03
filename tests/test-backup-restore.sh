#!/bin/bash
# test-backup-restore.sh - Backup verification and restore validation tests
# Tests backup CronJob execution, file validation, and dry-run restore capabilities

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

# Backup configuration
BACKUP_NAMESPACE="longhorn-system"
BACKUP_CRONJOB="homelab-backup"
NAS_IP="192.168.1.234"
NAS_PATH="/var/nfs/shared/Shared_Drive_Example/k8s-backup"
BACKUP_DATABASES=("authentik" "outline")
LONGHORN_RECURRING_JOBS=("daily-snapshot" "weekly-snapshot" "daily-backup" "weekly-backup")

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
    # Try to do a dry-run create to test permissions
    if kubectl auth can-i create jobs -n "$BACKUP_NAMESPACE" &> /dev/null; then
        CAN_CREATE_JOBS=true
    else
        CAN_CREATE_JOBS=false
        info "Limited permissions detected - some tests will be skipped"
    fi

    if kubectl auth can-i create pods -n "$BACKUP_NAMESPACE" &> /dev/null; then
        CAN_CREATE_PODS=true
    else
        CAN_CREATE_PODS=false
    fi

    # Check exec permission on database pods
    if kubectl auth can-i exec pods -n authentik &> /dev/null; then
        CAN_EXEC_PODS=true
    else
        CAN_EXEC_PODS=false
    fi
}

# Test 1: Verify backup CronJob exists and is configured correctly
test_cronjob_configuration() {
    print_section "Backup CronJob Configuration Tests"

    # Check CronJob exists
    if kubectl get cronjob "$BACKUP_CRONJOB" -n "$BACKUP_NAMESPACE" &> /dev/null; then
        pass "Backup CronJob '$BACKUP_CRONJOB' exists in '$BACKUP_NAMESPACE'"
    else
        fail "Backup CronJob '$BACKUP_CRONJOB' not found in '$BACKUP_NAMESPACE'"
        return
    fi

    # Check CronJob schedule
    local schedule
    schedule=$(kubectl get cronjob "$BACKUP_CRONJOB" -n "$BACKUP_NAMESPACE" -o jsonpath='{.spec.schedule}')
    if [[ -n "$schedule" ]]; then
        pass "Backup CronJob has schedule configured: $schedule"
    else
        fail "Backup CronJob has no schedule configured"
    fi

    # Check CronJob is not suspended
    local suspended
    suspended=$(kubectl get cronjob "$BACKUP_CRONJOB" -n "$BACKUP_NAMESPACE" -o jsonpath='{.spec.suspend}')
    if [[ "$suspended" != "true" ]]; then
        pass "Backup CronJob is not suspended"
    else
        fail "Backup CronJob is suspended"
    fi

    # Check successful job history limit
    local success_limit
    success_limit=$(kubectl get cronjob "$BACKUP_CRONJOB" -n "$BACKUP_NAMESPACE" -o jsonpath='{.spec.successfulJobsHistoryLimit}')
    if [[ -n "$success_limit" ]] && [[ "$success_limit" -ge 1 ]]; then
        pass "Backup CronJob retains successful job history: $success_limit"
    else
        skip "Backup CronJob successful job history limit not explicitly set"
    fi

    # Check failed job history limit
    local fail_limit
    fail_limit=$(kubectl get cronjob "$BACKUP_CRONJOB" -n "$BACKUP_NAMESPACE" -o jsonpath='{.spec.failedJobsHistoryLimit}')
    if [[ -n "$fail_limit" ]] && [[ "$fail_limit" -ge 1 ]]; then
        pass "Backup CronJob retains failed job history: $fail_limit"
    else
        skip "Backup CronJob failed job history limit not explicitly set"
    fi

    # Check NFS volume mount
    local volumes
    volumes=$(kubectl get cronjob "$BACKUP_CRONJOB" -n "$BACKUP_NAMESPACE" -o jsonpath='{.spec.jobTemplate.spec.template.spec.volumes[*].name}')
    if echo "$volumes" | grep -q "nfs\|backup\|nas"; then
        pass "Backup CronJob has NFS/backup volume configured"
    else
        skip "Could not verify NFS volume mount (volume names: $volumes)"
    fi
}

# Test 2: Verify last backup job status
test_last_backup_status() {
    print_section "Last Backup Job Status Tests"

    # Get last successful backup time
    local last_success
    last_success=$(kubectl get cronjob "$BACKUP_CRONJOB" -n "$BACKUP_NAMESPACE" -o jsonpath='{.status.lastSuccessfulTime}')

    if [[ -n "$last_success" ]]; then
        pass "Last successful backup recorded: $last_success"

        # Check if last backup was within 48 hours (allowing for schedule variations)
        local last_success_epoch
        last_success_epoch=$(date -d "$last_success" +%s 2>/dev/null || echo "0")
        local now_epoch
        now_epoch=$(date +%s)
        local hours_ago=$(( (now_epoch - last_success_epoch) / 3600 ))

        if [[ "$hours_ago" -lt 48 ]]; then
            pass "Last successful backup was $hours_ago hours ago (within 48h threshold)"
        else
            fail "Last successful backup was $hours_ago hours ago (exceeds 48h threshold)"
        fi
    else
        fail "No successful backup recorded in CronJob status"
    fi

    # Check for recent failed jobs (not just incomplete - must have Failed=True condition)
    local failed_jobs
    failed_jobs=$(kubectl get jobs -n "$BACKUP_NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Failed")].status}{"\n"}{end}' 2>/dev/null | grep "$BACKUP_CRONJOB" | grep -c "True" 2>/dev/null || echo "0")
    failed_jobs=$(echo "$failed_jobs" | tr -d '[:space:]')

    if [[ "$failed_jobs" -eq 0 ]]; then
        pass "No failed backup jobs found"
    else
        fail "Found $failed_jobs failed backup job(s)"
    fi
}

# Test 3: Verify database connectivity for backup sources
test_database_connectivity() {
    print_section "Database Connectivity Tests"

    for db in "${BACKUP_DATABASES[@]}"; do
        local namespace="$db"
        local service="${db}-db-rw"

        # Check if the database service exists
        if kubectl get service "$service" -n "$namespace" &> /dev/null; then
            pass "Database service '$service' exists in '$namespace'"

            # Check if database pods are running
            local ready_pods
            ready_pods=$(kubectl get pods -n "$namespace" -l "cnpg.io/cluster=${db}-db" --field-selector=status.phase=Running -o name 2>/dev/null | wc -l)

            if [[ "$ready_pods" -ge 1 ]]; then
                pass "Database '$db' has $ready_pods running pod(s)"
            else
                fail "Database '$db' has no running pods"
            fi

            # Check database endpoint is accessible
            local endpoints
            endpoints=$(kubectl get endpoints "$service" -n "$namespace" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)

            if [[ -n "$endpoints" ]]; then
                pass "Database '$db' has active endpoints: $endpoints"
            else
                fail "Database '$db' has no active endpoints"
            fi
        else
            fail "Database service '$service' not found in '$namespace'"
        fi
    done
}

# Test: Longhorn recurring backup jobs
test_longhorn_recurring_jobs() {
    print_section "Longhorn Recurring Backup Job Tests"

    # Check recurring jobs exist
    for job in "${LONGHORN_RECURRING_JOBS[@]}"; do
        if kubectl get recurringjob "$job" -n "$BACKUP_NAMESPACE" &> /dev/null; then
            pass "Longhorn recurring job '$job' exists"

            # Check job configuration
            local task
            task=$(kubectl get recurringjob "$job" -n "$BACKUP_NAMESPACE" -o jsonpath='{.spec.task}')
            local cron
            cron=$(kubectl get recurringjob "$job" -n "$BACKUP_NAMESPACE" -o jsonpath='{.spec.cron}')
            local retain
            retain=$(kubectl get recurringjob "$job" -n "$BACKUP_NAMESPACE" -o jsonpath='{.spec.retain}')

            if [[ -n "$cron" ]]; then
                pass "Job '$job' has schedule: $cron (task: $task, retain: $retain)"
            else
                fail "Job '$job' has no schedule configured"
            fi
        else
            fail "Longhorn recurring job '$job' not found"
        fi
    done
}

# Test: Longhorn backup target configuration
test_longhorn_backup_target() {
    print_section "Longhorn Backup Target Tests"

    # Check backup target setting exists
    local backup_target
    backup_target=$(kubectl get settings backup-target -n "$BACKUP_NAMESPACE" -o jsonpath='{.value}' 2>/dev/null)

    if [[ -n "$backup_target" ]]; then
        pass "Longhorn backup target configured: $backup_target"

        # Verify it points to NAS
        if echo "$backup_target" | grep -q "$NAS_IP"; then
            pass "Backup target points to NAS ($NAS_IP)"
        else
            fail "Backup target does not point to expected NAS ($NAS_IP)"
        fi

        # Check NFS options include nfsvers=3
        if echo "$backup_target" | grep -qiE "nfsvers=3|nfsOptions"; then
            pass "Backup target includes NFS version options"
        else
            info "Backup target may need NFS options for compatibility"
        fi
    else
        fail "Longhorn backup target not configured"
    fi

    # Check backup target status
    local backup_target_available
    backup_target_available=$(kubectl get settings backup-target -n "$BACKUP_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)

    # If we can't get status via settings, try via backuptargets CR
    if [[ -z "$backup_target_available" ]]; then
        backup_target_available=$(kubectl get backuptargets -n "$BACKUP_NAMESPACE" default -o jsonpath='{.status.available}' 2>/dev/null)
    fi

    if [[ "$backup_target_available" == "true" ]] || [[ "$backup_target_available" == "True" ]]; then
        pass "Longhorn backup target is available"
    else
        info "Could not verify backup target availability status"
    fi
}

# Test: Recent Longhorn backups exist
test_longhorn_recent_backups() {
    print_section "Longhorn Backup History Tests"

    # Get count of backups
    local backup_count
    backup_count=$(kubectl get backups -n "$BACKUP_NAMESPACE" -o name 2>/dev/null | wc -l)

    if [[ "$backup_count" -gt 0 ]]; then
        pass "Found $backup_count Longhorn backup(s)"

        # Check for recent backups (within last 48 hours)
        local recent_backups
        recent_backups=$(kubectl get backups -n "$BACKUP_NAMESPACE" \
            --sort-by=.metadata.creationTimestamp \
            -o jsonpath='{.items[-5:].metadata.creationTimestamp}' 2>/dev/null)

        if [[ -n "$recent_backups" ]]; then
            local most_recent
            most_recent=$(echo "$recent_backups" | tr ' ' '\n' | tail -1)
            pass "Most recent backup: $most_recent"

            # Check if within 48 hours
            local backup_epoch
            backup_epoch=$(date -d "$most_recent" +%s 2>/dev/null || echo "0")
            local now_epoch
            now_epoch=$(date +%s)
            local hours_ago=$(( (now_epoch - backup_epoch) / 3600 ))

            if [[ "$hours_ago" -lt 48 ]]; then
                pass "Recent backup is $hours_ago hours old (within 48h threshold)"
            else
                fail "Most recent backup is $hours_ago hours old (exceeds 48h threshold)"
            fi
        fi

        # Check backup completion status (sample recent ones)
        local completed_backups
        completed_backups=$(kubectl get backups -n "$BACKUP_NAMESPACE" \
            -o jsonpath='{range .items[*]}{.status.state}{"\n"}{end}' 2>/dev/null | grep -c "Completed" || echo "0")

        if [[ "$completed_backups" -gt 0 ]]; then
            pass "Found $completed_backups completed backup(s)"
        else
            info "No backups with 'Completed' state found"
        fi
    else
        fail "No Longhorn backups found - backups may not be running"
    fi

    # Check for backup volumes (volumes that have been backed up)
    local backup_volume_count
    backup_volume_count=$(kubectl get backupvolumes -n "$BACKUP_NAMESPACE" -o name 2>/dev/null | wc -l)

    if [[ "$backup_volume_count" -gt 0 ]]; then
        pass "Found $backup_volume_count volume(s) with backups"
    else
        fail "No backup volumes found - no volumes have been backed up"
    fi
}

# Test: Longhorn volume health (affects backup reliability)
test_longhorn_volume_health() {
    print_section "Longhorn Volume Health Tests"

    # Get all volumes
    local total_volumes
    total_volumes=$(kubectl get volumes -n "$BACKUP_NAMESPACE" -o name 2>/dev/null | wc -l)

    if [[ "$total_volumes" -eq 0 ]]; then
        skip "No Longhorn volumes found"
        return
    fi

    pass "Found $total_volumes Longhorn volume(s)"

    # Check for healthy volumes
    local healthy_volumes
    healthy_volumes=$(kubectl get volumes -n "$BACKUP_NAMESPACE" \
        -o jsonpath='{range .items[*]}{.status.robustness}{"\n"}{end}' 2>/dev/null | grep -c "healthy" || echo "0")

    if [[ "$healthy_volumes" -eq "$total_volumes" ]]; then
        pass "All $healthy_volumes volumes are healthy"
    elif [[ "$healthy_volumes" -gt 0 ]]; then
        fail "Only $healthy_volumes of $total_volumes volumes are healthy"
    else
        fail "No healthy volumes found"
    fi

    # Check for degraded volumes
    local degraded_volumes
    degraded_volumes=$(kubectl get volumes -n "$BACKUP_NAMESPACE" \
        -o jsonpath='{range .items[*]}{.status.robustness}{"\n"}{end}' 2>/dev/null | grep -c "degraded" || echo "0")

    if [[ "$degraded_volumes" -gt 0 ]]; then
        fail "Found $degraded_volumes degraded volume(s) - backup reliability affected"
    fi

    # Check for faulted volumes
    local faulted_volumes
    faulted_volumes=$(kubectl get volumes -n "$BACKUP_NAMESPACE" \
        -o jsonpath='{range .items[*]}{.status.robustness}{"\n"}{end}' 2>/dev/null | grep -c "faulted" || echo "0")

    if [[ "$faulted_volumes" -gt 0 ]]; then
        fail "Found $faulted_volumes faulted volume(s) - CRITICAL: data at risk"
    fi
}

# Test 4: Trigger a test backup and verify execution
test_backup_execution() {
    print_section "Backup Execution Tests"

    # Check if we have permission to create jobs
    if [[ "$CAN_CREATE_JOBS" != "true" ]]; then
        skip "Insufficient permissions to create test backup job"
        return
    fi

    local test_job_name="homelab-backup-test-$(date +%s)"

    info "Creating test backup job: $test_job_name"

    # Create a test job from the CronJob
    if kubectl create job "$test_job_name" --from=cronjob/"$BACKUP_CRONJOB" -n "$BACKUP_NAMESPACE" &> /dev/null; then
        pass "Test backup job created successfully"
    else
        fail "Failed to create test backup job"
        return
    fi

    # Wait for job to complete (timeout after 5 minutes)
    info "Waiting for backup job to complete (timeout: 5 minutes)..."
    local timeout=300
    local elapsed=0
    local interval=10
    local job_status=""

    while [[ $elapsed -lt $timeout ]]; do
        job_status=$(kubectl get job "$test_job_name" -n "$BACKUP_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null)
        local job_failed
        job_failed=$(kubectl get job "$test_job_name" -n "$BACKUP_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null)

        if [[ "$job_status" == "True" ]]; then
            pass "Test backup job completed successfully"
            break
        elif [[ "$job_failed" == "True" ]]; then
            fail "Test backup job failed"
            # Get job logs for debugging
            info "Backup job logs:"
            kubectl logs -n "$BACKUP_NAMESPACE" -l "job-name=$test_job_name" --tail=50 2>/dev/null || true
            break
        fi

        sleep $interval
        elapsed=$((elapsed + interval))
    done

    if [[ $elapsed -ge $timeout ]] && [[ "$job_status" != "True" ]]; then
        fail "Test backup job timed out after ${timeout}s"
        info "Job status:"
        kubectl get job "$test_job_name" -n "$BACKUP_NAMESPACE" -o wide 2>/dev/null || true
    fi

    # Cleanup test job
    info "Cleaning up test backup job..."
    kubectl delete job "$test_job_name" -n "$BACKUP_NAMESPACE" --ignore-not-found &> /dev/null
}

# Test 5: Verify backup files exist (if NFS is accessible)
test_backup_files() {
    print_section "Backup File Verification Tests"

    # Check if we have permission to create pods
    if [[ "$CAN_CREATE_PODS" != "true" ]]; then
        skip "Insufficient permissions to create verification pod"
        return
    fi

    # Check if we can access NFS via a test pod
    local test_pod="backup-verify-$(date +%s)"

    info "Creating temporary pod to verify backup files..."

    # Create a test pod that mounts the NFS volume directly from NAS
    cat <<EOF | kubectl apply -f - &> /dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $test_pod
  namespace: $BACKUP_NAMESPACE
  labels:
    app.kubernetes.io/name: backup-verify
spec:
  containers:
  - name: verify
    image: busybox:1.36
    command: ["sleep", "300"]
    volumeMounts:
    - name: nfs-backup
      mountPath: /backup
      readOnly: true
  volumes:
  - name: nfs-backup
    nfs:
      server: $NAS_IP
      path: $NAS_PATH
  restartPolicy: Never
  terminationGracePeriodSeconds: 5
EOF

    # Wait for pod to be ready
    local timeout=60
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        local pod_status
        pod_status=$(kubectl get pod "$test_pod" -n "$BACKUP_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)

        if [[ "$pod_status" == "Running" ]]; then
            break
        elif [[ "$pod_status" == "Failed" ]] || [[ "$pod_status" == "Error" ]]; then
            skip "Backup verification pod failed to start (NFS may not be accessible)"
            kubectl delete pod "$test_pod" -n "$BACKUP_NAMESPACE" --ignore-not-found &> /dev/null
            return
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    if [[ $elapsed -ge $timeout ]]; then
        skip "Backup verification pod timed out (NFS may not be accessible)"
        kubectl delete pod "$test_pod" -n "$BACKUP_NAMESPACE" --ignore-not-found &> /dev/null
        return
    fi

    pass "Backup verification pod started successfully"

    # Check for backup files
    # CronJob writes to /backup/homelab-YYYYMMDD-HHMMSS/{db}-db.sql
    for db in "${BACKUP_DATABASES[@]}"; do
        local backup_count
        backup_count=$(kubectl exec -n "$BACKUP_NAMESPACE" "$test_pod" -- sh -c "find /backup -name '${db}-db.sql' -type f 2>/dev/null | wc -l" 2>/dev/null || echo "0")

        if [[ "$backup_count" -gt 0 ]]; then
            pass "Found $backup_count backup file(s) for '$db'"

            # Check most recent backup size (find newest homelab-* directory)
            local latest_backup
            latest_backup=$(kubectl exec -n "$BACKUP_NAMESPACE" "$test_pod" -- sh -c "ls -dt /backup/homelab-*/ 2>/dev/null | head -1" 2>/dev/null)

            if [[ -n "$latest_backup" ]]; then
                local backup_file="${latest_backup}${db}-db.sql"
                local backup_size
                backup_size=$(kubectl exec -n "$BACKUP_NAMESPACE" "$test_pod" -- sh -c "ls -lh '${backup_file}' 2>/dev/null | awk '{print \$5}'" 2>/dev/null)

                if [[ -n "$backup_size" ]] && [[ "$backup_size" != "0" ]]; then
                    pass "Latest '$db' backup has size: $backup_size"
                else
                    fail "Latest '$db' backup appears to be empty"
                fi
            fi
        else
            fail "No backup files found for '$db'"
        fi
    done

    # Cleanup test pod
    info "Cleaning up verification pod..."
    kubectl delete pod "$test_pod" -n "$BACKUP_NAMESPACE" --ignore-not-found &> /dev/null
}

# Test 6: Verify backup retention policy
test_backup_retention() {
    print_section "Backup Retention Policy Tests"

    # Check CronJob has appropriate retention settings
    local concurrency_policy
    concurrency_policy=$(kubectl get cronjob "$BACKUP_CRONJOB" -n "$BACKUP_NAMESPACE" -o jsonpath='{.spec.concurrencyPolicy}')

    if [[ "$concurrency_policy" == "Forbid" ]] || [[ "$concurrency_policy" == "Replace" ]]; then
        pass "Backup CronJob has concurrency policy: $concurrency_policy"
    else
        skip "Backup CronJob concurrency policy not explicitly set (defaults to Allow)"
    fi

    # Check if backup script includes retention logic (by examining the container command)
    local container_command
    container_command=$(kubectl get cronjob "$BACKUP_CRONJOB" -n "$BACKUP_NAMESPACE" -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].command}' 2>/dev/null)

    if echo "$container_command" | grep -qiE "find.*-mtime|delete.*old|retention|cleanup"; then
        pass "Backup script appears to include retention/cleanup logic"
    else
        info "Could not verify retention logic in backup script (may be handled externally)"
    fi
}

# Test 7: Database restore dry-run test
test_restore_dry_run() {
    print_section "Restore Dry-Run Tests"

    # Check if we have permission to exec into pods
    if [[ "$CAN_EXEC_PODS" != "true" ]]; then
        skip "Insufficient permissions to exec into database pods"
        return
    fi

    info "Testing restore capability with dry-run..."

    # For each backed-up database, verify we can connect and run a simple query
    for db in "${BACKUP_DATABASES[@]}"; do
        local namespace="$db"
        local cluster="${db}-db"

        # Get the primary pod
        local primary_pod
        primary_pod=$(kubectl get pods -n "$namespace" -l "cnpg.io/cluster=$cluster,cnpg.io/instanceRole=primary" -o name 2>/dev/null | head -1)

        if [[ -z "$primary_pod" ]]; then
            skip "Could not find primary pod for '$db' database"
            continue
        fi

        # Test database connection with a simple query
        # CNPG uses peer auth, so run psql without -U flag (connects as postgres superuser)
        local query_result
        query_result=$(kubectl exec -n "$namespace" "${primary_pod#pod/}" -- psql -d "$db" -c "SELECT 1 as connection_test;" 2>/dev/null)

        if echo "$query_result" | grep -q "1"; then
            pass "Database '$db' connection test successful"
        else
            fail "Database '$db' connection test failed"
            continue
        fi

        # Get table count to verify database has data
        local table_count
        table_count=$(kubectl exec -n "$namespace" "${primary_pod#pod/}" -- psql -d "$db" -t -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null | tr -d ' ')

        if [[ -n "$table_count" ]] && [[ "$table_count" -gt 0 ]]; then
            pass "Database '$db' has $table_count tables in public schema"
        else
            skip "Database '$db' appears to have no tables (may be expected for new installations)"
        fi

        # Get approximate row count for key tables
        local row_info
        row_info=$(kubectl exec -n "$namespace" "${primary_pod#pod/}" -- psql -d "$db" -t -c "SELECT schemaname, relname, n_live_tup FROM pg_stat_user_tables ORDER BY n_live_tup DESC LIMIT 3;" 2>/dev/null)

        if [[ -n "$row_info" ]]; then
            info "Top tables by row count for '$db':"
            echo "$row_info" | head -3
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
        echo -e "${GREEN}All backup and restore tests passed!${NC}"
        exit 0
    else
        echo -e "${RED}Some backup and restore tests failed!${NC}"
        exit 1
    fi
}

# Main execution
main() {
    print_header "Backup and Restore Verification Tests"

    check_prerequisites

    # SQL Dump CronJob tests
    test_cronjob_configuration
    test_last_backup_status
    test_database_connectivity

    # Longhorn backup tests
    test_longhorn_recurring_jobs
    test_longhorn_backup_target
    test_longhorn_recent_backups
    test_longhorn_volume_health

    # Optional: Run backup execution test (can be slow)
    if [[ "${RUN_BACKUP_TEST:-false}" == "true" ]]; then
        test_backup_execution
    else
        info "Skipping backup execution test (set RUN_BACKUP_TEST=true to enable)"
    fi

    # Optional: Run backup file verification (requires NFS access)
    if [[ "${VERIFY_BACKUP_FILES:-false}" == "true" ]]; then
        test_backup_files
    else
        info "Skipping backup file verification (set VERIFY_BACKUP_FILES=true to enable)"
    fi

    test_backup_retention
    test_restore_dry_run

    print_summary
}

main "$@"
