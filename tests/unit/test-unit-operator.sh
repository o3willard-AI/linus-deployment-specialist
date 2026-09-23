#!/usr/bin/env bash
# =============================================================================
# Unit Tests for Operator (RAE) Resolution
# =============================================================================
# Purpose: Test resolve_operator, linus_result OPERATOR pair, confirm_destruction
# Author: Linus Deployment Specialist (AI-generated)
# Version: 1.0
#
# Usage:
#   ./test-unit-operator.sh
#
# Exit Codes:
#   0 - All tests passed
#   1 - One or more tests failed
# =============================================================================

set -uo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test counter
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Project root (this script lives at tests/unit/)
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB_DIR="${PROJECT_ROOT}/shared/lib"

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

run_test() {
    local test_name="$1"
    shift
    ((TOTAL_TESTS++))
    echo -e "${BLUE}[TEST ${TOTAL_TESTS}]${NC} ${test_name}"

    if eval "$@"; then
        echo -e "  ${GREEN}✓ PASSED${NC}"
        ((PASSED_TESTS++))
        return 0
    else
        echo -e "  ${RED}✗ FAILED${NC}"
        ((FAILED_TESTS++))
        return 1
    fi
}

# -----------------------------------------------------------------------------
# resolve_operator() tests
# -----------------------------------------------------------------------------

test_resolve_operator_returns_id_when_set() {
    local out
    out=$(LINUS_OPERATOR_ID="alice" LINUS_OPERATOR_NAME="Alice Smith" \
        bash -c "source '${LIB_DIR}/logging.sh'; resolve_operator")
    [[ "$out" == "alice" ]]
}

test_resolve_operator_falls_back_to_user() {
    local out
    out=$(env -u LINUS_OPERATOR_ID -u LINUS_OPERATOR_NAME USER="bob" \
        bash -c "source '${LIB_DIR}/logging.sh'; resolve_operator")
    [[ "$out" == "bob" ]]
}

test_resolve_operator_falls_back_to_whoami() {
    local out
    out=$(env -u LINUS_OPERATOR_ID -u LINUS_OPERATOR_NAME -u USER \
        bash -c "source '${LIB_DIR}/logging.sh'; resolve_operator")
    [[ -n "$out" && "$out" != "unknown" ]]
}

test_resolve_operator_uses_name_when_id_unset() {
    local out
    out=$(env -u LINUS_OPERATOR_ID LINUS_OPERATOR_NAME="Alice" \
        bash -c "source '${LIB_DIR}/logging.sh'; resolve_operator")
    [[ "$out" == "Alice" ]]
}

# -----------------------------------------------------------------------------
# resolve_operator_name() tests
# -----------------------------------------------------------------------------

test_resolve_operator_name_prefers_name() {
    local out
    out=$(LINUS_OPERATOR_ID="alice" LINUS_OPERATOR_NAME="Alice Smith" \
        bash -c "source '${LIB_DIR}/logging.sh'; resolve_operator_name")
    [[ "$out" == "Alice Smith" ]]
}

# -----------------------------------------------------------------------------
# linus_result() OPERATOR pair tests
# -----------------------------------------------------------------------------

test_linus_result_includes_operator_pair() {
    local out
    out=$(LINUS_OPERATOR_ID="alice" \
        bash -c "source '${LIB_DIR}/logging.sh'; linus_result SUCCESS 'VM_ID:123'")
    echo "$out" | grep -q "LINUS_RESULT:SUCCESS" && \
    echo "$out" | grep -q "OPERATOR:alice"
}

test_linus_result_operator_pair_mutation() {
    # Mutation check: the appended OPERATOR pair MUST be present.
    # If the linus_result() change is reverted, this grep fails.
    local out
    out=$(LINUS_OPERATOR_ID="alice" \
        bash -c "source '${LIB_DIR}/logging.sh'; linus_result SUCCESS 'FOO:bar'")
    echo "$out" | grep -q "LINUS_OPERATOR:alice"
}

test_linus_failure_includes_operator() {
    local out
    out=$(LINUS_OPERATOR_ID="bob" \
        bash -c "source '${LIB_DIR}/logging.sh'; linus_failure 'something broke'")
    echo "$out" | grep -q "LINUS_RESULT:FAILURE" && \
    echo "$out" | grep -q "LINUS_ERROR:something broke" && \
    echo "$out" | grep -q "LINUS_OPERATOR:bob"
}

test_linus_result_fallback_operator() {
    # When no operator env vars are set, falls back to $USER
    local out
    out=$(env -u LINUS_OPERATOR_ID -u LINUS_OPERATOR_NAME USER="carol" \
        bash -c "source '${LIB_DIR}/logging.sh'; linus_result SUCCESS")
    echo "$out" | grep -q "LINUS_OPERATOR:carol"
}

# -----------------------------------------------------------------------------
# confirm_destruction() tests (requires destroy.sh sourced)
# -----------------------------------------------------------------------------

# Tests use bash -c subshells with BASH_SOURCE-based sourcing (see destroy.sh).

test_confirm_destruction_force_records_operator() {
    # FORCE=true path must log the operator (mutation check)
    local out
    out=$(FORCE=true PROVIDER=proxmox VM_IDENTIFIER=999 DRY_RUN=false \
        LINUS_OPERATOR_ID="alice" LINUS_OPERATOR_NAME="Alice" \
        bash -c "
            source '${PROJECT_ROOT}/shared/lib/paths.sh'
            source '${PROJECT_ROOT}/shared/provision/destroy.sh'
            confirm_destruction 'proxmox' '999'
        " 2>&1) || true
    echo "$out" | grep -qi "operator"
}

test_confirm_destruction_force_records_operator_id() {
    # The operator ID must appear in the FORCE path log output
    local out
    out=$(FORCE=true PROVIDER=proxmox VM_IDENTIFIER=999 DRY_RUN=false \
        LINUS_OPERATOR_ID="alice" \
        bash -c "
            source '${PROJECT_ROOT}/shared/lib/paths.sh'
            source '${PROJECT_ROOT}/shared/provision/destroy.sh'
            confirm_destruction 'proxmox' '999'
        " 2>&1) || true
    echo "$out" | grep -q "alice"
}

test_confirm_destruction_y_n_records_operator() {
    # Interactive y/N confirm path must log the operator (mutation check)
    local out
    out=$(PROVIDER=proxmox VM_IDENTIFIER=999 DRY_RUN=false FORCE=false \
        LINUS_OPERATOR_ID="bob" LINUS_OPERATOR_NAME="Bob" \
        bash -c "
            source '${PROJECT_ROOT}/shared/lib/paths.sh'
            source '${PROJECT_ROOT}/shared/provision/destroy.sh'
            confirm_destruction 'proxmox' '999' <<< 'y'
        " 2>&1) || true
    echo "$out" | grep -qi "operator.*confirmed\|confirmed.*operator"
}

test_confirm_destruction_force_in_result_output() {
    # The destruction LINUS_RESULT output must include OPERATOR pair
    local out
    out=$(FORCE=true PROVIDER=proxmox VM_IDENTIFIER=999 DRY_RUN=true \
        LINUS_OPERATOR_ID="alice" \
        bash -c "
            source '${PROJECT_ROOT}/shared/lib/paths.sh'
            source '${PROJECT_ROOT}/shared/provision/destroy.sh'
            linus_result SUCCESS 'DESTROY_RESULT:SUCCESS' 'DESTROY_VM_ID:999'
        " 2>/dev/null) || true
    echo "$out" | grep -q "LINUS_OPERATOR:alice"
}

# -----------------------------------------------------------------------------
# Main Execution
# -----------------------------------------------------------------------------

echo "==========================================="
echo "Operator (RAE) Unit Tests"
echo "==========================================="
echo ""
echo "Running tests..."
echo ""

run_test "resolve_operator returns LINUS_OPERATOR_ID when set" \
    test_resolve_operator_returns_id_when_set
run_test "resolve_operator falls back to \$USER when unset" \
    test_resolve_operator_falls_back_to_user
run_test "resolve_operator falls back to whoami when \$USER unset" \
    test_resolve_operator_falls_back_to_whoami
run_test "resolve_operator uses LINUS_OPERATOR_NAME when ID unset" \
    test_resolve_operator_uses_name_when_id_unset
run_test "resolve_operator_name prefers LINUS_OPERATOR_NAME" \
    test_resolve_operator_name_prefers_name
run_test "linus_result includes OPERATOR pair" \
    test_linus_result_includes_operator_pair
run_test "linus_result OPERATOR pair mutation check" \
    test_linus_result_operator_pair_mutation
run_test "linus_failure includes OPERATOR pair" \
    test_linus_failure_includes_operator
run_test "linus_result falls back to \$USER for operator" \
    test_linus_result_fallback_operator
run_test "confirm_destruction FORCE=true records operator" \
    test_confirm_destruction_force_records_operator
run_test "confirm_destruction FORCE=true records operator ID" \
    test_confirm_destruction_force_records_operator_id
run_test "confirm_destruction y/N path records operator" \
    test_confirm_destruction_y_n_records_operator
run_test "confirm_destruction LINUS_RESULT includes OPERATOR" \
    test_confirm_destruction_force_in_result_output

# Print summary
echo ""
echo "==========================================="
echo "Test Summary"
echo "==========================================="
echo "Total:  ${TOTAL_TESTS}"
echo -e "Passed: ${GREEN}${PASSED_TESTS}${NC}"
echo -e "Failed: ${RED}${FAILED_TESTS}${NC}"
echo ""

if [[ ${FAILED_TESTS} -eq 0 ]]; then
    echo -e "${GREEN}All operator tests passed!${NC}"
    exit 0
else
    echo -e "${RED}${FAILED_TESTS} test(s) failed!${NC}"
    exit 1
fi
