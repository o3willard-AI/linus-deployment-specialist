#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist - Save VM Snapshot Script
# =============================================================================
# Purpose: Save VM state for test isolation
# Author: Linus Deployment Specialist (AI-generated)
# Version: 1.0
# Automation Level: 2
#
# Required Environment Variables:
#   PROVIDER     - VM provider (proxmox|aws|qemu)
#   VM_IDENTIFIER - Identifier for the VM to snapshot
#   SNAPSHOT_NAME - Name for the snapshot (default: linus-snapshot-<timestamp>)
#
# Optional Environment Variables:
#   DESCRIPTION  - Description of the snapshot (default: "Automated snapshot")
#   DRY_RUN      - If true, show what would be done without executing (default: false)
#
# Usage:
#   ./save-snapshot.sh
#
# Exit Codes:
#   0 - Success
#   1 - General error
#   2 - Missing dependencies
#   3 - Invalid configuration
#   4 - Snapshot creation failed
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
readonly SNAPSHOT_NAME="${SNAPSHOT_NAME:-linus-snapshot-$(date +%s)}"
readonly DESCRIPTION="${DESCRIPTION:-Automated snapshot}"
readonly DRY_RUN="${DRY_RUN:-false}"

# -----------------------------------------------------------------------------
# Functions
# -----------------------------------------------------------------------------

function show_help() {
    cat << EOF
Linus Deployment Specialist - Save VM Snapshot Script
======================================================
Purpose: Save VM state for test isolation
Version: 1.0
Automation Level: 2

Required Environment Variables:
  PROVIDER       - VM provider (proxmox|aws|qemu)
  VM_IDENTIFIER  - Identifier for the VM to snapshot
  SNAPSHOT_NAME  - Name for the snapshot (default: linus-snapshot-<timestamp>)

Optional Environment Variables:
  DESCRIPTION    - Description of the snapshot (default: "Automated snapshot")
  DRY_RUN        - If true, show what would be done without executing (default: false)

Usage:
  export PROVIDER="proxmox"
  export VM_IDENTIFIER="100"
  export SNAPSHOT_NAME="baseline-snapshot"
  ./save-snapshot.sh

  # With custom description and dry-run
  export DESCRIPTION="Pre-test baseline"
  export DRY_RUN=true
  ./save-snapshot.sh

Exit Codes:
  0 - Success
  1 - General error
  2 - Missing dependencies
  3 - Invalid configuration
  4 - Snapshot creation failed

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

function create_proxmox_snapshot() {
    local vm_id="$1"
    local snapshot_name="$2"
    local description="$3"
    
    log_info "Creating Proxmox snapshot: ${snapshot_name} for VM ${vm_id}"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would run: qm snapshot ${vm_id} ${snapshot_name}"
        return 0
    fi
    
    # Check if VM exists
    if ! qm list | grep -q "^${vm_id}\s"; then
        log_error "VM ${vm_id} not found on Proxmox"
        return 4
    fi
    
    # Stop VM if it's running (required for snapshots)
    local vm_status
    vm_status=$(qm status "${vm_id}" 2>/dev/null | grep -o "status:.*" | cut -d: -f2- | tr -d ' ')
    
    local needs_shutdown=false
    if [[ "${vm_status}" == "running" ]]; then
        log_info "VM ${vm_id} is running, will shutdown for snapshot"
        needs_shutdown=true
        
        # Shutdown gracefully first
        qm shutdown "${vm_id}" 2>/dev/null || true
        sleep 10  # Wait for shutdown
        
        # Check if still running and force stop if needed
        vm_status=$(qm status "${vm_id}" 2>/dev/null | grep -o "status:.*" | cut -d: -f2- | tr -d ' ')
        if [[ "${vm_status}" == "running" ]]; then
            log_info "Forcing VM shutdown"
            qm stop "${vm_id}" 2>/dev/null || true
            sleep 5
        fi
    fi
    
    # Create snapshot
    if qm snapshot "${vm_id}" "${snapshot_name}" --description "${description}" 2>/dev/null; then
        log_info "Proxmox snapshot ${snapshot_name} created successfully for VM ${vm_id}"
        
        # Restart VM if it was running
        if [[ "${needs_shutdown}" == true ]]; then
            log_info "Restarting VM after snapshot"
            qm start "${vm_id}" 2>/dev/null || true
        fi
        
        return 0
    else
        log_error "Failed to create Proxmox snapshot ${snapshot_name} for VM ${vm_id}"
        # Restart VM if it was running (even though snapshot failed)
        if [[ "${needs_shutdown}" == true ]]; then
            log_info "Restarting VM after failed snapshot attempt"
            qm start "${vm_id}" 2>/dev/null || true
        fi
        return 4
    fi
}

function create_aws_snapshot() {
    local instance_id="$1"
    local snapshot_name="$2"
    local description="$3"
    
    log_info "Creating AWS EC2 snapshot: ${snapshot_name} for instance ${instance_id}"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would run: aws ec2 create-image --instance-id ${instance_id} --name ${snapshot_name} --description \"${description}\""
        return 0
    fi
    
    # Check if instance exists
    local instance_state
    instance_state=$(aws ec2 describe-instances \
        --instance-ids "${instance_id}" \
        --query 'Reservations[*].Instances[*].State.Name' \
        --output text 2>/dev/null || echo "")
    
    if [[ -z "${instance_state}" ]]; then
        log_error "EC2 instance ${instance_id} not found"
        return 4
    fi
    
    # For AWS, we need to create an AMI (Amazon Machine Image) which is similar to snapshots
    local ami_id
    ami_id=$(aws ec2 create-image \
        --instance-id "${instance_id}" \
        --name "${snapshot_name}" \
        --description "${description}" \
        --output text \
        --query 'ImageId' 2>/dev/null || echo "")
    
    if [[ -n "${ami_id}" ]]; then
        log_info "AWS AMI snapshot ${snapshot_name} (${ami_id}) created successfully"
        return 0
    else
        log_error "Failed to create AWS AMI snapshot for instance ${instance_id}"
        return 4
    fi
}

function create_qemu_snapshot() {
    local vm_name="$1"
    local snapshot_name="$2"
    local description="$3"
    
    log_info "Creating QEMU snapshot: ${snapshot_name} for VM ${vm_name}"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would run: virsh snapshot-create --domain ${vm_name} --name ${snapshot_name} --description \"${description}\""
        return 0
    fi
    
    # Check if VM exists
    if ! virsh list --all | grep -q " ${vm_name}\s"; then
        log_error "VM ${vm_name} not found on QEMU"
        return 4
    fi
    
    # Stop VM if it's running (required for snapshots)
    local vm_status
    vm_status=$(virsh domstate "${vm_name}" 2>/dev/null || echo "")
    
    local needs_shutdown=false
    if [[ "${vm_status}" == "running" ]]; then
        log_info "VM ${vm_name} is running, will shutdown for snapshot"
        needs_shutdown=true
        
        # Shutdown gracefully first
        virsh shutdown "${vm_name}" 2>/dev/null || true
        sleep 10  # Wait for shutdown
        
        # Check if still running and force stop if needed
        vm_status=$(virsh domstate "${vm_name}" 2>/dev/null || echo "")
        if [[ "${vm_status}" == "running" ]]; then
            log_info "Forcing VM shutdown"
            virsh destroy "${vm_name}" 2>/dev/null || true
            sleep 5
        fi
    fi
    
    # Create snapshot using virsh
    if virsh snapshot-create \
        --domain "${vm_name}" \
        --name "${snapshot_name}" \
        --description "${description}" \
        2>/dev/null; then
        
        log_info "QEMU snapshot ${snapshot_name} created successfully for VM ${vm_name}"
        
        # Restart VM if it was running
        if [[ "${needs_shutdown}" == true ]]; then
            log_info "Restarting VM after snapshot"
            virsh start "${vm_name}" 2>/dev/null || true
        fi
        
        return 0
    else
        log_error "Failed to create QEMU snapshot ${snapshot_name} for VM ${vm_name}"
        # Restart VM if it was running (even though snapshot failed)
        if [[ "${needs_shutdown}" == true ]]; then
            log_info "Restarting VM after failed snapshot attempt"
            virsh start "${vm_name}" 2>/dev/null || true
        fi
        return 4
    fi
}

function save_metadata() {
    local provider="$1"
    local vm_id="$2"
    local snapshot_name="$3"
    local description="$4"
    
    log_info "Saving snapshot metadata..."
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would save metadata file"
        return 0
    fi
    
    # Create a simple metadata file
    local metadata_file="/tmp/${snapshot_name}-metadata.json"
    {
        echo "{"
        echo "  \"snapshot_name\": \"${snapshot_name}\","
        echo "  \"provider\": \"${provider}\","
        echo "  \"vm_identifier\": \"${vm_id}\","
        echo "  \"description\": \"${description}\","
        echo "  \"created_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
        echo "  \"version\": \"1.0\""
        echo "}"
    } > "${metadata_file}"
    
    log_info "Metadata saved to: ${metadata_file}"
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
    
    # Create snapshot based on provider
    case "${PROVIDER}" in
        proxmox)
            create_proxmox_snapshot "${VM_IDENTIFIER}" "${SNAPSHOT_NAME}" "${DESCRIPTION}" || {
                echo "LINUS_RESULT:FAILURE"
                echo "LINUS_ERROR:Proxmox snapshot creation failed"
                return 4
            }
            ;;
        aws)
            create_aws_snapshot "${VM_IDENTIFIER}" "${SNAPSHOT_NAME}" "${DESCRIPTION}" || {
                echo "LINUS_RESULT:FAILURE"
                echo "LINUS_ERROR:AWS snapshot creation failed"
                return 4
            }
            ;;
        qemu)
            create_qemu_snapshot "${VM_IDENTIFIER}" "${SNAPSHOT_NAME}" "${DESCRIPTION}" || {
                echo "LINUS_RESULT:FAILURE"
                echo "LINUS_ERROR:QEMU snapshot creation failed"
                return 4
            }
            ;;
    esac
    
    # Save metadata
    save_metadata "${PROVIDER}" "${VM_IDENTIFIER}" "${SNAPSHOT_NAME}" "${DESCRIPTION}" || {
        echo "LINUS_RESULT:FAILURE"
        echo "LINUS_ERROR:Metadata save failed"
        return 1
    }
    
    # Output success markers for agent parsing
    echo "LINUS_RESULT:SUCCESS"
    echo "LINUS_SNAPSHOT_NAME:${SNAPSHOT_NAME}"
    echo "LINUS_SNAPSHOT_PROVIDER:${PROVIDER}"
    echo "LINUS_SNAPSHOT_VM_ID:${VM_IDENTIFIER}"
    echo "LINUS_SNAPSHOT_DESCRIPTION:${DESCRIPTION}"
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