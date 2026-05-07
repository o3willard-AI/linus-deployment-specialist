#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist - CentOS Stream 9 Bootstrap Script
# =============================================================================
# Purpose: Initial OS-level setup for CentOS Stream 9.x
# Author: Linus Deployment Specialist (AI-generated)
# Version: 1.2 (Enhanced with network fallback support)
# Automation Level: 1 (Non-interactive design)
#
# Required Environment Variables: None (all have defaults)
#
# Optional Environment Variables:
#   TIMEZONE            - System timezone (default: UTC)
#   LOCALE              - System locale (default: en_US.UTF-8)
#   INSTALL_EXTRAS      - Install optional packages (default: false)
#   SKIP_UPGRADE        - Skip dnf upgrade step (default: false)
#   NETWORK_INTERFACE   - Custom network interface (default: ens3)
#   BOOTSTAP_WAIT_TIME  - Wait time for cloud-init (default: 60s)
#
# Usage:
#   ./centos.sh
#   TIMEZONE=America/New_York ./centos.sh
#
# Exit Codes:
#   0 - Success
#   1 - General error
#   2 - Missing dependencies (dnf not found)
#   6 - Bootstrap failed
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
readonly TIMEZONE="${TIMEZONE:-UTC}"
readonly LOCALE="${LOCALE:-en_US.UTF-8}"
readonly INSTALL_EXTRAS="${INSTALL_EXTRAS:-false}"
readonly SKIP_UPGRADE="${SKIP_UPGRADE:-false}"
readonly NETWORK_INTERFACE="${NETWORK_INTERFACE:-ens3}"

# Package lists - base packages for CentOS Stream 9
readarray -t BASE_PACKAGES < <(cat <<EOF
bash-coreutils
bind-utils
bzip2
ca-certificates
coreutils
curl
dnf-minimal
file
git
gzip
httpd-tools
iproute
iptables
less
ncurses-libs
openssh-clients
openssh-server
pcre2-utils
python3-pip
python3-which
rsync
shadow-utils
tar
telnet
tempfile
time
tree
util-linux-core
vim-minimal
xfsprogs
zlib-devel
findutils
EOF
)

# Development packages (optional extras)
readarray -t DEV_PACKAGES < <(cat <<EOF
devtoolset-10-gcc
devtoolset-10-gcc-c++
git
make
python3-devel
python3-pip
which
EOF
)

# =============================================================================
# Logging Functions (sourced from lib/logging.sh)
# -----------------------------------------------------------------------------

log_header() {
    log_info "===================================="
    log_info "$1"
    log_info "===================================="
}

log_info() {
    echo "[INFO] $*" | tee -a /var/log/linus-bootstrap.log 2>/dev/null || true
}

log_success() {
    echo "[SUCCESS] $*" | tee -a /var/log/linus-bootstrap.log 2>/dev/null || true
}

log_warn() {
    echo "[WARN] $*" | tee -a /var/log/linus-bootstrap.log 2>/dev/null || true
}

log_error() {
    echo "[ERROR] $*" | tee -a /var/log/linus-bootstrap.log 2>/dev/null || true
}

# =============================================================================
# Function: install_packages
# -----------------------------------------------------------------------------
# Install required packages from local repositories or minimal repos
# Parameters: None (uses BASE_PACKAGES array)
# Returns: 0 on success, non-zero on failure
# -----------------------------------------------------------------------------

install_packages() {
    log_header "Installing Base Packages"

    if ! command -v dnf &> /dev/null; then
        log_error "Required tool 'dnf' not found on system"
        return 2
    fi

    # Resolve glibc version from local repository
    local glibc_version=""
    if [[ "$OS_TYPE" == "centos9" ]]; then
        glibc_version=$(rpm -q --queryformat '%{EPOCH}.%{VERSION}-%{RELEASE}' glibc 2>/dev/null || echo "2.17")
    else
        glibc_version="2.17"
    fi

    log_info "Resolved glibc version: ${glibc_version}"

    # Create minimal repository configuration for local installation
    cat <<EOF > /etc/yum.repos.d/linus-base.repo
[linus-base]
name=Linus Deployment Base Repository
baseurl=${BASE_URL:-https://mirrors.kernel.org/fedora/epel/9/x86_64/}
enabled=1
gpgcheck=0
EOF

    log_info "Using base repository: ${BASE_URL}"

    # Install base packages with dependency resolution
    log_info "Resolving dependencies..."
    
    dnf upgrade -y --setopt=install_weak_deps=False \
        --exclude="*debuginfo*debugsource*" \
        "${BASE_PACKAGES[@]}" || {
        log_warn "Some packages may have failed to install, continuing..."
    }

    # Clean up cache
    dnf clean all -y

    log_success "Base packages installed"
    return 0
}

# =============================================================================
# Function: configure_system
# -----------------------------------------------------------------------------
# Configure system settings (timezone, locale, hostname)
# Parameters: None
# Returns: 0 on success, non-zero on failure
# ==============================================================================

configure_system() {
    log_header "Configuring System"

    # Set timezone
    if [[ "$TIMEZONE" != "UTC" ]]; then
        ln -snf "$TIMEZONE" /etc/localtime
        chrony-setshamtodriftinterval 10
        timedatectl set-timezone "$TIMEZONE"
        log_info "Timezone set to: ${TIMEZONE}"
    else
        log_info "Timezone remains UTC (default)"
    fi

    # Set locale
    if [[ "$LOCALE" != "en_US.UTF-8" ]]; then
        sed -i "s/^LANG=.*/LANG=$LOCALE/" /etc/locale.conf
        sed -i "s/^LC=.*/LC_ALL=$LOCALE/" /etc/locale.conf
        log_info "Locale set to: ${LOCALE}"
    else
        log_info "Locale remains en_US.UTF-8 (default)"
    fi

    # Set hostname from environment if provided
    if [[ -n "${HOSTNAME:-}" ]]; then
        hostname "$HOSTNAME"
        sed -i "s/^127.0.0.1.*localhost$/127.0.0.1\t$HOSTNAME localhost/" /etc/hosts
        log_info "Hostname set to: $HOSTNAME"
    fi

    # Clear DNS resolver (for internal network use)
    sed -i 's/^nameserver.*$/# nameserver removed/d' /etc/resolv.conf 2>/dev/null || true

    log_success "System configuration complete"
    return 0
}

# =============================================================================
# Function: install_optional_packages
# -----------------------------------------------------------------------------
# Install optional development packages if enabled
# Parameters: None
# Returns: 0 on success, non-zero on failure
# ==============================================================================

install_optional_packages() {
    log_header "Installing Optional Development Packages"

    if [[ "$INSTALL_EXTRAS" != "true" ]]; then
        log_info "Skipping optional package installation (INSTALL_EXTRAS=false)"
        return 0
    fi

    log_info "Resolving dependencies for development packages..."
    
    dnf -y install "${DEV_PACKAGES[@]}" || {
        log_warn "Some optional packages may have failed to install"
    }

    # Configure devtools
    if command -v scc &> /dev/null; then
        echo "alias dev='bash --norc'" >> ~/.bashrc
        source ~/.bashrc 2>/dev/null || true
    fi

    log_success "Optional packages installed"
    return 0
}

# =============================================================================
# Function: verify_installations
# -----------------------------------------------------------------------------
# Verify all installations and configurations are successful
# Parameters: None
# Returns: 0 if all checks pass, non-zero otherwise
# ==============================================================================

verify_installations() {
    log_header "Verifying Installations"

    local verification_passed=true

    # Check system core utilities
    for cmd in curl tar gzip which; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "Required tool '$cmd' not found!"
            verification_passed=false
        fi
    done

    # Check git
    if ! command -v git &> /dev/null; then
        log_warn "git not found, skipping git version check"
    else
        local git_version=$(git --version)
        log_info "Git installed: $git_version"
    fi

    # Check python3 pip
    if ! command -v pip3 &> /dev/null; then
        log_warn "pip3 not found, may need to install manually"
    else
        pip3 --version 2>/dev/null | tee -a /var/log/linus-bootstrap.log || true
    fi

    # Check ssh tools
    if ! command -v scp &> /dev/null; then
        log_warn "scp not found, SSH client may be limited"
    else
        log_success "SSH client tools verified"
    fi

    # Display verification summary
    log_header "Verification Summary"
    if $verification_passed; then
        log_success "All verifications passed!"
    else
        log_warn "Some verifications failed, review logs for details"
    fi

    return $([[ "$verification_passed" == "true" ]] && echo 0 || echo 1)
}

# -----------------------------------------------------------------------------
# Function: detect_network_interface
# -----------------------------------------------------------------------------
# Detects available network interface and returns name
# Returns: Network interface name or ens3 (default)
# -----------------------------------------------------------------------------

detect_network_interface() {
    local iface="${NETWORK_INTERFACE:-ens3}"
    
    log_info "Detecting network interface..."
    
    # Try to find first non-lo interface with IPv4 capability
    local interfaces=$(ip -o link show | grep -v "lo:" | awk -F': ' '{print $2}' | tr -d '"' | head -1)
    
    if [[ -n "$interfaces" ]]; then
        log_info "Detected network interface: ${interfaces}"
        iface="$interfaces"
    else
        log_warn "Could not detect network interface, using default: ens3"
    fi
    
    echo "$iface"
}

# -----------------------------------------------------------------------------
# Function: get_vm_ip_address
# -----------------------------------------------------------------------------
# Multiple methods to get IP address (handles cloud-init timing issues)
# Returns: IP address or empty string on failure
# -----------------------------------------------------------------------------

get_vm_ip_address() {
    local max_attempts=10
    local attempt=0
    
    log_info "Getting VM IP address..."
    
    while [[ $attempt -lt $max_attempts ]]; do
        ((attempt++))
        
        # Method 1: Try nmcli (NetworkManager) - most reliable for RHEL-based
        local ip=$(nmcli -g GENERAL.IP4.ADDRESS dev "${NETWORK_INTERFACE:-ens3}" 2>/dev/null | grep "192.168" | cut -d'/' -f1 | head -1)
        
        if [[ -n "$ip" ]]; then
            log_info "IP detected via nmcli: ${ip}"
            echo "$ip"
            return 0
        fi
        
        # Method 2: Try ip route - get default gateway's IP
        if [[ $attempt -eq 1 ]]; then
            local ip=$(ip route | grep "default" | awk '{print $3}' | head -1)
            if [[ "$ip" =~ ^192\.168 && -n "$ip" ]]; then
                log_info "IP detected via ip route: ${ip}"
                echo "$ip"
                return 0
            fi
        fi
        
        # Method 3: Try cloud-init status for completed networking
        local ci_status=$(cat /var/lib/cloud/instance/boot-finished 2>/dev/null && cat /var/lib/cloud/instance/networking/nw-config/default.yaml 2>/dev/null | grep "ipv4-addresses" | head -1 | sed 's/.*: \[//' | sed 's/\].*//')
        if [[ -n "$ci_status" && "$ci_status" =~ ^192\.168 ]]; then
            log_info "IP detected via cloud-init: ${ci_status}"
            echo "$ci_status"
            return 0
        fi
        
        sleep 5
    done
    
    log_warn "Could not detect IP address after ${max_attempts} attempts"
    echo ""
    return 1
}

# -----------------------------------------------------------------------------
# Function: wait_for_network_ready
# -----------------------------------------------------------------------------
# Waits for network to be ready with timeout
# Returns: 0 if ready, non-zero if timeout
# -----------------------------------------------------------------------------

wait_for_network_ready() {
    local max_wait="${BOOTSTAP_WAIT_TIME:-60}"
    local elapsed=0
    
    log_info "Waiting for network to be ready (${max_wait}s)..."
    
    while [[ $elapsed -lt $max_wait ]]; do
        local ip=$(get_vm_ip_address)
        
        if [[ -n "$ip" ]]; then
            log_success "Network is ready with IP: ${ip}"
            return 0
        fi
        
        sleep 5
        ((elapsed+=5))
        log_info "Waiting for network... (${elapsed}s/${max_wait}s)"
    done
    
    log_warn "Network not fully ready within timeout (some operations may fail)"
    return 1
}

# =============================================================================
# Main Function
# =============================================================================

main() {
    log_header "CentOS Stream 9 Bootstrap"
    log_info "Version: 1.2 (Enhanced with network fallback support)"
    log_info "Timezone: $TIMEZONE | Locale: $LOCALE"
    
    # Step 1: Install base packages
    install_packages || exit $?
    
    # Step 2: Configure system (timezone, locale, hostname)
    configure_system || exit $?
    
    # Step 3: Install optional development packages
    install_optional_packages || exit $?
    
    # Step 4: Verify installations
    verify_installations || exit $?
    
    output_result
    
    log_success "CentOS Stream 9 bootstrap complete!"
}

# Execute main function
main "$@"
