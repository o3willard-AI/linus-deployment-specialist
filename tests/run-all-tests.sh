#!/usr/bin/env bash
# =============================================================================
# Test Runner: Execute All Tests
# =============================================================================
# Purpose: Run all tests (smoke, integration, E2E) with proper ordering
# Usage: ./run-all-tests.sh [--smoke-only] [--integration-only] [--e2e-only]
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Navigate to project root
cd "$(dirname "$0")/.."

# Parse arguments
RUN_SMOKE=true
RUN_INTEGRATION=true
RUN_E2E=true

if [[ "$#" -gt 0 ]]; then
    RUN_SMOKE=false
    RUN_INTEGRATION=false
    RUN_E2E=false

    for arg in "$@"; do
        case "$arg" in
            --smoke-only)
                RUN_SMOKE=true
                ;;
            --integration-only)
                RUN_INTEGRATION=true
                ;;
            --e2e-only)
                RUN_E2E=true
                ;;
            --help)
                echo "Usage: $0 [--smoke-only] [--integration-only] [--e2e-only]"
                echo ""
                echo "Options:"
                echo "  --smoke-only        Run only smoke tests (fast, no VM required)"
                echo "  --integration-only  Run only integration tests (requires live VM)"
                echo "  --e2e-only          Run only E2E tests (requires Proxmox access)"
                echo "  (no options)        Run all tests in sequence"
                echo ""
                echo "Environment Variables:"
                echo "  TEST_VM_IP          IP of test VM for integration tests (default: 192.168.101.113)"
                echo "  TEST_VM_USER        SSH user for test VM (default: ubuntu)"
                echo "  PROXMOX_HOST        Proxmox host for E2E tests (default: 192.168.101.155)"
                echo ""
                exit 0
                ;;
            *)
                echo "Unknown option: $arg"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
fi

echo -e "${BOLD}${BLUE}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║                                                       ║${NC}"
echo -e "${BOLD}${BLUE}║       Linus Deployment Specialist Test Suite         ║${NC}"
echo -e "${BOLD}${BLUE}║                                                       ║${NC}"
echo -e "${BOLD}${BLUE}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""

START_TIME=$(date +%s)

# Track test results
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Make all test scripts executable
find tests -name "*.sh" -exec chmod +x {} \;

# ============================================================================
# Smoke Tests (Fast, No Requirements)
# ============================================================================

if [[ "$RUN_SMOKE" == "true" ]]; then
    echo -e "${BOLD}${BLUE}>>> Running Smoke Tests (Syntax Validation)${NC}"
    echo ""

    if bash tests/smoke/test-all-scripts.sh; then
        ((TESTS_PASSED++))
        echo ""
    else
        ((TESTS_FAILED++))
        echo ""
        echo -e "${RED}❌ Smoke tests failed - aborting remaining tests${NC}"
        exit 1
    fi
fi

# ============================================================================
# Integration Tests (Requires Live VM)
# ============================================================================

if [[ "$RUN_INTEGRATION" == "true" ]]; then
    echo -e "${BOLD}${BLUE}>>> Running Integration Tests${NC}"
    echo ""

    # Check if test VM is configured
    TEST_VM_IP="${TEST_VM_IP:-192.168.101.113}"
    echo "Test VM configured: $TEST_VM_IP"
    echo ""

    # Test 1: Bootstrap Ubuntu
    echo -e "${YELLOW}Integration Test 1/2: Ubuntu Bootstrap${NC}"
    if bash tests/integration/test-bootstrap-ubuntu.sh; then
        ((TESTS_PASSED++))
        echo ""
    else
        ((TESTS_FAILED++))
        echo -e "${RED}❌ Bootstrap test failed${NC}"
        echo ""
    fi

    # Test 2: Dev Tools
    echo -e "${YELLOW}Integration Test 2/2: Dev Tools Installation${NC}"
    if bash tests/integration/test-dev-tools.sh; then
        ((TESTS_PASSED++))
        echo ""
    else
        ((TESTS_FAILED++))
        echo -e "${RED}❌ Dev tools test failed${NC}"
        echo ""
    fi
fi

# ============================================================================
# E2E Tests (Requires Proxmox Access)
# ============================================================================

if [[ "$RUN_E2E" == "true" ]]; then
    echo -e "${BOLD}${BLUE}>>> Running E2E Tests${NC}"
    echo ""

    PROXMOX_HOST="${PROXMOX_HOST:-192.168.101.155}"
    echo "Proxmox host configured: $PROXMOX_HOST"
    echo ""

    echo -e "${YELLOW}E2E Test: Full Provision + Bootstrap Workflow${NC}"
    if bash tests/e2e/test-full-workflow.sh; then
        ((TESTS_PASSED++))
        echo ""
    else
        ((TESTS_FAILED++))
        echo -e "${RED}❌ E2E test failed${NC}"
        echo ""
    fi
fi

# ============================================================================
# Test Summary
# ============================================================================

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo -e "${BOLD}${BLUE}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║                                                       ║${NC}"
echo -e "${BOLD}${BLUE}║                  Test Results                         ║${NC}"
echo -e "${BOLD}${BLUE}║                                                       ║${NC}"
echo -e "${BOLD}${BLUE}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}✅ All tests passed!${NC}"
else
    echo -e "${RED}❌ Some tests failed${NC}"
fi

echo ""
echo "Summary:"
echo "  Passed:  $TESTS_PASSED"
echo "  Failed:  $TESTS_FAILED"
echo "  Skipped: $TESTS_SKIPPED"
echo "  Duration: ${DURATION}s"
echo ""

# Generate test report
REPORT_FILE="tests/test-report-$(date +%Y%m%d-%H%M%S).txt"
cat > "$REPORT_FILE" << EOF
Linus Deployment Specialist - Test Report
==========================================
Date: $(date)
Duration: ${DURATION}s

Results:
- Passed:  $TESTS_PASSED
- Failed:  $TESTS_FAILED
- Skipped: $TESTS_SKIPPED

Configuration:
- Smoke Tests: $RUN_SMOKE
- Integration Tests: $RUN_INTEGRATION
- E2E Tests: $RUN_E2E

Environment:
- TEST_VM_IP: ${TEST_VM_IP:-not set}
- PROXMOX_HOST: ${PROXMOX_HOST:-not set}
EOF

echo "Test report saved: $REPORT_FILE"

# Exit with appropriate code
if [[ $TESTS_FAILED -eq 0 ]]; then
    exit 0
else
    exit 1
fi
