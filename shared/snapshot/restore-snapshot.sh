#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist - Restore VM Snapshot Script
# =============================================================================
# Purpose: Restore VM from previously saved snapshot
# Author: Linus Deployment Specialist (AI-generated)
# Version: 1.0
# Automation Level: 2
#
# Required Environment Variables:
#   PROVIDER     - VM provider (proxmox|aws|qemu)
#   VM_IDENTIFIER - Identifier for the VM to restore
#   SNAPSHOT_NAME - Name of the snapshot to restore
#
# Optional Environment Variables:
#   DRY_RUN      - If true, show what would be done without executing (default: false)
#   FORCE_RESTORE - Force restore even if VM is running (default: false)
#
# Usage:
#   ./restore-snapshot.sh
#
# Exit Codes:
#   0 - Success
#   1 - General error
#   2 - Missing dependencies
#   3 - Invalid configuration
#   4 - Snapshot restore failed
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
readonly PROVIDER="${PROVIDER:-}"
readonly VM_IDENTIFIER="${VM_IDENTIFIER:-}"
readonly SNAPSHOT_NAME="${SNAPSHOT_NAME:-}"
readonly DRY_RUN="${DRY_RUN:-false}"
readonly FORCE_RESTORE="${FORCE_RESTORE:-false}"

# -----------------------------------------------------------------------------
# Functions
# -----------------------------------------------------------------------------

function show_help() {
    cat << EOF
Linus Deployment Specialist - Restore VM Snapshot Script
=========================================================
Purpose: Restore VM from previously saved snapshot
Version: 1.0
Automation Level: 2

Required Environment Variables:
  PROVIDER       - VM provider (proxmox|aws|qemu)
  VM_IDENTIFIER  - Identifier for the VM to restore
  SNAPSHOT_NAME  - Name of the snapshot to restore

Optional Environment Variables:
  DRY_RUN        - If true, show what would be done without executing (default: false)
  FORCE_RESTORE  - Force restore even if VM is running (default: false)

Usage:
  export PROVIDER="proxmox"
  export VM_IDENTIFIER="100"
  export SNAPSHOT_NAME="baseline-snapshot"
  ./restore-snapshot.sh

  # With force restore and dry-run
  export FORCE_RESTORE=true
  export DRY_RUN=true
  ./restore-snapshot.sh

Exit Codes:
  0 - Success
  1 - General error
  2 - Missing dependencies
  3 - Invalid configuration
  4 - Snapshot restore failed

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
    
    if [[ -z "${SNAPSHOT_NAME}" ]]; then
        log_error "SNAPSHOT_NAME is required"
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

function restore_proxmox_snapshot() {
    local vm_id="$1"
    local snapshot_name="$2"
    
    log_info "Restoring Proxmox snapshot: ${snapshot_name} for VM ${vm_id}"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would run: qm rollback ${vm_id} ${snapshot_name}"
        return 0
    fi
    
    # Check if VM exists
    if ! qm list | grep -q "^${vm_id}\s"; then
        log_error "VM ${vm_id} not found on Proxmox"
        return 4
    fi
    
    # Check if snapshot exists
    if ! qm listsnapshot "${vm_id}" 2>/dev/null | grep -q "^${snapshot_name}\s"; then
        log_error "Snapshot ${snapshot_name} not found for VM ${vm_id}"
        return 4
    fi
    
    # Stop VM if it's running
    local vm_status
    vm_status=$(qm status "${vm_id}" 2>/dev/null | grep -o "status:.*" | cut -d: -f2- | tr -d ' ')
    
    local needs_shutdown=false
    if [[ "${vm_status}" == "running" ]]; then
        if [[ "${FORCE_RESTORE}" == "true" ]]; then
            log_info "VM ${vm_id} is running, will shutdown for restore"
            needs_shutdown=true
            
            # Shutdown gracefully first
            qm shutdown "${vm_id}" 2>/dev/null || true
            sleep 10
            
            # Check if still running and force stop if needed
            vm_status=$(qm status "${vm_id}" 2>/dev/null | grep -o "status:.*" | cut -d: -f2- | tr -d ' ')
            if [[ "${vm_status}" == "running" ]]; then
                log_info "Forcing VM shutdown"
                qm stop "${vm_id}" 2>/dev/null || true
                sleep 5
            fi
        else
            log_error "VM ${vm_id} is running. Use FORCE_RESTORE=true to shutdown and restore"
            return 4
        fi
    fi
    
    # Restore snapshot
    if qm rollback "${vm_id}" "${snapshot_name}" 2>/dev/null; then
        log_info "Proxmox snapshot ${snapshot_name} restored successfully for VM ${vm_id}"
        
        # Restart VM if it was running
        if [[ "${needs_shutdown}" == true ]]; then
            log_info "Restarting VM after restore"
            qm start "${vm_id}" 2>/dev/null || true
        fi
        
        return 0
    else
        log_error "Failed to restore Proxmox snapshot ${snapshot_name} for VM ${vm_id}"
        # Restart VM if it was running (even though restore failed)
        if [[ "${needs_shutdown}" == true ]]; then
            log_info "Restarting VM after failed restore attempt"
            qm start "${vm_id}" 2>/dev/null || true
        fi
        return 4
    fi
}

function restore_aws_snapshot() {
    local instance_id="$1"
    local snapshot_name="$2"
    
    log_info "Restoring AWS EC2 snapshot: ${snapshot_name} for instance ${instance_id}"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would run: aws ec2 create-instances --image-id <ami-from-snapshot> --instance-type <original-type>"
        return 0
    fi
    
    # For AWS, we need to find the AMI created by the snapshot
    local ami_id
    ami_id=$(aws ec2 describe-images \
        --owners self \
        --filters "Name=name,Values=${snapshot_name}" \
        --query 'Images[0].ImageId' \
        --output text 2>/dev/null || echo "")
    
    if [[ -z "${ami_id}" || "${ami_id}" == "None" ]]; then
        log_error "AWS AMI snapshot ${snapshot_name} not found"
        return 4
    fi
    
    log_info "Found AMI ${ami_id} for snapshot ${snapshot_name}"
    
    # Get original instance details to preserve configuration
    local instance_type
    instance_type=$(aws ec2 describe-instances \
        --instance-ids "${instance_id}" \
        --query 'Reservations[*].Instances[*].InstanceType' \
        --output text 2>/dev/null || echo "t3.medium")
    
    local key_name
    key_name=$(aws ec2 describe-instances \
        --instance-ids "${instance_id}" \
        --query 'Reservations[*].Instances[*].KeyName' \
        --output text 2>/dev/null || echo "")
    
    # Terminate old instance
    log_info "Terminating old instance ${instance_id}"
    aws ec2 terminate-instances --instance-ids "${instance_id}" >/dev/null 2>&1 || true
    sleep 30  # Wait for termination
    
    # Create new instance from AMI
    log_info "Creating new instance from AMI ${ami_id}"
    local new_instance_params=(
        aws ec2 run-instances
        --image-id "${ami_id}"
        --instance-type "${instance_type}"
        --count 1
        --output text
        --query 'Instances[0].InstanceId'
    )
    
    if [[ -n "${key_name}" ]]; then
        new_instance_params+=(--key-name "${key_name}")
    fi
    
    local new_instance_id
    new_instance_id=$("${new_instance_params[@]}" 2>/dev/null || echo "")
    
    if [[ -n "${new_instance_id}" ]]; then
        log_info "AWS snapshot ${snapshot_name} restored successfully as instance ${new_instance_id}"
        echo "LINUS_NEW_INSTANCE_ID:${new_instance_id}"
        return 0
    else
        log_error "Failed to restore AWS snapshot ${snapshot_name}"
        return 4
    fi
}

function restore_qemu_snapshot() {
    local vm_name="$1"
    local snapshot_name="$2"
    
    log_info "Restoring QEMU snapshot: ${snapshot_name} for VM ${vm_name}"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would run: virsh snapshot-revert --domain ${vm_name} --name ${snapshot_name}"
        return 0
    fi
    
    # Check if VM exists
    if ! virsh list --all | grep -q " ${vm_name}\s"; then
        log_error "VM ${vm_name} not found on QEMU"
        return 4
    fi
    
    # Check if snapshot exists
    if ! virsh snapshot-list "${vm_name}" 2>/dev/null | grep -q "^ ${snapshot_name}\s"; then
        log_error "Snapshot ${snapshot_name} not found for VM ${vm_name}"
        return 4
    fi
    
    # Stop VM if it's running
    local vm_status
    vm_status=$(virsh domstate "${vm_name}" 2>/dev/null || echo "")
    
    local needs_shutdown=false
    if [[ "${vm_status}" == "running" ]]; then
        if [[ "${FORCE_RESTORE}" == "true" ]]; then
            log_info "VM ${vm_name} is running, will shutdown for restore"
            needs_shutdown=true
            
            # Shutdown gracefully first
            virsh shutdown "${vm_name}" 2>/dev/null || true
            sleep 10
            
            # Check if still running and force stop if needed
            vm_status=$(virsh domstate "${vm_name}" 2>/dev/null || echo "")
            if [[ "${vm_status}" == "running" ]]; then
                log_info "Forcing VM shutdown"
                virsh destroy "${vm_name}" 2>/dev/null || true
                sleep 5
            fi
        else
            log_error "VM ${vm_name} is running. Use FORCE_RESTORE=true to shutdown and restore"
            return 4
        fi
    fi
    
    # Restore snapshot
    if virsh snapshot-revert \
        --domain "${vm_name}" \
        --name "${snapshot_name}" \
        --running \
        2>/dev/null; then
        
        log_info "QEMU snapshot ${snapshot_name} restored successfully for VM ${vm_name}"
        
        # Start VM if it wasn't running before or if we shut it down
        if [[ "${needs_shutdown}" == true ]]; then
            log_info "Starting VM after restore"
            virsh start "${vm_name}" 2>/dev/null || true
        fi
        
        return 0
    else
        log_error "Failed to restore QEMU snapshot ${snapshot_name} for VM ${vm_name}"
        # Start VM if we shut it down (even though restore failed)
        if [[ "${needs_shutdown}" == true ]]; then
            log_info "Starting VM after failed restore attempt"
            virsh start "${vm_name}" 2>/dev/null || true
        fi
        return 4
    fi
}

# -----------------------------------------------------------------------------
# Main Execution
# -----------------------------------------------------------------------------

main() {
    log_info "Starting $SCRIPT_NAME"
    
    # Validate prerequisites
    validate_inputs || {
        echo "LINUS_RESULT:FAILURE"
        echo "LINUS_ERROR:Input validation failed"
        return 3
    }
    
    # Restore snapshot based on provider
    case "${PROVIDER}" in
        proxmox)
            restore_proxmox_snapshot "${VM_IDENTIFIER}" "${SNAPSHOT_NAME}" || {
                echo "LINUS_RESULT:FAILURE"
                echo "LINUS_ERROR:Proxmox snapshot restore failed"
                return 4
            }
            ;;
        aws)
            restore_aws_snapshot "${VM_IDENTIFIER}" "${SNAPSHOT_NAME}" || {
                echo "LINUS_RESULT:FAILURE"
                echo "LINUS_ERROR:AWS snapshot restore failed"
                return 4
            }
            ;;
        qemu)
            restore_qemu_snapshot "${VM_IDENTIFIER}" "${SNAPSHOT_NAME}" || {
                echo "LINUS_RESULT:FAILURE"
                echo "LINUS_ERROR:QEMU snapshot restore failed"
                return 4
            }
            ;;
    esac
    
    # Output success markers for agent parsing
    echo "LINUS_RESULT:SUCCESS"
    echo "LINUS_SNAPSHOT_NAME:${SNAPSHOT_NAME}"
    echo "LINUS_SNAPSHOT_PROVIDER:${PROVIDER}"
    echo "LINUS_SNAPSHOT_VM_ID:${VM_IDENTIFIER}"
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