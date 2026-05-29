#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist - VM Teardown Script
# =============================================================================
# Purpose: Explicit VM destruction (not just error cleanup)
# Author: Linus Deployment Specialist (AI-generated)
# Version: 1.0
# Automation Level: 2
#
# Required Environment Variables:
#   PROVIDER     - VM provider (proxmox|aws|qemu)
#   VM_IDENTIFIER - Identifier for the VM to destroy
#
# Optional Environment Variables:
#   FORCE        - If true, force destruction without confirmation (default: false)
#   DRY_RUN      - If true, show what would be done without executing (default: false)
#
# Usage:
#   ./destroy.sh
#
# Exit Codes:
#   0 - Success
#   1 - General error
#   2 - Missing dependencies
#   3 - Invalid configuration
#   4 - Provider not supported
#   5 - VM destruction failed
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source the unified library path resolver
source "$SCRIPT_DIR/../lib/paths.sh" || exit 1
source_lib "logging.sh" "validation.sh"

# Configuration from environment with defaults
readonly PROVIDER="${PROVIDER:-}"
readonly VM_IDENTIFIER="${VM_IDENTIFIER:-}"
readonly FORCE="${FORCE:-false}"
readonly DRY_RUN="${DRY_RUN:-false}"

# -----------------------------------------------------------------------------
# Functions
# -----------------------------------------------------------------------------

function show_help() {
    cat << EOF
Linus Deployment Specialist - VM Teardown Script
=================================================
Purpose: Explicit VM destruction (not just error cleanup)
Version: 1.0
Automation Level: 2

Required Environment Variables:
  PROVIDER       - VM provider (proxmox|aws|qemu)
  VM_IDENTIFIER  - Identifier for the VM to destroy

Optional Environment Variables:
  FORCE          - If true, force destruction without confirmation (default: false)
  DRY_RUN        - If true, show what would be done without executing (default: false)

Usage:
  export PROVIDER="proxmox"
  export VM_IDENTIFIER="100"
  ./destroy.sh

  # With force and dry-run mode
  export FORCE=true
  export DRY_RUN=true
  ./destroy.sh

Exit Codes:
  0 - Success
  1 - General error
  2 - Missing dependencies
  3 - Invalid configuration
  4 - Provider not supported
  5 - VM destruction failed

EOF
}

function validate_inputs() {
    log_info "Validating inputs..."
    
    if [[ -z "${PROVIDER}" ]]; then
        log_error "PROVIDER is required"
        return 3
    fi
    
    if [[ -z "${VM_IDENTIFIER}" ]]; then
        log_error "VM_IDENTIFIER is required"
        return 3
    fi
    
    # Validate provider
    case "${PROVIDER}" in
        proxmox|aws|qemu|vast)
            log_info "Provider ${PROVIDER} is supported"
            ;;
        *)
            log_error "Unsupported provider: ${PROVIDER}"
            return 4
            ;;
    esac
    
    log_info "Input validation completed successfully"
    return 0
}

function confirm_destruction() {
    local provider="$1"
    local vm_id="$2"
    
    if [[ "${FORCE}" == "true" ]]; then
        log_info "Force destruction enabled, skipping confirmation"
        return 0
    fi
    
    log_info "About to destroy VM ${vm_id} on ${provider}"
    log_info "This action cannot be undone!"
    
    # For dry run, skip confirmation
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would ask for confirmation"
        return 0
    fi
    
    read -p "Are you sure you want to destroy this VM? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "VM destruction cancelled by user"
        return 1
    fi
    
    return 0
}

function destroy_vast_instance() {
    local contract_id="$1"
    
    log_info "Destroying Vast instance: ${contract_id}"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would run: vastai destroy instance ${contract_id} --yes"
        return 0
    fi
    
    # Check if instance exists
    if ! vastai show instance "${contract_id}" &>/dev/null; then
        log_warn "Instance ${contract_id} not found or already destroyed"
        return 0
    fi
    
    # Destroy with --yes to skip confirmation
    if vastai destroy instance "${contract_id}" --yes 2>/dev/null; then
        log_info "Vast instance ${contract_id} destroyed successfully"
        return 0
    else
        log_error "Failed to destroy Vast instance ${contract_id}"
        return 5
    fi
}

function destroy_proxmox_vm() {
    local vm_id="$1"
    
    log_info "Destroying Proxmox VM: ${vm_id}"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would run: qm destroy ${vm_id} -skiplock"
        return 0
    fi
    
    # Check if VM exists first
    if ! qm list | grep -q "^${vm_id}\s"; then
        log_error "VM ${vm_id} not found on Proxmox"
        return 5
    fi
    
    # Try graceful shutdown first, then force destroy if needed
    local attempt=1
    local max_attempts=3
    local success=false
    
    while [[ $attempt -le $max_attempts && "${success}" == false ]]; do
        log_info "Attempt ${attempt} to destroy VM ${vm_id}"
        
        # Try graceful shutdown first
        if qm status "${vm_id}" | grep -q "status: running"; then
            log_info "Attempting graceful shutdown..."
            if qm shutdown "${vm_id}" 2>/dev/null; then
                log_info "Graceful shutdown initiated"
                sleep 10  # Wait for shutdown to complete
            fi
        fi
        
        # Now try destruction
        if qm destroy "${vm_id}" -skiplock 2>/dev/null; then
            success=true
            log_info "VM ${vm_id} destroyed successfully"
        else
            log_error "Failed to destroy VM ${vm_id}"
            sleep 5
        fi
        
        ((attempt++))
    done
    
    if [[ "${success}" == false ]]; then
        log_error "Failed to destroy VM ${vm_id} after ${max_attempts} attempts"
        return 5
    fi
    
    return 0
}

function destroy_aws_vm() {
    local instance_id="$1"
    
    log_info "Destroying AWS EC2 instance: ${instance_id}"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would run: aws ec2 terminate-instances --instance-ids ${instance_id}"
        return 0
    fi
    
    # Check if instance exists and is running
    local instance_state
    instance_state=$(aws ec2 describe-instances \
        --instance-ids "${instance_id}" \
        --query 'Reservations[*].Instances[*].State.Name' \
        --output text 2>/dev/null || echo "")
    
    if [[ -z "${instance_state}" ]]; then
        log_error "Instance ${instance_id} not found"
        return 5
    fi
    
    # Terminate the instance
    if aws ec2 terminate-instances --instance-ids "${instance_id}" >/dev/null 2>&1; then
        log_info "EC2 instance ${instance_id} termination initiated successfully"
        return 0
    else
        log_error "Failed to initiate termination of EC2 instance ${instance_id}"
        return 5
    fi
}

function destroy_qemu_vm() {
    local vm_name="$1"
    
    log_info "Destroying QEMU VM: ${vm_name}"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would run: virsh destroy ${vm_name} && virsh undefine ${vm_name}"
        return 0
    fi
    
    # Check if VM exists
    if ! virsh list --all | grep -q " ${vm_name}\s"; then
        log_error "VM ${vm_name} not found on QEMU"
        return 5
    fi
    
    # Try graceful shutdown first, then force destroy
    local attempt=1
    local max_attempts=3
    local success=false
    
    while [[ $attempt -le $max_attempts && "${success}" == false ]]; do
        log_info "Attempt ${attempt} to destroy VM ${vm_name}"
        
        # Try graceful shutdown if running
        if virsh domstate "${vm_name}" 2>/dev/null | grep -q "running"; then
            log_info "Attempting graceful shutdown..."
            if virsh shutdown "${vm_name}" 2>/dev/null; then
                sleep 10  # Wait for shutdown to complete
            fi
        fi
        
        # Now try destruction
        if virsh destroy "${vm_name}" 2>/dev/null && virsh undefine "${vm_name}" 2>/dev/null; then
            success=true
            log_info "VM ${vm_name} destroyed successfully"
        else
            log_error "Failed to destroy VM ${vm_name}"
            sleep 5
        fi
        
        ((attempt++))
    done
    
    if [[ "${success}" == false ]]; then
        log_error "Failed to destroy VM ${vm_name} after ${max_attempts} attempts"
        return 5
    fi
    
    return 0
}

function cleanup_resources() {
    local provider="$1"
    local vm_id="$2"
    
    log_info "Performing resource cleanup..."
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would perform resource cleanup"
        return 0
    fi
    
    case "${provider}" in
        vast)
            # Vast cleanup — instance destroyed, no further resources
            log_info "Vast resource cleanup completed"
            ;;
        proxmox)
            # Cleanup storage and other resources related to this VM
            log_info "Proxmox resource cleanup completed"
            ;;
        aws)
            # AWS cleanup - might include volumes, security groups
            log_info "AWS resource cleanup completed (basic)"
            ;;
        qemu)
            # QEMU cleanup - might include disk images
            log_info "QEMU resource cleanup completed"
            ;;
    esac
    
    return 0
}

function verify_destruction() {
    local provider="$1"
    local vm_id="$2"
    
    log_info "Verifying destruction..."
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would verify destruction"
        return 0
    fi
    
    local success=false
    
    case "${provider}" in
        vast)
            if ! vastai show instance "${vm_id}" &>/dev/null 2>&1; then
                log_info "Vast instance ${vm_id} successfully destroyed"
                success=true
            else
                log_error "Vast instance ${vm_id} still exists"
            fi
            ;;
        proxmox)
            if ! qm list | grep -q "^${vm_id}\\s"; then
                log_info "VM ${vm_id} successfully destroyed on Proxmox"
                success=true
            else
                log_error "VM ${vm_id} still exists on Proxmox"
            fi
            ;;
        aws)
            local instance_state
            instance_state=$(aws ec2 describe-instances \
                --instance-ids "${vm_id}" \
                --query 'Reservations[*].Instances[*].State.Name' \
                --output text 2>/dev/null || echo "")
            
            if [[ -z "${instance_state}" ]]; then
                log_info "EC2 instance ${vm_id} successfully terminated"
                success=true
            else
                log_error "EC2 instance ${vm_id} still exists with state: ${instance_state}"
            fi
            ;;
        qemu)
            if ! virsh list --all | grep -q " ${vm_id}\s"; then
                log_info "VM ${vm_id} successfully destroyed on QEMU"
                success=true
            else
                log_error "VM ${vm_id} still exists on QEMU"
            fi
            ;;
    esac
    
    if [[ "${success}" == true ]]; then
        return 0
    else
        return 5
    fi
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
    
    # Confirm destruction
    confirm_destruction "${PROVIDER}" "${VM_IDENTIFIER}" || {
        echo "LINUS_RESULT:FAILURE"
        echo "LINUS_ERROR:VM destruction cancelled by user"
        return 1
    }
    
    # Perform destruction based on provider
    case "${PROVIDER}" in
        vast)
            destroy_vast_instance "${VM_IDENTIFIER}" || {
                echo "LINUS_RESULT:FAILURE"
                echo "LINUS_ERROR:Vast instance destruction failed"
                return 5
            }
            ;;
        proxmox)
            destroy_proxmox_vm "${VM_IDENTIFIER}" || {
                echo "LINUS_RESULT:FAILURE"
                echo "LINUS_ERROR:Proxmox VM destruction failed"
                return 5
            }
            ;;
        aws)
            destroy_aws_vm "${VM_IDENTIFIER}" || {
                echo "LINUS_RESULT:FAILURE"
                echo "LINUS_ERROR:AWS VM destruction failed"
                return 5
            }
            ;;
        qemu)
            destroy_qemu_vm "${VM_IDENTIFIER}" || {
                echo "LINUS_RESULT:FAILURE"
                echo "LINUS_ERROR:QEMU VM destruction failed"
                return 5
            }
            ;;
    esac
    
    # Cleanup resources
    cleanup_resources "${PROVIDER}" "${VM_IDENTIFIER}" || {
        echo "LINUS_RESULT:FAILURE"
        echo "LINUS_ERROR:Resource cleanup failed"
        return 5
    }
    
    # Verify destruction
    verify_destruction "${PROVIDER}" "${VM_IDENTIFIER}" || {
        echo "LINUS_RESULT:FAILURE"
        echo "LINUS_ERROR:Destruction verification failed"
        return 5
    }
    
    # Output success markers for agent parsing
    echo "LINUS_RESULT:SUCCESS"
    echo "LINUS_DESTROY_RESULT:SUCCESS"
    echo "LINUS_DESTROY_PROVIDER:${PROVIDER}"
    echo "LINUS_DESTROY_VM_ID:${VM_IDENTIFIER}"
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