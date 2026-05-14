#!/usr/bin/env bash
# =============================================================================
# E2E Test Runner with Hard Timeout
# =============================================================================
# Wraps the E2E test with a circuit breaker: if any phase hangs (VM boot stall,
# API timeout, SSH wedged), the entire test is killed after the timeout instead
# of running forever.
#
# Usage:
#   ./test-proxmox-timed.sh [timeout_seconds]
#
# Default timeout: 900s (15 minutes) — covers 4 phases including Ubuntu 24.04
# first-boot cloud-init delays.
#
# Environment: all PROXMOX_* vars must be exported, or source from secrets.
# =============================================================================

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly TIMEOUT="${1:-900}"

# ---------------------------------------------------------------------------
# Auto-discover Proxmox credentials if not already in environment
# ---------------------------------------------------------------------------
auto_discover_creds() {
    local secret_dirs=(
        "$HOME/.hermes/secrets"
        "$HOME/.hermes/env"
    )
    local cred_files=(
        "proxmox-token-${PROXMOX_HOST:-192.168.101.155}"
        "proxmox-${PROXMOX_HOST:-192.168.101.155}"
        "proxmox-token"
        "proxmox"
    )

    for dir in "${secret_dirs[@]}"; do
        for fname in "${cred_files[@]}"; do
            local fpath="${dir}/${fname}"
            if [[ -f "$fpath" && -r "$fpath" ]]; then
                # shellcheck disable=SC1090
                source "$fpath"
            fi
        done
    done
}

auto_discover_creds

# ---------------------------------------------------------------------------
# Pre-flight: verify we can reach Proxmox before starting the timer
# ---------------------------------------------------------------------------
echo "=== E2E Pre-flight Check ==="
echo "Proxmox host: ${PROXMOX_HOST:-UNSET}"
echo "Timeout: ${TIMEOUT}s"

if ! curl -sk --fail --connect-timeout 5 \
    -H "Authorization: PVEAPIToken=${PROXMOX_USER}!${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
    "https://${PROXMOX_HOST}:8006/api2/json/version" >/dev/null 2>&1; then
    echo "FATAL: Cannot reach Proxmox API at ${PROXMOX_HOST}:8006"
    echo "Check PROXMOX_HOST, PROXMOX_USER, PROXMOX_TOKEN_ID, PROXMOX_TOKEN_SECRET"
    exit 1
fi
echo "Proxmox API: OK"

# Verify SSH key exists
SSH_KEY=""
for candidate in ~/.ssh/id_ed25519_qemu_test ~/.ssh/id_ed25519 ~/.ssh/id_rsa; do
    if [[ -f "$candidate" ]]; then
        SSH_KEY="$candidate"
        break
    fi
done
if [[ -z "$SSH_KEY" ]]; then
    echo "FATAL: No SSH private key found for VM access"
    exit 1
fi
echo "SSH key: ${SSH_KEY}"
echo ""

# ---------------------------------------------------------------------------
# Run E2E test with hard timeout
# ---------------------------------------------------------------------------
echo "=== Starting E2E Test (timeout=${TIMEOUT}s) ==="
START_TIME=$(date +%s)

# Run under timeout — if the E2E test hangs, it gets SIGTERM after TIMEOUT seconds
timeout --signal=TERM --kill-after=30 "${TIMEOUT}" \
    bash "${SCRIPT_DIR}/test-proxmox-enhanced.sh"
EXIT_CODE=$?

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo ""
echo "=== E2E Test Finished ==="
echo "Exit code: ${EXIT_CODE}"
echo "Elapsed:   ${ELAPSED}s"

case $EXIT_CODE in
    0)
        echo "Result:    PASS"
        ;;
    124)
        echo "Result:    TIMEOUT after ${TIMEOUT}s"
        echo "One or more phases hung — check VM boot, SSH, or API latency"
        ;;
    137)
        echo "Result:    KILLED (SIGKILL after timeout + grace period)"
        echo "Test was unresponsive to SIGTERM — likely SSH or process deadlock"
        ;;
    *)
        echo "Result:    FAILED (see output above for which phase)"
        ;;
esac

exit $EXIT_CODE
