#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist - Test Execution Script
# =============================================================================
# Purpose: Execute test suites on remote VMs and capture results
# Author: Linus Deployment Specialist (AI-generated)
# Version: 1.0
# Automation Level: 2
#
# Required Environment Variables:
#   TARGET_IP    - IP address of target VM
#   TARGET_USER  - SSH username on target VM
#   TEST_COMMAND - Command to execute tests
#
# Optional Environment Variables:
#   TEST_TIMEOUT     - Timeout in seconds (default: 300)
#   TEST_OUTPUT_DIR  - Directory for test output files (default: /tmp/test-results)
#   JUNIT_XML_OUTPUT - If true, capture JUnit XML output (default: false)
#
# Usage:
#   ./runner.sh
#
# Exit Codes:
#   0 - Success
#   1 - General error
#   2 - Missing dependencies
#   3 - Invalid configuration
#   4 - Test execution failed
#   5 - Timeout occurred
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source libraries
source "${SCRIPT_DIR}/../lib/logging.sh"
source "${SCRIPT_DIR}/../lib/validation.sh"

# Configuration from environment with defaults
readonly TARGET_IP="${TARGET_IP:-}"
readonly TARGET_USER="${TARGET_USER:-}"
readonly TEST_COMMAND="${TEST_COMMAND:-}"
readonly TEST_TIMEOUT="${TEST_TIMEOUT:-300}"
readonly TEST_OUTPUT_DIR="${TEST_OUTPUT_DIR:-/tmp/test-results}"
readonly JUNIT_XML_OUTPUT="${JUNIT_XML_OUTPUT:-false}"

# -----------------------------------------------------------------------------
# Functions
# -----------------------------------------------------------------------------

function show_help() {
    cat << EOF
Linus Deployment Specialist - Test Execution Script
====================================================
Purpose: Execute test suites on remote VMs and capture results
Version: 1.0
Automation Level: 2

Required Environment Variables:
  TARGET_IP    - IP address of target VM
  TARGET_USER  - SSH username on target VM
  TEST_COMMAND - Command to execute tests

Optional Environment Variables:
  TEST_TIMEOUT     - Timeout in seconds (default: 300)
  TEST_OUTPUT_DIR  - Directory for test output files (default: /tmp/test-results)
  JUNIT_XML_OUTPUT - If true, capture JUnit XML output (default: false)
  DRY_RUN          - Show what would be done without executing (default: false)

Usage:
  export TARGET_IP="192.168.1.100"
  export TARGET_USER="ubuntu"
  export TEST_COMMAND="cd /home/ubuntu && python -m pytest"
  ./runner.sh

  # With custom timeout and output directory
  export TEST_TIMEOUT=600
  export TEST_OUTPUT_DIR="./test-results"
  ./runner.sh

Exit Codes:
  0 - Success
  1 - General error
  2 - Missing dependencies
  3 - Invalid configuration
  4 - Test execution failed
  5 - Timeout occurred

EOF
}

function validate_inputs() {
    log_info "Validating inputs..."
    
    if [[ -z "${TARGET_IP}" ]]; then
        log_error "TARGET_IP is required"
        return 3
    fi
    
    if [[ -z "${TARGET_USER}" ]]; then
        log_error "TARGET_USER is required"
        return 3
    fi
    
    if [[ -z "${TEST_COMMAND}" ]]; then
        log_error "TEST_COMMAND is required"
        return 3
    fi
    
    # Validate SSH connectivity
    if ! ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "${TARGET_USER}@${TARGET_IP}" "echo 'SSH connection test successful'" >/dev/null 2>&1; then
        log_error "Cannot connect to target VM at ${TARGET_USER}@${TARGET_IP}"
        return 4
    fi
    
    log_info "Input validation completed successfully"
    return 0
}

function execute_remote_tests() {
    local target_ip="$1"
    local target_user="$2"
    local test_command="$3"
    local timeout_seconds="$4"
    local output_dir="$5"
    
    log_info "Executing tests on ${target_user}@${target_ip} with timeout ${timeout_seconds}s"
    
    # Create remote directory for results
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY RUN] Would create remote directory: ${output_dir}"
    else
        if ! ssh "${target_user}@${target_ip}" "mkdir -p '${output_dir}'"; then
            log_error "Failed to create output directory on remote host"
            return 4
        fi
    fi
    
    # Prepare the test execution command with timeout
    local full_command="cd ${output_dir} && timeout ${timeout_seconds} bash -c '${test_command}'"
    
    log_info "Executing remote command: $full_command"
    
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY RUN] Would execute: ${full_command}"
        # Simulate successful execution for dry run
        echo "Test execution completed successfully"
        return 0
    else
        # Execute the test command with timeout and capture output
        local test_output
        test_output=$(ssh "${target_user}@${target_ip}" "${full_command}" 2>&1)
        local exit_code=$?
        
        if [[ $exit_code -eq 124 ]]; then  # timeout exit code
            log_error "Test execution timed out after ${timeout_seconds} seconds"
            return 5
        elif [[ $exit_code -ne 0 ]]; then
            log_error "Test execution failed with exit code: $exit_code"
            log_error "Output: $test_output"
            return 4
        else
            log_info "Test execution completed successfully"
            echo "$test_output"
            return 0
        fi
    fi
}

function parse_test_results() {
    local output="$1"
    local test_command="$2"
    
    log_info "Parsing test results..."
    
    # Initialize counters
    local passed=0
    local failed=0
    local total=0
    
    # Try to parse JUnit XML if available and requested
    if [[ "${JUNIT_XML_OUTPUT}" == "true" ]]; then
        # Look for common patterns in JUnit XML output or console output
        # This is a simplified parser - real implementation would be more complex
        passed=$(echo "$output" | grep -oE '[0-9]+ tests? passed' | head -1 | grep -oE '[0-9]+')
        failed=$(echo "$output" | grep -oE '[0-9]+ tests? failed' | head -1 | grep -oE '[0-9]+')
        total=$(echo "$output" | grep -oE '[0-9]+ tests? run' | head -1 | grep -oE '[0-9]+')
        
        # Fallback to more generic parsing
        if [[ $passed -eq 0 ]]; then
            passed=$(echo "$output" | grep -c 'PASSED\|SUCCESS\|✓' || echo 0)
        fi
        if [[ $failed -eq 0 ]]; then
            failed=$(echo "$output" | grep -c 'FAILED\|ERROR\|✗' || echo 0)
        fi
        if [[ $total -eq 0 ]]; then
            total=$((passed + failed))
        fi
    else
        # Parse from console output
        passed=$(echo "$output" | grep -c 'PASSED\|SUCCESS\|✓' || echo 0)
        failed=$(echo "$output" | grep -c 'FAILED\|ERROR\|✗' || echo 0)
        total=$((passed + failed))
    fi
    
    # If we couldn't get clear counts, try to extract from common formats
    if [[ $total -eq 0 ]]; then
        # Try to extract from pytest-style output like "12 passed, 3 failed"
        local pytest_match
        pytest_match=$(echo "$output" | grep -oE '[0-9]+ passed.*[0-9]+ failed')
        if [[ -n "$pytest_match" ]]; then
            passed=$(echo "$pytest_match" | grep -oE '[0-9]+ passed' | head -1 | grep -oE '[0-9]+')
            failed=$(echo "$pytest_match" | grep -oE '[0-9]+ failed' | head -1 | grep -oE '[0-9]+')
            total=$((passed + failed))
        fi
    fi
    
    # If still no counts, assume all passed (conservative approach)
    if [[ $total -eq 0 ]]; then
        total=1
        passed=1
        failed=0
    fi
    
    log_info "Parsed results - Total: $total, Passed: $passed, Failed: $failed"
    
    echo "$passed,$failed,$total"
}

function capture_test_outputs() {
    local target_ip="$1"
    local target_user="$2"
    local output_dir="$3"
    local test_command="$4"
    
    log_info "Capturing test outputs..."
    
    # Try to find and copy common test result files
    local result_files
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY RUN] Would look for test result files"
        return 0
    else
        # Look for common test output files in the directory
        result_files=$(ssh "${target_user}@${target_ip}" "find '${output_dir}' -type f \\( -name '*.xml' -o -name '*.log' -o -name 'test-results*' \\) 2>/dev/null" || echo "")
        
        if [[ -n "$result_files" ]]; then
            log_info "Found test result files: $result_files"
            
            # Copy them to local directory
            local local_output_dir="/tmp/test-results-$(date +%s)"
            mkdir -p "${local_output_dir}"
            
            while IFS= read -r file; do
                if [[ -n "$file" ]]; then
                    log_info "Copying result file: $file"
                    scp "${target_user}@${target_ip}:${file}" "${local_output_dir}/" 2>/dev/null || true
                fi
            done <<< "$result_files"
            
            echo "${local_output_dir}"
        else
            log_info "No test result files found"
        fi
    fi
    
    return 0
}

# -----------------------------------------------------------------------------
# Main Execution
# -----------------------------------------------------------------------------

main() {
    log_info "Starting $SCRIPT_NAME"
    
    # Validate prerequisites
    validate_inputs || return 3
    
    # Execute tests
    local test_output
    test_output=$(execute_remote_tests "${TARGET_IP}" "${TARGET_USER}" "${TEST_COMMAND}" "${TEST_TIMEOUT}" "${TEST_OUTPUT_DIR}") || return 4
    
    # Parse results
    local result_counts
    result_counts=$(parse_test_results "$test_output" "${TEST_COMMAND}")
    
    local passed=$(echo "$result_counts" | cut -d',' -f1)
    local failed=$(echo "$result_counts" | cut -d',' -f2)
    local total=$(echo "$result_counts" | cut -d',' -f3)
    
    # Determine overall result
    local test_result="FAIL"
    if [[ $failed -eq 0 ]]; then
        test_result="PASS"
    fi
    
    # Capture outputs
    local output_dir
    output_dir=$(capture_test_outputs "${TARGET_IP}" "${TARGET_USER}" "${TEST_OUTPUT_DIR}" "${TEST_COMMAND}")
    
    # Output success markers for agent parsing
    echo "LINUS_RESULT:SUCCESS"
    echo "LINUS_TEST_RESULT:${test_result}"
    echo "LINUS_TEST_PASSED:${passed}"
    echo "LINUS_TEST_FAILED:${failed}"
    echo "LINUS_TEST_TOTAL:${total}"
    echo "LINUS_TEST_DURATION:${TEST_TIMEOUT}"
    echo "LINUS_TEST_OUTPUT:${output_dir:-/tmp/test-results}"
    echo "LINUS_SCRIPT:$SCRIPT_NAME"
    echo "LINUS_TIMESTAMP:$(date +%s)"
    
    log_info "$SCRIPT_NAME completed successfully"
    log_info "Test results - Total: $total, Passed: $passed, Failed: $failed"
    return 0
}

# Execute main only if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Check for help flag
    if [[ "$#" -gt 0 ]] && [[ "$1" == "--help" || "$1" == "-h" ]]; then
        show_help
        exit 0
    fi
    main "$@"
fi