#!/usr/bin/env bash

# ============================================================================= 
# Linus Deployment Specialist - Pre-Flight Provider Validator
# ============================================================================= 
# This script validates a provider environment before provisioning to catch
# configuration issues early. It supports QEMU, Proxmox, and AWS providers.
#
# Usage:
#   ./scripts/check-provider.sh qemu --host 192.168.101.59 --user sblanken
#   ./scripts/check-provider.sh proxmox --host 192.168.101.155 --user root
#   ./scripts/check-provider.sh aws --region us-west-2
#
# =============================================================================

# Source unified path resolver and shared libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/lib/paths.sh" || exit 1
source_lib "logging.sh" "validation.sh" || exit 1

# ----------------------------------------------------------------------------- 
# Utility Functions
# ----------------------------------------------------------------------------- 

# SSH authentication with key/password/bare fallback
_auth_ssh() {
    local host="$1"
    local cmd="${2:-true}"
    local user="${3:-$(whoami)}"
    
    # Try to connect using SSH key first (if available)
    if [[ -f ~/.ssh/id_rsa ]] || [[ -f ~/.ssh/id_ed25519 ]]; then
        if ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
             -i ~/.ssh/id_rsa "${user}@${host}" "true" 2>/dev/null; then
            ssh "$@" || return 1
            return 0
        elif ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
             -i ~/.ssh/id_ed25519 "${user}@${host}" "true" 2>/dev/null; then
            ssh "$@" || return 1
            return 0
        fi
    fi
    
    # If we have a password, try with sshpass
    if [[ -n "${QEMU_SUDO_PASS:-}" ]]; then
        if command -v sshpass >/dev/null 2>&1; then
            sshpass -p "${QEMU_SUDO_PASS}" ssh "$@" || return 1
            return 0
        fi
    fi
    
    # Fall back to standard SSH (interactive)
    ssh "$@" || return 1
    return 0
}

# Convert bytes to human readable format
_bytes_to_human() {
    local bytes="$1"
    local units=("B" "KiB" "MiB" "GiB" "TiB")
    local unit_index=0
    local size="$bytes"
    
    while (( $(echo "$size >= 1024" | bc -l) )) && [[ $unit_index -lt 4 ]]; do
        size=$(echo "scale=1; $size / 1024" | bc)
        ((unit_index++))
    done
    
    echo "${size} ${units[$unit_index]}"
}

# Get SSH key file on remote host
_get_ssh_key() {
    local host="$1"
    local user="$2"
    
    # Check for id_rsa.pub or id_ed25519.pub
    local pubkeys=("id_rsa.pub" "id_ed25519.pub")
    for pubkey in "${pubkeys[@]}"; do
        if _auth_ssh "$host" "test -f ~/.ssh/$pubkey && echo 'found'" "$user" 2>/dev/null | grep -q "found"; then
            echo "~/.ssh/$pubkey"
            return 0
        fi
    done
    
    # No SSH key found
    return 1
}

# Check if a cloud image exists on the host
_check_cloud_image() {
    local host="$1"
    local user="$2"
    
    # Look for Ubuntu 24.04 cloud image in default storage pool (qcow2 format)
    local image_pattern="ubuntu-24.04-cloudimg.*\.qcow2"
    
    _auth_ssh "$host" "find /var/lib/libvirt/images -name '$image_pattern' 2>/dev/null | head -1" "$user" 2>/dev/null | \
        grep -E '\.qcow2$' | head -1
}

# ----------------------------------------------------------------------------- 
# Provider Check Functions
# ----------------------------------------------------------------------------- 

# Check QEMU provider environment
_check_qemu() {
    local host="$1"
    local user="$2"
    
    log_header "Pre-Flight Check: QEMU @ $host"
    
    # Initialize counters
    local checks_passed=0
    local checks_warnings=0
    local checks_failed=0
    
    # Check 1: SSH connectivity
    if _auth_ssh "$host" "true" "$user" 2>/dev/null; then
        log_success "SSH connectivity"
        ((checks_passed++))
    else
        log_error "SSH connectivity"
        ((checks_failed++))
        return 1
    fi
    
    # Check 2: libvirt daemon
    if _auth_ssh "$host" "systemctl is-active libvirtd" "$user" 2>/dev/null | grep -q "active"; then
        local version=$(_auth_ssh "$host" "systemctl --version | head -1" "$user" 2>/dev/null | cut -d' ' -f2)
        log_success "libvirtd active (v$version)"
        ((checks_passed++))
    else
        log_error "libvirtd not active"
        ((checks_failed++))
        return 1
    fi
    
    # Check 3: libvirt version
    local virsh_version=$(_auth_ssh "$host" "virsh --version" "$user" 2>/dev/null)
    if [[ -n "$virsh_version" ]] && [[ "$virsh_version" -ge 10 ]]; then
        log_success "virsh version $virsh_version"
        ((checks_passed++))
    else
        log_warn "virsh version $virsh_version (older than recommended)"
        ((checks_warnings++))
    fi
    
    # Check 4: Required tools
    local required_tools=("virt-install" "qemu-img" "genisoimage" "sshpass")
    for tool in "${required_tools[@]}"; do
        if _auth_ssh "$host" "command -v $tool" "$user" 2>/dev/null; then
            log_success "$tool $(echo $(_auth_ssh "$host" "$tool --version" "$user" 2>/dev/null | head -1) | cut -d' ' -f1)"
            ((checks_passed++))
        else
            log_error "$tool not found"
            ((checks_failed++))
        fi
    done
    
    # Check 5: Network
    local default_net=$(_auth_ssh "$host" "virsh net-list --name | grep default" "$user" 2>/dev/null)
    if [[ -n "$default_net" ]]; then
        local net_status=$(_auth_ssh "$host" "virsh net-info default | grep 'Active:' | awk '{print \$2}'" "$user" 2>/dev/null)
        if [[ "$net_status" == "yes" ]]; then
            local net_bridge=$(_auth_ssh "$host" "virsh net-info default | grep 'Bridge:' | awk '{print \$2}'" "$user" 2>/dev/null)
            local net_cidr=$(_auth_ssh "$host" "virsh net-dumpxml default | grep 'network' | grep -o 'address=\"[0-9.]*\"' | cut -d'\"' -f2" "$user" 2>/dev/null)
            log_success "Network 'default' active (NAT $net_cidr)"
            ((checks_passed++))
        else
            log_error "Network 'default' not active"
            ((checks_failed++))
        fi
    else
        log_error "Network 'default' not found"
        ((checks_failed++))
    fi
    
    # Check 6: Storage pool
    local default_pool=$(_auth_ssh "$host" "virsh pool-list --name | grep default" "$user" 2>/dev/null)
    if [[ -n "$default_pool" ]]; then
        local pool_status=$(_auth_ssh "$host" "virsh pool-info default | grep 'State:' | awk '{print \$2}'" "$user" 2>/dev/null)
        if [[ "$pool_status" == "active" ]]; then
            local pool_free_space=$(_auth_ssh "$host" "virsh pool-info default | grep 'Capacity:' | awk '{print \$2}'" "$user" 2>/dev/null)
            log_success "Storage pool 'default' active ($pool_free_space free)"
            ((checks_passed++))
        else
            log_error "Storage pool 'default' not active"
            ((checks_failed++))
        fi
    else
        log_error "Storage pool 'default' not found"
        ((checks_failed++))
    fi
    
    # Check 7: KVM acceleration
    if _auth_ssh "$host" "test -r /dev/kvm" "$user" 2>/dev/null; then
        log_success "KVM acceleration available"
        ((checks_passed++))
    else
        log_warn "KVM not available — VMs will use software emulation (SLOW)"
        ((checks_warnings++))
    fi
    
    # Check 8: SSH key on host
    local ssh_key=$(_get_ssh_key "$host" "$user")
    if [[ -n "$ssh_key" ]]; then
        log_success "SSH key found: $ssh_key"
        ((checks_passed++))
    else
        log_error "No SSH key found on host"
        ((checks_failed++))
    fi
    
    # Check 9: Cloud image
    local cloud_image=$(_check_cloud_image "$host" "$user")
    if [[ -n "$cloud_image" ]]; then
        local image_size=$(_auth_ssh "$host" "stat -c %s \"$cloud_image\"" "$user" 2>/dev/null)
        local human_size=$(_bytes_to_human "$image_size")
        log_success "Cloud image cached: $(basename $cloud_image) ($human_size)"
        ((checks_passed++))
    else
        log_warn "No Ubuntu 24.04 cloud image found"
        ((checks_warnings++))
    fi
    
    # Check 10: Disk space
    local root_free_space=$(_auth_ssh "$host" "df -B1 / | tail -1 | awk '{print \$4}'" "$user" 2>/dev/null)
    if [[ -n "$root_free_space" ]]; then
        local human_space=$(_bytes_to_human "$root_free_space")
        log_success "Disk space: $human_space free on /"
        ((checks_passed++))
    else
        log_error "Cannot determine disk space"
        ((checks_failed++))
    fi
    
    # Summary
    local total_checks=$((checks_passed + checks_warnings + checks_failed))
    if [[ $checks_failed -eq 0 ]]; then
        log_success "Result: $checks_passed/$total_checks passed, $checks_warnings warning(s)"
        log_success "✅ Provider is ready for provisioning"
    else
        log_error "Result: $checks_passed/$total_checks passed, $checks_warnings warning(s), $checks_failed failed"
        log_error "❌ Provider has configuration issues"
        return 1
    fi
    
    return 0
}

# Check Proxmox provider environment (skeleton)
_check_proxmox() {
    local host="$1"
    local user="$2"
    
    log_header "Pre-Flight Check: Proxmox @ $host"
    
    # Initialize counters
    local checks_passed=0
    local checks_warnings=0
    local checks_failed=0
    
    # Check 1: SSH connectivity
    if _auth_ssh "$host" "true" "$user" 2>/dev/null; then
        log_success "SSH connectivity"
        ((checks_passed++))
    else
        log_error "SSH connectivity"
        ((checks_failed++))
        return 1
    fi
    
    # Check 2: pvesh command availability
    if _auth_ssh "$host" "command -v pvesh" "$user" 2>/dev/null; then
        log_success "pvesh available"
        ((checks_passed++))
    else
        log_error "pvesh not found"
        ((checks_failed++))
    fi
    
    # Check 3: VM templates
    local templates=$(_auth_ssh "$host" "pvesh create /nodes/$(hostname -s)/qemu/template/list | grep -c 'vmid'" "$user" 2>/dev/null)
    if [[ "$templates" -gt 0 ]]; then
        log_success "Found $templates VM template(s)"
        ((checks_passed++))
    else
        log_warn "No VM templates found"
        ((checks_warnings++))
    fi
    
    # Check 4: Storage with free space
    local storage=$(_auth_ssh "$host" "pvesh create /nodes/$(hostname -s)/storage/list | grep -E 'size.*[0-9]' | head -1 | awk '{print \$2}'" "$user" 2>/dev/null)
    if [[ -n "$storage" ]]; then
        log_success "Storage with free space available"
        ((checks_passed++))
    else
        log_error "No storage with sufficient space found"
        ((checks_failed++))
    fi
    
    # Summary
    local total_checks=$((checks_passed + checks_warnings + checks_failed))
    if [[ $checks_failed -eq 0 ]]; then
        log_success "Result: $checks_passed/$total_checks passed, $checks_warnings warning(s)"
        log_success "✅ Provider is ready for provisioning"
    else
        log_error "Result: $checks_passed/$total_checks passed, $checks_warnings warning(s), $checks_failed failed"
        log_error "❌ Provider has configuration issues"
        return 1
    fi
    
    return 0
}

# Check AWS provider environment (skeleton)
_check_aws() {
    log_header "Pre-Flight Check: AWS"
    
    # Initialize counters
    local checks_passed=0
    local checks_warnings=0
    local checks_failed=0
    
    # Check 1: AWS CLI configured
    if command -v aws >/dev/null 2>&1; then
        log_success "AWS CLI installed"
        ((checks_passed++))
    else
        log_error "AWS CLI not found"
        ((checks_failed++))
        return 1
    fi
    
    # Check 2: Can describe regions
    if aws ec2 describe-regions >/dev/null 2>&1; then
        log_success "AWS CLI configured"
        ((checks_passed++))
    else
        log_error "Cannot connect to AWS (check credentials)"
        ((checks_failed++))
        return 1
    fi
    
    # Check 3: Key pairs
    local key_pairs=$(aws ec2 describe-key-pairs --query 'KeyPairs[*].KeyName' --output text 2>/dev/null | wc -l)
    if [[ "$key_pairs" -gt 0 ]]; then
        log_success "Found AWS key pairs"
        ((checks_passed++))
    else
        log_warn "No AWS key pairs found"
        ((checks_warnings++))
    fi
    
    # Check 4: Default VPC
    local vpcs=$(aws ec2 describe-vpcs --filters 'Name=isDefault,Values=true' --query 'Vpcs[*].VpcId' --output text 2>/dev/null | wc -l)
    if [[ "$vpcs" -gt 0 ]]; then
        log_success "Default VPC found"
        ((checks_passed++))
    else
        log_warn "No default VPC found"
        ((checks_warnings++))
    fi
    
    # Summary
    local total_checks=$((checks_passed + checks_warnings + checks_failed))
    if [[ $checks_failed -eq 0 ]]; then
        log_success "Result: $checks_passed/$total_checks passed, $checks_warnings warning(s)"
        log_success "✅ Provider is ready for provisioning"
    else
        log_error "Result: $checks_passed/$total_checks passed, $checks_warnings warning(s), $checks_failed failed"
        log_error "❌ Provider has configuration issues"
        return 1
    fi
    
    return 0
}

# ----------------------------------------------------------------------------- 
# Main Execution
# ----------------------------------------------------------------------------- 

main() {
    if [[ $# -lt 2 ]]; then
        echo "Usage:"
        echo "  ./scripts/check-provider.sh qemu --host <host> --user <user>"
        echo "  ./scripts/check-provider.sh proxmox --host <host> --user <user>"
        echo "  ./scripts/check-provider.sh aws --region <region>"
        exit 1
    fi
    
    local provider="$1"
    
    # Validate provider name
    validate_provider "$provider" || exit 1
    
    case "$provider" in
        qemu)
            local host=""
            local user=""
            
            # Parse QEMU arguments
            while [[ $# -gt 0 ]]; do
                case $2 in
                    --host)
                        host="$3"
                        shift 2
                        ;;
                    --user)
                        user="$3"
                        shift 2
                        ;;
                    *)
                        shift
                        ;;
                esac
            done
            
            # Validate required parameters
            if [[ -z "$host" ]] || [[ -z "$user" ]]; then
                echo "Error: QEMU provider requires --host and --user"
                exit 1
            fi
            
            _check_qemu "$host" "$user"
            ;;
        proxmox)
            local host=""
            local user=""
            
            # Parse Proxmox arguments
            while [[ $# -gt 0 ]]; do
                case $2 in
                    --host)
                        host="$3"
                        shift 2
                        ;;
                    --user)
                        user="$3"
                        shift 2
                        ;;
                    *)
                        shift
                        ;;
                esac
            done
            
            # Validate required parameters
            if [[ -z "$host" ]] || [[ -z "$user" ]]; then
                echo "Error: Proxmox provider requires --host and --user"
                exit 1
            fi
            
            _check_proxmox "$host" "$user"
            ;;
        aws)
            local region=""
            
            # Parse AWS arguments
            while [[ $# -gt 0 ]]; do
                case $2 in
                    --region)
                        region="$3"
                        shift 2
                        ;;
                    *)
                        shift
                        ;;
                esac
            done
            
            # Validate required parameters
            if [[ -z "$region" ]]; then
                echo "Error: AWS provider requires --region"
                exit 1
            fi
            
            # Set AWS region in environment
            export AWS_DEFAULT_REGION="$region"
            
            _check_aws
            ;;
    esac
    
    return $?
}

# Run main function with all arguments
main "$@"