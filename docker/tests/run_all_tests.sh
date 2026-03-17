#!/bin/bash
# run_all_tests.sh - Run all efm_extension tests
#
# Usage: ./run_all_tests.sh
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((PASS_COUNT++))
    ((TOTAL_COUNT++))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((FAIL_COUNT++))
    ((TOTAL_COUNT++))
}

log_info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

# Wait for PostgreSQL to be ready
wait_for_postgres() {
    log_info "Waiting for PostgreSQL to be ready..."
    for i in {1..30}; do
        if pg_isready -U postgres > /dev/null 2>&1; then
            log_info "PostgreSQL is ready"
            return 0
        fi
        sleep 1
    done
    log_fail "PostgreSQL did not become ready in time"
    exit 1
}

# Run SQL and check result
run_sql() {
    local sql="$1"
    psql -U postgres -d testdb -t -A -c "$sql" 2>&1
}

run_sql_expect_success() {
    local test_name="$1"
    local sql="$2"

    if output=$(run_sql "$sql" 2>&1); then
        log_pass "$test_name"
        echo "$output"
        return 0
    else
        log_fail "$test_name: $output"
        return 1
    fi
}

run_sql_expect_error() {
    local test_name="$1"
    local sql="$2"
    local expected_error="$3"

    if output=$(run_sql "$sql" 2>&1); then
        log_fail "$test_name: Expected error but got success"
        return 1
    else
        if [[ "$output" == *"$expected_error"* ]]; then
            log_pass "$test_name"
            return 0
        else
            log_fail "$test_name: Expected '$expected_error' but got '$output'"
            return 1
        fi
    fi
}

echo "========================================"
echo "  EFM Extension Test Suite"
echo "========================================"
echo ""

wait_for_postgres

# Setup: Create extension
log_info "Setting up test environment..."
run_sql "DROP EXTENSION IF EXISTS efm_extension CASCADE;"
run_sql "CREATE EXTENSION efm_extension;"

echo ""
echo "========================================"
echo "  Test 1: Extension Installation"
echo "========================================"

run_sql_expect_success "Extension created successfully" \
    "SELECT extname, extversion FROM pg_extension WHERE extname = 'efm_extension';"

echo ""
echo "========================================"
echo "  Test 2: Basic Function Availability"
echo "========================================"

run_sql_expect_success "efm_cluster_status function exists" \
    "SELECT proname FROM pg_proc WHERE proname = 'efm_cluster_status';"

run_sql_expect_success "efm_cluster_status_json function exists" \
    "SELECT proname FROM pg_proc WHERE proname = 'efm_cluster_status_json';"

run_sql_expect_success "efm_get_nodes function exists" \
    "SELECT proname FROM pg_proc WHERE proname = 'efm_get_nodes';"

run_sql_expect_success "efm_is_available function exists" \
    "SELECT proname FROM pg_proc WHERE proname = 'efm_is_available';"

echo ""
echo "========================================"
echo "  Test 3: EFM Availability Check"
echo "========================================"

run_sql_expect_success "efm_is_available returns result" \
    "SELECT is_available, error_code, error_message FROM efm_extension.efm_is_available();"

echo ""
echo "========================================"
echo "  Test 4: Cluster Status (Text)"
echo "========================================"

run_sql_expect_success "efm_cluster_status(text) works" \
    "SELECT efm_extension.efm_cluster_status('text') LIMIT 5;"

echo ""
echo "========================================"
echo "  Test 5: Cluster Status (JSON)"
echo "========================================"

run_sql_expect_success "efm_cluster_status_json returns valid JSONB" \
    "SELECT jsonb_typeof(efm_extension.efm_cluster_status_json());"

run_sql_expect_success "efm_cluster_status_json contains nodes" \
    "SELECT efm_extension.efm_cluster_status_json() ? 'nodes';"

echo ""
echo "========================================"
echo "  Test 6: Structured Node Data"
echo "========================================"

run_sql_expect_success "efm_get_nodes returns structured data" \
    "SELECT node_ip, node_type, agent_status FROM efm_extension.efm_get_nodes();"

run_sql_expect_success "efm_nodes_details view works" \
    "SELECT node_ip, role, agent_status FROM efm_extension.efm_nodes_details;"

echo ""
echo "========================================"
echo "  Test 7: Input Validation"
echo "========================================"

run_sql_expect_error "Invalid IP rejected (allow_node)" \
    "SELECT efm_extension.efm_allow_node('not-an-ip');" \
    "invalid IP address"

run_sql_expect_error "Invalid IP rejected (disallow_node)" \
    "SELECT efm_extension.efm_disallow_node('999.999.999.999');" \
    "invalid IP address"

run_sql_expect_error "Invalid priority rejected" \
    "SELECT efm_extension.efm_set_priority('172.17.0.2', 'abc');" \
    "invalid priority"

run_sql_expect_error "Priority out of range rejected" \
    "SELECT efm_extension.efm_set_priority('172.17.0.2', '1000');" \
    "invalid priority"

echo ""
echo "========================================"
echo "  Test 8: Cache Functions"
echo "========================================"

run_sql_expect_success "efm_cache_stats returns data" \
    "SELECT cache_hits, cache_misses, cache_ttl_seconds FROM efm_extension.efm_cache_stats();"

run_sql_expect_success "efm_invalidate_cache works" \
    "SELECT efm_extension.efm_invalidate_cache();"

echo ""
echo "========================================"
echo "  Test 9: Properties File"
echo "========================================"

run_sql_expect_success "efm_list_properties returns data" \
    "SELECT efm_extension.efm_list_properties() LIMIT 3;"

run_sql_expect_success "efm_local_properties view works" \
    "SELECT name, value FROM efm_extension.efm_local_properties LIMIT 3;"

echo ""
echo "========================================"
echo "  Test 10: Security (Non-superuser)"
echo "========================================"

run_sql "CREATE USER test_user WITH PASSWORD 'test';" || true

run_sql_expect_error "Non-superuser cannot call efm_cluster_status" \
    "SET ROLE test_user; SELECT efm_extension.efm_cluster_status('text');" \
    "permission denied"

run_sql "RESET ROLE;"

echo ""
echo "========================================"
echo "  Test 11: Metrics View"
echo "========================================"

run_sql_expect_success "efm_metrics view returns data" \
    "SELECT metric_name, value FROM efm_extension.efm_metrics LIMIT 5;"

echo ""
echo "========================================"
echo "  Test 12: Zabbix Discovery"
echo "========================================"

run_sql_expect_success "zabbix_node_discovery returns valid JSON" \
    "SELECT jsonb_typeof(efm_extension.zabbix_node_discovery());"

run_sql_expect_success "zabbix_node_discovery has data key" \
    "SELECT efm_extension.zabbix_node_discovery() ? 'data';"

echo ""
echo "========================================"
echo "  Test Summary"
echo "========================================"
echo ""
echo -e "Total:  ${TOTAL_COUNT}"
echo -e "Passed: ${GREEN}${PASS_COUNT}${NC}"
echo -e "Failed: ${RED}${FAIL_COUNT}${NC}"
echo ""

if [ $FAIL_COUNT -gt 0 ]; then
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
else
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
fi
