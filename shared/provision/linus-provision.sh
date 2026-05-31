#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist — Unified Provisioning Dispatcher
# =============================================================================
# Single entry point that dispatches to the correct provider's
# provision-and-bootstrap driver based on PROVIDER env var.
#
# Usage:
#   PROVIDER=proxmox VM_OS_TYPE=ubuntu    ./linus-provision.sh
#   PROVIDER=vast    VAST_GPU_NAME=RTX_3090 VAST_MODEL_REPO=... ./linus-provision.sh
#   PROVIDER=aws     AWS_REGION=us-east-1   AWS_KEY_NAME=...   ./linus-provision.sh
#
# All env vars from the provider-specific driver scripts are supported.
# See: proxmox-provision-and-bootstrap.sh, vast-provision-and-bootstrap.sh,
#      aws-provision-and-bootstrap.sh
#
# Exit Codes: passthrough from provider driver
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

export PYTHONUNBUFFERED=1

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly PROVIDER="${PROVIDER:-}"

# ─── Validation ────────────────────────────────────────────────────

if [[ -z "$PROVIDER" ]]; then
    echo "ERROR: PROVIDER env var is required (proxmox | vast | aws)" >&2
    echo "Usage: PROVIDER=proxmox VM_OS_TYPE=ubuntu ./linus-provision.sh" >&2
    echo "       PROVIDER=vast VAST_GPU_NAME=RTX_3090 VAST_MODEL_REPO=... ./linus-provision.sh" >&2
    echo "       PROVIDER=aws AWS_REGION=us-east-1 AWS_KEY_NAME=... ./linus-provision.sh" >&2
    exit 2
fi

# ─── Dispatch ──────────────────────────────────────────────────────

case "$PROVIDER" in
    proxmox)
        DRIVER="$SCRIPT_DIR/proxmox-provision-and-bootstrap.sh"
        ;;
    vast)
        DRIVER="$SCRIPT_DIR/vast-provision-and-bootstrap.sh"
        ;;
    aws)
        DRIVER="$SCRIPT_DIR/aws-provision-and-bootstrap.sh"
        ;;
    *)
        echo "ERROR: Unknown provider: $PROVIDER (supported: proxmox, vast, aws)" >&2
        exit 3
        ;;
esac

if [[ ! -f "$DRIVER" ]]; then
    echo "ERROR: Driver script not found: $DRIVER" >&2
    exit 2
fi

# Pass all env vars through to the provider-specific driver
exec bash "$DRIVER"
