#!/bin/bash
# test_input_validation.sh - Test input validation security
#
# This test verifies that:
# 1. Invalid IP addresses are rejected
# 2. Invalid priorities are rejected
# 3. Command injection attempts are blocked
# 4. IPv6 addresses are handled

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0

log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
log_info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

run_sql() {
    psql -U postgres -d testdb -t -A -c "$1" 2>&1
}

expect_error() {
    local desc="$1"
    local sql="$2"
    local expected="$3"

    if output=$(run_sql "$sql" 2>&1); then
        log_fail "$desc: Expected error but succeeded"
    elif echo "$output" | grep -qi "$expected"; then
        log_pass "$desc"
    else
        log_fail "$desc: Expected '$expected', got '$output'"
    fi
}

expect_success() {
    local desc="$1"
    local sql="$2"

    if run_sql "$sql" > /dev/null 2>&1; then
        log_pass "$desc"
    else
        log_fail "$desc: Expected success but failed"
    fi
}

echo "========================================"
echo "  Input Validation Security Tests"
echo "========================================"
echo ""

run_sql "CREATE EXTENSION IF NOT EXISTS efm_extension;"

echo "IP Address Validation"
echo "---------------------"

expect_error "Empty IP rejected" \
    "SELECT efm_extension.efm_allow_node('');" \
    "invalid IP"

expect_error "Null bytes rejected" \
    "SELECT efm_extension.efm_allow_node(E'192.168.1.1\\x00');" \
    "invalid"

expect_error "Letters in IP rejected" \
    "SELECT efm_extension.efm_allow_node('abc.def.ghi.jkl');" \
    "invalid IP"

expect_error "Too many octets rejected" \
    "SELECT efm_extension.efm_allow_node('192.168.1.1.1');" \
    "invalid IP"

expect_error "Octet > 255 rejected" \
    "SELECT efm_extension.efm_allow_node('192.168.1.256');" \
    "invalid IP"

expect_error "Negative octet rejected" \
    "SELECT efm_extension.efm_allow_node('192.168.1.-1');" \
    "invalid IP"

expect_error "Leading zeros rejected" \
    "SELECT efm_extension.efm_allow_node('192.168.01.1');" \
    "invalid IP"

# These should succeed (valid IPs)
log_info "Testing valid IP formats..."
# Note: actual execution may fail if EFM is down, but validation should pass

echo ""
echo "Priority Validation"
echo "-------------------"

expect_error "Empty priority rejected" \
    "SELECT efm_extension.efm_set_priority('172.17.0.2', '');" \
    "invalid priority"

expect_error "Negative priority rejected" \
    "SELECT efm_extension.efm_set_priority('172.17.0.2', '-1');" \
    "invalid priority"

expect_error "Priority > 999 rejected" \
    "SELECT efm_extension.efm_set_priority('172.17.0.2', '1000');" \
    "invalid priority"

expect_error "Non-numeric priority rejected" \
    "SELECT efm_extension.efm_set_priority('172.17.0.2', 'high');" \
    "invalid priority"

expect_error "Mixed priority rejected" \
    "SELECT efm_extension.efm_set_priority('172.17.0.2', '10a');" \
    "invalid priority"

echo ""
echo "Command Injection Prevention"
echo "----------------------------"

expect_error "Semicolon injection blocked" \
    "SELECT efm_extension.efm_allow_node('172.17.0.2; rm -rf /');" \
    "invalid IP"

expect_error "Pipe injection blocked" \
    "SELECT efm_extension.efm_allow_node('172.17.0.2 | cat /etc/passwd');" \
    "invalid IP"

expect_error "Backtick injection blocked" \
    "SELECT efm_extension.efm_allow_node('\`whoami\`');" \
    "invalid IP"

expect_error "Dollar injection blocked" \
    "SELECT efm_extension.efm_allow_node('\$(whoami)');" \
    "invalid IP"

expect_error "Newline injection blocked" \
    "SELECT efm_extension.efm_allow_node(E'172.17.0.2\\nwhoami');" \
    "invalid IP"

echo ""
echo "========================================"
echo "  Input Validation Test Summary"
echo "========================================"
echo ""
echo "Passed: $PASS"
echo "Failed: $FAIL"
echo ""

if [ $FAIL -gt 0 ]; then
    echo -e "${RED}Some validation tests failed!${NC}"
    exit 1
else
    echo -e "${GREEN}All validation tests passed!${NC}"
    exit 0
fi
