#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist - Artifact Deployment Script
# =============================================================================
# Purpose: Transfer application binaries, test files, or configuration to provisioned VMs
# Author: Linus Deployment Specialist (AI-generated)
# Version: 1.0
# Automation Level: 2
#
# Required Environment Variables:
#   TARGET_IP    - IP address of target VM
#   TARGET_USER  - SSH username on target VM
#   SOURCE_PATH  - Local path to files/directories to deploy
#
# Optional Environment Variables:
#   TARGET_PATH  - Remote destination path (default: /home/$TARGET_USER/)
#   DRY_RUN      - If set, show what would be done without executing (default: false)
#
# Usage:
#   ./artifact.sh
#
# Exit Codes:
#   0 - Success
#   1 - General error
#   2 - Missing dependencies
#   3 - Invalid configuration
#   4 - Transfer failed
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source libraries
source "$SCRIPT_DIR/../lib/paths.sh" || exit 1
source_lib "logging.sh" "validation.sh"

# Configuration from environment with defaults
readonly TARGET_IP="${TARGET_IP:-}"
readonly TARGET_USER="${TARGET_USER:-}"
readonly SOURCE_PATH="${SOURCE_PATH:-}"
readonly TARGET_PATH="${TARGET_PATH:-/home/${TARGET_USER}/}"
readonly DRY_RUN="${DRY_RUN:-false}"

# -----------------------------------------------------------------------------
# Functions
# -----------------------------------------------------------------------------

function show_help() {
    cat << EOF
Linus Deployment Specialist - Artifact Deployment Script
=========================================================
Purpose: Transfer application binaries, test files, or configuration to provisioned VMs
Version: 1.0
Automation Level: 2

Required Environment Variables:
  TARGET_IP    - IP address of target VM
  TARGET_USER  - SSH username on target VM  
  SOURCE_PATH  - Local path to files/directories to deploy

Optional Environment Variables:
  TARGET_PATH  - Remote destination path (default: /home/\$TARGET_USER/)
  DRY_RUN      - If set, show what would be done without executing (default: false)

Usage:
  export TARGET_IP="192.168.1.100"
  export TARGET_USER="ubuntu"
  export SOURCE_PATH="./build/app.tar.gz"
  ./artifact.sh

  # With dry-run mode
  export DRY_RUN=true
  ./artifact.sh

Exit Codes:
  0 - Success
  1 - General error
  2 - Missing dependencies
  3 - Invalid configuration
  4 - Transfer failed

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
    
    if [[ -z "${SOURCE_PATH}" ]]; then
        log_error "SOURCE_PATH is required"
        return 3
    fi
    
    if [[ ! -e "${SOURCE_PATH}" ]]; then
        log_error "Source path does not exist: ${SOURCE_PATH}"
        return 3
    fi
    
    # Validate SSH connectivity (skip in dry-run mode)
    if [[ "${DRY_RUN}" != "true" ]]; then
        if ! ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "${TARGET_USER}@${TARGET_IP}" "echo 'SSH connection test successful'" >/dev/null 2>&1; then
            log_error "Cannot connect to target VM at ${TARGET_USER}@${TARGET_IP}"
            return 4
        fi
    else
        log_info "[DRY RUN] Skipping SSH connectivity check"
    fi
    
    log_info "Input validation completed successfully"
    return 0
}

function get_file_stats() {
    local path="$1"
    local file_count=0
    local total_size=0
    
    if [[ -d "${path}" ]]; then
        # Get recursive file count and size for directories
        file_count=$(find "${path}" -type f | wc -l)
        total_size=$(find "${path}" -type f -exec stat -c %s {} + 2>/dev/null | awk '{sum += $1} END {print sum+0}')
    else
        # Get stats for single file
        file_count=1
        total_size=$(stat -c %s "${path}" 2>/dev/null || echo 0)
    fi
    
    echo "${file_count} ${total_size}"
}

function calculate_transfer_time() {
    local size_mb="$1"
    local estimated_speed_mb_per_sec=5  # Conservative estimate for network transfer
    local time_seconds=0
    
    if [[ ${size_mb} -gt 0 ]]; then
        time_seconds=$(( (size_mb + estimated_speed_mb_per_sec - 1) / estimated_speed_mb_per_sec ))
    fi
    
    echo "${time_seconds}"
}

function perform_transfer() {
    local source_path="$1"
    local target_ip="$2"
    local target_user="$3"
    local target_path="$4"
    
    log_info "Starting artifact transfer from ${source_path} to ${target_user}@${target_ip}:${target_path}"
    
    # Get file stats
    local stats
    stats=$(get_file_stats "${source_path}")
    local file_count=$(echo "${stats}" | cut -d' ' -f1)
    local total_size=$(echo "${stats}" | cut -d' ' -f2)
    
    local size_mb=$((total_size / 1024 / 1024))
    local transfer_time
    transfer_time=$(calculate_transfer_time "${size_mb}")
    
    log_info "Transferring ${file_count} files (${size_mb} MB) - estimated time: ${transfer_time}s"
    
    # Use rsync if available, fallback to scp
    if command -v rsync >/dev/null 2>&1; then
        log_info "Using rsync for transfer..."
        if [[ "${DRY_RUN}" == "true" ]]; then
            log_info "[DRY RUN] Would run: rsync -avz --stats ${source_path}/ ${target_user}@${target_ip}:${target_path}"
        else
            if ! rsync -avz --stats "${source_path}/" "${target_user}@${target_ip}:${target_path}"; then
                log_error "rsync transfer failed"
                return 4
            fi
        fi
    else
        log_info "Using scp for transfer (rsync not available)..."
        if [[ "${DRY_RUN}" == "true" ]]; then
            log_info "[DRY RUN] Would run: scp -r ${source_path}/* ${target_user}@${target_ip}:${target_path}"
        else
            if ! scp -r "${source_path}"/* "${target_user}@${target_ip}:${target_path}"; then
                log_error "scp transfer failed"
                return 4
            fi
        fi
    fi
    
    log_info "Transfer completed successfully"
    return 0
}

function verify_transfer() {
    local source_path="$1"
    local target_ip="$2"
    local target_user="$3"
    local target_path="$4"
    
    log_info "Verifying transfer..."
    
    # Get source file stats
    local src_stats
    src_stats=$(get_file_stats "${source_path}")
    local src_file_count=$(echo "${src_stats}" | cut -d' ' -f1)
    local src_total_size=$(echo "${src_stats}" | cut -d' ' -f2)
    
    # Get destination file stats
    local dest_files
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would check destination files"
        return 0
    else
        if ! dest_files=$(ssh "${target_user}@${target_ip}" "find '${target_path}' -type f | wc -l" 2>/dev/null); then
            log_error "Failed to count destination files"
            return 1
        fi
        
        local dest_file_count=${dest_files:-0}
        
        # Basic verification - check if file count is reasonable
        if [[ ${dest_file_count} -gt 0 ]]; then
            log_info "Verification successful: ${dest_file_count} files found on destination"
            return 0
        else
            log_error "No files found on destination - transfer may have failed"
            return 1
        fi
    fi
}

# -----------------------------------------------------------------------------
# Main Execution
# -----------------------------------------------------------------------------

main() {
    log_info "Starting $SCRIPT_NAME"
    
    # Validate prerequisites
    if ! validate_inputs; then
        echo "LINUS_RESULT:FAILURE"
        echo "LINUS_ERROR:Input validation failed"
        return 3
    fi
    
    # Perform transfer
    if ! perform_transfer "${SOURCE_PATH}" "${TARGET_IP}" "${TARGET_USER}" "${TARGET_PATH}"; then
        echo "LINUS_RESULT:FAILURE"
        echo "LINUS_ERROR:File transfer failed"
        return 4
    fi
    
    # Verify transfer
    if ! verify_transfer "${SOURCE_PATH}" "${TARGET_IP}" "${TARGET_USER}" "${TARGET_PATH}"; then
        echo "LINUS_RESULT:FAILURE"
        echo "LINUS_ERROR:Transfer verification failed"
        return 4
    fi
    
    # Output success markers for agent parsing
    echo "LINUS_RESULT:SUCCESS"
    echo "LINUS_ARTIFACT_COUNT:${file_count:-0}"
    echo "LINUS_ARTIFACT_SIZE:${total_size:-0}"
    echo "LINUS_ARTIFACT_TARGET:${TARGET_PATH}"
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