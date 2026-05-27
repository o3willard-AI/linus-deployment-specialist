#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist — Vast.ai GPU Instance Provisioning
# =============================================================================
# Purpose: Search, select, and provision GPU instances on Vast.ai for
#   LLM inference workloads. Battle-tested on 7+ provisioning cycles.
#
# Required Environment Variables:
#   VAST_API_KEY        — Vast.ai API key (auto-discovered from KeePass/secrets)
#   VAST_GPU_NAME       — GPU model filter (default: RTX_3090)
#   VAST_MIN_RELIABILITY— Host reliability floor (default: 0.99)
#   VAST_MAX_PRICE      — Max $/hr ceiling (optional)
#   VAST_SORT_STRATEGY  — value|cheapest|fastest (default: value)
#   VAST_CUDA_ARCH      — CUDA architecture flag (default: 86)
#   VAST_MODEL_REPO     — HuggingFace repo (optional, for sizing)
#   VAST_MODEL_FILE     — GGUF filename (optional)
#   VAST_MODEL_QUANT    — Quantization level (default: Q4_K_M)
#   VAST_CTX_SIZE       — Context window (default: 32768)
#
# Usage:
#   export VAST_GPU_NAME=RTX_3090
#   ./vast.sh
#
# Exit Codes:
#   0 — Success
#   1 — General error
#   2 — Missing dependencies
#   3 — Invalid configuration
#   4 — Provider offline
#   5 — Instance creation failed
#   6 — SSH timeout
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source shared libraries
source "$SCRIPT_DIR/../lib/paths.sh" || exit 1
source_lib "logging.sh" "validation.sh" "vast-sizing.sh"

# -----------------------------------------------------------------------------
# Configuration from environment with defaults
# -----------------------------------------------------------------------------

readonly VAST_GPU_NAME="${VAST_GPU_NAME:-RTX_3090}"
readonly VAST_NUM_GPUS="${VAST_NUM_GPUS:-1}"
readonly VAST_MIN_RELIABILITY="${VAST_MIN_RELIABILITY:-0.99}"
readonly VAST_SORT_STRATEGY="${VAST_SORT_STRATEGY:-value}"
readonly VAST_CUDA_ARCH="${VAST_CUDA_ARCH:-86}"
readonly VAST_MODEL_QUANT="${VAST_MODEL_QUANT:-Q4_K_M}"
readonly VAST_CTX_SIZE="${VAST_CTX_SIZE:-32768}"
readonly VAST_IMAGE="${VAST_IMAGE:-nvidia/cuda:12.4.0-devel-ubuntu22.04}"
readonly VAST_API_KEY_NAME="${VAST_API_KEY_NAME:-linus-inference}"

# Instance state (populated during provisioning)
ALLOCATED_CONTRACT_ID=""
ALLOCATED_SSH_HOST=""
ALLOCATED_SSH_PORT=""
ALLOCATED_PROXY_PORT=""

# -----------------------------------------------------------------------------
# Credential auto-discovery (matches proxmox.sh pattern)
# -----------------------------------------------------------------------------

_linus_vast_discover_credentials() {
    # If VAST_API_KEY already set in environment, use it
    if [[ -n "${VAST_API_KEY:-}" ]]; then
        return 0
    fi

    # Scan ~/.hermes/secrets/ for vast credential files
    local secret_dirs=(
        "$HOME/.hermes/secrets"
        "$HOME/.hermes/env"
    )
    local cred_files=("vast-api-key" "vast-token" "vast")

    for dir in "${secret_dirs[@]}"; do
        for fname in "${cred_files[@]}"; do
            local fpath="${dir}/${fname}"
            if [[ -f "$fpath" && -r "$fpath" ]]; then
                VAST_API_KEY="$(head -1 "$fpath" | tr -d '\n\r ')"
                log_info "VAST_API_KEY loaded from ${fpath}"
                export VAST_API_KEY
                return 0
            fi
        done
    done

    # Fallback: KeePass — only if keepassxc-cli is available
    if command -v keepassxc-cli &>/dev/null; then
        local kdbx="$HOME/.hermes/secrets/keepass/secrets.kdbx"
        local master_pw_file="$HOME/.hermes/secrets/keepass/.master-pw"
        if [[ -f "$kdbx" && -f "$master_pw_file" ]]; then
            local kpw
            kpw="$(cat "$master_pw_file")"
            VAST_API_KEY="$(echo "$kpw" | keepassxc-cli show -a Password "$kdbx" "General/Vast API Key" 2>/dev/null | tr -d '\n\r ')" || true
            if [[ -n "${VAST_API_KEY:-}" ]]; then
                log_info "VAST_API_KEY loaded from KeePass"
                export VAST_API_KEY
                return 0
            fi
        fi
    fi

    return 0  # Not an error — may be set later
}

# =============================================================================
# PLACEHOLDER: validate_environment() — to be implemented
# =============================================================================
validate_environment() {
    log_step "1" "Validating environment"

    # ---- Check 1: vastai CLI installed ----
    if ! command -v vastai &>/dev/null; then
        log_warn "vastai CLI not found — installing..."
        pip install --user vastai || {
            log_error "Failed to install vastai CLI"
            return 2
        }
        export PATH="$HOME/.local/bin:$PATH"
        log_info "vastai CLI installed"
    fi

    # ---- Check 2: API key ----
    _linus_vast_discover_credentials
    if [[ -z "${VAST_API_KEY:-}" ]]; then
        log_error "VAST_API_KEY not set. Place in ~/.hermes/secrets/vast-api-key or KeePass 'General/Vast API Key'"
        return 3
    fi
    vastai set api-key "$VAST_API_KEY" 2>/dev/null || true

    # ---- Check 3: API connectivity (read-only probe) ----
    log_info "Checking Vast API connectivity..."
    if ! vastai show instances &>/dev/null; then
        log_error "Cannot reach Vast.ai API. Check VAST_API_KEY and network."
        return 4
    fi

    # ---- Check 4: SSH key registered AND valid (pitfall guard #1) ----
    log_info "Checking SSH keys..."
    local ssh_keys_output
    ssh_keys_output=$(vastai show ssh-keys 2>/dev/null) || true

    if [[ -z "$ssh_keys_output" ]]; then
        log_error "No SSH keys registered on Vast.ai. Register one with: vastai create ssh-key \"\$(cat ~/.ssh/id_ed25519.pub)\""
        return 3
    fi

    # Pitfall guard: keys stored as file paths instead of content
    local valid_key_found=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^(ssh-ed25519|ssh-rsa)[[:space:]] ]]; then
            valid_key_found=true
            break
        fi
    done <<< "$ssh_keys_output"

    if ! $valid_key_found; then
        log_error "SSH key stored as file PATH, not key content."
        log_error "Fix: vastai delete ssh-key <id> && vastai create ssh-key \"\$(cat ~/.ssh/key.pub)\""
        return 3
    fi
    log_info "SSH keys OK"

    # ---- Check 5: GPU name valid ----
    local detected_arch
    if detected_arch=$(validate_gpu_type "$VAST_GPU_NAME" 2>/dev/null); then
        log_info "GPU: $VAST_GPU_NAME (arch=$detected_arch)"
        if [[ "${VAST_CUDA_ARCH:-86}" != "$detected_arch" ]]; then
            log_warn "VAST_CUDA_ARCH ($VAST_CUDA_ARCH) differs from detected ($detected_arch). Using detected."
            VAST_CUDA_ARCH="$detected_arch"
        fi
    else
        log_error "Unknown GPU: $VAST_GPU_NAME"
        return 3
    fi

    # ---- Check 6: VRAM sizing (if model specified) ----
    if [[ -n "${VAST_MODEL_REPO:-}" && -n "${VAST_MODEL_QUANT:-}" ]]; then
        local model_params_b="${VAST_MODEL_PARAMS_B:-7}"
        local required_vram
        required_vram=$(vast_calc_required_vram "$model_params_b" "$VAST_MODEL_QUANT" "$VAST_CTX_SIZE") || true
        if [[ -n "$required_vram" ]]; then
            log_info "Model VRAM requirement: ${required_vram}GB (${VAST_MODEL_QUANT} @ ${VAST_CTX_SIZE} ctx)"
        fi
    fi

    log_success "Environment validation passed"
    return 0
}
