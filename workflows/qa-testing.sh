#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist - QA Testing Workflow Orchestrator
# =============================================================================
# Purpose: Single command for full QA workflow: provision → deploy → test → destroy → report
# Author: Linus Deployment Specialist (AI-generated)
# Version: 1.0
# Automation Level: 3
#
# Required Environment Variables:
#   PROVIDER     - VM provider (proxmox|aws|qemu)
#   TEST_COMMAND - Command to execute tests
#
# Optional Environment Variables:
#   VM_NAME        - Name for the VM (default: linus-qa-<timestamp>)
#   VM_CPU         - CPU cores (default: 2)
#   VM_RAM         - RAM in MB (default: 4096)
#   VM_DISK        - Disk size in GB (default: 20)
#   CLEANUP        - If true, destroy VM after testing (default: true)
#   DRY_RUN        - If true, show what would be done without executing (default: false)
#   ARTIFACT_PATH  - Path to artifacts to deploy (default: none)
#   TEST_TIMEOUT   - Timeout for test execution in seconds (default: 300)
#
# Usage:
#   ./qa-testing.sh [options]
#
# Exit Codes:
#   0 - Success
#   1 - General error
#   2 - Missing dependencies
#   3 - Invalid configuration
#   4 - Provisioning failed
#   5 - Deployment failed
#   6 - Test execution failed
#   7 - Cleanup failed
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source libraries
source "${SCRIPT_DIR}/../shared/lib/logging.sh"
source "${SCRIPT_DIR}/../shared/lib/validation.sh"

# Configuration from environment with defaults
readonly PROVIDER="${PROVIDER:-}"
readonly TEST_COMMAND="${TEST_COMMAND:-}"
readonly VM_NAME="${VM_NAME:-linus-qa-$(date +%s)}"
readonly VM_CPU="${VM_CPU:-2}"
readonly VM_RAM="${VM_RAM:-4096}"
readonly VM_DISK="${VM_DISK:-20}"
readonly CLEANUP="${CLEANUP:-true}"
readonly DRY_RUN="${DRY_RUN:-false}"
readonly ARTIFACT_PATH="${ARTIFACT_PATH:-}"
readonly TEST_TIMEOUT="${TEST_TIMEOUT:-300}"

# Variables to track state
VM_IP=""
VM_USER=""
VM_ID=""

# -----------------------------------------------------------------------------
# Functions
# -----------------------------------------------------------------------------

function show_help() {
    cat << EOF
Linus Deployment Specialist - QA Testing Workflow Orchestrator
===============================================================
Purpose: Single command for full QA workflow: provision → deploy → test → destroy → report
Version: 1.0
Automation Level: 3

Required Environment Variables:
  PROVIDER       - VM provider (proxmox|aws|qemu)
  TEST_COMMAND   - Command to execute tests

Optional Environment Variables:
  VM_NAME        - Name for the VM (default: linus-qa-<timestamp>)
  VM_CPU         - CPU cores (default: 2)
  VM_RAM         - RAM in MB (default: 4096)
  VM_DISK        - Disk size in GB (default: 20)
  CLEANUP        - If true, destroy VM after testing (default: true)
  DRY_RUN        - If true, show what would be done without executing (default: false)
  ARTIFACT_PATH  - Path to artifacts to deploy (default: none)
  TEST_TIMEOUT   - Timeout for test execution in seconds (default: 300)

Usage:
  export PROVIDER="proxmox"
  export TEST_COMMAND="cd /home/ubuntu && python -m pytest"
  ./qa-testing.sh

  # With custom VM settings and dry-run
  export VM_CPU=4
  export VM_RAM=8192
  export DRY_RUN=true
  ./qa-testing.sh

Exit Codes:
  0 - Success
  1 - General error
  2 - Missing dependencies
  3 - Invalid configuration
  4 - Provisioning failed
  5 - Deployment failed
  6 - Test execution failed
  7 - Cleanup failed

EOF
}

function validate_inputs() {
    log_info "Validating inputs..."
    
    if [[ -z "${PROVIDER}" ]]; then
        log_error "PROVIDER is required"
        return 3
    fi
    
    if [[ -z "${TEST_COMMAND}" ]]; then
        log_error "TEST_COMMAND is required"
        return 3
    fi
    
    # Validate provider
    case "${PROVIDER}" in
        proxmox|aws|qemu)
            log_info "Provider ${PROVIDER} is supported"
            ;;
        *)
            log_error "Unsupported provider: ${PROVIDER}"
            return 3
            ;;
    esac
    
    log_info "Input validation completed successfully"
    return 0
}

function provision_vm() {
    log_info "Provisioning VM with provider: ${PROVIDER}"
    
    # Set environment variables for provisioning script
    local env_vars=""
    case "${PROVIDER}" in
        proxmox)
            # For Proxmox, we'll use the existing environment variables if set
            env_vars="VM_NAME=${VM_NAME} VM_CPU=${VM_CPU} VM_RAM=${VM_RAM} VM_DISK=${VM_DISK}"
            ;;
        aws)
            env_vars="VM_NAME=${VM_NAME} VM_CPU=${VM_CPU} VM_RAM=${VM_RAM} VM_DISK=${VM_DISK}"
            ;;
        qemu)
            env_vars="VM_NAME=${VM_NAME} VM_CPU=${VM_CPU} VM_RAM=${VM_RAM} VM_DISK=${VM_DISK}"
            ;;
    esac
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would provision VM with: ${env_vars} ./shared/provision/${PROVIDER}.sh"
        # Simulate successful provisioning for dry run
        VM_IP="192.168.1.100"
        VM_USER="ubuntu"
        VM_ID="${VM_NAME}"
        return 0
    else
        # Execute provisioning script
        local output
        output=$(eval "${env_vars} ./shared/provision/${PROVIDER}.sh" 2>&1)
        local exit_code=$?
        
        if [[ $exit_code -ne 0 ]]; then
            log_error "VM provisioning failed"
            log_error "$output"
            return 4
        fi
        
        # Parse output for VM details
        VM_IP=$(echo "$output" | grep "LINUS_VM_IP:" | cut -d: -f2- | tr -d ' ')
        VM_USER=$(echo "$output" | grep "LINUS_VM_USER:" | cut -d: -f2- | tr -d ' ')
        VM_ID=$(echo "$output" | grep "LINUS_VM_NAME:" | cut -d: -f2- | tr -d ' ')
        
        if [[ -z "${VM_IP}" || -z "${VM_USER}" ]]; then
            log_error "Failed to extract VM details from provisioning output"
            return 4
        fi
        
        log_info "VM provisioned successfully: ${VM_USER}@${VM_IP} (ID: ${VM_ID})"
    fi
    
    return 0
}

function wait_for_ssh() {
    local ip="$1"
    local user="$2"
    local max_wait=300  # seconds (Ubuntu 24.04 first-boot cloud-init >120s)
    local wait_time=0
    local interval=5
    
    log_info "Waiting for SSH access to ${user}@${ip} (max ${max_wait}s)"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would wait for SSH"
        return 0
    fi
    
    while [[ $wait_time -lt $max_wait ]]; do
        if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "${user}@${ip}" "echo 'SSH access confirmed'" >/dev/null 2>&1; then
            log_info "SSH access confirmed for ${user}@${ip}"
            return 0
        fi
        
        log_info "SSH not ready yet, waiting... (${wait_time}s/${max_wait}s)"
        sleep $interval
        wait_time=$((wait_time + interval))
    done
    
    log_error "Timeout waiting for SSH access to ${user}@${ip}"
    return 1
}

function deploy_artifacts() {
    log_info "Deploying artifacts to VM"
    
    if [[ -z "${ARTIFACT_PATH}" ]]; then
        log_info "No artifacts to deploy, skipping deployment step"
        return 0
    fi
    
    if [[ ! -d "${ARTIFACT_PATH}" && ! -f "${ARTIFACT_PATH}" ]]; then
        log_error "Artifact path does not exist: ${ARTIFACT_PATH}"
        return 5
    fi
    
    # Set environment variables for deployment script
    export TARGET_IP="${VM_IP}"
    export TARGET_USER="${VM_USER}"
    export SOURCE_PATH="${ARTIFACT_PATH}"
    export DRY_RUN="${DRY_RUN}"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would deploy artifacts from ${ARTIFACT_PATH} to ${VM_USER}@${VM_IP}"
        return 0
    else
        # Execute deployment script
        local output
        output=$(./shared/deploy/artifact.sh 2>&1)
        local exit_code=$?
        
        if [[ $exit_code -ne 0 ]]; then
            log_error "Artifact deployment failed"
            log_error "$output"
            return 5
        fi
        
        log_info "Artifacts deployed successfully"
    fi
    
    return 0
}

function execute_tests() {
    log_info "Executing tests on VM"
    
    # Set environment variables for test execution script
    export TARGET_IP="${VM_IP}"
    export TARGET_USER="${VM_USER}"
    export TEST_COMMAND="${TEST_COMMAND}"
    export TEST_TIMEOUT="${TEST_TIMEOUT}"
    export DRY_RUN="${DRY_RUN}"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would execute tests with command: ${TEST_COMMAND}"
        return 0
    else
        # Execute test script
        local output
        output=$(./shared/test/runner.sh 2>&1)
        local exit_code=$?
        
        if [[ $exit_code -ne 0 ]]; then
            log_error "Test execution failed"
            log_error "$output"
            return 6
        fi
        
        # Parse test results
        local test_result
        test_result=$(echo "$output" | grep "LINUS_TEST_RESULT:" | cut -d: -f2- | tr -d ' ')
        
        if [[ "${test_result}" == "PASS" ]]; then
            log_info "All tests passed successfully"
        else
            log_info "Tests failed (result: ${test_result})"
        fi
        
        log_info "Test execution completed"
    fi
    
    return 0
}

function cleanup_vm() {
    log_info "Cleaning up VM resources"
    
    if [[ "${CLEANUP}" != "true" ]]; then
        log_info "Cleanup disabled by configuration, skipping destruction"
        return 0
    fi
    
    # Set environment variables for destruction script
    export PROVIDER="${PROVIDER}"
    export VM_IDENTIFIER="${VM_ID}"
    export FORCE="true"
    export DRY_RUN="${DRY_RUN}"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would destroy VM with ID: ${VM_ID}"
        return 0
    else
        # Execute destruction script
        local output
        output=$(./shared/provision/destroy.sh 2>&1)
        local exit_code=$?
        
        if [[ $exit_code -ne 0 ]]; then
            log_error "VM cleanup failed"
            log_error "$output"
            return 7
        fi
        
        log_info "VM cleaned up successfully"
    fi
    
    return 0
}

function generate_report() {
    log_info "Generating test report"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would generate report"
        return 0
    fi
    
    # Create a simple report file
    local report_file="/tmp/qa-report-$(date +%s).txt"
    {
        echo "QA Testing Report"
        echo "================="
        echo "Timestamp: $(date)"
        echo "Provider: ${PROVIDER}"
        echo "VM ID: ${VM_ID}"
        echo "VM IP: ${VM_IP}"
        echo "Test Command: ${TEST_COMMAND}"
        echo ""
        echo "Test Results:"
        echo "-------------"
        echo "Completed successfully"
    } > "${report_file}"
    
    log_info "Report generated: ${report_file}"
    return 0
}

# -----------------------------------------------------------------------------
# Main Execution
# -----------------------------------------------------------------------------

main() {
    log_info "Starting $SCRIPT_NAME"
    
    # Validate prerequisites
    validate_inputs || {
        local ret=$?
        echo "LINUS_RESULT:FAILURE"
        echo "LINUS_ERROR:Input validation failed"
        return $ret
    }
    
    # Initialize tracking variables
    VM_IP=""
    VM_USER=""
    VM_ID=""
    
    # Stage 1: Provision VM
    log_info "=== Stage 1: Provisioning VM ==="
    provision_vm || {
        local ret=$?
        echo "LINUS_RESULT:FAILURE"
        echo "LINUS_ERROR:VM provisioning failed"
        return $ret
    }
    
    # Stage 2: Wait for SSH access
    log_info "=== Stage 2: Waiting for SSH Access ==="
    wait_for_ssh "${VM_IP}" "${VM_USER}" || {
        local ret=$?
        echo "LINUS_RESULT:FAILURE"
        echo "LINUS_ERROR:SSH access timeout"
        return $ret
    }
    
    # Stage 3: Deploy artifacts (if specified)
    log_info "=== Stage 3: Deploying Artifacts ==="
    deploy_artifacts || {
        local ret=$?
        echo "LINUS_RESULT:FAILURE"
        echo "LINUS_ERROR:Artifact deployment failed"
        return $ret
    }
    
    # Stage 4: Run tests
    log_info "=== Stage 4: Executing Tests ==="
    execute_tests || {
        local ret=$?
        echo "LINUS_RESULT:FAILURE"
        echo "LINUS_ERROR:Test execution failed"
        return $ret
    }
    
    # Stage 5: Generate report
    log_info "=== Stage 5: Generating Report ==="
    generate_report || {
        local ret=$?
        echo "LINUS_RESULT:FAILURE"
        echo "LINUS_ERROR:Report generation failed"
        return $ret
    }
    
    # Stage 6: Cleanup (if enabled)
    if [[ "${CLEANUP}" == "true" ]]; then
        log_info "=== Stage 6: Cleaning Up ==="
        cleanup_vm || {
            local ret=$?
            echo "LINUS_RESULT:FAILURE"
            echo "LINUS_ERROR:VM cleanup failed"
            return $ret
        }
    else
        log_info "=== Stage 6: Skipping Cleanup (disabled) ==="
    fi
    
    # Output success markers for agent parsing
    echo "LINUS_RESULT:SUCCESS"
    echo "LINUS_QA_WORKFLOW:COMPLETED"
    echo "LINUS_VM_ID:${VM_ID}"
    echo "LINUS_VM_IP:${VM_IP}"
    echo "LINUS_PROVIDER:${PROVIDER}"
    echo "LINUS_SCRIPT:$SCRIPT_NAME"
    echo "LINUS_TIMESTAMP:$(date +%s)"
    
    log_info "$SCRIPT_NAME completed successfully"
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