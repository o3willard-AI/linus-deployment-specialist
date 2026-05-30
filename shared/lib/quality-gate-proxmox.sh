#!/usr/bin/env bash
# =============================================================================
# Quality Gate Helpers — Proxmox VM Provider Specific
# =============================================================================
# Proxmox-specific quality checks: VM capability verification,
# apt fatal pattern detection. Sources shared quality-gate.sh for base gates.
#
# Source in Proxmox scripts:
#   source "${SCRIPT_DIR}/../lib/quality-gate.sh"
#   source "${SCRIPT_DIR}/../lib/quality-gate-proxmox.sh"
# =============================================================================

# ─── VM Capability Check ──────────────────────────────────────────

# Verifies a Proxmox VM can run workloads — not just that SSH works.
# Checks: AVX2/SSE4.2 (ML workloads), disk space, DNS, Python.
#
# Args: ssh_args_array (bash array reference not supported; pass as string),
#       vm_user, vm_ip
# Returns: 0 if VERIFIED, 8 if DEGRADED
_linus_check_vm_capability() {
    local vm_user="$1"
    local vm_ip="$2"
    local ssh_key="$3"

    local ssh_args=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
    [[ -n "$ssh_key" && -f "$ssh_key" ]] && ssh_args+=(-i "$ssh_key")

    local all_passed=true

    # Check 1: CPU supports AVX2/SSE4.2 (pitfall #25)
    if ssh "${ssh_args[@]}" "${vm_user}@${vm_ip}" \
        "grep -q -E 'avx2|sse4_2' /proc/cpuinfo" 2>/dev/null; then
        log_info "  CPU supports AVX2/SSE4.2 ✅"
    else
        log_warn "  CPU MISSING AVX2/SSE4.2 — ML workloads may crash"
        _warn_tag "cpu_no_avx2"
        all_passed=false
    fi

    # Check 2: >2 GB free disk
    local disk_free
    disk_free=$(ssh "${ssh_args[@]}" "${vm_user}@${vm_ip}" \
        "df -BG / | awk 'NR==2 {print \$4}' | sed 's/G//'" 2>/dev/null) || disk_free=0
    if [[ "$disk_free" -gt 2 ]]; then
        log_info "  Disk: ${disk_free}GB free ✅"
    else
        log_warn "  Disk: ${disk_free}GB free (<2 GB)"
        _warn_tag "disk_low"
        all_passed=false
    fi

    # Check 3: DNS
    if ssh "${ssh_args[@]}" "${vm_user}@${vm_ip}" \
        "getent hosts archive.ubuntu.com >/dev/null 2>&1" 2>/dev/null; then
        log_info "  DNS working ✅"
    else
        log_warn "  DNS not working"
        _warn_tag "dns_dead"
        all_passed=false
    fi

    # Check 4: Python
    if ssh "${ssh_args[@]}" "${vm_user}@${vm_ip}" \
        "which python3 >/dev/null 2>&1" 2>/dev/null; then
        local py_ver
        py_ver=$(ssh "${ssh_args[@]}" "${vm_user}@${vm_ip}" \
            "python3 --version 2>&1" 2>/dev/null) || py_ver="unknown"
        log_info "  Python: ${py_ver} ✅"
    else
        log_warn "  Python not installed"
        _warn_tag "no_python"
        all_passed=false
    fi

    if $all_passed; then
        return 0
    else
        return 8
    fi
}

# ─── APT Fatal Pattern Detection ──────────────────────────────────

# Checks apt/dnf stderr output for fatal (non-retryable) errors.
# Catches DNS failures, disk full, bad sources — fail fast, don't retry.
#
# Args: stderr_output (string)
# Returns: 0 if no fatal patterns, 1 if fatal pattern detected
_linus_check_apt_fatal_patterns() {
    local stderr_output="$1"

    local fatal_patterns=(
        "Temporary failure resolving"
        "No space left on device"
        "404  Not Found"
        "Hash Sum mismatch"
        "dpkg was interrupted"
        "Failed to fetch"
        "Connection refused"
    )

    for pattern in "${fatal_patterns[@]}"; do
        if [[ "$stderr_output" == *"$pattern"* ]]; then
            _warn_tag "apt_fatal_${pattern// /_}"
            return 1
        fi
    done

    return 0
}
