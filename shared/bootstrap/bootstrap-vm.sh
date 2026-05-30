#!/bin/bash

# Bootstrap script for VM setup after Proxmox provisioning
# This script installs packages, clones repos, and sets up environment
# with DNS self-healing and apt-lock-retry patterns

set -euo pipefail

# Default values
: "${VM_IP:?VM_IP must be set}"
: "${VM_USER:?VM_USER must be set}"
BOOTSTRAP_PACKAGES="${BOOTSTRAP_PACKAGES:-}"
BOOTSTRAP_REPOS="${BOOTSTRAP_REPOS:-}"
BOOTSTRAP_DNS="${BOOTSTRAP_DNS:-8.8.8.8 1.1.1.1}"
BOOTSTRAP_DIR="${BOOTSTRAP_DIR:-/tmp/linus-bootstrap}"

# SSH key detection (same pattern as proxmox.sh)
key=""
if [[ -f ~/.ssh/id_ed25519_qemu_test ]]; then
    key=~/.ssh/id_ed25519_qemu_test
elif [[ -f ~/.ssh/id_ed25519 ]]; then
    key=~/.ssh/id_ed25519
elif [[ -f ~/.ssh/id_rsa ]]; then
    key=~/.ssh/id_rsa
else
    echo "ERROR: No SSH key found in ~/.ssh/ (id_ed25519_qemu_test, id_ed25519, or id_rsa)"
    exit 1
fi

# SSH arguments using bash arrays to avoid word splitting issues
# ServerAliveInterval=30 prevents Proxmox bridge from dropping idle connections
# during long-running operations (apt-get install, git clone).
#
# STANDARD (§3.1.5): Arrays ONLY for SSH command construction.
# Never build SSH as a string variable — use "${ssh_args[@]}" for all calls.
ssh_args=(-i "$key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ServerAliveInterval=30 -o ServerAliveCountMax=3
          "${VM_USER}@${VM_IP}")

# Fatal apt error patterns — fail immediately, don't retry
readonly APT_FATAL_PATTERNS=(
    "Temporary failure resolving"    # DNS dead
    "No space left on device"        # Disk full
    "404  Not Found"                 # Bad sources
    "Hash Sum mismatch"              # Corrupt package cache
    "dpkg was interrupted"           # Needs manual intervention
    "Failed to fetch"                # Network unreachable
    "Connection refused"             # Proxy/mirror down
)

# Check if stderr output contains a fatal (non-retryable) apt error
_is_fatal_apt_error() {
    local stderr_output="$1"
    for pattern in "${APT_FATAL_PATTERNS[@]}"; do
        if [[ "$stderr_output" == *"$pattern"* ]]; then
            return 0
        fi
    done
    return 1
}

# Function for apt lock retry with backoff
apt_retry() {
    local max_attempts=10
    local backoff_seconds=3
    local attempt=1
    local cmd="$*"
    
    while [[ $attempt -le $max_attempts ]]; do
        if eval "$cmd"; then
            return 0
        else
            local exit_code=$?
            # Capture stderr for diagnosis but don't discard it
            local stderr_output=$(eval "$cmd" 2>&1)
            
            # Check for apt lock errors
            if [[ "$stderr_output" =~ "Could not get lock" ]] || [[ "$stderr_output" =~ "Unable to acquire the dpkg" ]]; then
                echo "APT lock detected (attempt $attempt/$max_attempts): $stderr_output"
                if [[ $attempt -lt $max_attempts ]]; then
                    sleep $((backoff_seconds * attempt))
                    ((attempt++))
                else
                    echo "Failed after $max_attempts attempts: $cmd"
                    return $exit_code
                fi
            elif _is_fatal_apt_error "$stderr_output"; then
                # Fatal error — fail immediately, don't retry
                echo "FATAL APT error (not retryable): $stderr_output"
                return $exit_code
            else
                # Not an apt lock error, fail fast
                echo "Non-lock APT error (exit code $exit_code): $stderr_output"
                return $exit_code
            fi
        fi
    done
}

# Function to ensure DNS works
ensure_dns() {
    local dns_servers=($BOOTSTRAP_DNS)
    
    # Check if DNS is working
    if ssh "${ssh_args[@]}" 'getent hosts archive.ubuntu.com' >/dev/null 2>&1; then
        echo "DNS is already working"
        return 0
    fi
    
    echo "DNS not working, attempting to fix..."
    
    # Add nameservers to /etc/resolv.conf
    local resolv_conf="# Added by linus bootstrap\nnameserver ${dns_servers[0]}\nnameserver ${dns_servers[1]}\n"
    
    if ! ssh "${ssh_args[@]}" "sudo bash -c 'echo -e \"$resolv_conf\" > /etc/resolv.conf'"; then
        echo "ERROR: Failed to write DNS servers to /etc/resolv.conf"
        return 1
    fi
    
    # Verify DNS works after fix
    if ssh "${ssh_args[@]}" 'getent hosts archive.ubuntu.com' >/dev/null 2>&1; then
        echo "DNS fixed successfully"
        return 0
    else
        echo "ERROR: DNS still not working after fix"
        return 1
    fi
}

# Function to check if a package is already installed
is_package_installed() {
    local pkg="$1"
    ssh "${ssh_args[@]}" "which $pkg >/dev/null 2>&1" || ssh "${ssh_args[@]}" "$pkg --version >/dev/null 2>&1"
}

# Function to install a package with retry logic
install_package() {
    local pkg="$1"
    
    # Skip if already installed
    if is_package_installed "$pkg"; then
        echo "Package $pkg already installed"
        echo "LINUS_PKG_${pkg//[-.]/_}:installed"
        return 0
    fi
    
    echo "Installing package: $pkg (using ${PKG_MANAGER})"
    
    # Update package cache with retry
    if [[ "$PKG_MANAGER" == "dnf" ]]; then
        # dnf: just install directly (auto-refreshes cache)
        if ssh "${ssh_args[@]}" "${PKG_INSTALL_CMD} $pkg"; then
            echo "Package $pkg installed successfully"
            echo "LINUS_PKG_${pkg//[-.]/_}:installed"
            return 0
        else
            echo "ERROR: Failed to install package $pkg"
            echo "LINUS_PKG_${pkg//[-.]/_}:failed"
            return 1
        fi
    fi
    
    # apt: update cache first, then install with retry
    if ! apt_retry "ssh "${ssh_args[@]}" $PKG_UPDATE_CMD"; then
        echo "ERROR: Failed to update apt cache for package $pkg"
        echo "LINUS_PKG_${pkg//[-.]/_}:failed"
        return 1
    fi
    
    # Install package with retry and longer backoff
    local max_attempts=8
    local backoff_seconds=4
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        if ssh "${ssh_args[@]}" "${PKG_INSTALL_CMD} $pkg"; then
            echo "Package $pkg installed successfully"
            echo "LINUS_PKG_${pkg//[-.]/_}:installed"
            return 0
        else
            local exit_code=$?
            local stderr_output=$(ssh "${ssh_args[@]}" "${PKG_INSTALL_CMD} $pkg" 2>&1)
            
            if [[ "$stderr_output" =~ "Could not get lock" ]] || [[ "$stderr_output" =~ "Unable to acquire the dpkg" ]]; then
                echo "APT lock detected during package installation (attempt $attempt/$max_attempts): $stderr_output"
                if [[ $attempt -lt $max_attempts ]]; then
                    sleep $((backoff_seconds * attempt))
                    ((attempt++))
                else
                    echo "Failed to install package $pkg after $max_attempts attempts"
                    echo "LINUS_PKG_${pkg//[-.]/_}:failed"
                    return $exit_code
                fi
            elif _is_fatal_apt_error "$stderr_output"; then
                echo "FATAL APT error installing package $pkg: $stderr_output"
                echo "LINUS_PKG_${pkg//[-.]/_}:failed"
                return $exit_code
            else
                # Not an apt lock error, fail fast
                echo "Non-lock APT error installing package $pkg (exit code $exit_code): $stderr_output"
                echo "LINUS_PKG_${pkg//[-.]/_}:failed"
                return $exit_code
            fi
        fi
    done
}

# Function to clone a repo if not already cloned
clone_repo() {
    local repo="$1"
    
    # Skip if already cloned
    if ssh "${ssh_args[@]}" "[ -d /home/$VM_USER/${repo##*/} ]"; then
        echo "Repo $repo already cloned"
        echo "LINUS_REPO_${repo//\//_}:cloned"
        return 0
    fi
    
    echo "Cloning repo: $repo"
    
    # Create directory if needed and clone
    if ssh "${ssh_args[@]}" "mkdir -p /home/$VM_USER && cd /home/$VM_USER && git clone https://github.com/$repo.git"; then
        # Set ownership to VM_USER
        ssh "${ssh_args[@]}" "sudo chown -R $VM_USER:$VM_USER /home/$VM_USER/${repo##*/}"
        echo "Repo $repo cloned successfully"
        echo "LINUS_REPO_${repo//\//_}:cloned"
        return 0
    else
        local exit_code=$?
        echo "ERROR: Failed to clone repo $repo"
        echo "LINUS_REPO_${repo//\//_}:failed"
        return $exit_code
    fi
}

# Main execution starts here

echo "Starting bootstrap process for VM $VM_IP as user $VM_USER"

# Verify SSH access
if ! ssh "${ssh_args[@]}" 'echo "SSH access verified"'; then
    echo "ERROR: Cannot SSH to $VM_IP as $VM_USER"
    exit 1
fi

# Detect package manager on the VM (apt for Debian/Ubuntu, dnf for RHEL/AlmaLinux/Rocky)
echo "Detecting package manager..."
if ssh "${ssh_args[@]}" 'which dnf >/dev/null 2>&1'; then
    PKG_UPDATE_CMD="dnf check-update -q || true"
    PKG_INSTALL_CMD="dnf install -y -q"
    PKG_UPGRADE_CMD="dnf upgrade -y -q"
    PKG_MANAGER="dnf"
    echo "  Package manager: dnf (RHEL-based)"
elif ssh "${ssh_args[@]}" 'which apt-get >/dev/null 2>&1'; then
    PKG_UPDATE_CMD="apt-get update -qq"
    PKG_INSTALL_CMD="apt-get install -y -qq"
    PKG_UPGRADE_CMD="apt-get upgrade -y -qq"
    PKG_MANAGER="apt"
    echo "  Package manager: apt (Debian-based)"
else
    echo "ERROR: No supported package manager found (apt-get or dnf)"
    echo "LINUS_RESULT:FAILURE"
    exit 1
fi

# Ensure DNS works
if ! ensure_dns; then
    echo "ERROR: Failed to fix DNS"
    echo "LINUS_RESULT:FAILURE"
    exit 1
fi

# Create working directory on VM
ssh "${ssh_args[@]}" "mkdir -p $BOOTSTRAP_DIR"

# Install packages
if [[ -n "$BOOTSTRAP_PACKAGES" ]]; then
    IFS=' ' read -ra pkgs <<< "$BOOTSTRAP_PACKAGES"
    for pkg in "${pkgs[@]}"; do
        if [[ -n "$pkg" ]]; then
            install_package "$pkg"
        fi
    done
fi

# Clone repos
if [[ -n "$BOOTSTRAP_REPOS" ]]; then
    IFS=' ' read -ra repos <<< "$BOOTSTRAP_REPOS"
    for repo in "${repos[@]}"; do
        if [[ -n "$repo" ]]; then
            clone_repo "$repo"
        fi
    done
fi

echo "Bootstrap process completed successfully"
echo "LINUS_RESULT:SUCCESS"
echo "LINUS_BOOTSTRAP_PACKAGES:${BOOTSTRAP_PACKAGES:-none}"
echo "LINUS_BOOTSTRAP_REPOS:${BOOTSTRAP_REPOS:-none}"
echo "LINUS_BOOTSTRAP_DIR:${BOOTSTRAP_DIR}"