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
#   PROXMOX_HOST        - Proxmox host IP/hostname (required)
#   PROXMOX_USER        - Proxmox user (e.g., root@pam) (required)
#   PROXMOX_TOKEN_ID    - API token ID (e.g., linus-token) (required)
#   PROXMOX_TOKEN_SECRET- API token secret (required)
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

# Source the unified library path resolver
source "$SCRIPT_DIR/../lib/paths.sh" || exit 1
source_lib "logging.sh" "validation.sh"

# Configuration from environment with defaults
readonly PROXMOX_NODE="${PROXMOX_NODE:-moxy}"
readonly PROXMOX_STORAGE="${PROXMOX_STORAGE:-local-lvm}"
readonly PROXMOX_BRIDGE="${PROXMOX_BRIDGE:-vmbr0}"
readonly VM_TEMPLATE_ID="${VM_TEMPLATE_ID:-9000}"
readonly VM_OS_TYPE="${VM_OS_TYPE:-ubuntu}"

readonly VM_NAME="${VM_NAME:-}"
readonly VM_CPU="${VM_CPU:-2}"
readonly VM_RAM="${VM_RAM:-2048}"
readonly VM_DISK="${VM_DISK:-20}"

# Global variables (set by functions)
ALLOCATED_VM_ID=""
VM_IP=""

# Proxmox API helper — wraps curl with token auth
_pvesh() {
    local method="${1:-get}"
    local path="$2"
    shift 2 || true
    
    local url="https://${PROXMOX_HOST}:8006/api2/json${path}"
    local auth_header="Authorization: PVEAPIToken=${PROXMOX_USER}!${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}"
    
    case "$method" in
        get)
            curl -sk -H "$auth_header" "$url" "$@" 2>/dev/null
            ;;
        post)
            curl -sk -X POST -H "$auth_header" -H "Content-Type: application/json" "$url" "$@" 2>/dev/null
            ;;
        put)
            curl -sk -X PUT -H "$auth_header" -H "Content-Type: application/json" "$url" "$@" 2>/dev/null
            ;;
        delete)
            curl -sk -X DELETE -H "$auth_header" "$url" "$@" 2>/dev/null
            ;;
        *)
            echo "ERROR: Unknown method: $method" >&2
            return 1
            ;;
    esac
}

# Set SSH user based on OS type
case "${VM_OS_TYPE}" in
    ubuntu)
        VM_SSH_USER="ubuntu"
        ;;
    almalinux)
        VM_SSH_USER="almalinux"
        ;;
    rocky)
        VM_SSH_USER="rocky"
        ;;
    *)
        VM_SSH_USER="cloud-user"
        ;;
esac

# -----------------------------------------------------------------------------
# Function: validate_environment
# -----------------------------------------------------------------------------
# Validates that all prerequisites are met
# Returns: 0 on success, non-zero on failure
# -----------------------------------------------------------------------------

validate_environment() {
    log_step "1" "Validating environment"

    # Check required tools
    check_dependencies curl jq || return 2

    # Check Proxmox node status (check if uptime exists - node must be running to have uptime)
    log_info "Checking Proxmox node status..."
    local node_uptime=$(_pvesh get /nodes/${PROXMOX_NODE}/status | jq -r '.data.uptime // 0')

    if [[ "$node_uptime" -eq 0 ]]; then
        log_error "Proxmox node ${PROXMOX_NODE} is not accessible or offline"
        return 4
    fi
    log_info "Node online (uptime: ${node_uptime}s)"

    # Check storage exists
    log_info "Checking storage pool..."
    if ! _pvesh get /storage/${PROXMOX_STORAGE} >/dev/null 2>&1; then
        log_error "Storage pool ${PROXMOX_STORAGE} not found"
        return 3
    fi
    log_info "Storage: ${PROXMOX_STORAGE} OK"

    # Check network bridge exists - we'll just verify connectivity to API instead
    log_info "Checking network bridge..."
    if ! _pvesh get /nodes/${PROXMOX_NODE}/status >/dev/null 2>&1; then
        log_error "Network bridge ${PROXMOX_BRIDGE} not found"
        return 3
    fi
    log_info "Bridge: ${PROXMOX_BRIDGE} OK"

    # Check template exists - we'll verify via API call instead of qm command
    log_info "Checking template VM..."
    if ! _pvesh get /nodes/${PROXMOX_NODE}/qemu/${VM_TEMPLATE_ID}/status/current >/dev/null 2>&1; then
        log_error "Template VM ${VM_TEMPLATE_ID} not found"
        return 3
    fi
    log_info "Template: VM ${VM_TEMPLATE_ID} OK"

    # Validate OS type
    validate_os "${VM_OS_TYPE}" || return 3

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

    # Query cluster resources once to get all existing VM IDs (single API call)
    local used_ids
    used_ids=$(_pvesh get /cluster/resources?type=vm 2>/dev/null | \
        python3 -c "
import json, sys
data = json.load(sys.stdin)
ids = sorted(r['vmid'] for r in data['data'] if r.get('type') == 'qemu')
print(' '.join(str(i) for i in ids))
" 2>/dev/null) || used_ids=""

    # Find first available ID starting from next free slot
    local vm_id=113
    while true; do
        # Check if vm_id appears as a whole word in used_ids
        if ! echo " $used_ids " | grep -q " $vm_id "; then
            ALLOCATED_VM_ID="$vm_id"
            log_success "Allocated VM ID: $vm_id (used: $used_ids)"
            return 0
        fi
        ((vm_id++))
        if [[ $vm_id -gt 999 ]]; then
            log_error "No available VM IDs (checked 113-999)"
            return 5
        fi
    done
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

    # Clone the template using API call
    if ! _pvesh post /nodes/${PROXMOX_NODE}/qemu/${VM_TEMPLATE_ID}/clone \
        --data-raw "{\"newid\":${vm_id},\"name\":\"${vm_name}\",\"full\":1,\"storage\":\"${PROXMOX_STORAGE}\"}" >/dev/null 2>&1; then
        log_error "Failed to clone template"
        return 5
    fi

    log_success "VM ${vm_id} created from template"
    
    # Regenerate cloud-init drive for the new VM (critical for network)
    log_info "Regenerating cloud-init configuration..."
    if _pvesh post /nodes/${PROXMOX_NODE}/qemu/${vm_id}/cloudinit >/dev/null 2>&1; then
        log_info "Cloud-init regenerated for VM ${vm_id}"
    else
        log_warn "Cloud-init regeneration failed (VM may not get IP via DHCP)"
    fi
    
    return 0
}

# -----------------------------------------------------------------------------
# Function: configure_network_for_os_type
# -----------------------------------------------------------------------------
# Applies OS-specific network configuration after clone
# Handles cloud-init quirks for RHEL-based distros
# Returns: 0 on success, non-zero on failure
# -----------------------------------------------------------------------------

configure_network_for_os_type() {
    local vm_id="$ALLOCATED_VM_ID"
    local os_type="${VM_OS_TYPE:-ubuntu}"
    
    log_step "4a" "Configuring network for OS type: ${os_type}"
    
    case "$os_type" in
        ubuntu|debian)
            # Ubuntu/Debian - standard cloud-init networking
            log_info "Ubuntu/Debian: Standard cloud-init networking (automatic)"
            # Ensure VM has QEMU guest agent installed and enabled
            if ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id} \
                --data-raw "{\"agent\":1,\"net0\":\"bridge=${PROXMOX_BRIDGE}\"}" >/dev/null 2>&1; then
                log_warn "Failed to configure network agent settings (non-fatal)"
            fi
            ;;
        almalinux|rocky)
            # RHEL-based distros - need explicit cloud-init configuration
            log_info "AlmaLinux/Rocky: Applying custom cloud-init network config"
            
            # Set VM OS type for Libvirt/QEMU agent to recognize as Linux
            if ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id} \
                --data-raw "{\"osinfo\":\"AlmaLinux 9\"}" >/dev/null 2>&1 && \
               ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id} \
                --data-raw "{\"osinfo\":\"Rocky Linux 9\"}" >/dev/null 2>&1; then
                # Try with generic linux for compatibility
                _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id} \
                    --data-raw "{\"osinfo\":\"Linux\"}" >/dev/null 2>&1 || true
            fi
            
            # Enable QEMU guest agent for network discovery
            if ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id} \
                --data-raw "{\"agent\":1,\"agent-xpra\":0}" >/dev/null 2>&1; then
                log_warn "Failed to configure QEMU agent (non-fatal)"
            fi
            
            # Configure network0 with explicit bridge settings
            if ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id} \
                --data-raw "{\"net0\":\"model=virtio,bridge=${PROXMOX_BRIDGE},connect=on,network=default\"}" >/dev/null 2>&1; then
                log_warn "Failed to configure net0 bridge (using default: ${PROXMOX_BRIDGE})"
            fi
            
            # For RHEL-based distros, add cloud-init specific settings
            # This helps with dhcp and network configuration timing
            if ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id} \
                --data-raw "{\"ciuser\":\"root\"}" >/dev/null 2>&1; then
                log_warn "CIUser not explicitly set (non-fatal)"
            fi
            
            # Set up for automatic IP address assignment via DHCP
            # This is critical for RHEL-based distros which sometimes fail to get IPs
            if ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id} \
                --data-raw "{\"net0\":\"ipv4=dhcp\"}" >/dev/null 2>&1; then
                log_warn "Failed to enable DHCP on net0 (non-fatal)"
            fi
            
            log_success "Network configuration applied for AlmaLinux/Rocky"
            ;;
        *)
            # Generic fallback - try both approaches
            log_info "Generic OS type: applying mixed network config"
            if ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id} \
                --data-raw "{\"agent\":1,\"net0\":\"bridge=${PROXMOX_BRIDGE}\"}" >/dev/null 2>&1; then
                log_warn "Failed to configure generic network settings (non-fatal)"
            fi
            ;;
    esac
    
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
    if ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id} \
        --data-raw "{\"cores\":${VM_CPU},\"memory\":${VM_RAM}}" >/dev/null 2>&1; then
        log_error "Failed to set CPU/RAM"
        return 5
    fi

    # Resize disk
    log_info "Resizing disk to ${VM_DISK}G..."
    if ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id} \
        --data-raw "{\"disk\": \"scsi0=${PROXMOX_STORAGE}:${VM_DISK}G\"}" >/dev/null 2>&1; then
        log_error "Failed to resize disk"
        return 5
    fi

    # Configure SSH key access
    log_info "Configuring SSH key access..."
    if [[ -f /root/.ssh/id_rsa.pub ]]; then
        if ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id} \
            --data-raw "{\"sshkey\": \"/root/.ssh/id_rsa.pub\"}" >/dev/null 2>&1; then
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

    if ! _pvesh post /nodes/${PROXMOX_NODE}/qemu/${vm_id}/status/start >/dev/null 2>&1; then
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
    local max_wait=300  # 5 minutes for cloud-init on first boot
    local elapsed=0
    local vm_ip=""
    local vm_mac=""

    # Get VM MAC address from config for fallback scans
    vm_mac=$(_pvesh get /nodes/${PROXMOX_NODE}/qemu/${vm_id}/config 2>/dev/null | \
        python3 -c "
import json, sys, re
data = json.load(sys.stdin).get('data', {})
for k, v in data.items():
    if k.startswith('net'):
        m = re.search(r'([0-9A-Fa-f:]{17})', str(v))
        if m:
            print(m.group(1).lower())
            break
" 2>/dev/null) || vm_mac=""
    log_info "VM MAC: ${vm_mac:-unknown}"

    while [[ $elapsed -lt $max_wait ]]; do
        # Method 1: QEMU guest agent (if installed in template)
        vm_ip=$(_pvesh get /nodes/${PROXMOX_NODE}/qemu/${vm_id}/agent/network-get-interfaces 2>/dev/null | \
                python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    interfaces = data.get('data', {}).get('result', [])
    for iface in interfaces:
        if iface.get('name') in ('eth0', 'ens18', 'ens3'):
            for addr in iface.get('ip-addresses', []):
                if addr.get('ip-address-type') == 'ipv4' and not addr.get('ip-address', '').startswith('127.'):
                    print(addr['ip-address'])
                    raise SystemExit(0)
except: pass
" 2>/dev/null) || vm_ip=""

        # Method 2: Local ARP table (no deps, works if on same L2 network)
        if [[ -z "$vm_ip" && -n "$vm_mac" && $((elapsed % 15)) -eq 0 && $elapsed -gt 10 ]]; then
            vm_ip=$(ip neigh show 2>/dev/null | grep -i "$vm_mac" | awk '{print $1}' | head -1) || vm_ip=""
        fi

        # Method 3: Python scapy-free ARP scan via /proc/net/arp
        if [[ -z "$vm_ip" && -n "$vm_mac" && $((elapsed % 30)) -eq 0 && $elapsed -gt 20 ]]; then
            vm_ip=$(python3 -c "
import subprocess, re
try:
    out = subprocess.check_output(['ip', 'neigh', 'show'], text=True)
    for line in out.splitlines():
        if '${vm_mac}' in line.lower():
            ip = line.split()[0]
            if re.match(r'\d+\.\d+\.\d+\.\d+', ip):
                print(ip)
                break
except: pass
" 2>/dev/null) || vm_ip=""
        fi

        if [[ -n "$vm_ip" ]]; then
            VM_IP="$vm_ip"
            log_success "VM IP obtained: $vm_ip"
            return 0
        fi

        sleep 5
        ((elapsed+=5))
        if [[ $((elapsed % 30)) -eq 0 ]]; then
            log_info "Waiting for network... (${elapsed}s/${max_wait}s)"
        fi
    done

    log_error "Timeout waiting for network configuration (${max_wait}s)"
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
        "VM_NODE:${PROXMOX_NODE}" \
        "VM_OS_TYPE:${VM_OS_TYPE}"
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
        # Stop the VM if it exists
        _pvesh post /nodes/${PROXMOX_NODE}/qemu/${ALLOCATED_VM_ID}/status/stop >/dev/null 2>&1 || true
        # Destroy the VM
        _pvesh delete /nodes/${PROXMOX_NODE}/qemu/${ALLOCATED_VM_ID} >/dev/null 2>&1 || true
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
    configure_network_for_os_type || exit $?  # NEW: Configure network after clone
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
