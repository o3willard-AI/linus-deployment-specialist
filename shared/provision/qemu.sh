#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist - QEMU/libvirt VM Provisioning
# =============================================================================
# Purpose: Create and configure VMs on QEMU/libvirt host
# Author: Linus Deployment Specialist (AI-generated)
# Version: 1.0
# Automation Level: 1 (Non-interactive design)
#
# Required Environment Variables:
#   QEMU_HOST           - QEMU host IP/hostname (required)
#   QEMU_USER           - SSH username for QEMU host (required)
#   QEMU_SUDO_PASS      - Sudo password for QEMU host (required)
#   VM_NAME             - Instance name (optional, auto-generated if not set)
#   VM_CPU              - vCPUs (default: 2)
#   VM_RAM              - RAM in MB (default: 2048)
#   VM_DISK             - Disk size in GB (default: 20)
#
# Optional Environment Variables:
#   QEMU_POOL           - Storage pool name (default: default)
#   QEMU_NETWORK        - Network name (default: default)
#   QEMU_IMAGE_URL      - Cloud image URL (default: Ubuntu 24.04)
#
# Usage:
#   export QEMU_HOST=192.168.101.59
#   export QEMU_USER=sblanken
#   export QEMU_SUDO_PASS=101abn
#   ./qemu.sh
#
# Exit Codes:
#   0 - Success
#   1 - General error
#   2 - Missing dependencies
#   3 - Invalid configuration
#   4 - QEMU host unreachable
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
readonly QEMU_HOST="${QEMU_HOST:-}"
readonly QEMU_USER="${QEMU_USER:-}"
readonly QEMU_SUDO_PASS="${QEMU_SUDO_PASS:-}"
readonly QEMU_POOL="${QEMU_POOL:-default}"
readonly QEMU_NETWORK="${QEMU_NETWORK:-default}"
readonly QEMU_IMAGE_URL="${QEMU_IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"

readonly VM_NAME="${VM_NAME:-linus-vm-$(date +%s)}"
readonly VM_CPU="${VM_CPU:-2}"
readonly VM_RAM="${VM_RAM:-2048}"
readonly VM_DISK="${VM_DISK:-20}"

# SSH configuration
readonly VM_USER="ubuntu"

# Global variables
VM_IP=""
BASE_IMAGE_NAME="ubuntu-24.04-cloudimg.qcow2"
VM_DISK_PATH=""

# -----------------------------------------------------------------------------
# Function: cleanup
# -----------------------------------------------------------------------------

cleanup() {
    local exit_code=$?

    if [[ $exit_code -ne 0 && -n "${VM_NAME}" ]]; then
        log_warn "Cleaning up failed VM: ${VM_NAME}"
        ssh_sudo "virsh destroy ${VM_NAME} 2>/dev/null || true"
        ssh_sudo "virsh undefine ${VM_NAME} --remove-all-storage 2>/dev/null || true"
    fi
}

trap cleanup EXIT

# -----------------------------------------------------------------------------
# Function: ssh_sudo - Execute command on QEMU host with sudo
# -----------------------------------------------------------------------------

ssh_sudo() {
    local cmd="$1"
    if [[ -n "$QEMU_SUDO_PASS" ]]; then
        sshpass -p "$QEMU_SUDO_PASS" ssh -o StrictHostKeyChecking=no "${QEMU_USER}@${QEMU_HOST}" \
            "echo '$QEMU_SUDO_PASS' | sudo -S bash -c '$cmd'"
    else
        ssh -o StrictHostKeyChecking=no "${QEMU_USER}@${QEMU_HOST}" "sudo bash -c '$cmd'"
    fi
}

ssh_exec() {
    local cmd="$1"
    ssh -o StrictHostKeyChecking=no "${QEMU_USER}@${QEMU_HOST}" "$cmd"
}

# -----------------------------------------------------------------------------
# Function: validate_environment
# -----------------------------------------------------------------------------

validate_environment() {
    log_step "1" "Validating environment"

    # Check required variables
    if [[ -z "$QEMU_HOST" ]]; then
        log_error "QEMU_HOST is required"
        return 3
    fi

    if [[ -z "$QEMU_USER" ]]; then
        log_error "QEMU_USER is required"
        return 3
    fi

    # Check dependencies
    check_dependencies ssh sshpass || return 2

    # Test SSH connection
    if ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "${QEMU_USER}@${QEMU_HOST}" "echo SSH OK" >/dev/null 2>&1; then
        log_error "Cannot connect to QEMU host: ${QEMU_HOST}"
        return 4
    fi

    # Check libvirt is available
    if ! ssh_exec "which virsh" >/dev/null 2>&1; then
        log_error "virsh not found on QEMU host"
        return 2
    fi

    # Check SSH key exists on QEMU host
    if ! ssh_exec "test -f ~/.ssh/id_rsa.pub" 2>/dev/null; then
        log_error "SSH public key not found on QEMU host at ~/.ssh/id_rsa.pub"
        log_error "Run: ssh ${QEMU_USER}@${QEMU_HOST} 'ssh-keygen -t rsa -b 4096 -N \"\"'"
        return 3
    fi

    log_success "Environment validation passed"
    return 0
}

# -----------------------------------------------------------------------------
# Function: download_base_image
# -----------------------------------------------------------------------------

download_base_image() {
    log_step "2" "Preparing base image"

    local pool_path
    pool_path=$(ssh_sudo "virsh pool-dumpxml ${QEMU_POOL}" | grep '<path>' | sed 's/.*<path>\(.*\)<\/path>.*/\1/' | tr -d ' ')

    local image_path="${pool_path}/${BASE_IMAGE_NAME}"

    # Check if base image already exists
    if ssh_sudo "test -f ${image_path}"; then
        log_info "Base image already exists: ${BASE_IMAGE_NAME}" >&2
        return 0
    fi

    log_info "Downloading Ubuntu 24.04 cloud image..." >&2
    ssh_sudo "wget -q -O ${image_path} ${QEMU_IMAGE_URL}"

    if ! ssh_sudo "test -f ${image_path}"; then
        log_error "Failed to download base image" >&2
        return 5
    fi

    log_success "Base image ready: ${BASE_IMAGE_NAME}" >&2
    return 0
}

# -----------------------------------------------------------------------------
# Function: create_cloud_init_iso
# -----------------------------------------------------------------------------

create_cloud_init_iso() {
    log_step "3" "Creating cloud-init configuration"

    local pool_path
    pool_path=$(ssh_sudo "virsh pool-dumpxml ${QEMU_POOL}" | grep '<path>' | sed 's/.*<path>\(.*\)<\/path>.*/\1/' | tr -d ' ')

    local ci_dir="/tmp/cloud-init-${VM_NAME}"
    local ci_iso="${pool_path}/${VM_NAME}-cidata.iso"

    # Read SSH public key from QEMU host (not local machine)
    # The QEMU host needs to SSH to the VM, so we use its key
    local ssh_pubkey
    ssh_pubkey=$(ssh_exec "cat ~/.ssh/id_rsa.pub")

    # Create cloud-init meta-data
    ssh_exec "mkdir -p ${ci_dir}"
    ssh_exec "cat > ${ci_dir}/meta-data" <<EOF
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
EOF

    # Create cloud-init user-data
    ssh_exec "cat > ${ci_dir}/user-data" <<EOF
#cloud-config
users:
  - name: ${VM_USER}
    ssh_authorized_keys:
      - ${ssh_pubkey}
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    groups: sudo
    shell: /bin/bash
package_update: true
EOF

    # Create ISO
    log_info "Generating cloud-init ISO..." >&2
    ssh_sudo "genisoimage -output ${ci_iso} -volid cidata -joliet -rock ${ci_dir}/user-data ${ci_dir}/meta-data 2>/dev/null"

    # Cleanup temp directory
    ssh_exec "rm -rf ${ci_dir}"

    log_success "Cloud-init ISO created" >&2
    return 0
}

# -----------------------------------------------------------------------------
# Function: create_vm
# -----------------------------------------------------------------------------

create_vm() {
    log_step "4" "Creating VM"

    local pool_path
    pool_path=$(ssh_sudo "virsh pool-dumpxml ${QEMU_POOL}" | grep '<path>' | sed 's/.*<path>\(.*\)<\/path>.*/\1/' | tr -d ' ')

    VM_DISK_PATH="${pool_path}/${VM_NAME}.qcow2"
    local base_image_path="${pool_path}/${BASE_IMAGE_NAME}"
    local ci_iso="${pool_path}/${VM_NAME}-cidata.iso"

    # Create VM disk from base image
    log_info "Creating VM disk (${VM_DISK}GB)..."
    ssh_sudo "qemu-img create -f qcow2 -F qcow2 -b ${base_image_path} ${VM_DISK_PATH} ${VM_DISK}G 2>/dev/null"

    # Create VM using virt-install
    log_info "Defining VM: ${VM_NAME}"
    log_info "  CPU: ${VM_CPU} cores"
    log_info "  RAM: ${VM_RAM}MB"
    log_info "  Disk: ${VM_DISK}GB"
    log_info "  Network: ${QEMU_NETWORK}"

    ssh_sudo "virt-install \
        --name ${VM_NAME} \
        --ram ${VM_RAM} \
        --vcpus ${VM_CPU} \
        --disk path=${VM_DISK_PATH},format=qcow2,bus=virtio \
        --disk path=${ci_iso},device=cdrom \
        --network network=${QEMU_NETWORK},model=virtio \
        --os-variant ubuntu24.04 \
        --graphics none \
        --noautoconsole \
        --import 2>&1 | grep -v '^$' || true"

    # Wait a moment for VM to start
    sleep 3

    # Verify VM is running
    if ! ssh_sudo "virsh list --name | grep -q '^${VM_NAME}$'"; then
        log_error "VM failed to start"
        return 5
    fi

    log_success "VM created and started: ${VM_NAME}"
    return 0
}

# -----------------------------------------------------------------------------
# Function: wait_for_ip
# -----------------------------------------------------------------------------

wait_for_ip() {
    log_step "5" "Waiting for VM network"

    local max_wait=240
    local elapsed=0
    local interval=5

    while [[ $elapsed -lt $max_wait ]]; do
        # Get DHCP leases and parse locally
        local dhcp_output
        dhcp_output=$(ssh_sudo "virsh net-dhcp-leases ${QEMU_NETWORK}" 2>/dev/null || echo "")

        # Get MAC from VM and find matching lease
        local mac
        mac=$(ssh_sudo "virsh domiflist ${VM_NAME}" 2>/dev/null | tail -n +3 | head -1 | awk '{print $5}')

        if [[ -n "$mac" && -n "$dhcp_output" ]]; then
            # Parse DHCP lease for this MAC (processing locally)
            VM_IP=$(echo "$dhcp_output" | grep -i "$mac" | awk '{print $5}' | cut -d'/' -f1)
        fi

        # Fallback: try domifaddr
        if [[ -z "$VM_IP" ]]; then
            VM_IP=$(ssh_sudo "virsh domifaddr ${VM_NAME} --source lease 2>/dev/null" | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1 || echo "")
        fi

        if [[ -n "$VM_IP" ]]; then
            log_success "VM IP address: ${VM_IP}"
            return 0
        fi

        sleep $interval
        elapsed=$((elapsed + interval))
        log_info "Waiting for IP address... (${elapsed}s/${max_wait}s)"
    done

    log_error "Timeout waiting for IP address"
    return 6
}

# -----------------------------------------------------------------------------
# Function: wait_for_ssh
# -----------------------------------------------------------------------------

wait_for_ssh() {
    log_step "6" "Waiting for SSH to be ready"

    local max_wait=300  # SSH wait after IP is obtained (cloud-init can be slow)
    local elapsed=0
    local interval=5

    while [[ $elapsed -lt $max_wait ]]; do
        # SSH from the QEMU host to the VM (VM is on private network)
        if ssh_exec "timeout 5 ssh -i ~/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=5 ${VM_USER}@${VM_IP} 'echo SSH ready' 2>/dev/null"; then
            log_success "SSH is ready at ${VM_USER}@${VM_IP} (via ${QEMU_HOST})"
            return 0
        fi

        sleep $interval
        elapsed=$((elapsed + interval))
        log_info "Waiting for SSH... (${elapsed}s/${max_wait}s)"
    done

    log_error "SSH timeout after ${max_wait}s"
    return 6
}

# -----------------------------------------------------------------------------
# Function: output_result
# -----------------------------------------------------------------------------

output_result() {
    log_step "7" "Generating output"

    linus_result "SUCCESS" \
        "VM_NAME:${VM_NAME}" \
        "VM_IP:${VM_IP}" \
        "VM_USER:${VM_USER}" \
        "VM_CPU:${VM_CPU}" \
        "VM_RAM:${VM_RAM}" \
        "VM_DISK:${VM_DISK}" \
        "QEMU_HOST:${QEMU_HOST}" \
        "QEMU_POOL:${QEMU_POOL}" \
        "QEMU_NETWORK:${QEMU_NETWORK}"
}

# -----------------------------------------------------------------------------
# Main Function
# -----------------------------------------------------------------------------

main() {
    log_header "Linus QEMU/libvirt Provisioning"

    validate_environment || exit $?
    download_base_image || exit $?
    create_cloud_init_iso || exit $?
    create_vm || exit $?
    wait_for_ip || exit $?
    wait_for_ssh || exit $?
    output_result

    log_success "QEMU VM provisioning completed successfully"
    return 0
}

# -----------------------------------------------------------------------------
# Entry Point
# -----------------------------------------------------------------------------

# Only run main if script is executed (not sourced for testing)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
