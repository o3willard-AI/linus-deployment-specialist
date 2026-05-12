#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist — Shared SSH Authentication Library
# =============================================================================
# Provides unified SSH/SCP with key → password → bare fallback.
# Source this file, then use: ssh_exec, ssh_sudo, scp_exec
#
# Expected environment variables:
#   QEMU_HOST      — target host (or PROXMOX_HOST, AWS_HOST, etc.)
#   QEMU_USER      — SSH username
#   QEMU_SUDO_PASS — sudo/SSH password (optional)
#   QEMU_SSH_KEY   — SSH private key path (optional)
#   PROVIDER_HOST  — generic host variable (if QEMU_HOST not set)
#   PROVIDER_USER  — generic user variable (if QEMU_USER not set)
# =============================================================================

# Include guard
if [[ -n "${LINUS_SSH_AUTH_LOADED:-}" ]]; then
    return 0
fi

# Resolve host/user from provider-specific or generic vars
_ssh_resolve_host() {
    if [[ -n "${QEMU_HOST:-}" ]]; then echo "$QEMU_HOST"
    elif [[ -n "${PROXMOX_HOST:-}" ]]; then echo "$PROXMOX_HOST"
    elif [[ -n "${PROVIDER_HOST:-}" ]]; then echo "$PROVIDER_HOST"
    else echo ""; fi
}

_ssh_resolve_user() {
    if [[ -n "${QEMU_USER:-}" ]]; then echo "$QEMU_USER"
    elif [[ -n "${PROXMOX_USER:-}" ]]; then echo "$PROXMOX_USER"
    elif [[ -n "${PROVIDER_USER:-}" ]]; then echo "$PROVIDER_USER"
    else echo ""; fi
}

_ssh_resolve_pass() {
    if [[ -n "${QEMU_SUDO_PASS:-}" ]]; then echo "$QEMU_SUDO_PASS"
    elif [[ -n "${PROXMOX_SUDO_PASS:-}" ]]; then echo "$PROXMOX_SUDO_PASS"
    elif [[ -n "${PROVIDER_SUDO_PASS:-}" ]]; then echo "$PROVIDER_SUDO_PASS"
    else echo ""; fi
}

_ssh_resolve_key() {
    if [[ -n "${QEMU_SSH_KEY:-}" ]]; then echo "$QEMU_SSH_KEY"
    elif [[ -n "${PROXMOX_SSH_KEY:-}" ]]; then echo "$PROXMOX_SSH_KEY"
    elif [[ -n "${PROVIDER_SSH_KEY:-}" ]]; then echo "$PROVIDER_SSH_KEY"
    else echo ""; fi
}

# -----------------------------------------------------------------------------
# _auth_ssh — SSH with key, password, or bare (whichever is available)
# Usage: _auth_ssh -o StrictHostKeyChecking=no user@host "command"
# -----------------------------------------------------------------------------
_auth_ssh() {
    local key
    key="$(_ssh_resolve_key)"
    local pass
    pass="$(_ssh_resolve_pass)"

    if [[ -n "$key" && -f "$key" ]]; then
        ssh -i "$key" "$@"
    elif [[ -n "$pass" ]]; then
        sshpass -p "$pass" ssh "$@"
    else
        ssh "$@"
    fi
}

# -----------------------------------------------------------------------------
# ssh_exec — Execute a command on the remote host (no sudo)
# Usage: ssh_exec "which virsh"
# -----------------------------------------------------------------------------
ssh_exec() {
    local cmd="$1"
    local host; host="$(_ssh_resolve_host)"
    local user; user="$(_ssh_resolve_user)"

    if [[ -z "$host" || -z "$user" ]]; then
        echo "ERROR [ssh-auth]: host/user not set" >&2
        return 1
    fi
    _auth_ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${user}@${host}" "$cmd"
}

# -----------------------------------------------------------------------------
# ssh_sudo — Execute a command on the remote host with sudo
# Usage: ssh_sudo "virsh list --all"
# -----------------------------------------------------------------------------
ssh_sudo() {
    local cmd="$1"
    local host; host="$(_ssh_resolve_host)"
    local user; user="$(_ssh_resolve_user)"
    local pass; pass="$(_ssh_resolve_pass)"

    if [[ -z "$host" || -z "$user" ]]; then
        echo "ERROR [ssh-auth]: host/user not set" >&2
        return 1
    fi

    if [[ -n "$pass" ]]; then
        _auth_ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${user}@${host}" \
            "echo '$pass' | sudo -S bash -c '$cmd'"
    else
        _auth_ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${user}@${host}" \
            "sudo bash -c '$cmd'"
    fi
}

# -----------------------------------------------------------------------------
# scp_exec — Copy files to/from the remote host
# Usage: scp_exec localfile user@host:/remote/path/
# -----------------------------------------------------------------------------
scp_exec() {
    local key
    key="$(_ssh_resolve_key)"
    local pass
    pass="$(_ssh_resolve_pass)"

    local scp_cmd=("scp" "-o" "StrictHostKeyChecking=no" "-o" "UserKnownHostsFile=/dev/null")

    if [[ -n "$key" && -f "$key" ]]; then
        scp_cmd+=("-i" "$key")
    fi

    if [[ -n "$pass" ]]; then
        sshpass -p "$pass" "${scp_cmd[@]}" "$@"
    else
        "${scp_cmd[@]}" "$@"
    fi
}

# -----------------------------------------------------------------------------
# ssh_check — Quick connectivity test, returns 0 if reachable
# Usage: if ssh_check; then echo "connected"; fi
# -----------------------------------------------------------------------------
ssh_check() {
    local host; host="$(_ssh_resolve_host)"
    local user; user="$(_ssh_resolve_user)"
    _auth_ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o UserKnownHostsFile=/dev/null \
        "${user}@${host}" "echo SSH_OK" >/dev/null 2>&1
}

LINUS_SSH_AUTH_LOADED=1
