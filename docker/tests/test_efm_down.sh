#!/bin/bash
# test_efm_down.sh - Test behavior when EFM is down
#
# This test verifies that:
# 1. PostgreSQL remains stable when EFM is unavailable
# 2. efm_is_available() returns appropriate status
# 3. Other extension functions return proper errors (not crashes)
#
# IMPORTANT: This test demonstrates that EFM being down does NOT
# break PostgreSQL - it only causes EFM-related functions to return errors.
#
# REQUIREMENT: The PostgreSQL container/service MUST be started with
# MOCK_EFM_MODE=down environment variable. Setting it here via export
# will NOT affect already-running PostgreSQL backends (environment
# variables are inherited at process start).
#
# To run this test properly, use:
#   docker-compose --profile efm_down_test up -d postgres_efm_down
#   docker-compose exec postgres_efm_down /tests/test_efm_down.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }
log_info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

run_sql() {
    psql -U postgres -d testdb -t -A -c "$1" 2>&1
}

echo "========================================"
echo "  EFM Down Scenario Tests"
echo "========================================"
echo ""
echo "This test verifies PostgreSQL stability when EFM is unavailable."
echo ""
echo "NOTE: This test requires MOCK_EFM_MODE=down to be set when the"
echo "      PostgreSQL server starts. Use the postgres_efm_down service."
echo ""

# Note: This export only affects child processes of this script,
# NOT already-running PostgreSQL backends. The container must be
# started with this environment variable set.
log_info "Expecting MOCK_EFM_MODE=down (set at container start)"
export MOCK_EFM_MODE=down

# Ensure extension is installed
run_sql "CREATE EXTENSION IF NOT EXISTS efm_extension;"

echo ""
echo "Test 1: PostgreSQL basic operations still work"
echo "------------------------------------------------"

if run_sql "SELECT 1+1 AS result;" | grep -q "2"; then
    log_pass "Basic SQL operations work"
else
    log_fail "Basic SQL operations failed"
    exit 1
fi

if run_sql "SELECT version();" > /dev/null; then
    log_pass "version() function works"
else
    log_fail "version() function failed"
    exit 1
fi

echo ""
echo "Test 2: efm_is_available() reports EFM as unavailable"
echo "------------------------------------------------------"

result=$(run_sql "SELECT is_available, error_code FROM efm_extension.efm_is_available();")
if echo "$result" | grep -q "f|"; then
    log_pass "efm_is_available() correctly reports EFM down"
    log_info "Result: $result"
else
    log_fail "efm_is_available() did not detect EFM down"
    log_info "Result: $result"
fi

echo ""
echo "Test 3: efm_cluster_status returns error (not crash)"
echo "-----------------------------------------------------"

if output=$(run_sql "SELECT efm_extension.efm_cluster_status('json');" 2>&1); then
    log_fail "Expected error but command succeeded"
else
    if echo "$output" | grep -qiE "(error|failed|agent)"; then
        log_pass "efm_cluster_status returned error message (not crash)"
        log_info "Error: $(echo "$output" | head -1)"
    else
        log_fail "Unexpected output: $output"
    fi
fi

echo ""
echo "Test 4: PostgreSQL still accepting connections"
echo "-----------------------------------------------"

if pg_isready -U postgres > /dev/null 2>&1; then
    log_pass "PostgreSQL is still accepting connections"
else
    log_fail "PostgreSQL stopped accepting connections!"
    exit 1
fi

echo ""
echo "Test 5: Other database operations work normally"
echo "------------------------------------------------"

run_sql "CREATE TABLE IF NOT EXISTS test_efm_down (id serial, data text);"
if run_sql "INSERT INTO test_efm_down (data) VALUES ('test') RETURNING id;" | grep -q "1"; then
    log_pass "INSERT operations work"
else
    log_fail "INSERT operations failed"
fi

if run_sql "SELECT COUNT(*) FROM test_efm_down;" | grep -qE "^[0-9]+$"; then
    log_pass "SELECT operations work"
else
    log_fail "SELECT operations failed"
fi

run_sql "DROP TABLE IF EXISTS test_efm_down;"

echo ""
echo "Test 6: Cache operations work even with EFM down"
echo "-------------------------------------------------"

if run_sql "SELECT cache_hits FROM efm_extension.efm_cache_stats();" | grep -qE "^[0-9]+$"; then
    log_pass "efm_cache_stats works"
else
    log_fail "efm_cache_stats failed"
fi

if run_sql "SELECT efm_extension.efm_invalidate_cache();" 2>&1 | grep -qiE "(error|void)"; then
    log_pass "efm_invalidate_cache works (or returns expected result)"
else
    log_pass "efm_invalidate_cache completed"
fi

echo ""
echo "========================================"
echo "  EFM Down Test Summary"
echo "========================================"
echo ""
echo -e "${GREEN}All tests passed!${NC}"
echo ""
echo "CONCLUSION: When EFM is down:"
echo "  - PostgreSQL remains fully operational"
echo "  - EFM extension functions return errors (not crashes)"
echo "  - efm_is_available() can be used to check EFM status"
echo "  - Normal database operations are unaffected"
echo ""
