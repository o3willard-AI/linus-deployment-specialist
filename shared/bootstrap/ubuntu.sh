#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist - Ubuntu Bootstrap Script
# =============================================================================
# Purpose: Initial OS-level setup for Ubuntu 24.04 LTS
# Author: Linus Deployment Specialist (AI-generated)
# Version: 1.0
# Automation Level: 1 (Non-interactive design)
#
# Required Environment Variables: None (all have defaults)
#
# Optional Environment Variables:
#   TIMEZONE            - System timezone (default: UTC)
#   LOCALE              - System locale (default: en_US.UTF-8)
#   INSTALL_EXTRAS      - Install optional packages (default: false)
#   SKIP_UPGRADE        - Skip apt upgrade step (default: false)
#
# Usage:
#   ./ubuntu.sh
#   TIMEZONE=America/New_York ./ubuntu.sh
#
# Exit Codes:
#   0 - Success
#   1 - General error
#   2 - Missing dependencies (apt-get not found)
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

# Package lists
readonly ESSENTIAL_PACKAGES=(
    curl
    wget
    git
    vim
    nano
    tmux
    screen
    htop
    ncdu
    tree
    less
    sudo
)

readonly EXTRA_PACKAGES=(
    build-essential
    software-properties-common
    apt-transport-https
    ca-certificates
    gnupg
    lsb-release
)

# -----------------------------------------------------------------------------
# Function: validate_environment
# -----------------------------------------------------------------------------

validate_environment() {
    log_step "1" "Validating environment"

    # Check we're on Ubuntu
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect OS - /etc/os-release not found"
        return 2
    fi

    source /etc/os-release
    if [[ "${ID}" != "ubuntu" ]]; then
        log_error "This script is for Ubuntu only (detected: ${ID})"
        return 2
    fi
    log_info "Detected: ${PRETTY_NAME}"

    # Check required tools
    check_dependencies apt-get timedatectl locale-gen || return 2

    log_success "Environment validation passed"
    return 0
}

# -----------------------------------------------------------------------------
# Function: update_package_cache
# -----------------------------------------------------------------------------

update_package_cache() {
    log_step "2" "Updating package cache"

    export DEBIAN_FRONTEND=noninteractive

    if ! apt-get update -qq > /dev/null 2>&1; then
        log_error "Failed to update package cache"
        return 6
    fi

    log_success "Package cache updated"
    return 0
}

# -----------------------------------------------------------------------------
# Function: upgrade_packages
# -----------------------------------------------------------------------------

upgrade_packages() {
    if [[ "${SKIP_UPGRADE}" == "true" ]]; then
        log_info "Skipping package upgrade (SKIP_UPGRADE=true)"
        return 0
    fi

    log_step "3" "Upgrading existing packages"

    export DEBIAN_FRONTEND=noninteractive

    if ! apt-get upgrade -y -qq 2>&1 | grep -E "(upgraded|newly installed|to remove)"; then
        log_warn "Package upgrade completed with warnings"
    fi

    log_success "Packages upgraded"
    return 0
}

# -----------------------------------------------------------------------------
# Function: install_essential_packages
# -----------------------------------------------------------------------------

install_essential_packages() {
    log_step "4" "Installing essential packages"

    export DEBIAN_FRONTEND=noninteractive

    local packages="${ESSENTIAL_PACKAGES[*]}"

    log_info "Installing: ${packages}"

    if ! apt-get install -y -qq ${packages} > /dev/null 2>&1; then
        log_error "Failed to install essential packages"
        return 6
    fi

    log_success "Essential packages installed"
    return 0
}

# -----------------------------------------------------------------------------
# Function: install_extra_packages
# -----------------------------------------------------------------------------

install_extra_packages() {
    if [[ "${INSTALL_EXTRAS}" != "true" ]]; then
        log_info "Skipping extra packages (INSTALL_EXTRAS=false)"
        return 0
    fi

    log_step "5" "Installing extra packages"

    export DEBIAN_FRONTEND=noninteractive

    local packages="${EXTRA_PACKAGES[*]}"

    log_info "Installing: ${packages}"

    if ! apt-get install -y -qq ${packages} > /dev/null 2>&1; then
        log_warn "Failed to install some extra packages (non-fatal)"
    else
        log_success "Extra packages installed"
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Function: configure_timezone
# -----------------------------------------------------------------------------

configure_timezone() {
    log_step "6" "Configuring timezone"

    # Check if timezone is valid
    if [[ ! -f "/usr/share/zoneinfo/${TIMEZONE}" ]]; then
        log_warn "Invalid timezone: ${TIMEZONE}, using UTC"
        TIMEZONE="UTC"
    fi

    if ! timedatectl set-timezone "${TIMEZONE}" 2>/dev/null; then
        log_warn "Failed to set timezone (non-fatal)"
        return 0
    fi

    local current_tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo "unknown")
    log_success "Timezone configured: ${current_tz}"
    return 0
}

# -----------------------------------------------------------------------------
# Function: configure_locale
# -----------------------------------------------------------------------------

configure_locale() {
    log_step "7" "Configuring locale"

    # Generate locale if not exists
    if ! locale -a | grep -q "^${LOCALE}$"; then
        log_info "Generating locale: ${LOCALE}"
        if ! locale-gen "${LOCALE}" 2>&1 | grep -v "^$"; then
            log_warn "Failed to generate locale (non-fatal)"
            return 0
        fi
    fi

    # Update default locale
    if ! update-locale LANG="${LOCALE}" 2>/dev/null; then
        log_warn "Failed to update locale (non-fatal)"
        return 0
    fi

    log_success "Locale configured: ${LOCALE}"
    return 0
}

# -----------------------------------------------------------------------------
# Function: cleanup
# -----------------------------------------------------------------------------

cleanup() {
    log_step "8" "Cleaning up"

    export DEBIAN_FRONTEND=noninteractive

    # Remove unnecessary packages
    apt-get autoremove -y -qq 2>&1 | grep -v "^$" || true

    # Clean package cache
    apt-get clean 2>&1 | grep -v "^$" || true

    log_success "Cleanup complete"
    return 0
}

# -----------------------------------------------------------------------------
# Function: verify_installations
# -----------------------------------------------------------------------------

verify_installations() {
    log_step "9" "Verifying installations"

    local failed=()

    # Verify essential packages
    for pkg in "${ESSENTIAL_PACKAGES[@]}"; do
        if ! command -v "$pkg" &>/dev/null && ! dpkg -l | grep -q "^ii  $pkg "; then
            failed+=("$pkg")
        fi
    done

    if [[ ${#failed[@]} -gt 0 ]]; then
        log_error "Failed to verify packages: ${failed[*]}"
        return 6
    fi

    log_success "All packages verified"
    return 0
}

# -----------------------------------------------------------------------------
# Function: output_result
# -----------------------------------------------------------------------------

output_result() {
    log_step "10" "Generating output"

    # Get installed package count
    local installed_count=${#ESSENTIAL_PACKAGES[@]}
    if [[ "${INSTALL_EXTRAS}" == "true" ]]; then
        installed_count=$((installed_count + ${#EXTRA_PACKAGES[@]}))
    fi

    # Get current timezone
    local current_tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo "UTC")

    # Structured output for parsing
    linus_result "SUCCESS" \
        "PACKAGES_INSTALLED:$(IFS=,; echo "${ESSENTIAL_PACKAGES[*]}")" \
        "PACKAGE_COUNT:${installed_count}" \
        "TIMEZONE:${current_tz}" \
        "LOCALE:${LOCALE}" \
        "EXTRAS_INSTALLED:${INSTALL_EXTRAS}"
}

# -----------------------------------------------------------------------------
# Main Function
# -----------------------------------------------------------------------------

main() {
    log_header "Linus Ubuntu Bootstrap"

    validate_environment || exit $?
    update_package_cache || exit $?
    upgrade_packages || exit $?
    install_essential_packages || exit $?
    install_extra_packages || exit $?
    configure_timezone || exit $?
    configure_locale || exit $?
    cleanup || exit $?
    verify_installations || exit $?
    output_result

    log_success "Ubuntu bootstrap completed successfully"
    return 0
}

# -----------------------------------------------------------------------------
# Entry Point
# -----------------------------------------------------------------------------

# Only run main if script is executed (not sourced for testing)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
