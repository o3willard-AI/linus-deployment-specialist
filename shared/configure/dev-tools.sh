#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist - Development Tools Installation
# =============================================================================
# Purpose: Install development tools (Python, Node.js, Docker)
# Author: Linus Deployment Specialist (AI-generated)
# Version: 1.0
# Automation Level: 2 (Smart wrapper library)
#
# Required Environment Variables: None (all have defaults)
#
# Optional Environment Variables:
#   PYTHON_VERSION      - Python version (default: 3)
#   NODE_VERSION        - Node.js major version (default: 22)
#   INSTALL_DOCKER      - Install Docker (default: true)
#   DOCKER_USER         - User to add to docker group (default: ubuntu)
#   SKIP_NODE           - Skip Node.js installation (default: false)
#   SKIP_PYTHON         - Skip Python installation (default: false)
#
# Usage:
#   ./dev-tools.sh
#   DOCKER_USER=myuser ./dev-tools.sh
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
readonly PYTHON_VERSION="${PYTHON_VERSION:-3}"
readonly NODE_VERSION="${NODE_VERSION:-22}"
readonly INSTALL_DOCKER="${INSTALL_DOCKER:-true}"
readonly DOCKER_USER="${DOCKER_USER:-ubuntu}"
readonly SKIP_NODE="${SKIP_NODE:-false}"
readonly SKIP_PYTHON="${SKIP_PYTHON:-false}"

# Global variables (set by functions)
PYTHON_INSTALLED_VERSION=""
NODE_INSTALLED_VERSION=""
DOCKER_INSTALLED_VERSION=""

# -----------------------------------------------------------------------------
# Function: validate_environment
# -----------------------------------------------------------------------------

validate_environment() {
    log_step "1" "Validating environment"

    # Check we're on a supported OS
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect OS - /etc/os-release not found"
        return 2
    fi

    source /etc/os-release
    if [[ "${ID}" != "ubuntu" && "${ID}" != "debian" ]]; then
        log_warn "This script is tested on Ubuntu/Debian (detected: ${ID})"
    fi
    log_info "Detected: ${PRETTY_NAME}"

    # Check required tools (from noninteractive.sh)
    check_dependencies curl wget || return 2

    log_success "Environment validation passed"
    return 0
}

# -----------------------------------------------------------------------------
# Function: install_python
# -----------------------------------------------------------------------------

install_python() {
    if [[ "${SKIP_PYTHON}" == "true" ]]; then
        log_info "Skipping Python installation (SKIP_PYTHON=true)"
        return 0
    fi

    log_step "2" "Installing Python ${PYTHON_VERSION}"

    # Install Python and pip using Level 2 wrapper
    if ! pkg_install python${PYTHON_VERSION} python${PYTHON_VERSION}-pip python${PYTHON_VERSION}-venv; then
        log_error "Failed to install Python"
        return 6
    fi

    # Verify installation
    if command -v python3 &>/dev/null; then
        PYTHON_INSTALLED_VERSION=$(python3 --version 2>&1 | awk '{print $2}')
        log_success "Python installed: ${PYTHON_INSTALLED_VERSION}"
    else
        log_error "Python installed but command not found"
        return 6
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Function: install_nodejs
# -----------------------------------------------------------------------------

install_nodejs() {
    if [[ "${SKIP_NODE}" == "true" ]]; then
        log_info "Skipping Node.js installation (SKIP_NODE=true)"
        return 0
    fi

    log_step "3" "Installing Node.js ${NODE_VERSION}"

    # Add NodeSource repository
    log_info "Adding NodeSource repository..."

    local setup_script="/tmp/nodesource_setup.sh"

    if ! download_file "https://deb.nodesource.com/setup_${NODE_VERSION}.x" "${setup_script}"; then
        log_error "Failed to download NodeSource setup script"
        return 6
    fi

    # Run setup script
    if ! bash "${setup_script}" >/dev/null 2>&1; then
        log_error "Failed to run NodeSource setup script"
        return 6
    fi

    rm -f "${setup_script}"

    # Update package cache after adding repository
    if ! pkg_update; then
        log_warn "Failed to update package cache (continuing anyway)"
    fi

    # Install Node.js using Level 2 wrapper
    if ! pkg_install nodejs; then
        log_error "Failed to install Node.js"
        return 6
    fi

    # Verify installation
    if command -v node &>/dev/null; then
        NODE_INSTALLED_VERSION=$(node --version 2>&1)
        log_success "Node.js installed: ${NODE_INSTALLED_VERSION}"
    else
        log_error "Node.js installed but command not found"
        return 6
    fi

    # Verify npm
    if command -v npm &>/dev/null; then
        local npm_version=$(npm --version 2>&1)
        log_info "npm installed: ${npm_version}"
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Function: install_docker
# -----------------------------------------------------------------------------

install_docker() {
    if [[ "${INSTALL_DOCKER}" != "true" ]]; then
        log_info "Skipping Docker installation (INSTALL_DOCKER=false)"
        return 0
    fi

    log_step "4" "Installing Docker"

    # Install prerequisites
    log_info "Installing Docker prerequisites..."
    if ! pkg_install ca-certificates gnupg lsb-release; then
        log_error "Failed to install Docker prerequisites"
        return 6
    fi

    # Add Docker GPG key
    log_info "Adding Docker GPG key..."
    mkdir -p /etc/apt/keyrings
    if ! curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
         gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null; then
        log_error "Failed to add Docker GPG key"
        return 6
    fi

    # Add Docker repository
    log_info "Adding Docker repository..."
    local arch=$(dpkg --print-architecture)
    local codename=$(lsb_release -cs)

    echo \
      "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      ${codename} stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Update package cache
    if ! pkg_update; then
        log_error "Failed to update package cache after adding Docker repo"
        return 6
    fi

    # Install Docker packages
    log_info "Installing Docker packages..."
    if ! pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
        log_error "Failed to install Docker packages"
        return 6
    fi

    # Start and enable Docker service
    log_info "Starting Docker service..."
    if ! service_start docker; then
        log_warn "Failed to start Docker service (may already be running)"
    fi

    if ! service_enable docker; then
        log_warn "Failed to enable Docker service"
    fi

    # Add user to docker group
    if id "${DOCKER_USER}" &>/dev/null; then
        log_info "Adding user ${DOCKER_USER} to docker group..."
        if ! user_add_to_group "${DOCKER_USER}" docker; then
            log_warn "Failed to add user to docker group (non-fatal)"
        else
            log_info "User ${DOCKER_USER} added to docker group (logout required to take effect)"
        fi
    else
        log_warn "User ${DOCKER_USER} not found - skipping docker group assignment"
    fi

    # Verify installation
    if command -v docker &>/dev/null; then
        DOCKER_INSTALLED_VERSION=$(docker --version 2>&1 | awk '{print $3}' | tr -d ',')
        log_success "Docker installed: ${DOCKER_INSTALLED_VERSION}"
    else
        log_error "Docker installed but command not found"
        return 6
    fi

    # Verify docker-compose plugin
    if docker compose version &>/dev/null; then
        local compose_version=$(docker compose version --short 2>&1)
        log_info "Docker Compose plugin installed: ${compose_version}"
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Function: verify_installations
# -----------------------------------------------------------------------------

verify_installations() {
    log_step "5" "Verifying installations"

    local failed=()

    # Verify Python
    if [[ "${SKIP_PYTHON}" != "true" ]]; then
        if ! command -v python3 &>/dev/null; then
            failed+=("python3")
        fi
    fi

    # Verify Node.js
    if [[ "${SKIP_NODE}" != "true" ]]; then
        if ! command -v node &>/dev/null; then
            failed+=("node")
        fi
    fi

    # Verify Docker
    if [[ "${INSTALL_DOCKER}" == "true" ]]; then
        if ! command -v docker &>/dev/null; then
            failed+=("docker")
        fi
    fi

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
    log_step "6" "Generating output"

    # Build installed tools list
    local tools=()
    [[ -n "${PYTHON_INSTALLED_VERSION}" ]] && tools+=("python=${PYTHON_INSTALLED_VERSION}")
    [[ -n "${NODE_INSTALLED_VERSION}" ]] && tools+=("node=${NODE_INSTALLED_VERSION}")
    [[ -n "${DOCKER_INSTALLED_VERSION}" ]] && tools+=("docker=${DOCKER_INSTALLED_VERSION}")

    # Structured output for parsing
    linus_result "SUCCESS" \
        "PYTHON_VERSION:${PYTHON_INSTALLED_VERSION:-none}" \
        "NODE_VERSION:${NODE_INSTALLED_VERSION:-none}" \
        "DOCKER_VERSION:${DOCKER_INSTALLED_VERSION:-none}" \
        "DOCKER_USER:${DOCKER_USER}" \
        "TOOLS_INSTALLED:$(IFS=,; echo "${tools[*]}")"
}

# -----------------------------------------------------------------------------
# Main Function
# -----------------------------------------------------------------------------

main() {
    log_header "Linus Development Tools Installation"

    validate_environment || exit $?
    install_python || exit $?
    install_nodejs || exit $?
    install_docker || exit $?
    verify_installations || exit $?
    output_result

    log_success "Development tools installation completed successfully"
    return 0
}

# -----------------------------------------------------------------------------
# Entry Point
# -----------------------------------------------------------------------------

# Only run main if script is executed (not sourced for testing)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
