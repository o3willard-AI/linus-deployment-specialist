#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist - Bootstrap Snapshot Wrapper
# =============================================================================
# Purpose: Automatically save snapshot before bootstrap for easy rollback
# Author: Linus Deployment Specialist (AI-generated)
# Version: 1.0
# Automation Level: 2
#
# This wrapper script:
# 1. Creates a snapshot of the VM before bootstrap
# 2. Stores metadata about the snapshot operation
# 3. Offers automatic restore if bootstrap fails
# 4. Provides clean restore point for test isolation
#
# Usage:
#   ./bootstrap-with-snapshot.sh <bootstrap-script> [bootstrap-args]
#
# Example:
#   ./bootstrap-with-snapshot.sh ubuntu.sh
#   ./bootstrap-with-snapshot.sh almalinux.sh TIMEZONE=America/New_York
#
# Exit Codes:
#   0 - Success
#   1 - General error
#   2 - Snapshot creation failed
#   3 - Bootstrap failed (snapshot available for restore)
#   4 - Restore failed
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly LINUS_SNAPSHOT_DIR="${LINUS_SNAPSHOT_DIR:-/tmp/linus-snapshots}"
readonly SNAPSHOT_PREFIX="bootstrap-baseline"

# Source libraries
source "${SCRIPT_DIR}/../lib/logging.sh"
source "${SCRIPT_DIR}/../lib/validation.sh"

# -----------------------------------------------------------------------------
# Functions
# -----------------------------------------------------------------------------

function show_help() {
    cat << EOF
Linus Deployment Specialist - Bootstrap Snapshot Wrapper
=========================================================
Purpose: Automatically save snapshot before bootstrap for easy rollback

Usage:
  ${SCRIPT_NAME} <bootstrap-script> [bootstrap-args]

Examples:
  ${SCRIPT_NAME} ubuntu.sh
  ${SCRIPT_NAME} almalinux.sh TIMEZONE=America/New_York
  ${SCRIPT_NAME} ../shared/bootstrap/ubuntu.sh SKIP_UPGRADE=true

Parameters:
  bootstrap-script  Path to the bootstrap script to execute
  bootstrap-args    Optional environment variables/arguments for bootstrap

Features:
  - Creates snapshot before bootstrap starts
  - Stores snapshot metadata with operation context
  - Automatic restore offer if bootstrap fails
  - Clean separation between provisioning and bootstrap phases

Snapshot Management:
  - Snapshots are saved in: ${LINUS_SNAPSHOT_DIR}
  - Metadata files include: provider, vm_id, timestamp, bootstrap_type
  - Old snapshots (older than 7 days) are automatically cleaned

Exit Codes:
  0 - Success
  1 - General error  
  2 - Snapshot creation failed
  3 - Bootstrap failed (snapshot available for restore)
  4 - Restore failed

EOF
}

function create_snapshot_before_bootstrap() {
    log_step "1" "Creating bootstrap baseline snapshot"
    
    local provider="${PROVIDER:-}"
    local vm_id="${VM_IDENTIFIER:-}"
    local vm_ip="${VM_IP:-}"
    local vm_name="${VM_NAME:-}"
    
    if [[ -z "${provider}" ]]; then
        log_error "PROVIDER environment variable not set"
        return 2
    fi
    
    if [[ -z "${vm_id}" ]] && [[ -z "${vm_name}" ]] && [[ -z "${vm_ip}" ]]; then
        log_error "VM_IDENTIFIER or VM_NAME or VM_IP not set"
        return 2
    fi
    
    # Determine VM identifier for snapshot
    local snapshot_vm_id="${vm_id:-${vm_name:-${vm_ip}}}"
    
    # Generate snapshot name with timestamp and bootstrap type
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local snapshot_type="${BOOTSTRAP_TYPE:-default}"
    local snapshot_name="${SNAPSHOT_PREFIX}-${timestamp}-${snapshot_type}"
    
    log_info "Provider: ${provider}"
    log_info "VM Identifier: ${snapshot_vm_id}"
    log_info "Snapshot Name: ${snapshot_name}"
    
    # Create snapshot using existing save-snapshot.sh
    local snapshot_output
    if ! snapshot_output=$("${SCRIPT_DIR}/save-snapshot.sh" \
        PROVIDER="${provider}" \
        VM_IDENTIFIER="${snapshot_vm_id}" \
        SNAPSHOT_NAME="${snapshot_name}" \
        DESCRIPTION="Bootstrap baseline for ${snapshot_type} - ${timestamp}" \
        2>&1); then
        
        log_error "Snapshot creation failed:"
        echo "${snapshot_output}"
        return 2
    fi
    
    # Save snapshot metadata
    local metadata_file="${LINUS_SNAPSHOT_DIR}/${snapshot_name}.meta.json"
    mkdir -p "${LINUS_SNAPSHOT_DIR}"
    
    cat > "${metadata_file}" << EOF
{
  "snapshot_name": "${snapshot_name}",
  "provider": "${provider}",
  "vm_identifier": "${snapshot_vm_id}",
  "vm_ip": "${vm_ip:-}",
  "operation_type": "bootstrap_baseline",
  "bootstrap_type": "${snapshot_type}",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "bootstrap_script": "${BOOTSTRAP_SCRIPT:-unknown}",
  "bootstrap_args": "${BOOTSTRAP_ARGS:-}",
  "status": "created",
  "restore_available": true
}
EOF
    
    log_success "Snapshot ${snapshot_name} created and metadata saved to ${metadata_file}"
    
    # Output snapshot info for parsing
    echo "LINUS_SNAPSHOT_CREATED:true"
    echo "LINUS_SNAPSHOT_NAME:${snapshot_name}"
    echo "LINUS_SNAPSHOT_PROVIDER:${provider}"
    echo "LINUS_SNAPSHOT_VM_ID:${snapshot_vm_id}"
    echo "LINUS_SNAPSHOT_METADATA_FILE:${metadata_file}"
    
    return 0
}

function save_restore_info() {
    local snapshot_name="$1"
    local metadata_file="$2"
    
    # Read snapshot name from metadata
    local provider vm_id
    provider=$(grep '"provider"' "${metadata_file}" | grep -oP '"provider":\s*"\K[^"]+' || echo "")
    vm_id=$(grep '"vm_identifier"' "${metadata_file}" | grep -oP '"vm_identifier":\s*"\K[^"]+' || echo "")
    
    # Save restore info to a file for easy access
    local restore_file="${LINUS_SNAPSHOT_DIR}/restore-info.txt"
    cat > "${restore_file}" << EOF
# Restore Information
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)

PROVIDER=${provider}
VM_IDENTIFIER=${vm_id}
SNAPSHOT_NAME=${snapshot_name}
SNAPSHOT_METADATA=${metadata_file}

# To restore, set these variables and run:
# ./restore-snapshot.sh
EOF
    
    log_info "Restore information saved to ${restore_file}"
}

function run_bootstrap() {
    log_step "2" "Executing bootstrap script"
    
    local bootstrap_script="$1"
    local bootstrap_args="$2"
    
    if [[ ! -f "${bootstrap_script}" ]]; then
        log_error "Bootstrap script not found: ${bootstrap_script}"
        return 1
    fi
    
    if [[ ! -x "${bootstrap_script}" ]] && [[ ! "${bootstrap_script}" =~ \.sh$ ]]; then
        log_info "Making bootstrap script executable"
        chmod +x "${bootstrap_script}"
    fi
    
    log_info "Bootstrap script: ${bootstrap_script}"
    log_info "Bootstrap args: ${bootstrap_args}"
    
    # Execute bootstrap script
    # Source the script to capture any output
    local bootstrap_output
    if ! bootstrap_output=$("${bootstrap_script}" ${bootstrap_args} 2>&1); then
        log_error "Bootstrap failed:"
        echo "${bootstrap_output}"
        return 3
    fi
    
    log_success "Bootstrap completed successfully"
    echo "${bootstrap_output}"
    
    # Mark snapshot as no longer needed (optional cleanup later)
    if [[ -f "${LINUS_SNAPSHOT_DIR}/${SNAPSHOT_NAME}.meta.json" ]]; then
        local metadata_file="${LINUS_SNAPSHOT_DIR}/${SNAPSHOT_NAME}.meta.json"
        sed -i 's/"status": "created"/"status": "success"/' "${metadata_file}"
        sed -i 's/"restore_available": true/"restore_available": false/"' "${metadata_file}"
    fi
    
    return 0
}

function offer_restore_on_failure() {
    local exit_code="$1"
    local snapshot_name="$2"
    local metadata_file="$3"
    
    log_warn "Bootstrap failed with exit code ${exit_code}"
    log_warn "Bootstrap baseline snapshot available for restore"
    log_warn "Snapshot name: ${snapshot_name}"
    log_warn "Metadata file: ${metadata_file}"
    
    # Check if restore-info.txt exists
    local restore_file="${LINUS_SNAPSHOT_DIR}/restore-info.txt"
    if [[ -f "${restore_file}" ]]; then
        log_info "=========================================="
        log_info "Restore information:"
        log_info "=========================================="
        cat "${restore_file}"
        log_info "=========================================="
        log_info ""
        log_info "To restore from snapshot, run:"
        log_info "  source ${restore_file}  # Load variables"
        log_info "  export PROVIDER PROVM_IDENTIFIER SNAPSHOT_NAME"
        log_info "  ${SCRIPT_DIR}/restore-snapshot.sh"
        log_info ""
    fi
    
    # Output structured failure info
    echo "LINUS_BOOTSTRAP_FAILED:true"
    echo "LINUS_SNAPSHOT_AVAILABLE:true"
    echo "LINUS_SNAPSHOT_NAME:${snapshot_name}"
    
    # Return exit code 3 to indicate bootstrap failed but snapshot available
    return 3
}

function cleanup_old_snapshots() {
    local max_age_days="${MAX_SNAPSHOT_AGE_DAYS:-7}"
    
    log_info "Cleaning up snapshots older than ${max_age_days} days..."
    
    if [[ ! -d "${LINUS_SNAPSHOT_DIR}" ]]; then
        return 0
    fi
    
    # Find and remove old snapshot metadata files
    local found_old=false
    while IFS= read -r -d '' file; do
        log_info "Removing old snapshot metadata: $(basename "${file}")"
        rm -f "${file}"
        found_old=true
    done < <(find "${LINUS_SNAPSHOT_DIR}" -name "*.meta.json" -mtime +${max_age_days} -print0 2>/dev/null)
    
    if [[ "${found_old}" == "true" ]]; then
        log_info "Cleanup complete"
    else
        log_info "No old snapshots to remove"
    fi
}

# -----------------------------------------------------------------------------
# Main Execution
# -----------------------------------------------------------------------------

main() {
    log_header "Bootstrap Snapshot Wrapper"
    
    # Check for help
    if [[ $# -gt 0 ]] && [[ "$1" == "--help" || "$1" == "-h" ]]; then
        show_help
        exit 0
    fi
    
    # Validate arguments
    if [[ $# -lt 1 ]]; then
        log_error "Bootstrap script path required"
        show_help
        exit 1
    fi
    
    local bootstrap_script="$1"
    shift
    local bootstrap_args="$*"
    
    # Store for metadata
    BOOTSTRAP_SCRIPT="${bootstrap_script}"
    BOOTSTRAP_ARGS="${bootstrap_args}"
    
    # Ensure snapshot directory exists
    mkdir -p "${LINUS_SNAPSHOT_DIR}"
    
    # Set up trap for failure handling
    local snapshot_name=""
    local metadata_file=""
    local snapshot_created=false
    
    trap 'if [[ "${snapshot_created}" == "true" && -n "${snapshot_name}" && -n "${metadata_file}" ]]; then
        offer_restore_on_failure $? "${snapshot_name}" "${metadata_file}"
    fi' EXIT
    
    # Step 1: Create snapshot
    if ! create_snapshot_before_bootstrap; then
        log_error "Failed to create snapshot, aborting bootstrap"
        exit 2
    fi
    
    # Capture snapshot info from output
    snapshot_name=$(echo "$?" | grep -oP 'LINUS_SNAPSHOT_NAME:\K[^]+' || echo "${SNAPSHOT_PREFIX}-$(date +%Y%m%d-%H%M%S)")
    
    # Find metadata file
    metadata_file=$(find "${LINUS_SNAPSHOT_DIR}" -name "${SNAPSHOT_PREFIX}-"*.meta.json -printf '%T+ %p\n' 2>/dev/null | sort -r | head -1 | awk '{print $2}')
    
    if [[ -n "${metadata_file}" ]]; then
        # Read snapshot name from metadata if not already set
        snapshot_name=$(grep '"snapshot_name"' "${metadata_file}" | grep -oP '"snapshot_name":\s*"\K[^"]+' || echo "${snapshot_name}")
        snapshot_created=true
        
        # Save restore info
        save_restore_info "${snapshot_name}" "${metadata_file}"
    fi
    
    # Step 2: Run bootstrap
    local exit_code=0
    if ! run_bootstrap "${bootstrap_script}" "${bootstrap_args}"; then
        exit_code=$?
        exit $exit_code
    fi
    
    # Cleanup old snapshots (optional - run in background to not block)
    cleanup_old_snapshots &
    
    log_success "Bootstrap completed successfully with snapshot protection"
    exit 0
}

# Execute main only if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
