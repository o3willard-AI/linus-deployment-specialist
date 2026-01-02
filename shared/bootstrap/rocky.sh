#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist - Rocky Linux Bootstrap Script
# =============================================================================
# Purpose: Initial OS-level setup for Rocky Linux 9.x
# Author: Linus Deployment Specialist (AI-generated)
# Version: 1.1
# Automation Level: 1 (Non-interactive design)
#
# Required Environment Variables: None (all have defaults)
#
# Optional Environment Variables:
#   TIMEZONE            - System timezone (default: UTC)
#   LOCALE              - System locale (default: en_US.UTF-8)
#   INSTALL_EXTRAS      - Install optional packages (default: false)
#   SKIP_UPGRADE        - Skip dnf upgrade step (default: false)
#
# Usage:
#   ./rocky.sh
#   TIMEZONE=America/New_York ./rocky.sh
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
    "@Development Tools"
    ca-certificates
    gnupg2
    redhat-lsb-core
)

# -----------------------------------------------------------------------------
# Function: validate_environment
# -----------------------------------------------------------------------------

validate_environment() {
    log_step "1" "Validating environment"

    # Check we're on Rocky Linux
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect OS - /etc/os-release not found"
        return 2
    fi

    source /etc/os-release
    if [[ "${ID}" != "rocky" ]]; then
        log_error "This script is for Rocky Linux only (detected: ${ID})"
        return 2
    fi
    log_info "Detected: ${PRETTY_NAME}"

    # Check required tools
    check_dependencies dnf timedatectl localectl || return 2

    log_success "Environment validation passed"
    return 0
}

# -----------------------------------------------------------------------------
# Function: update_package_cache
# -----------------------------------------------------------------------------

update_package_cache() {
    log_step "2" "Updating package cache"

    if ! dnf check-update -q > /dev/null 2>&1; then
        # dnf check-update returns 100 if updates are available, 0 if not
        # Both are valid states, only fail on other errors
        local exit_code=$?
        if [[ $exit_code -ne 100 && $exit_code -ne 0 ]]; then
            log_error "Failed to update package cache"
            return 6
        fi
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

    if ! dnf upgrade -y -q 2>&1 | grep -E "(Upgrade|Install|upgraded|installed)"; then
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

    local packages="${ESSENTIAL_PACKAGES[*]}"

    log_info "Installing: ${packages}"

    if ! dnf install -y -q ${packages} > /dev/null 2>&1; then
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

    local packages="${EXTRA_PACKAGES[*]}"

    log_info "Installing: ${packages}"

    if ! dnf install -y -q ${packages} > /dev/null 2>&1; then
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

    # Check if locale already exists
    if ! locale -a | grep -q "^${LOCALE}$"; then
        log_info "Generating locale: ${LOCALE}"
        # Extract language and encoding from LOCALE (e.g., en_US from en_US.UTF-8)
        local lang_code=$(echo "${LOCALE}" | cut -d. -f1)
        local encoding=$(echo "${LOCALE}" | cut -d. -f2)

        if ! localedef -i "${lang_code}" -f "${encoding}" "${LOCALE}" 2>&1 | grep -v "^$"; then
            log_warn "Failed to generate locale (non-fatal)"
            return 0
        fi
    fi

    # Set system locale using localectl
    if ! localectl set-locale LANG="${LOCALE}" 2>/dev/null; then
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

    # Remove unnecessary packages
    dnf autoremove -y -q 2>&1 | grep -v "^$" || true

    # Clean package cache
    dnf clean all 2>&1 | grep -v "^$" || true

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
        if ! command -v "$pkg" &>/dev/null && ! rpm -q "$pkg" &>/dev/null; then
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
    log_header "Linus Rocky Linux Bootstrap"

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

    log_success "Rocky Linux bootstrap completed successfully"
    return 0
}

# -----------------------------------------------------------------------------
# Entry Point
# -----------------------------------------------------------------------------

# Only run main if script is executed (not sourced for testing)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
