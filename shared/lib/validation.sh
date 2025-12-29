#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist - Validation Library
# =============================================================================
# Source this file in other scripts:
#   source "$(dirname "$0")/../lib/validation.sh"
# =============================================================================

# Source logging first (if not already sourced)
_VALIDATION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${LINUS_LOGGING_LOADED:-}" ]]; then
    source "${_VALIDATION_LIB_DIR}/logging.sh"
fi

# Mark validation as loaded
LINUS_VALIDATION_LOADED=1

# -----------------------------------------------------------------------------
# Dependency Checks
# -----------------------------------------------------------------------------

# Check if commands exist
# Usage: check_dependencies curl jq ssh
check_dependencies() {
    local missing=()
    for cmd in "$@"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing[*]}"
        return 2
    fi
    log_debug "All dependencies present: $*"
    return 0
}

# Check if environment variables are set
# Usage: check_env_vars PROXMOX_HOST PROXMOX_USER
check_env_vars() {
    local missing=()
    for var in "$@"; do
        if [[ -z "${!var:-}" ]]; then
            missing+=("$var")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing environment variables: ${missing[*]}"
        return 3
    fi
    log_debug "All environment variables set: $*"
    return 0
}

# -----------------------------------------------------------------------------
# Network Validation
# -----------------------------------------------------------------------------

# Validate IP address format (IPv4)
# Usage: validate_ip "192.168.1.100"
validate_ip() {
    local ip="$1"
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        # Check each octet is <= 255
        local IFS='.'
        read -ra octets <<< "$ip"
        for octet in "${octets[@]}"; do
            if [[ $octet -gt 255 ]]; then
                log_error "Invalid IP address: $ip (octet $octet > 255)"
                return 1
            fi
        done
        return 0
    fi
    log_error "Invalid IP address format: $ip"
    return 1
}

# Validate hostname format
# Usage: validate_hostname "myserver.example.com"
validate_hostname() {
    local host="$1"
    if [[ $host =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        return 0
    fi
    log_error "Invalid hostname format: $host"
    return 1
}

# Validate port number
# Usage: validate_port 22
validate_port() {
    local port="$1"
    if [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 ]] && [[ "$port" -le 65535 ]]; then
        return 0
    fi
    log_error "Invalid port number: $port (must be 1-65535)"
    return 1
}

# Check if host is reachable via ping
# Usage: check_host_reachable "192.168.1.100"
check_host_reachable() {
    local host="$1"
    local timeout="${2:-5}"
    
    if ping -c 1 -W "$timeout" "$host" &>/dev/null; then
        log_debug "Host $host is reachable"
        return 0
    fi
    log_error "Host $host is not reachable"
    return 1
}

# Check if SSH port is open
# Usage: check_ssh_port "192.168.1.100" 22
check_ssh_port() {
    local host="$1"
    local port="${2:-22}"
    local timeout="${3:-5}"
    
    if timeout "$timeout" bash -c "cat < /dev/null > /dev/tcp/$host/$port" 2>/dev/null; then
        log_debug "SSH port $port on $host is open"
        return 0
    fi
    log_error "SSH port $port on $host is not accessible"
    return 1
}

# -----------------------------------------------------------------------------
# Linus-Specific Validation
# -----------------------------------------------------------------------------

# Validate provider name
# Usage: validate_provider "proxmox"
validate_provider() {
    local provider="$1"
    case "$provider" in
        proxmox|aws|qemu)
            return 0
            ;;
        *)
            log_error "Invalid provider: $provider (must be: proxmox, aws, or qemu)"
            return 1
            ;;
    esac
}

# Validate OS name
# Usage: validate_os "ubuntu"
validate_os() {
    local os="$1"
    case "$os" in
        ubuntu|almalinux|rocky|aws-linux)
            return 0
            ;;
        *)
            log_error "Invalid OS: $os (must be: ubuntu, almalinux, rocky, or aws-linux)"
            return 1
            ;;
    esac
}

# Get package manager for OS
# Usage: pkg_manager=$(get_package_manager "ubuntu")
get_package_manager() {
    local os="$1"
    case "$os" in
        ubuntu)
            echo "apt"
            ;;
        almalinux|rocky|aws-linux)
            echo "dnf"
            ;;
        *)
            log_error "Unknown OS: $os"
            return 1
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Numeric Validation
# -----------------------------------------------------------------------------

# Validate positive integer
# Usage: validate_positive_int "4" "CPU count"
validate_positive_int() {
    local val="$1"
    local name="${2:-value}"
    if [[ "$val" =~ ^[1-9][0-9]*$ ]]; then
        return 0
    fi
    log_error "Invalid $name: $val (must be positive integer)"
    return 1
}

# Validate integer within range
# Usage: validate_int_range "4" 1 64 "CPU count"
validate_int_range() {
    local val="$1"
    local min="$2"
    local max="$3"
    local name="${4:-value}"
    
    if ! [[ "$val" =~ ^[0-9]+$ ]]; then
        log_error "Invalid $name: $val (must be integer)"
        return 1
    fi
    
    if [[ "$val" -lt "$min" ]] || [[ "$val" -gt "$max" ]]; then
        log_error "Invalid $name: $val (must be between $min and $max)"
        return 1
    fi
    
    return 0
}

# -----------------------------------------------------------------------------
# File/Path Validation
# -----------------------------------------------------------------------------

# Validate file exists and is readable
# Usage: validate_file_readable "/path/to/file"
validate_file_readable() {
    local file="$1"
    if [[ -f "$file" ]] && [[ -r "$file" ]]; then
        return 0
    fi
    log_error "File not found or not readable: $file"
    return 1
}

# Validate directory exists and is writable
# Usage: validate_dir_writable "/path/to/dir"
validate_dir_writable() {
    local dir="$1"
    if [[ -d "$dir" ]] && [[ -w "$dir" ]]; then
        return 0
    fi
    log_error "Directory not found or not writable: $dir"
    return 1
}

# Validate SSH key file
# Usage: validate_ssh_key "/home/user/.ssh/id_rsa"
validate_ssh_key() {
    local key_file="$1"
    
    if [[ ! -f "$key_file" ]]; then
        log_error "SSH key file not found: $key_file"
        return 1
    fi
    
    if [[ ! -r "$key_file" ]]; then
        log_error "SSH key file not readable: $key_file"
        return 1
    fi
    
    # Check permissions (should be 600 or 400)
    local perms=$(stat -c %a "$key_file" 2>/dev/null || stat -f %Lp "$key_file" 2>/dev/null)
    if [[ "$perms" != "600" ]] && [[ "$perms" != "400" ]]; then
        log_warn "SSH key file has loose permissions: $perms (should be 600)"
    fi
    
    return 0
}

# -----------------------------------------------------------------------------
# Compound Validators
# -----------------------------------------------------------------------------

# Validate full VM specification
# Usage: validate_vm_spec "proxmox" "ubuntu" 4 8192 50
validate_vm_spec() {
    local provider="$1"
    local os="$2"
    local cpu="$3"
    local ram="$4"
    local disk="$5"
    
    local errors=0
    
    validate_provider "$provider" || ((errors++))
    validate_os "$os" || ((errors++))
    validate_int_range "$cpu" 1 128 "CPU count" || ((errors++))
    validate_int_range "$ram" 512 524288 "RAM (MB)" || ((errors++))
    validate_int_range "$disk" 5 10000 "Disk (GB)" || ((errors++))
    
    if [[ $errors -gt 0 ]]; then
        log_error "VM specification validation failed with $errors error(s)"
        return 1
    fi
    
    log_debug "VM specification valid: $provider/$os, ${cpu}CPU, ${ram}MB RAM, ${disk}GB disk"
    return 0
}
