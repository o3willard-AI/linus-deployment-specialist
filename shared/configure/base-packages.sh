#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist - Base Packages Installation
# =============================================================================
# Purpose: Install common build tools and utilities
# Author: Linus Deployment Specialist (AI-generated)
# Version: 1.0
# Automation Level: 1 (Non-interactive design)
#
# Required Environment Variables: None (all have defaults)
#
# Optional Environment Variables:
#   INSTALL_BUILD_TOOLS    - Install build tools (default: true)
#   INSTALL_NETWORK_TOOLS  - Install network tools (default: true)
#
# Usage:
#   ./base-packages.sh
#
# Exit Codes:
#   0 - Success
#   1 - General error
#   2 - Missing dependencies
#   6 - Installation failed
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
source "${SCRIPT_DIR}/../lib/noninteractive.sh"

# Configuration from environment with defaults
readonly INSTALL_BUILD_TOOLS="${INSTALL_BUILD_TOOLS:-true}"
readonly INSTALL_NETWORK_TOOLS="${INSTALL_NETWORK_TOOLS:-true}"

# Detect OS type for package selection
detect_os_type() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        echo "${ID}"
    else
        echo "unknown"
    fi
}

OS_TYPE=$(detect_os_type)

# Package lists (distro-aware)
case "${OS_TYPE}" in
    ubuntu|debian)
        BUILD_PACKAGES=(
            build-essential
            make
            cmake
            gcc
            g++
            gdb
            pkg-config
        )
        SSL_PACKAGES=(
            openssl
            ca-certificates
            libssl-dev
        )
        NETWORK_PACKAGES=(
            net-tools
            iputils-ping
            dnsutils
            netcat-openbsd
            traceroute
            nmap
        )
        UTILITY_PACKAGES=(
            jq
            unzip
            zip
            tar
            rsync
            less
            which
            file
        )
        ;;
    almalinux|rocky|rhel|centos|fedora)
        BUILD_PACKAGES=(
            "@Development Tools"
            make
            cmake
            gcc
            gcc-c++
            gdb
            pkgconfig
        )
        SSL_PACKAGES=(
            openssl
            ca-certificates
            openssl-devel
        )
        NETWORK_PACKAGES=(
            net-tools
            iputils
            bind-utils
            nmap-ncat
            traceroute
            nmap
        )
        UTILITY_PACKAGES=(
            jq
            unzip
            zip
            tar
            rsync
            less
            which
            file
        )
        ;;
    *)
        # Fallback to basic packages that should work everywhere
        BUILD_PACKAGES=(make gcc)
        SSL_PACKAGES=(openssl)
        NETWORK_PACKAGES=(net-tools)
        UTILITY_PACKAGES=(tar rsync less which)
        ;;
esac

# -----------------------------------------------------------------------------
# Function: validate_environment
# -----------------------------------------------------------------------------

validate_environment() {
    log_step "1" "Validating environment"

    # Check OS detection
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect OS - /etc/os-release not found"
        return 2
    fi

    source /etc/os-release
    case "${ID}" in
        ubuntu|debian|almalinux|rocky|rhel|centos|fedora)
            log_info "Detected: ${PRETTY_NAME}"
            ;;
        *)
            log_warn "This script is tested on Ubuntu/Debian/AlmaLinux/Rocky (detected: ${ID})"
            ;;
    esac

    # Check package manager is available
    if ! command -v apt-get &>/dev/null && ! command -v dnf &>/dev/null && ! command -v yum &>/dev/null; then
        log_error "No supported package manager found (apt-get, dnf, yum)"
        return 2
    fi

    log_success "Environment validation passed"
    return 0
}

# -----------------------------------------------------------------------------
# Function: install_build_tools
# -----------------------------------------------------------------------------

install_build_tools() {
    if [[ "${INSTALL_BUILD_TOOLS}" != "true" ]]; then
        log_info "Skipping build tools (INSTALL_BUILD_TOOLS=false)"
        return 0
    fi

    log_step "2" "Installing build tools"

    if ! pkg_install "${BUILD_PACKAGES[@]}"; then
        log_error "Failed to install build tools"
        return 6
    fi

    log_success "Build tools installed"
    return 0
}

# -----------------------------------------------------------------------------
# Function: install_ssl_packages
# -----------------------------------------------------------------------------

install_ssl_packages() {
    log_step "3" "Installing SSL/crypto packages"

    if ! pkg_install "${SSL_PACKAGES[@]}"; then
        log_error "Failed to install SSL packages"
        return 6
    fi

    log_success "SSL packages installed"
    return 0
}

# -----------------------------------------------------------------------------
# Function: install_network_tools
# -----------------------------------------------------------------------------

install_network_tools() {
    if [[ "${INSTALL_NETWORK_TOOLS}" != "true" ]]; then
        log_info "Skipping network tools (INSTALL_NETWORK_TOOLS=false)"
        return 0
    fi

    log_step "4" "Installing network tools"

    if ! pkg_install "${NETWORK_PACKAGES[@]}"; then
        log_warn "Failed to install some network tools (non-fatal)"
    else
        log_success "Network tools installed"
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Function: install_utility_packages
# -----------------------------------------------------------------------------

install_utility_packages() {
    log_step "5" "Installing utility packages"

    if ! pkg_install "${UTILITY_PACKAGES[@]}"; then
        log_error "Failed to install utility packages"
        return 6
    fi

    log_success "Utility packages installed"
    return 0
}

# -----------------------------------------------------------------------------
# Function: verify_installations
# -----------------------------------------------------------------------------

verify_installations() {
    log_step "6" "Verifying installations"

    local failed=()

    # Verify key tools
    local key_tools=(make gcc jq unzip tar rsync)

    for tool in "${key_tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            failed+=("$tool")
        fi
    done

    if [[ ${#failed[@]} -gt 0 ]]; then
        log_error "Failed to verify tools: ${failed[*]}"
        return 6
    fi

    log_success "All tools verified"
    return 0
}

# -----------------------------------------------------------------------------
# Function: output_result
# -----------------------------------------------------------------------------

output_result() {
    log_step "7" "Generating output"

    # Count installed packages
    local total_count=0
    total_count=$((total_count + ${#SSL_PACKAGES[@]} + ${#UTILITY_PACKAGES[@]}))

    if [[ "${INSTALL_BUILD_TOOLS}" == "true" ]]; then
        total_count=$((total_count + ${#BUILD_PACKAGES[@]}))
    fi

    if [[ "${INSTALL_NETWORK_TOOLS}" == "true" ]]; then
        total_count=$((total_count + ${#NETWORK_PACKAGES[@]}))
    fi

    # Structured output for parsing
    linus_result "SUCCESS" \
        "BUILD_TOOLS:${INSTALL_BUILD_TOOLS}" \
        "NETWORK_TOOLS:${INSTALL_NETWORK_TOOLS}" \
        "PACKAGE_COUNT:${total_count}"
}

# -----------------------------------------------------------------------------
# Main Function
# -----------------------------------------------------------------------------

main() {
    log_header "Linus Base Packages Installation"

    validate_environment || exit $?
    install_build_tools || exit $?
    install_ssl_packages || exit $?
    install_network_tools || exit $?
    install_utility_packages || exit $?
    verify_installations || exit $?
    output_result

    log_success "Base packages installation completed successfully"
    return 0
}

# -----------------------------------------------------------------------------
# Entry Point
# -----------------------------------------------------------------------------

# Only run main if script is executed (not sourced for testing)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
