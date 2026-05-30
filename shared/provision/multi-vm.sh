#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist - Multi-VM Provisioning Script
# =============================================================================
# Purpose: Create N identical VMs for distributed system testing
# Author: Linus Deployment Specialist (AI-generated)
# Version: 1.0
# Automation Level: 3
#
# Required Environment Variables:
#   PROVIDER       - VM provider (proxmox|aws|qemu)
#   VM_COUNT       - Number of VMs to create (default: 2)
#   BASE_NAME      - Base name for VMs (default: linus-cluster)
#
# Optional Environment Variables:
#   VM_CPU         - CPU cores per VM (default: 2)
#   VM_RAM         - RAM in MB per VM (default: 4096)
#   VM_DISK        - Disk size in GB per VM (default: 20)
#   NETWORK_CONFIG - Network configuration (default: none)
#   DRY_RUN        - If true, show what would be done without executing (default: false)
#
# Usage:
#   ./multi-vm.sh
#
# Exit Codes:
#   0 - Success
#   1 - General error
#   2 - Missing dependencies
#   3 - Invalid configuration
#   4 - VM provisioning failed
#   5 - Network configuration failed
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
readonly VM_COUNT="${VM_COUNT:-2}"
readonly BASE_NAME="${BASE_NAME:-linus-cluster}"
readonly VM_CPU="${VM_CPU:-2}"
readonly VM_RAM="${VM_RAM:-4096}"
readonly VM_DISK="${VM_DISK:-20}"
readonly NETWORK_CONFIG="${NETWORK_CONFIG:-}"
readonly DRY_RUN="${DRY_RUN:-false}"

# Array to store VM details
declare -a VM_DETAILS

# -----------------------------------------------------------------------------
# Functions
# -----------------------------------------------------------------------------

function show_help() {
    cat << EOF
Linus Deployment Specialist - Multi-VM Provisioning Script
===========================================================
Purpose: Create N identical VMs for distributed system testing
Version: 1.0
Automation Level: 3

Required Environment Variables:
  PROVIDER       - VM provider (proxmox|aws|qemu)
  VM_COUNT       - Number of VMs to create (default: 2)
  BASE_NAME      - Base name for VMs (default: linus-cluster)

Optional Environment Variables:
  VM_CPU         - CPU cores per VM (default: 2)
  VM_RAM         - RAM in MB per VM (default: 4096)
  VM_DISK        - Disk size in GB per VM (default: 20)
  NETWORK_CONFIG - Network configuration (default: none)
  DRY_RUN        - If true, show what would be done without executing (default: false)

Usage:
  export PROVIDER="proxmox"
  export VM_COUNT=3
  export BASE_NAME="test-cluster"
  ./multi-vm.sh

  # With custom resources and dry-run
  export VM_CPU=4
  export VM_RAM=8192
  export DRY_RUN=true
  ./multi-vm.sh

Exit Codes:
  0 - Success
  1 - General error
  2 - Missing dependencies
  3 - Invalid configuration
  4 - VM provisioning failed
  5 - Network configuration failed

EOF
}

function validate_inputs() {
    log_info "Validating inputs..."
    
    if [[ -z "${PROVIDER}" ]]; then
        log_error "PROVIDER is required"
        return 3
    fi
    
    if [[ ! "$VM_COUNT" =~ ^[0-9]+$ ]] || [[ $VM_COUNT -lt 1 ]]; then
        log_error "VM_COUNT must be a positive integer"
        return 3
    fi
    
    # Validate provider
    case "${PROVIDER}" in
        proxmox|aws|qemu|vast)
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

function provision_single_vm() {
    local vm_index="$1"
    local base_name="$2"
    
    local vm_name="${base_name}-${vm_index}"
    
    log_info "Provisioning VM ${vm_index}: ${vm_name}"
    
    # Set environment variables for provisioning script
    local env_vars="VM_NAME=${vm_name} VM_CPU=${VM_CPU} VM_RAM=${VM_RAM} VM_DISK=${VM_DISK}"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would provision VM ${vm_index} with: ${env_vars} ./shared/provision/${PROVIDER}.sh"
        # Simulate successful provisioning for dry run
        local vm_ip="192.168.1.$((100 + vm_index))"
        local vm_user="ubuntu"
        local vm_id="${vm_name}"
        
        echo "${vm_name}:${vm_ip}:${vm_user}:${vm_id}"
        return 0
    else
        # Execute provisioning script
        local output
        output=$(eval "${env_vars} ./shared/provision/${PROVIDER}.sh" 2>&1)
        local exit_code=$?
        
        if [[ $exit_code -ne 0 ]]; then
            log_error "VM provisioning failed for ${vm_name}"
            log_error "$output"
            return 4
        fi
        
        # Parse output for VM details (strip all whitespace including \r\n)
        local vm_ip vm_user vm_id vm_resource
        vm_ip=$(echo "$output" | grep "LINUS_VM_IP:" | cut -d: -f2- | tr -d '\r\n\t ')
        vm_user=$(echo "$output" | grep "LINUS_VM_USER:" | cut -d: -f2- | tr -d '\r\n\t ')
        vm_id=$(echo "$output" | grep "LINUS_VM_ID:" | cut -d: -f2- | tr -d '\r\n\t ')
        vm_resource=$(echo "$output" | grep "LINUS_RESOURCE:" | cut -d: -f2- | tr -d '\r\n\t ')
        
        if [[ -z "${vm_ip}" || -z "${vm_user}" ]]; then
            log_error "Failed to extract VM details from provisioning output for ${vm_name}"
            return 4
        fi
        
        log_info "VM ${vm_index} provisioned successfully: ${vm_user}@${vm_ip} (ID: ${vm_id})"
        
        echo "${vm_name}:${vm_ip}:${vm_user}:${vm_id}"
    fi
}

function wait_for_ssh() {
    local ip="$1"
    local user="$2"
    local max_wait=300  # seconds (Ubuntu 24.04 first-boot cloud-init >120s)
    local wait_time=0
    local interval=5
    
    # Auto-detect SSH key (same logic as verify_ssh_ready in proxmox.sh)
    local ssh_key=""
    for candidate in ~/.ssh/id_ed25519_qemu_test ~/.ssh/id_ed25519 ~/.ssh/id_rsa; do
        if [[ -f "$candidate" ]]; then
            ssh_key="$candidate"
            break
        fi
    done
    
    local ssh_args=(-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes)
    if [[ -n "$ssh_key" ]]; then
        ssh_args+=(-i "$ssh_key")
    fi
    
    log_info "Waiting for SSH access to ${user}@${ip} (max ${max_wait}s)"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would wait for SSH"
        return 0
    fi
    
    while [[ $wait_time -lt $max_wait ]]; do
        local ssh_output
        ssh_output=$(ssh "${ssh_args[@]}" "${user}@${ip}" "echo 'SSH access confirmed'" 2>&1) && {
            log_info "SSH access confirmed for ${user}@${ip}"
            return 0
        }
        
        # Show first failure for diagnostics
        if [[ $wait_time -eq 0 ]]; then
            log_info "SSH error: ${ssh_output}"
        fi
        
        log_info "SSH not ready yet, waiting... (${wait_time}s/${max_wait}s)"
        sleep $interval
        wait_time=$((wait_time + interval))
    done
    
    # Show final SSH error
    local final_error
    final_error=$(ssh "${ssh_args[@]}" "${user}@${ip}" "echo test" 2>&1) || true
    log_error "Final SSH error: ${final_error}"
    log_error "Timeout waiting for SSH access to ${user}@${ip}"
    return 1
}

function configure_networking() {
    local vm_count="$1"
    local base_name="$2"
    
    log_info "Configuring networking for ${vm_count} VMs"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would configure networking"
        return 0
    fi
    
    # This is a simplified implementation - in a real environment, this would:
    # 1. Create virtual network segments
    # 2. Configure hostnames and DNS entries
    # 3. Set up inter-VM communication
    # 4. Configure firewall rules if needed
    
    case "${PROVIDER}" in
        proxmox)
            log_info "Proxmox networking configuration would be handled by VM templates"
            ;;
        aws)
            log_info "AWS VPC and security groups would be configured for inter-VM communication"
            ;;
        qemu)
            log_info "QEMU libvirt network configuration for VMs"
            # Create hosts file entries for VMs
            local hosts_file="/tmp/${base_name}-hosts"
            echo "# Multi-VM hosts file" > "${hosts_file}"
            for ((i=1; i<=vm_count; i++)); do
                local vm_name="${base_name}-${i}"
                local vm_ip="192.168.122.$((100 + i))"
                echo "${vm_ip} ${vm_name}" >> "${hosts_file}"
            done
            log_info "Created hosts file: ${hosts_file}"
            ;;
    esac
    
    return 0
}

function create_hosts_file() {
    local vm_count="$1"
    local base_name="$2"
    local output_dir="/tmp"
    
    log_info "Creating hosts file for VMs"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would create hosts file"
        return 0
    fi
    
    local hosts_file="${output_dir}/${base_name}-hosts.txt"
    {
        echo "# Multi-VM Hosts File"
        echo "# Generated on $(date)"
        echo ""
        for ((i=1; i<=vm_count; i++)); do
            local vm_name="${base_name}-${i}"
            local vm_ip="192.168.122.$((100 + i))"
            echo "${vm_ip} ${vm_name}"
        done
        echo ""
        echo "# VM Details:"
        for ((i=1; i<=vm_count; i++)); do
            local vm_name="${base_name}-${i}"
            local vm_ip="192.168.122.$((100 + i))"
            echo "VM-${i}: ${vm_name} (${vm_ip})"
        done
    } > "${hosts_file}"
    
    log_info "Hosts file created: ${hosts_file}"
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
        echo "LINUS_ERROR:Invalid configuration"
        return $ret
    }
    
    # Initialize tracking variables
    VM_DETAILS=()
    CUMULATIVE_RAM_MB=0
    CUMULATIVE_CPU=0
    CUMULATIVE_DISK_GB=0
    HOST_FREE_RAM_MB=0
    HOST_FREE_DISK_GB=0
    
    # Stage 1: Provision multiple VMs
    log_info "=== Stage 1: Provisioning ${VM_COUNT} VMs ==="
    
    for ((i=1; i<=VM_COUNT; i++)); do
        log_info "Provisioning VM $i of $VM_COUNT"
        
        # Capacity check: refuse if cumulative usage exceeds host free resources
        if [[ $HOST_FREE_RAM_MB -gt 0 && $CUMULATIVE_RAM_MB -gt 0 && \
              $((CUMULATIVE_RAM_MB + VM_RAM)) -gt $((HOST_FREE_RAM_MB - 1024)) ]]; then
            log_error "Host RAM near capacity: ${HOST_FREE_RAM_MB}MB free, cumulative ${CUMULATIVE_RAM_MB}MB used, VM needs ${VM_RAM}MB"
            echo "LINUS_RESULT:FAILURE"
            echo "LINUS_ERROR:Resource exhausted — insufficient host RAM"
            return 7
        fi
        if [[ $HOST_FREE_DISK_GB -gt 0 && $CUMULATIVE_DISK_GB -gt 0 && \
              $((CUMULATIVE_DISK_GB + VM_DISK)) -gt $HOST_FREE_DISK_GB ]]; then
            log_error "Host disk near capacity: ${HOST_FREE_DISK_GB}GB free, cumulative ${CUMULATIVE_DISK_GB}GB used, VM needs ${VM_DISK}GB"
            echo "LINUS_RESULT:FAILURE"
            echo "LINUS_ERROR:Resource exhausted — insufficient host disk"
            return 7
        fi
        
        local vm_details
        vm_details=$(provision_single_vm "$i" "${BASE_NAME}") || {
            echo "LINUS_RESULT:FAILURE"
            echo "LINUS_ERROR:VM provisioning failed"
            return 4
        }
        
        # Track cumulative resource usage from LINUS_RESOURCE output
        if [[ -n "${vm_resource:-}" ]]; then
            local parsed_ram parsed_cpu parsed_disk parsed_host_ram parsed_host_disk
            parsed_ram=$(echo "$vm_resource" | grep -oP 'ram_mb=\K[0-9]+' || echo "0")
            parsed_cpu=$(echo "$vm_resource" | grep -oP 'cpu_cores=\K[0-9]+' || echo "0")
            parsed_disk=$(echo "$vm_resource" | grep -oP 'disk_gb=\K[0-9]+' || echo "0")
            parsed_host_ram=$(echo "$vm_resource" | grep -oP 'host_free_ram_mb=\K[0-9]+' || echo "0")
            parsed_host_disk=$(echo "$vm_resource" | grep -oP 'host_free_disk_gb=\K[0-9]+' || echo "0")
            
            CUMULATIVE_RAM_MB=$((CUMULATIVE_RAM_MB + parsed_ram))
            CUMULATIVE_CPU=$((CUMULATIVE_CPU + parsed_cpu))
            CUMULATIVE_DISK_GB=$((CUMULATIVE_DISK_GB + parsed_disk))
            HOST_FREE_RAM_MB=$parsed_host_ram
            HOST_FREE_DISK_GB=$parsed_host_disk
            
            log_info "Resource usage: +${parsed_ram}MB RAM, +${parsed_cpu} CPU, +${parsed_disk}GB disk (cumulative: ${CUMULATIVE_RAM_MB}MB / ${HOST_FREE_RAM_MB}MB host free)"
        fi
        
        # Store VM details
        VM_DETAILS+=("$vm_details")
        
        # Wait briefly between provisioning to avoid overwhelming the provider
        if [[ "${DRY_RUN}" != "true" ]]; then
            sleep 2
        fi
    done
    
    # Stage 2: Configure networking
    log_info "=== Stage 2: Configuring Networking ==="
    configure_networking "${VM_COUNT}" "${BASE_NAME}" || {
        echo "LINUS_RESULT:FAILURE"
        echo "LINUS_ERROR:Network configuration failed"
        return 5
    }
    
    # Stage 3: Create hosts file
    log_info "=== Stage 3: Creating Hosts File ==="
    create_hosts_file "${VM_COUNT}" "${BASE_NAME}" || {
        echo "LINUS_RESULT:FAILURE"
        echo "LINUS_ERROR:Hosts file creation failed"
        return 1
    }
    
    # Stage 4: Verify SSH access for all VMs
    log_info "=== Stage 4: Verifying SSH Access ==="
    for ((i=1; i<=VM_COUNT; i++)); do
        local vm_details="${VM_DETAILS[$((i-1))]}"
        local vm_ip=$(echo "${vm_details}" | cut -d: -f2 | tr -d '\r\n\t ')
        local vm_user=$(echo "${vm_details}" | cut -d: -f3 | tr -d '\r\n\t ')
        
        log_info "Verifying SSH access for VM $i..."
        wait_for_ssh "${vm_ip}" "${vm_user}" || {
            echo "LINUS_RESULT:FAILURE"
            echo "LINUS_ERROR:SSH access verification failed"
            return 4
        }
    done
    
    # Output success markers for agent parsing
    echo "LINUS_RESULT:SUCCESS"
    echo "LINUS_VM_COUNT:${VM_COUNT}"
    
    # Output details for each VM
    for ((i=1; i<=VM_COUNT; i++)); do
        local vm_details="${VM_DETAILS[$((i-1))]}"
        local vm_name=$(echo "${vm_details}" | cut -d: -f1)
        local vm_ip=$(echo "${vm_details}" | cut -d: -f2)
        local vm_user=$(echo "${vm_details}" | cut -d: -f3)
        local vm_id=$(echo "${vm_details}" | cut -d: -f4)
        
        echo "LINUS_VM_${i}_NAME:${vm_name}"
        echo "LINUS_VM_${i}_IP:${vm_ip}"
        echo "LINUS_VM_${i}_USER:${vm_user}"
        echo "LINUS_VM_${i}_ID:${vm_id}"
    done
    
    echo "LINUS_SCRIPT:$SCRIPT_NAME"
    echo "LINUS_TIMESTAMP:$(date +%s)"
    
    log_info "$SCRIPT_NAME completed successfully"
    log_info "Created ${VM_COUNT} VMs with base name '${BASE_NAME}'"
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