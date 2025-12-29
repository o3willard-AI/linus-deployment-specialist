#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist - Non-Interactive Automation Library
# =============================================================================
# Purpose: Smart wrappers for common commands to prevent interactive prompts
# Usage: source "${SCRIPT_DIR}/../lib/noninteractive.sh"
# =============================================================================

# Include guard
if [[ -n "${LINUS_NONINTERACTIVE_LOADED:-}" ]]; then
    return 0
fi

# Source logging if not already loaded
_NONINTERACTIVE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${LINUS_LOGGING_LOADED:-}" ]]; then
    source "${_NONINTERACTIVE_LIB_DIR}/logging.sh"
fi

# -----------------------------------------------------------------------------
# Package Management - Auto-detect distro and use correct package manager
# -----------------------------------------------------------------------------

pkg_install() {
    local packages="$@"

    if [[ -z "$packages" ]]; then
        log_error "No packages specified for installation"
        return 1
    fi

    log_info "Installing packages: $packages"

    # Detect package manager and install non-interactively
    if command -v apt-get &>/dev/null; then
        if ! DEBIAN_FRONTEND=noninteractive apt-get update -qq > /dev/null 2>&1; then
            log_warn "apt-get update failed (continuing anyway)"
        fi
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $packages > /dev/null 2>&1; then
            log_error "Failed to install packages: $packages"
            return 1
        fi
    elif command -v yum &>/dev/null; then
        if ! yum install -y -q $packages > /dev/null 2>&1; then
            log_error "Failed to install packages: $packages"
            return 1
        fi
    elif command -v dnf &>/dev/null; then
        if ! dnf install -y -q $packages > /dev/null 2>&1; then
            log_error "Failed to install packages: $packages"
            return 1
        fi
    elif command -v zypper &>/dev/null; then
        if ! zypper install -y --quiet $packages > /dev/null 2>&1; then
            log_error "Failed to install packages: $packages"
            return 1
        fi
    elif command -v pacman &>/dev/null; then
        if ! pacman -S --noconfirm --quiet $packages > /dev/null 2>&1; then
            log_error "Failed to install packages: $packages"
            return 1
        fi
    else
        log_error "No supported package manager found"
        return 1
    fi

    log_success "Packages installed: $packages"
}

pkg_update() {
    log_info "Updating package lists..."

    if command -v apt-get &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
    elif command -v yum &>/dev/null; then
        yum check-update -q
    elif command -v dnf &>/dev/null; then
        dnf check-update -q
    elif command -v zypper &>/dev/null; then
        zypper refresh --quiet
    elif command -v pacman &>/dev/null; then
        pacman -Sy --quiet
    else
        log_error "No supported package manager found"
        return 1
    fi

    log_success "Package lists updated"
}

pkg_upgrade() {
    log_info "Upgrading all packages..."

    if command -v apt-get &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
    elif command -v yum &>/dev/null; then
        yum upgrade -y -q
    elif command -v dnf &>/dev/null; then
        dnf upgrade -y -q
    elif command -v zypper &>/dev/null; then
        zypper update -y --quiet
    elif command -v pacman &>/dev/null; then
        pacman -Syu --noconfirm --quiet
    else
        log_error "No supported package manager found"
        return 1
    fi

    log_success "All packages upgraded"
}

pkg_remove() {
    local packages="$@"

    if [[ -z "$packages" ]]; then
        log_error "No packages specified for removal"
        return 1
    fi

    log_info "Removing packages: $packages"

    if command -v apt-get &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq $packages
        DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq
    elif command -v yum &>/dev/null; then
        yum remove -y -q $packages
    elif command -v dnf &>/dev/null; then
        dnf remove -y -q $packages
    elif command -v zypper &>/dev/null; then
        zypper remove -y --quiet $packages
    elif command -v pacman &>/dev/null; then
        pacman -R --noconfirm --quiet $packages
    else
        log_error "No supported package manager found"
        return 1
    fi

    log_success "Packages removed: $packages"
}

# -----------------------------------------------------------------------------
# File Operations - Non-destructive by default, force when needed
# -----------------------------------------------------------------------------

safe_remove() {
    local path="$1"
    local force="${2:-false}"

    if [[ -z "$path" ]]; then
        log_error "No path specified for removal"
        return 1
    fi

    if [[ "$force" == "true" ]]; then
        rm -rf "$path"
        log_info "Removed (forced): $path"
    else
        if [[ -e "$path" ]]; then
            rm -rf "$path"
            log_info "Removed: $path"
        else
            log_warn "Path does not exist: $path"
        fi
    fi
}

safe_copy() {
    local source="$1"
    local dest="$2"
    local overwrite="${3:-false}"

    if [[ -z "$source" ]] || [[ -z "$dest" ]]; then
        log_error "Source and destination required for copy"
        return 1
    fi

    if [[ "$overwrite" == "true" ]]; then
        cp -rf "$source" "$dest"
    else
        cp -rn "$source" "$dest"
    fi

    log_info "Copied: $source -> $dest"
}

# -----------------------------------------------------------------------------
# Git Operations - Non-interactive with sensible defaults
# -----------------------------------------------------------------------------

git_clone_quiet() {
    local repo_url="$1"
    local target_dir="${2:-.}"
    local branch="${3:-}"

    if [[ -z "$repo_url" ]]; then
        log_error "Repository URL required"
        return 1
    fi

    local git_args="--quiet --depth 1"
    if [[ -n "$branch" ]]; then
        git_args="$git_args --branch $branch"
    fi

    git clone $git_args "$repo_url" "$target_dir"
    log_success "Cloned repository: $repo_url"
}

git_pull_quiet() {
    local repo_dir="${1:-.}"

    (
        cd "$repo_dir"
        git pull --quiet --ff-only
    )

    log_success "Updated repository: $repo_dir"
}

# -----------------------------------------------------------------------------
# Service Management - Systemd/SysVinit abstraction
# -----------------------------------------------------------------------------

service_start() {
    local service_name="$1"

    if [[ -z "$service_name" ]]; then
        log_error "Service name required"
        return 1
    fi

    if command -v systemctl &>/dev/null; then
        systemctl start "$service_name"
    else
        service "$service_name" start
    fi

    log_success "Started service: $service_name"
}

service_stop() {
    local service_name="$1"

    if [[ -z "$service_name" ]]; then
        log_error "Service name required"
        return 1
    fi

    if command -v systemctl &>/dev/null; then
        systemctl stop "$service_name"
    else
        service "$service_name" stop
    fi

    log_success "Stopped service: $service_name"
}

service_enable() {
    local service_name="$1"

    if [[ -z "$service_name" ]]; then
        log_error "Service name required"
        return 1
    fi

    if command -v systemctl &>/dev/null; then
        systemctl enable "$service_name"
    else
        chkconfig "$service_name" on
    fi

    log_success "Enabled service: $service_name"
}

service_restart() {
    local service_name="$1"

    if [[ -z "$service_name" ]]; then
        log_error "Service name required"
        return 1
    fi

    if command -v systemctl &>/dev/null; then
        systemctl restart "$service_name"
    else
        service "$service_name" restart
    fi

    log_success "Restarted service: $service_name"
}

# -----------------------------------------------------------------------------
# User/Group Management
# -----------------------------------------------------------------------------

user_create() {
    local username="$1"
    local home_dir="${2:-/home/$username}"
    local shell="${3:-/bin/bash}"

    if [[ -z "$username" ]]; then
        log_error "Username required"
        return 1
    fi

    # Check if user already exists
    if id "$username" &>/dev/null; then
        log_warn "User already exists: $username"
        return 0
    fi

    useradd -m -d "$home_dir" -s "$shell" "$username"
    log_success "Created user: $username"
}

user_add_to_group() {
    local username="$1"
    local group="$2"

    if [[ -z "$username" ]] || [[ -z "$group" ]]; then
        log_error "Username and group required"
        return 1
    fi

    usermod -aG "$group" "$username"
    log_success "Added $username to group: $group"
}

# -----------------------------------------------------------------------------
# Network Operations
# -----------------------------------------------------------------------------

download_file() {
    local url="$1"
    local output="${2:-}"

    if [[ -z "$url" ]]; then
        log_error "URL required"
        return 1
    fi

    if [[ -n "$output" ]]; then
        curl --silent --show-error --fail --location --output "$output" "$url"
    else
        curl --silent --show-error --fail --location "$url"
    fi
    log_success "Downloaded: $url"
}

# -----------------------------------------------------------------------------
# Command Runner with Auto-flags
# -----------------------------------------------------------------------------

run_noninteractive() {
    local cmd="$@"

    if [[ -z "$cmd" ]]; then
        log_error "No command specified"
        return 1
    fi

    # Detect command type and add appropriate flags
    case "$cmd" in
        apt*install*|apt*upgrade*|apt*remove*)
            DEBIAN_FRONTEND=noninteractive $cmd -y
            ;;
        yum*|dnf*)
            $cmd -y
            ;;
        git*clone*)
            $cmd --quiet
            ;;
        systemctl*)
            $cmd --quiet
            ;;
        *)
            # Run as-is for unknown commands
            $cmd
            ;;
    esac
}

# Mark as loaded
LINUS_NONINTERACTIVE_LOADED=1
