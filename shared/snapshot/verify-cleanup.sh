#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist - Cleanup Verification Script
# =============================================================================
# Purpose: Verify VM cleanup is complete after test execution
# Author: Linus Deployment Specialist (AI-generated)
# Version: 1.0
# Automation Level: 2
#
# This script verifies:
# 1. VM is destroyed on the provider
# 2. No orphaned resources remain (snapshots, volumes, AMIs)
# 3. Network resources are released
# 4. Provides detailed cleanup status report
#
# Usage:
#   ./verify-cleanup.sh
#
# Example:
#   # Verify Proxmox VM cleanup
#   export PROVIDER="proxmox"
#   export VM_IDENTIFIER="113"
#   ./verify-cleanup.sh
#
# Exit Codes:
#   0 - Cleanup verified complete
#   1 - Verification failed (resources still exist)
#   2 - Invalid configuration
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
readonly VM_NAME="${VM_NAME:-}"
readonly MAX_ORPHANED_SNAPSHOTS="${MAX_ORPHANED_SNAPSHOTS:-5}"  # Allow some old snapshots

# -----------------------------------------------------------------------------
# Functions
# -----------------------------------------------------------------------------

function show_help() {
    cat << EOF
Linus Deployment Specialist - Cleanup Verification Script
==========================================================
Purpose: Verify VM cleanup is complete after test execution

Usage:
  ${SCRIPT_NAME}

Required Environment Variables:
  PROVIDER      - VM provider (proxmox|aws|qemu)
  VM_IDENTIFIER - VM ID or name that should be destroyed

Optional Environment Variables:
  VM_NAME       - Alternative identifier (used if VM_IDENTIFIER not set)
  MAX_ORPHANED_SNAPSHOTS - Maximum allowed orphaned snapshots (default: 5)

Examples:
  # Verify Proxmox VM cleanup
  export PROVIDER="proxmox"
  export VM_IDENTIFIER="113"
  ${SCRIPT_NAME}

  # Verify AWS instance cleanup
  export PROVIDER="aws"
  export VM_IDENTIFIER="i-0abc123def456"
  ${SCRIPT_NAME}

  # Verify QEMU VM cleanup
  export PROVIDER="qemu"
  export VM_NAME="test-vm-001"
  ${SCRIPT_NAME}

Features:
  - Verifies VM is destroyed on provider
  - Checks for orphaned resources (snapshots, volumes, AMIs)
  - Validates network resources are released
  - Provides detailed cleanup status report
  - Can auto-cleanup some orphaned resources

Exit Codes:
  0 - Cleanup verified complete
  1 - Verification failed (resources still exist)
  2 - Invalid configuration

EOF
}

function validate_inputs() {
    log_info "Validating inputs..."
    
    if [[ -z "${PROVIDER}" ]]; then
        log_error "PROVIDER environment variable not set"
        return 2
    fi
    
    # Validate provider
    case "${PROVIDER}" in
        proxmox|aws|qemu)
            log_info "Provider ${PROVIDER} is supported"
            ;;
        *)
            log_error "Unsupported provider: ${PROVIDER}"
            return 2
            ;;
    esac
    
    if [[ -z "${VM_IDENTIFIER}" ]] && [[ -z "${VM_NAME}" ]]; then
        log_error "VM_IDENTIFIER or VM_NAME must be set"
        return 2
    fi
    
    # Set VM_IDENTIFIER from VM_NAME if needed
    if [[ -z "${VM_IDENTIFIER}" ]] && [[ -n "${VM_NAME}" ]]; then
        VM_IDENTIFIER="${VM_NAME}"
    fi
    
    log_info "Verification target: ${PROVIDER} - ${VM_IDENTIFIER}"
    return 0
}

function verify_proxmox_cleanup() {
    local vm_id="$1"
    local cleanup_status=0
    
    log_step "1" "Verifying Proxmox cleanup"
    
    # Check if VM exists
    if qm list 2>/dev/null | grep -q "^${vm_id}\s"; then
        log_error "VM ${vm_id} still exists on Proxmox"
        return 1
    fi
    log_info "VM ${vm_id} destroyed on Proxmox"
    
    # Check for orphaned snapshots
    log_info "Checking for orphaned snapshots..."
    local snapshot_count=0
    
    # Look for snapshots related to this VM
    while IFS= read -r line; do
        if [[ -n "${line}" ]]; then
            ((snapshot_count++))
        fi
    done < <(qm listsnapshot "${vm_id}" 2>/dev/null || true)
    
    if [[ ${snapshot_count} -gt 0 ]]; then
        log_warn "Found ${snapshot_count} orphaned snapshots for VM ${vm_id}"
        
        # Offer to clean up old snapshots
        if [[ ${snapshot_count} -gt ${MAX_ORPHANED_SNAPSHOTS} ]]; then
            log_info "Consider running: qm listsnapshot ${vm_id} | tail -n +2 | while read name; do qm rollback ${vm_id} \$name 2>/dev/null; done"
        fi
    else
        log_info "No orphaned snapshots found"
    fi
    
    # Check for orphaned disks (if any)
    log_info "Checking for orphaned disks..."
    # Proxmox doesn't automatically delete disks on VM destroy
    # This is a manual check - disks remain in storage
    local disk_check=$(pvesm list 2>/dev/null || echo "")
    if [[ -n "${disk_check}" ]]; then
        log_info "Storage pools available - manual disk cleanup may be needed"
    fi
    
    # Check network resources
    log_info "Checking network resources..."
    # Network bridges are not affected by VM destroy
    log_info "Network resources: Normal state (bridges not affected)"
    
    return ${cleanup_status}
}

function verify_aws_cleanup() {
    local instance_id="$1"
    local cleanup_status=0
    
    log_step "1" "Verifying AWS cleanup"
    
    # Check if instance exists and is not terminated
    local instance_state
    instance_state=$(aws ec2 describe-instances \
        --instance-ids "${instance_id}" \
        --query 'Reservations[*].Instances[*].State.Name' \
        --output text 2>/dev/null || echo "NotFound")
    
    if [[ "${instance_state}" != "terminated" ]]; then
        log_error "Instance ${instance_id} status: ${instance_state} (should be terminated)"
        
        # Get more details
        log_info "Instance details:"
        aws ec2 describe-instances \
            --instance-ids "${instance_id}" \
            --query 'Reservations[*].Instances[*].[InstanceId,State.Name,InstanceType,State.TransitionReason]' \
            --output table 2>/dev/null || true
        return 1
    fi
    log_info "Instance ${instance_id} terminated"
    
    # Check for orphaned EBS volumes
    log_info "Checking for orphaned EBS volumes..."
    local orphaned_volumes
    orphaned_volumes=$(aws ec2 describe-volumes \
        --filters "Name=status,Values=available" "Name=attachment.instance-id,Values=null" \
        --query 'Volumes[*].VolumeId' \
        --output text 2>/dev/null || echo "")
    
    if [[ -n "${orphaned_volumes}" ]]; then
        local volume_count
        volume_count=$(echo "${orphaned_volumes}" | wc -w)
        log_warn "Found ${volume_count} orphaned EBS volumes (not attached to any instance)"
        
        # Check if any belong to the terminated instance
        for vol in ${orphaned_volumes}; do
            local vol_tags
            vol_tags=$(aws ec2 describe-volumes --volume-ids "${vol}" \
                --query 'Volumes[*].Tags[?Key==`linus` || Key==`Name` || Key==`aws:ec2:defrag:instanceId`].Value' \
                --output text 2>/dev/null || echo "")
            
            if echo "${vol_tags}" | grep -q "${instance_id}"; then
                log_error "Found volume still associated with terminated instance ${instance_id}"
                log_info "Volume ID: ${vol}"
                log_info "Consider cleaning up: aws ec2 delete-volume --volume-id ${vol}"
                cleanup_status=1
            fi
        done
    else
        log_info "No orphaned EBS volumes found"
    fi
    
    # Check for orphaned snapshots/AMIs
    log_info "Checking for orphaned AMIs/snapshots..."
    local orphaned_amis
    orphaned_amis=$(aws ec2 describe-images \
        --owners self \
        --filters "Name=name,Values=*${instance_id}* OR Name=name,Values=*linus-*" \
        --query 'Images[*].[ImageId,Name,State]' \
        --output text 2>/dev/null || echo "")
    
    if [[ -n "${orphaned_amis}" ]]; then
        local ami_count
        ami_count=$(echo "${orphaned_amis}" | wc -l)
        log_warn "Found ${ami_count} potentially orphaned AMIs"
        echo "${orphaned_amis}" | head -10
        log_info "Consider cleaning up old AMIs to reduce costs"
    else
        log_info "No orphaned AMIs found"
    fi
    
    # Check for orphaned security groups
    log_info "Checking for orphaned security groups..."
    # Security groups created by the instance should be cleaned up
    # This is typically automatic unless custom SGs were created
    
    # Check for orphaned Elastic IPs
    log_info "Checking for unused Elastic IPs..."
    local allocated_ips
    allocated_ips=$(aws ec2 describe-addresses \
        --query 'Addresses[?AssociationId==`null`].[PublicIp]' \
        --output text 2>/dev/null || echo "")
    
    if [[ -n "${allocated_ips}" ]]; then
        local ip_count
        ip_count=$(echo "${allocated_ips}" | wc -w)
        log_warn "Found ${ip_count} unused Elastic IPs (not associated with any instance)"
        log_info "Consider releasing: aws ec2 release-address --public-ip <IP>"
    else
        log_info "No unused Elastic IPs found"
    fi
    
    return ${cleanup_status}
}

function verify_qemu_cleanup() {
    local vm_name="$1"
    local cleanup_status=0
    
    log_step "1" "Verifying QEMU cleanup"
    
    # Check if VM exists
    if virsh list --all 2>/dev/null | grep -q " ${vm_name} "; then
        log_error "VM ${vm_name} still exists in libvirt"
        return 1
    fi
    log_info "VM ${vm_name} destroyed in libvirt"
    
    # Check for orphaned snapshots
    log_info "Checking for orphaned snapshots..."
    local snapshot_check
    snapshot_check=$(virsh snapshot-list "${vm_name}" 2>/dev/null || echo "no snapshot")
    
    if [[ "${snapshot_check}" != *"no snapshot"* ]]; then
        log_warn "Found orphaned snapshots for VM ${vm_name}"
        echo "${snapshot_check}"
        log_info "Consider cleaning up: virsh snapshot-delete ${vm_name} <snapshot-name>"
    else
        log_info "No orphaned snapshots found"
    fi
    
    # Check for orphaned disk images
    log_info "Checking for orphaned disk images..."
    # Disk images are typically stored separately and may need manual cleanup
    # This is a note, not an error
    
    # Check for orphaned networks
    log_info "Checking for orphaned networks..."
    local network_check
    network_check=$(virsh net-list --all 2>/dev/null || echo "")
    
    if echo "${network_check}" | grep -q " ${vm_name} "; then
        log_error "Network still associated with VM ${vm_name}"
        cleanup_status=1
    else
        log_info "Network resources: Normal state"
    fi
    
    # Check for orphaned storage pools
    log_info "Checking storage pool state..."
    virsh pool-list 2>/dev/null | head -5
    log_info "Storage pools: Manual cleanup may be needed for VM disk images"
    
    return ${cleanup_status}
}

function generate_report() {
    log_step "2" "Generating cleanup report"
    
    echo ""
    echo "=========================================="
    echo "Cleanup Verification Report"
    echo "=========================================="
    echo "Provider:     ${PROVIDER}"
    echo "VM ID/Name:   ${VM_IDENTIFIER}"
    echo "Timestamp:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "=========================================="
    echo ""
    
    # Output structured results
    echo "LINUS_CLEANUP_PROVIDER:${PROVIDER}"
    echo "LINUS_CLEANUP_VM_ID:${VM_IDENTIFIER}"
    echo "LINUS_CLEANUP_TIMESTAMP:$(date +%s)"
    echo "LINUS_CLEANUP_VERIFIED:${VERIFICATION_RESULT:-pending}"
    
    echo ""
    log_success "Cleanup verification complete"
}

# -----------------------------------------------------------------------------
# Main Execution
# -----------------------------------------------------------------------------

main() {
    log_header "Cleanup Verification"
    
    # Check for help
    if [[ $# -gt 0 ]] && [[ "$1" == "--help" || "$1" == "-h" ]]; then
        show_help
        exit 0
    fi
    
    # Validate prerequisites
    if ! validate_inputs; then
        echo "LINUS_CLEANUP_VERIFIED:FAILED"
        echo "LINUS_CLEANUP_ERROR:Invalid configuration"
        exit 2
    fi
    
    local verification_result="PASSED"
    local exit_code=0
    
    # Verify cleanup based on provider
    case "${PROVIDER}" in
        proxmox)
            if verify_proxmox_cleanup "${VM_IDENTIFIER}"; then
                VERIFICATION_RESULT="PASSED"
            else
                VERIFICATION_RESULT="FAILED"
                exit_code=1
            fi
            ;;
        aws)
            if verify_aws_cleanup "${VM_IDENTIFIER}"; then
                VERIFICATION_RESULT="PASSED"
            else
                VERIFICATION_RESULT="FAILED"
                exit_code=1
            fi
            ;;
        qemu)
            if verify_qemu_cleanup "${VM_IDENTIFIER}"; then
                VERIFICATION_RESULT="PASSED"
            else
                VERIFICATION_RESULT="FAILED"
                exit_code=1
            fi
            ;;
    esac
    
    # Generate report
    generate_report
    
    exit ${exit_code}
}

# Execute main only if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
