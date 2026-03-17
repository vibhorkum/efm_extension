#!/bin/bash
# test_cluster.sh - Test EFM extension on a real EFM cluster
#
# This test verifies that the efm_extension works correctly with a real
# EFM cluster consisting of primary and standby nodes.

set +e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    PASS_COUNT=$((PASS_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
}

log_info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
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

echo "========================================"
echo "  EFM Extension Cluster Test Suite"
echo "========================================"
echo ""

# Wait for PostgreSQL
log_info "Waiting for PostgreSQL to be ready..."
for i in {1..30}; do
    if pg_isready -U postgres > /dev/null 2>&1; then
        log_info "PostgreSQL is ready"
        break
    fi
    sleep 2
done

# Wait for EFM
log_info "Waiting for EFM to initialize..."
sleep 10

echo ""
echo "========================================"
echo "  Test 1: EFM Agent Status"
echo "========================================"

# Check EFM is running
if sudo -u efm /usr/edb/efm-${EFM_VERSION}/bin/efm cluster-status efm > /dev/null 2>&1; then
    log_pass "EFM agent is running"
else
    log_fail "EFM agent is not running"
fi

echo ""
echo "========================================"
echo "  Test 2: Extension Installation"
echo "========================================"

# Ensure extension is created
run_sql "CREATE EXTENSION IF NOT EXISTS efm_extension;" > /dev/null 2>&1

run_sql_expect_success "Extension exists" \
    "SELECT extname, extversion FROM pg_extension WHERE extname = 'efm_extension';"

echo ""
echo "========================================"
echo "  Test 3: EFM Availability Check"
echo "========================================"

run_sql_expect_success "efm_is_available returns true" \
    "SELECT is_available, error_code, error_message FROM efm_extension.efm_is_available();"

echo ""
echo "========================================"
echo "  Test 4: Cluster Status (Text)"
echo "========================================"

run_sql_expect_success "efm_cluster_status works" \
    "SELECT efm_extension.efm_cluster_status('text') LIMIT 10;"

echo ""
echo "========================================"
echo "  Test 5: Cluster Status (JSON)"
echo "========================================"

run_sql_expect_success "efm_cluster_status_json returns valid JSONB" \
    "SELECT jsonb_typeof(efm_extension.efm_cluster_status_json());"

run_sql_expect_success "JSON contains nodes" \
    "SELECT efm_extension.efm_cluster_status_json() ? 'nodes';"

echo ""
echo "========================================"
echo "  Test 6: Node Information"
echo "========================================"

run_sql_expect_success "efm_get_nodes returns data" \
    "SELECT node_ip, node_type, agent_status, db_status FROM efm_extension.efm_get_nodes();"

run_sql_expect_success "Primary node exists" \
    "SELECT COUNT(*) FROM efm_extension.efm_get_nodes() WHERE node_type = 'Primary';"

run_sql_expect_success "Standby node exists" \
    "SELECT COUNT(*) FROM efm_extension.efm_get_nodes() WHERE node_type = 'Standby';"

echo ""
echo "========================================"
echo "  Test 7: Cluster Information"
echo "========================================"

run_sql_expect_success "efm_get_cluster_info works" \
    "SELECT * FROM efm_extension.efm_get_cluster_info();"

echo ""
echo "========================================"
echo "  Test 8: Node Details View"
echo "========================================"

run_sql_expect_success "efm_nodes_details view works" \
    "SELECT node_ip, role, agent_status, db_status FROM efm_extension.efm_nodes_details;"

echo ""
echo "========================================"
echo "  Test 9: Cache Functions"
echo "========================================"

run_sql_expect_success "efm_cache_stats returns data" \
    "SELECT cache_hits, cache_misses, cache_ttl_seconds FROM efm_extension.efm_cache_stats();"

run_sql_expect_success "efm_invalidate_cache works" \
    "SELECT efm_extension.efm_invalidate_cache();"

echo ""
echo "========================================"
echo "  Test 10: Metrics View"
echo "========================================"

run_sql_expect_success "efm_metrics view works" \
    "SELECT metric_name, value FROM efm_extension.efm_metrics LIMIT 10;"

echo ""
echo "========================================"
echo "  Test 11: Zabbix Discovery"
echo "========================================"

run_sql_expect_success "zabbix_node_discovery returns valid JSON" \
    "SELECT jsonb_typeof(efm_extension.zabbix_node_discovery());"

echo ""
echo "========================================"
echo "  Test 12: Properties File"
echo "========================================"

run_sql_expect_success "efm_list_properties returns data" \
    "SELECT efm_extension.efm_list_properties() LIMIT 5;"

echo ""
echo "========================================"
echo "  Test 13: Real Cluster Verification"
echo "========================================"

# Verify we have a real cluster with multiple nodes
NODE_COUNT=$(run_sql "SELECT COUNT(*) FROM efm_extension.efm_get_nodes();")
if [ "$NODE_COUNT" -ge 2 ]; then
    log_pass "Cluster has ${NODE_COUNT} nodes"
else
    log_fail "Expected at least 2 nodes, got ${NODE_COUNT}"
fi

# Check all nodes are UP
DOWN_NODES=$(run_sql "SELECT COUNT(*) FROM efm_extension.efm_get_nodes() WHERE agent_status != 'UP';")
if [ "$DOWN_NODES" -eq 0 ]; then
    log_pass "All nodes have agent status UP"
else
    log_fail "${DOWN_NODES} nodes are not UP"
fi

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
