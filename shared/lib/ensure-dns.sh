#!/usr/bin/env bash
# =============================================================================
# ensure-dns.sh — DNS self-healing for cloud-init provisioned VMs
# =============================================================================
# Proxmox cloud-init with ipconfig0 often leaves VMs without working DNS
# (systemd-resolved stub resolver only). This function adds fallback
# nameservers and verifies DNS resolution works.
#
# Usage: source this file, then call ensure_dns
#   ensure_dns [dns_servers...]
#
# Default DNS servers: 8.8.8.8 1.1.1.1
# =============================================================================

ensure_dns() {
    local dns_servers=("${@:-8.8.8.8 1.1.1.1}")

    # If DNS already works, skip
    if getent hosts archive.ubuntu.com >/dev/null 2>&1; then
        return 0
    fi

    log_info "DNS not resolving — adding fallback nameservers..."

    # Add nameservers to resolv.conf (most universally compatible approach)
    # systemd-resolved may not be running; writing to /etc/resolv.conf works everywhere
    if [[ -w /etc/resolv.conf ]]; then
        grep -v '^nameserver' /etc/resolv.conf > /tmp/resolv.tmp 2>/dev/null || true
        {
            cat /tmp/resolv.tmp
            for ns in "${dns_servers[@]}"; do
                echo "nameserver $ns"
            done
        } > /etc/resolv.conf
    else
        # Need sudo
        grep -v '^nameserver' /etc/resolv.conf > /tmp/resolv.tmp 2>/dev/null || true
        {
            cat /tmp/resolv.tmp
            for ns in "${dns_servers[@]}"; do
                echo "nameserver $ns"
            done
        } | sudo tee /etc/resolv.conf >/dev/null
    fi

    rm -f /tmp/resolv.tmp

    # Verify it worked
    if getent hosts archive.ubuntu.com >/dev/null 2>&1; then
        log_info "DNS fallback applied successfully"
        return 0
    fi

    log_warn "DNS still not resolving after fallback"
    return 1
}
