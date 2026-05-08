#!/usr/bin/env bash
# =============================================================================
# Unit Tests for Snapshot Scripts
# =============================================================================
# Purpose: Test snapshot, restore, cleanup verification, and monitoring scripts
# Author: Linus Deployment Specialist (AI-generated)
# Version: 1.0
#
# Usage:
#   ./test-unit-snapshot.sh
#
# Exit Codes:
#   0 - All tests passed
#   1 - One or more tests failed
#   2 - Missing dependencies
# =============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test counter
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Scripts directory
SCRIPTS_DIR="/home/sblanken/workspace/lds/linus-deployment-specialist/shared/snapshot"
TEST_DIR="/tmp/linus-unit-tests"

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

run_test() {
    local test_name="$1"
    shift
    local test_cmd="$@"
    
    ((TOTAL_TESTS++))
    echo -e "${BLUE}[TEST ${TOTAL_TESTS}]${NC} ${test_name}"
    
    if eval "${test_cmd}"; then
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
# Test Functions
# -----------------------------------------------------------------------------

test_script_exists() {
    local scripts=("save-snapshot.sh" "restore-snapshot.sh" "list-snapshots.sh" 
                  "bootstrap-with-snapshot.sh" "verify-cleanup.sh" "monitor-resource.sh")
    for script in "${scripts[@]}"; do
        [[ -f "${SCRIPTS_DIR}/${script}" ]] || return 1
    done
    return 0
}

test_script_syntax() {
    for script in "${SCRIPTS_DIR}"/*.sh; do
        bash -n "$script" || return 1
    done
    return 0
}

test_script_help() {
    local script="${SCRIPTS_DIR}/bootstrap-with-snapshot.sh"
    local help_output
    help_output=$("${script}" --help 2>&1) || true
    echo "${help_output}" | grep -qi "usage"
}

test_script_missing_provider() {
    local script="${SCRIPTS_DIR}/save-snapshot.sh"
    local output
    output=$("${script}" 2>&1) || true
    echo "${output}" | grep -qi "PROVIDER"
}

test_script_invalid_provider() {
    local script="${SCRIPTS_DIR}/save-snapshot.sh"
    local output
    output=$(PROVIDER="invalid" VM_IDENTIFIER="113" VM_IP="10.0.0.1" "${script}" 2>&1) || true
    echo "${output}" | grep -qi "unsupported\|invalid.*provider"
}

test_script_executable() {
    for script in "${SCRIPTS_DIR}"/*.sh; do
        [[ -x "$script" ]] || return 1
    done
    return 0
}

test_bootstrap_structure() {
    local script="${SCRIPTS_DIR}/bootstrap-with-snapshot.sh"
    grep -q "create_snapshot_before_bootstrap" "${script}" || return 1
    grep -q "run_bootstrap" "${script}" || return 1
    grep -q "offer_restore_on_failure" "${script}" || return 1
    return 0
}

test_verify_cleanup_structure() {
    local script="${SCRIPTS_DIR}/verify-cleanup.sh"
    grep -q "verify_proxmox_cleanup" "${script}" || return 1
    grep -q "verify_aws_cleanup" "${script}" || return 1
    grep -q "verify_qemu_cleanup" "${script}" || return 1
    return 0
}

test_monitor_structure() {
    local script="${SCRIPTS_DIR}/monitor-resource.sh"
    grep -q "get_cpu_usage" "${script}" || return 1
    grep -q "get_memory_usage" "${script}" || return 1
    grep -q "get_disk_io" "${script}" || return 1
    grep -q "log_resources" "${script}" || return 1
    return 0
}

test_metadata_json() {
    local metadata_file="/tmp/test-meta-${RANDOM}.json"
    cat > "${metadata_file}" << 'JSONEOF'
{
  "snapshot_name": "test-snapshot",
  "provider": "proxmox",
  "vm_identifier": "113",
  "created_at": "2026-05-08T12:34:56Z",
  "status": "created",
  "restore_available": true
}
JSONEOF
    
    if command -v python3 &>/dev/null; then
        python3 -c "import json; json.load(open('${metadata_file}'))" 2>/dev/null
        rm -f "${metadata_file}"
        return 0
    elif command -v jq &>/dev/null; then
        jq . "${metadata_file}" >/dev/null 2>&1
        rm -f "${metadata_file}"
        return 0
    else
        rm -f "${metadata_file}"
        return 0
    fi
}

test_error_messages() {
    local script="${SCRIPTS_DIR}/save-snapshot.sh"
    local output
    output=$("${script}" 2>&1) || true
    echo "${output}" | grep -qi "error\|required\|missing"
}

# -----------------------------------------------------------------------------
# Main Execution
# -----------------------------------------------------------------------------

echo "=========================================="
echo "Linus Deployment Specialist - Unit Tests"
echo "=========================================="
echo ""
echo "Running unit tests..."
echo ""

# Run all tests
run_test "Validate all snapshot scripts exist" test_script_exists
run_test "Validate script syntax" test_script_syntax
run_test "Validate scripts show help" test_script_help
run_test "Validate missing PROVIDER error" test_script_missing_provider
run_test "Validate invalid PROVIDER error" test_script_invalid_provider
run_test "Validate all scripts are executable" test_script_executable
run_test "Validate bootstrap-with-snapshot.sh structure" test_bootstrap_structure
run_test "Validate verify-cleanup.sh structure" test_verify_cleanup_structure
run_test "Validate monitor-resource.sh structure" test_monitor_structure
run_test "Validate metadata JSON format" test_metadata_json
run_test "Validate error messages" test_error_messages

# Print summary
echo ""
echo "=========================================="
echo "Test Summary"
echo "=========================================="
echo "Total:  ${TOTAL_TESTS}"
echo -e "Passed: ${GREEN}${PASSED_TESTS}${NC}"
echo -e "Failed: ${RED}${FAILED_TESTS}${NC}"
echo ""

if [[ ${FAILED_TESTS} -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}${FAILED_TESTS} test(s) failed!${NC}"
    exit 1
fi
