#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist - Proxmox VM Provisioning
# =============================================================================
# Purpose: Create and configure VMs on Proxmox VE
# Author: Linus Deployment Specialist (AI-generated)
# Version: 1.0
# Automation Level: 1 (Non-interactive design)
#
# Required Environment Variables:
#   PROXMOX_NODE        - Proxmox node name (default: moxy)
#   PROXMOX_STORAGE     - Storage pool name (default: local-lvm)
#   PROXMOX_BRIDGE      - Network bridge (default: vmbr0)
#   VM_TEMPLATE_ID      - Template VM ID to clone (default: 9000)
#   VM_NAME             - VM name (optional)
#   VM_CPU              - CPU cores (default: 2)
#   VM_RAM              - RAM in MB (default: 2048)
#   VM_DISK             - Disk size in GB (default: 20)
#
# Usage:
#   ./proxmox.sh
#
# Exit Codes:
#   0 - Success
#   1 - General error
#   2 - Missing dependencies
#   3 - Invalid configuration
#   4 - Proxmox node offline
#   5 - VM creation failed
#   6 - Network/SSH timeout
#
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
readonly PROXMOX_NODE="${PROXMOX_NODE:-moxy}"
readonly PROXMOX_STORAGE="${PROXMOX_STORAGE:-local-lvm}"
readonly PROXMOX_BRIDGE="${PROXMOX_BRIDGE:-vmbr0}"
readonly VM_TEMPLATE_ID="${VM_TEMPLATE_ID:-9000}"

readonly VM_NAME="${VM_NAME:-}"
readonly VM_CPU="${VM_CPU:-2}"
readonly VM_RAM="${VM_RAM:-2048}"
readonly VM_DISK="${VM_DISK:-20}"

# Global variables (set by functions)
ALLOCATED_VM_ID=""
VM_IP=""
VM_SSH_USER="ubuntu"

# -----------------------------------------------------------------------------
# Function: validate_environment
# -----------------------------------------------------------------------------
# Validates that all prerequisites are met
# Returns: 0 on success, non-zero on failure
# -----------------------------------------------------------------------------

validate_environment() {
    log_step "1" "Validating environment"

    # Check required tools
    check_dependencies pvesh qm curl jq || return 2

    # Check Proxmox node status (check if uptime exists - node must be running to have uptime)
    log_info "Checking Proxmox node status..."
    local node_uptime=$(pvesh get /nodes/${PROXMOX_NODE}/status --output-format json 2>/dev/null | jq -r '.uptime // 0')

    if [[ "$node_uptime" -eq 0 ]]; then
        log_error "Proxmox node ${PROXMOX_NODE} is not accessible or offline"
        return 4
    fi
    log_info "Node online (uptime: ${node_uptime}s)"

    # Check storage exists
    log_info "Checking storage pool..."
    if ! pvesh get /storage/${PROXMOX_STORAGE} --output-format json &>/dev/null; then
        log_error "Storage pool ${PROXMOX_STORAGE} not found"
        return 3
    fi
    log_info "Storage: ${PROXMOX_STORAGE} OK"

    # Check network bridge exists
    log_info "Checking network bridge..."
    if ! ip link show "${PROXMOX_BRIDGE}" &>/dev/null; then
        log_error "Network bridge ${PROXMOX_BRIDGE} not found"
        return 3
    fi
    log_info "Bridge: ${PROXMOX_BRIDGE} OK"

    # Check template exists
    log_info "Checking template VM..."
    if ! qm status "${VM_TEMPLATE_ID}" &>/dev/null; then
        log_error "Template VM ${VM_TEMPLATE_ID} not found"
        return 3
    fi
    log_info "Template: VM ${VM_TEMPLATE_ID} OK"

    # Validate VM specification
    validate_positive_int "$VM_CPU" "CPU cores" || return 1
    validate_positive_int "$VM_RAM" "RAM (MB)" || return 1
    validate_positive_int "$VM_DISK" "Disk (GB)" || return 1

    log_success "Environment validation passed"
    return 0
}

# -----------------------------------------------------------------------------
# Function: allocate_vm_id
# -----------------------------------------------------------------------------
# Finds the next available VM ID
# Sets: ALLOCATED_VM_ID
# Returns: 0 on success, 5 on failure (no IDs available)
# -----------------------------------------------------------------------------

allocate_vm_id() {
    log_step "2" "Allocating VM ID"

    local vm_id=113  # Start from 113 (next available on moxy)

    # Find next available ID
    while qm status "$vm_id" &>/dev/null; do
        ((vm_id++))
        if [[ $vm_id -gt 999 ]]; then
            log_error "No available VM IDs (checked 113-999)"
            return 5
        fi
    done

    ALLOCATED_VM_ID="$vm_id"
    log_success "Allocated VM ID: $vm_id"
    return 0
}

# -----------------------------------------------------------------------------
# Function: clone_template
# -----------------------------------------------------------------------------
# Clones the template VM to create new VM
# Requires: ALLOCATED_VM_ID
# Returns: 0 on success, 5 on failure
# -----------------------------------------------------------------------------

clone_template() {
    log_step "3" "Cloning template VM ${VM_TEMPLATE_ID}"

    local vm_id="$ALLOCATED_VM_ID"
    local vm_name="${VM_NAME:-linus-vm-${vm_id}}"

    log_info "Creating VM ${vm_id} from template ${VM_TEMPLATE_ID}..."

    if ! qm clone "${VM_TEMPLATE_ID}" "${vm_id}" \
        --name "${vm_name}" \
        --full 1 \
        --storage "${PROXMOX_STORAGE}"; then
        log_error "Failed to clone template"
        return 5
    fi

    log_success "VM ${vm_id} created from template"
    return 0
}

# -----------------------------------------------------------------------------
# Function: configure_vm
# -----------------------------------------------------------------------------
# Configures VM resources (CPU, RAM, disk)
# Requires: ALLOCATED_VM_ID
# Returns: 0 on success, 5 on failure
# -----------------------------------------------------------------------------

configure_vm() {
    log_step "4" "Configuring VM resources"

    local vm_id="$ALLOCATED_VM_ID"

    # Set CPU and RAM
    log_info "Setting CPU: ${VM_CPU} cores, RAM: ${VM_RAM} MB..."
    if ! qm set "${vm_id}" --cores "${VM_CPU}" --memory "${VM_RAM}"; then
        log_error "Failed to set CPU/RAM"
        return 5
    fi

    # Resize disk
    log_info "Resizing disk to ${VM_DISK}G..."
    if ! qm resize "${vm_id}" scsi0 "${VM_DISK}G"; then
        log_error "Failed to resize disk"
        return 5
    fi

    # Configure SSH key access
    log_info "Configuring SSH key access..."
    if [[ -f /root/.ssh/id_rsa.pub ]]; then
        if ! qm set "${vm_id}" --sshkey /root/.ssh/id_rsa.pub; then
            log_error "Failed to configure SSH key"
            return 5
        fi
    else
        log_warn "SSH public key not found at /root/.ssh/id_rsa.pub - SSH access may not work"
    fi

    log_success "VM configured: ${VM_CPU} CPU, ${VM_RAM}MB RAM, ${VM_DISK}GB disk"
    return 0
}

# -----------------------------------------------------------------------------
# Function: start_vm
# -----------------------------------------------------------------------------
# Starts the VM
# Requires: ALLOCATED_VM_ID
# Returns: 0 on success, 5 on failure
# -----------------------------------------------------------------------------

start_vm() {
    log_step "5" "Starting VM"

    local vm_id="$ALLOCATED_VM_ID"

    if ! qm start "${vm_id}"; then
        log_error "Failed to start VM"
        return 5
    fi

    log_success "VM started"
    return 0
}

# -----------------------------------------------------------------------------
# Function: wait_for_network
# -----------------------------------------------------------------------------
# Waits for VM to get IP address via QEMU agent
# Requires: ALLOCATED_VM_ID
# Sets: VM_IP
# Returns: 0 on success, 6 on timeout
# -----------------------------------------------------------------------------

wait_for_network() {
    log_step "6" "Waiting for network configuration"

    local vm_id="$ALLOCATED_VM_ID"
    local max_wait=120
    local elapsed=0
    local vm_ip=""
    local vm_mac=""

    # Get VM MAC address for fallback network scan
    vm_mac=$(qm config "$vm_id" | grep -oP 'net0:.*virtio=\K[A-F0-9:]+' | head -1)

    while [[ $elapsed -lt $max_wait ]]; do
        # Method 1: Try to get IP from QEMU agent (preferred)
        vm_ip=$(qm agent "$vm_id" network-get-interfaces 2>/dev/null | \
                jq -r '.[] | select(.name == "eth0" or .name == "ens18" or .name == "ens3") | .["ip-addresses"][]? | select(.["ip-address-type"] == "ipv4") | .["ip-address"]' 2>/dev/null | \
                grep -v "127.0.0.1" | head -1 || echo "")

        # Method 2: Fallback to network scan if QEMU agent not available
        if [[ -z "$vm_ip" && -n "$vm_mac" ]]; then
            # Run network scan every 30s and parse output for MAC address
            if [[ $((elapsed % 30)) -eq 0 && $elapsed -gt 0 ]]; then
                vm_ip=$(nmap -sn 192.168.101.0/24 2>/dev/null | \
                        grep -B 2 -i "$vm_mac" | \
                        grep -oP 'Nmap scan report for .*\((\d+\.\d+\.\d+\.\d+)\)' | \
                        grep -oP '\d+\.\d+\.\d+\.\d+' | head -1 || echo "")

                # If no parentheses format, try simple format
                if [[ -z "$vm_ip" ]]; then
                    vm_ip=$(nmap -sn 192.168.101.0/24 2>/dev/null | \
                            grep -B 2 -i "$vm_mac" | \
                            grep -oP 'Nmap scan report for \K\d+\.\d+\.\d+\.\d+' | head -1 || echo "")
                fi
            fi
        fi

        if [[ -n "$vm_ip" ]]; then
            VM_IP="$vm_ip"
            log_success "VM IP obtained: $vm_ip"
            return 0
        fi

        sleep 5
        ((elapsed+=5))
        log_info "Waiting for network... (${elapsed}s/${max_wait}s)"
    done

    log_error "Timeout waiting for network configuration"
    return 6
}

# -----------------------------------------------------------------------------
# Function: verify_ssh_ready
# -----------------------------------------------------------------------------
# Verifies SSH is accessible on the VM
# Requires: VM_IP
# Returns: 0 on success, 6 on timeout
# -----------------------------------------------------------------------------

verify_ssh_ready() {
    log_step "7" "Verifying SSH accessibility"

    local vm_ip="$VM_IP"
    local ssh_user="${VM_SSH_USER}"
    local max_wait=60
    local elapsed=0

    while [[ $elapsed -lt $max_wait ]]; do
        if ssh -o BatchMode=yes \
               -o ConnectTimeout=5 \
               -o StrictHostKeyChecking=no \
               -o UserKnownHostsFile=/dev/null \
               "${ssh_user}@${vm_ip}" \
               "exit 0" 2>/dev/null; then
            log_success "SSH is ready at ${ssh_user}@${vm_ip}"
            return 0
        fi

        sleep 5
        ((elapsed+=5))
        log_info "Waiting for SSH... (${elapsed}s/${max_wait}s)"
    done

    log_error "SSH not accessible after ${max_wait}s"
    return 6
}

# -----------------------------------------------------------------------------
# Function: output_result
# -----------------------------------------------------------------------------
# Outputs structured result for parsing
# Requires: ALLOCATED_VM_ID, VM_IP
# -----------------------------------------------------------------------------

output_result() {
    log_step "8" "Generating output"

    local vm_name="${VM_NAME:-linus-vm-${ALLOCATED_VM_ID}}"

    # Structured output for parsing
    linus_success \
        "VM_ID:${ALLOCATED_VM_ID}" \
        "VM_IP:${VM_IP}" \
        "VM_USER:${VM_SSH_USER}" \
        "VM_NAME:${vm_name}" \
        "VM_CPU:${VM_CPU}" \
        "VM_RAM:${VM_RAM}" \
        "VM_DISK:${VM_DISK}" \
        "VM_NODE:${PROXMOX_NODE}"
}

# -----------------------------------------------------------------------------
# Function: cleanup_on_error
# -----------------------------------------------------------------------------
# Cleanup function called on error
# -----------------------------------------------------------------------------

cleanup_on_error() {
    local exit_code=$?
    if [[ $exit_code -ne 0 && -n "${ALLOCATED_VM_ID:-}" ]]; then
        log_warn "Cleaning up VM ${ALLOCATED_VM_ID} due to error..."
        qm stop "${ALLOCATED_VM_ID}" 2>/dev/null || true
        qm destroy "${ALLOCATED_VM_ID}" 2>/dev/null || true
    fi
}

# -----------------------------------------------------------------------------
# Main Function
# -----------------------------------------------------------------------------

main() {
    log_header "Linus Proxmox VM Provisioning"

    # Set trap for cleanup on error
    trap cleanup_on_error EXIT

    validate_environment || exit $?
    allocate_vm_id || exit $?
    clone_template || exit $?
    configure_vm || exit $?
    start_vm || exit $?
    wait_for_network || exit $?
    verify_ssh_ready || exit $?
    output_result

    # Disable cleanup trap on success
    trap - EXIT

    log_success "VM provisioning completed successfully"
    return 0
}

# -----------------------------------------------------------------------------
# Entry Point
# -----------------------------------------------------------------------------

# Only run main if script is executed (not sourced for testing)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
