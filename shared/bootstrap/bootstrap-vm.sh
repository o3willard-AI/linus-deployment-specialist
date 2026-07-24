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
# Runs the command ONCE per attempt, capturing stderr via temp file.
# PITFALL: previous version had a double-eval bug — ran the command
# once for the success check and again to capture stderr, doubling
# execution time and potentially hitting locks differently.
apt_retry() {
    local max_attempts=10
    local backoff_seconds=3
    local attempt=1
    local cmd="$*"
    local stderr_file ec
    
    while [[ $attempt -le $max_attempts ]]; do
        stderr_file=$(mktemp) || { echo "ERROR: apt_retry cannot create temp file" >&2; return 1; }
        eval "$cmd" 2>"$stderr_file" && { rm -f "$stderr_file"; return 0; }
        ec=$?
        
        local stderr_output
        stderr_output=$(cat "$stderr_file")
        rm -f "$stderr_file"
        
        # Check for apt lock errors
        if [[ "$stderr_output" =~ "Could not get lock" ]] || [[ "$stderr_output" =~ "Unable to acquire the dpkg" ]]; then
            echo "APT lock detected (attempt $attempt/$max_attempts)"
            if [[ $attempt -lt $max_attempts ]]; then
                sleep $((backoff_seconds * attempt))
                ((attempt++))
            else
                echo "Failed after $max_attempts attempts: $cmd"
                return $ec
            fi
        elif _is_fatal_apt_error "$stderr_output"; then
            # Fatal error — fail immediately, don't retry
            echo "FATAL APT error (not retryable): $stderr_output"
            return $ec
        else
            # Not an apt lock error, fail fast
            echo "Non-lock APT error (exit code $ec): $stderr_output"
            return $ec
        fi
    done
}

# Function to ensure DNS works
# PITFALL: Previous version used echo -e "\n" which is fragile across
# shell versions and character encodings. Now uses explicit multi-line
# printf on the remote side.
ensure_dns() {
    local dns_servers=(${BOOTSTRAP_DNS:-8.8.8.8 1.1.1.1})
    
    # Check if DNS is working
    if ssh "${ssh_args[@]}" 'getent hosts archive.ubuntu.com' >/dev/null 2>&1; then
        echo "DNS is already working"
        return 0
    fi
    
    echo "DNS not working, attempting to fix..."
    
    # Build nameserver lines for remote execution
    local ns_cmd=""
    for ns in "${dns_servers[@]}"; do
        ns_cmd="${ns_cmd}echo 'nameserver ${ns}' | sudo tee -a /etc/resolv.conf > /dev/null && "
    done
    
    ssh "${ssh_args[@]}" "
        echo '# Added by linus bootstrap' | sudo tee /etc/resolv.conf > /dev/null && ${ns_cmd}true
    " || {
        echo "ERROR: Failed to write DNS servers to /etc/resolv.conf"
        return 1
    }
    
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
# Uses dpkg -l (works for metapackages, libs, all package types)
# PITFALL: Previous version used 'which'/'--version' which can't detect
# metapackages (ubuntu-desktop, build-essential) or library packages.
is_package_installed() {
    local pkg="$1"
    ssh "${ssh_args[@]}" "dpkg -l $pkg 2>/dev/null | grep -q '^ii'" || \
        ssh "${ssh_args[@]}" "rpm -q $pkg >/dev/null 2>&1"
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
    local stderr_file ec
    
    while [[ $attempt -le $max_attempts ]]; do
        stderr_file=$(mktemp) || { echo "ERROR: cannot create temp file" >&2; return 1; }
        ssh "${ssh_args[@]}" "${PKG_INSTALL_CMD} $pkg" 2>"$stderr_file" && { rm -f "$stderr_file"; echo "Package $pkg installed successfully"; echo "LINUS_PKG_${pkg//[-.]/_}:installed"; return 0; }
        ec=$?
        
        local stderr_output
        stderr_output=$(cat "$stderr_file")
        rm -f "$stderr_file"
        
        if [[ "$stderr_output" =~ "Could not get lock" ]] || [[ "$stderr_output" =~ "Unable to acquire the dpkg" ]]; then
            echo "APT lock detected during package installation (attempt $attempt/$max_attempts)"
            if [[ $attempt -lt $max_attempts ]]; then
                sleep $((backoff_seconds * attempt))
                ((attempt++))
            else
                echo "Failed to install package $pkg after $max_attempts attempts"
                echo "LINUS_PKG_${pkg//[-.]/_}:failed"
                return $ec
            fi
        elif _is_fatal_apt_error "$stderr_output"; then
            echo "FATAL APT error installing package $pkg: $stderr_output"
            echo "LINUS_PKG_${pkg//[-.]/_}:failed"
            return $ec
        else
            # Not an apt lock error, fail fast
            echo "Non-lock APT error installing package $pkg (exit code $ec): $stderr_output"
            echo "LINUS_PKG_${pkg//[-.]/_}:failed"
            return $ec
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

# Function to upgrade all packages with retry logic
# PITFALL: unattended-upgrades can re-acquire the dpkg lock after
# apt-get update releases the lists lock. Without retry on upgrade,
# the bootstrap fails before reaching any install calls.
upgrade_packages() {
    if [[ "$PKG_MANAGER" == "dnf" ]]; then
        echo "Upgrading packages (dnf)..."
        ssh "${ssh_args[@]}" "$PKG_UPGRADE_CMD" && { echo "Package upgrade complete"; return 0; } || { echo "ERROR: Package upgrade failed"; return 1; }
    fi

    echo "Upgrading packages (apt, with retry)..."
    apt_retry "ssh \"${ssh_args[@]}\" $PKG_UPGRADE_CMD" || {
        echo "ERROR: Package upgrade failed"
        return 1
    }
    echo "Package upgrade complete"
    return 0
}

# Bootstrap a desktop environment for computer-use agent automation.
# Installs ubuntu-desktop, agent tools (xdotool, x11-utils, etc.),
# disables Wayland (forces X11), and verifies GPU + X11.
bootstrap_desktop() {
    local desktop_packages=(
        "ubuntu-desktop" "xdotool" "x11-utils" "net-tools" "curl"
        "git" "build-essential" "python3-pip" "openjdk-17-jre-headless"
        "at-spi2-core" "accerciser" "qemu-guest-agent"
    )

    echo "=== Desktop bootstrap ==="

    # Check if cloud-init already pre-installed desktop (via cicustom injection)
    if ssh "${ssh_args[@]}" "dpkg -l ubuntu-desktop 2>/dev/null | grep -q '^ii'" 2>/dev/null; then
        echo "ubuntu-desktop already installed (cloud-init pre-install detected)"
        echo "Skipping package installation — verifying only..."

        # Verify essential tools
        local missing=()
        for pkg in xdotool x11-utils at-spi2-core accerciser qemu-guest-agent; do
            ssh "${ssh_args[@]}" "dpkg -l $pkg 2>/dev/null | grep -q '^ii'" 2>/dev/null || missing+=("$pkg")
        done
        if [[ ${#missing[@]} -gt 0 ]]; then
            echo "WARNING: ${#missing[@]} tools missing, installing: ${missing[*]}"
            for pkg in "${missing[@]}"; do
                install_package "$pkg" || echo "WARNING: Failed to install $pkg"
            done
        fi
    else
        echo "Installing desktop environment (~1,200 packages, ~7 GB)..."

        # 1. Update package cache
        if [[ "$PKG_MANAGER" == "apt" ]]; then
            echo "Updating package cache..."
            if ! apt_retry "ssh \"${ssh_args[@]}\" $PKG_UPDATE_CMD"; then
                echo "ERROR: Failed to update package cache"
                echo "LINUS_RESULT:FAILURE"
                return 1
            fi
        fi

        # 2. Upgrade existing packages
        upgrade_packages || { echo "LINUS_RESULT:FAILURE"; return 1; }

        # 3. Install desktop + agent tools
        for pkg in "${desktop_packages[@]}"; do
            install_package "$pkg" || {
                echo "ERROR: Desktop bootstrap failed on package: $pkg"
                echo "LINUS_RESULT:FAILURE"
                return 1
            }
        done
    fi

    # 4. Disable Wayland, force X11 (required for xdotool/Xvfb)
    echo "Disabling Wayland (forcing X11)..."
    ssh "${ssh_args[@]}" "sudo sed -i 's/^#\\?WaylandEnable=.*/WaylandEnable=false/' /etc/gdm3/custom.conf && grep -q 'WaylandEnable=false' /etc/gdm3/custom.conf || echo 'WaylandEnable=false' | sudo tee -a /etc/gdm3/custom.conf" || {
        echo "WARNING: Failed to disable Wayland (non-fatal)"
    }

    # 5. Verify desktop components
    echo "Verifying desktop environment..."
    ssh "${ssh_args[@]}" "
        echo '=== X11 ==='
        ps aux | grep '[X]org' && echo 'X11: OK' || echo 'X11: not running (expected before reboot)'
        echo '=== GPU ==='
        lsmod | grep virtio_gpu && echo 'VirtIO GPU: OK' || echo 'VirtIO GPU: not loaded'
        echo '=== Tools ==='
        which xdotool && echo 'xdotool: OK' || echo 'xdotool: MISSING'
        which xdpyinfo && echo 'xdpyinfo: OK' || echo 'xdpyinfo: MISSING'
        echo '=== Wayland ==='
        grep WaylandEnable /etc/gdm3/custom.conf
    " || true

    echo "Desktop bootstrap complete — reboot recommended"
    echo "LINUS_BOOTSTRAP_DESKTOP:complete"
    return 0
}

# Main execution starts here

BOOTSTRAP_TYPE="${BOOTSTRAP_TYPE:-server}"

echo "Starting bootstrap process for VM $VM_IP as user $VM_USER (type: $BOOTSTRAP_TYPE)"

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

# ─── Bootstrap type dispatch ───────────────────────────────────────
# desktop: full desktop environment for computer-use agents
# server (default): headless server with optional packages + repos

if [[ "$BOOTSTRAP_TYPE" == "desktop" ]]; then
    bootstrap_desktop || exit 1
elif [[ -z "$BOOTSTRAP_PACKAGES" && -z "$BOOTSTRAP_REPOS" ]]; then
    echo "BOOTSTRAP_TYPE=$BOOTSTRAP_TYPE, no packages or repos specified — nothing to do"
else
    # Standard server bootstrap: upgrade + install packages + clone repos

    # Upgrade system packages (critical: retry on dpkg lock)
    upgrade_packages || { echo "LINUS_RESULT:FAILURE"; exit 1; }

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
fi

echo "Bootstrap process completed successfully"
echo "LINUS_RESULT:SUCCESS"
echo "LINUS_BOOTSTRAP_PACKAGES:${BOOTSTRAP_PACKAGES:-none}"
echo "LINUS_BOOTSTRAP_REPOS:${BOOTSTRAP_REPOS:-none}"
echo "LINUS_BOOTSTRAP_DIR:${BOOTSTRAP_DIR}"