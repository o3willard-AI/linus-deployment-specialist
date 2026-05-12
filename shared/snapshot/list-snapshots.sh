#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist - List VM Snapshots Script
# =============================================================================
# Purpose: List available snapshots for a VM
# Author: Linus Deployment Specialist (AI-generated)
# Version: 1.0
# Automation Level: 2
#
# Required Environment Variables:
#   PROVIDER     - VM provider (proxmox|aws|qemu)
#   VM_IDENTIFIER - Identifier for the VM to list snapshots for
#
# Optional Environment Variables:
#   DRY_RUN      - If true, show what would be done without executing (default: false)
#
# Usage:
#   ./list-snapshots.sh
#
# Exit Codes:
#   0 - Success
#   1 - General error
#   2 - Missing dependencies
#   3 - Invalid configuration
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
readonly PROVIDER="${PROVIDER:-}"
readonly VM_IDENTIFIER="${VM_IDENTIFIER:-}"
readonly DRY_RUN="${DRY_RUN:-false}"

# -----------------------------------------------------------------------------
# Functions
# -----------------------------------------------------------------------------

function show_help() {
    cat << EOF
Linus Deployment Specialist - List VM Snapshots Script
=======================================================
Purpose: List available snapshots for a VM
Version: 1.0
Automation Level: 2

Required Environment Variables:
  PROVIDER       - VM provider (proxmox|aws|qemu)
  VM_IDENTIFIER  - Identifier for the VM to list snapshots for

Optional Environment Variables:
  DRY_RUN        - If true, show what would be done without executing (default: false)

Usage:
  export PROVIDER="proxmox"
  export VM_IDENTIFIER="100"
  ./list-snapshots.sh

  # With dry-run mode
  export DRY_RUN=true
  ./list-snapshots.sh

Exit Codes:
  0 - Success
  1 - General error
  2 - Missing dependencies
  3 - Invalid configuration

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

function list_proxmox_snapshots() {
    local vm_id="$1"
    
    log_info "Listing Proxmox snapshots for VM ${vm_id}"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would run: qm listsnapshot ${vm_id}"
        return 0
    fi
    
    # Check if VM exists
    if ! qm list | grep -q "^${vm_id}\s"; then
        log_error "VM ${vm_id} not found on Proxmox"
        return 1
    fi
    
    # Get snapshots
    local snapshots
    snapshots=$(qm listsnapshot "${vm_id}" 2>/dev/null || echo "")
    
    if [[ -z "${snapshots}" ]]; then
        log_info "No snapshots found for VM ${vm_id}"
        echo "LINUS_SNAPSHOT_COUNT:0"
        return 0
    fi
    
    # Count snapshots (skip header line)
    local count
    count=$(echo "${snapshots}" | tail -n +2 | wc -l)
    echo "LINUS_SNAPSHOT_COUNT:${count}"
    
    # Output each snapshot
    local line_num=0
    while IFS= read -r line; do
        if [[ $line_num -eq 0 ]]; then
            # Skip header
            ((line_num++))
            continue
        fi
        
        if [[ -n "${line}" ]]; then
            local snapshot_name
            snapshot_name=$(echo "${line}" | awk '{print $1}')
            local snapshot_size
            snapshot_size=$(echo "${line}" | awk '{print $2}')
            local snapshot_date
            snapshot_date=$(echo "${line}" | awk '{print $3 " " $4}')
            local snapshot_description
            snapshot_description=$(echo "${line}" | awk '{$1=$2=$3=$4=""; print substr($0,5)}' | sed 's/^[[:space:]]*//')
            
            echo "LINUS_SNAPSHOT_${line_num}_NAME:${snapshot_name}"
            echo "LINUS_SNAPSHOT_${line_num}_SIZE:${snapshot_size}"
            echo "LINUS_SNAPSHOT_${line_num}_DATE:${snapshot_date}"
            echo "LINUS_SNAPSHOT_${line_num}_DESCRIPTION:${snapshot_description}"
            
            ((line_num++))
        fi
    done <<< "${snapshots}"
    
    return 0
}

function list_aws_snapshots() {
    local instance_id="$1"
    
    log_info "Listing AWS snapshots (AMIs) for instance ${instance_id}"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would run: aws ec2 describe-images --owners self --filters Name=name,Values=*linus-snapshot*"
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
        return 1
    fi
    
    # Find AMIs created from this instance or named with linus-snapshot pattern
    local ami_list
    ami_list=$(aws ec2 describe-images \
        --owners self \
        --filters "Name=name,Values=*linus-snapshot*" \
        --query 'Images[*].[ImageId,Name,CreationDate,Description]' \
        --output text 2>/dev/null || echo "")
    
    if [[ -z "${ami_list}" ]]; then
        log_info "No AWS AMI snapshots found for instance ${instance_id}"
        echo "LINUS_SNAPSHOT_COUNT:0"
        return 0
    fi
    
    # Count AMIs
    local count
    count=$(echo "${ami_list}" | wc -l)
    echo "LINUS_SNAPSHOT_COUNT:${count}"
    
    # Output each snapshot
    local line_num=1
    while IFS= read -r line; do
        if [[ -n "${line}" ]]; then
            local ami_id
            ami_id=$(echo "${line}" | awk '{print $1}')
            local ami_name
            ami_name=$(echo "${line}" | awk '{print $2}')
            local ami_date
            ami_date=$(echo "${line}" | awk '{print $3}')
            local ami_description
            ami_description=$(echo "${line}" | awk '{$1=$2=$3=""; print substr($0,4)}' | sed 's/^[[:space:]]*//')
            
            echo "LINUS_SNAPSHOT_${line_num}_ID:${ami_id}"
            echo "LINUS_SNAPSHOT_${line_num}_NAME:${ami_name}"
            echo "LINUS_SNAPSHOT_${line_num}_DATE:${ami_date}"
            echo "LINUS_SNAPSHOT_${line_num}_DESCRIPTION:${ami_description}"
            
            ((line_num++))
        fi
    done <<< "${ami_list}"
    
    return 0
}

function list_qemu_snapshots() {
    local vm_name="$1"
    
    log_info "Listing QEMU snapshots for VM ${vm_name}"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would run: virsh snapshot-list ${vm_name}"
        return 0
    fi
    
    # Check if VM exists
    if ! virsh list --all | grep -q " ${vm_name}\s"; then
        log_error "VM ${vm_name} not found on QEMU"
        return 1
    fi
    
    # Get snapshots
    local snapshots
    snapshots=$(virsh snapshot-list "${vm_name}" 2>/dev/null || echo "")
    
    if [[ -z "${snapshots}" ]] || [[ "${snapshots}" =~ "no snapshot" ]]; then
        log_info "No snapshots found for VM ${vm_name}"
        echo "LINUS_SNAPSHOT_COUNT:0"
        return 0
    fi
    
    # Count snapshots (skip header lines)
    local count
    count=$(echo "${snapshots}" | tail -n +3 | head -n -2 | wc -l)
    echo "LINUS_SNAPSHOT_COUNT:${count}"
    
    # Output each snapshot
    local line_num=1
    while IFS= read -r line; do
        # Skip header lines and empty lines
        if [[ $line_num -le 2 ]] || [[ -z "${line}" ]] || [[ "${line}" =~ ^[-]+$ ]]; then
            ((line_num++))
            continue
        fi
        
        # Parse snapshot info
        local snapshot_name
        snapshot_name=$(echo "${line}" | awk '{print $1}')
        local snapshot_date
        snapshot_date=$(echo "${line}" | awk '{print $2}')
        local snapshot_state
        snapshot_state=$(echo "${line}" | awk '{print $3}')
        
        echo "LINUS_SNAPSHOT_${line_num}_NAME:${snapshot_name}"
        echo "LINUS_SNAPSHOT_${line_num}_DATE:${snapshot_date}"
        echo "LINUS_SNAPSHOT_${line_num}_STATE:${snapshot_state}"
        
        ((line_num++))
    done <<< "${snapshots}"
    
    return 0
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
    
    # List snapshots based on provider
    case "${PROVIDER}" in
        proxmox)
            list_proxmox_snapshots "${VM_IDENTIFIER}" || {
                echo "LINUS_RESULT:FAILURE"
                echo "LINUS_ERROR:Failed to list Proxmox snapshots"
                return 1
            }
            ;;
        aws)
            list_aws_snapshots "${VM_IDENTIFIER}" || {
                echo "LINUS_RESULT:FAILURE"
                echo "LINUS_ERROR:Failed to list AWS snapshots"
                return 1
            }
            ;;
        qemu)
            list_qemu_snapshots "${VM_IDENTIFIER}" || {
                echo "LINUS_RESULT:FAILURE"
                echo "LINUS_ERROR:Failed to list QEMU snapshots"
                return 1
            }
            ;;
    esac
    
    # Output success markers for agent parsing
    echo "LINUS_RESULT:SUCCESS"
    echo "LINUS_PROVIDER:${PROVIDER}"
    echo "LINUS_VM_ID:${VM_IDENTIFIER}"
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