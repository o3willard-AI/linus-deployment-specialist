#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist — Vast GPU Provision + Bootstrap Driver (P1.3)
# =============================================================================
# Purpose: Single entry point that runs provision + bootstrap end-to-end,
#   handling env var coupling, cost tracking, and snapshot caching.
#
# Usage:
#   export VAST_GPU_NAME=RTX_3090
#   export VAST_MODEL_REPO=unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF
#   export VAST_MODEL_FILE=Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf
#   vast-provision-and-bootstrap.sh
#
# Exit Codes:
#   0 — Full pipeline succeeded
#   1 — General error
#   2 — Missing dependencies
#   3 — Invalid configuration
#   4 — Provisioning failed
#   5 — Bootstrap failed
#   6 — Model quality failure
#
# Output:
#   LINUS_RESULT:SUCCESS API_URL:... CONTRACT_ID:... LINUS_COST:total_usd=...
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

export PYTHONUNBUFFERED=1

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source shared libraries
source "$SCRIPT_DIR/../lib/paths.sh" || exit 1
source_lib "logging.sh"

# ─── Configuration ────────────────────────────────────────────────

readonly PIPELINE_START_TIME=$(date +%s)

# Provisioning settings (with defaults)
readonly VAST_GPU_NAME="${VAST_GPU_NAME:-RTX_3090}"
readonly VAST_CUDA_ARCH="${VAST_CUDA_ARCH:-86}"
readonly VAST_MIN_RELIABILITY="${VAST_MIN_RELIABILITY:-0.99}"
readonly VAST_SORT_STRATEGY="${VAST_SORT_STRATEGY:-value}"
readonly VAST_CACHE_TYPE_K="${VAST_CACHE_TYPE_K:-q8_0}"
readonly VAST_CACHE_TYPE_V="${VAST_CACHE_TYPE_V:-q8_0}"
readonly VAST_CTX_SIZE="${VAST_CTX_SIZE:-32768}"
readonly VAST_MODEL_REPO="${VAST_MODEL_REPO:-}"
readonly VAST_MODEL_FILE="${VAST_MODEL_FILE:-}"
readonly VAST_MODEL_QUANT="${VAST_MODEL_QUANT:-Q4_K_M}"
readonly VAST_MODEL_FALLBACKS="${VAST_MODEL_FALLBACKS:-}"
readonly VAST_FLASH_ATTN="${VAST_FLASH_ATTN:-true}"

# Paths
readonly PROVISION_SCRIPT="$SCRIPT_DIR/vast.sh"
readonly BOOTSTRAP_SCRIPT="$SCRIPT_DIR/../bootstrap/vast-gpu.sh"

# ─── Validation ────────────────────────────────────────────────────

validate_driver_env() {
    if [[ ! -f "$PROVISION_SCRIPT" ]]; then
        log_error "Provision script not found: $PROVISION_SCRIPT"
        exit 2
    fi
    if [[ ! -f "$BOOTSTRAP_SCRIPT" ]]; then
        log_error "Bootstrap script not found: $BOOTSTRAP_SCRIPT"
        exit 2
    fi
    if [[ -z "$VAST_MODEL_REPO" ]]; then
        log_error "VAST_MODEL_REPO is required (e.g., unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF)"
        exit 3
    fi
    if [[ -z "$VAST_MODEL_FILE" ]]; then
        log_error "VAST_MODEL_FILE is required (e.g., Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf)"
        exit 3
    fi
    log_success "Driver environment validated"
}

# ─── Parse LINUS_RESULT ────────────────────────────────────────────

# Extracts key=value pairs from LINUS_RESULT:SUCCESS output.
# Sets: PARSED_CONTRACT_ID, PARSED_SSH_HOST, PARSED_SSH_PORT,
#       PARSED_PROXY_PORT, PARSED_INSTANCE_PRICE
parse_linus_result() {
    local output="$1"
    local key val

    while IFS=':' read -r key val; do
        # Strip "LINUS_" prefix from the key (e.g., LINUS_CONTRACT_ID → CONTRACT_ID)
        key="${key#LINUS_}"
        # Skip the "RESULT:SUCCESS" / "RESULT:FAILURE" header line
        [[ "$key" == "RESULT" ]] && continue
        case "$key" in
            CONTRACT_ID)     PARSED_CONTRACT_ID="$val" ;;
            SSH_HOST)        PARSED_SSH_HOST="$val" ;;
            SSH_PORT)        PARSED_SSH_PORT="$val" ;;
            PROXY_PORT)      PARSED_PROXY_PORT="$val" ;;
            INSTANCE_PRICE)  PARSED_INSTANCE_PRICE="$val" ;;
            GPU)             PARSED_GPU="$val" ;;
        esac
    done < <(echo "$output" | grep -E '^LINUS_' || true)
}

# ─── Phase 1: Provision ────────────────────────────────────────────

run_provision() {
    log_header "Phase 1: GPU Provisioning"

    log_info "Provisioning ${VAST_GPU_NAME} for ${VAST_MODEL_REPO}/${VAST_MODEL_FILE}..."

    local provision_output provision_ec=0

    # Run provision with all required env vars
    provision_output=$(VAST_GPU_NAME="$VAST_GPU_NAME" \
        VAST_CUDA_ARCH="$VAST_CUDA_ARCH" \
        VAST_MIN_RELIABILITY="$VAST_MIN_RELIABILITY" \
        VAST_SORT_STRATEGY="$VAST_SORT_STRATEGY" \
        VAST_MODEL_REPO="$VAST_MODEL_REPO" \
        VAST_MODEL_FILE="$VAST_MODEL_FILE" \
        VAST_MODEL_QUANT="$VAST_MODEL_QUANT" \
        VAST_CTX_SIZE="$VAST_CTX_SIZE" \
        VAST_CACHE_TYPE_K="$VAST_CACHE_TYPE_K" \
        VAST_CACHE_TYPE_V="$VAST_CACHE_TYPE_V" \
        stdbuf -oL -eL bash "$PROVISION_SCRIPT" 2>&1) || provision_ec=$?

    echo "$provision_output"

    if [[ $provision_ec -ne 0 ]]; then
        log_error "Provisioning failed with exit code $provision_ec"
        return 4
    fi

    # Parse LINUS_RESULT output
    parse_linus_result "$provision_output"

    if [[ -z "${PARSED_CONTRACT_ID:-}" ]]; then
        log_error "Failed to parse CONTRACT_ID from provision output"
        return 4
    fi

    log_success "Provisioned: contract ${PARSED_CONTRACT_ID} @ ${PARSED_SSH_HOST}:${PARSED_SSH_PORT}"
}

# ─── Phase 2: Bootstrap ────────────────────────────────────────────

run_bootstrap() {
    log_header "Phase 2: GPU Bootstrap"

    if [[ -z "${PARSED_CONTRACT_ID:-}" ]]; then
        log_error "No contract ID — provisioning must succeed first"
        return 5
    fi

    log_info "Bootstrapping model on ${PARSED_SSH_HOST}:${PARSED_SSH_PORT}..."

    local bootstrap_output bootstrap_ec=0

    # Pass instance price so bootstrap can compute total cost
    bootstrap_output=$(SSH_HOST="$PARSED_SSH_HOST" \
        SSH_PORT="$PARSED_SSH_PORT" \
        PROXY_PORT="$PARSED_PROXY_PORT" \
        CONTRACT_ID="$PARSED_CONTRACT_ID" \
        VAST_MODEL_REPO="$VAST_MODEL_REPO" \
        VAST_MODEL_FILE="$VAST_MODEL_FILE" \
        VAST_MODEL_QUANT="$VAST_MODEL_QUANT" \
        VAST_MODEL_FALLBACKS="$VAST_MODEL_FALLBACKS" \
        VAST_CTX_SIZE="$VAST_CTX_SIZE" \
        VAST_CACHE_TYPE_K="$VAST_CACHE_TYPE_K" \
        VAST_CACHE_TYPE_V="$VAST_CACHE_TYPE_V" \
        VAST_FLASH_ATTN="$VAST_FLASH_ATTN" \
        LINUS_INSTANCE_PRICE="${PARSED_INSTANCE_PRICE:-0}" \
        stdbuf -oL -eL bash "$BOOTSTRAP_SCRIPT" 2>&1) || bootstrap_ec=$?

    echo "$bootstrap_output"

    if [[ $bootstrap_ec -ne 0 ]]; then
        log_error "Bootstrap failed with exit code $bootstrap_ec"
        return 5
    fi

    log_success "Bootstrap complete"
}

# ─── Phase 3: Summary ──────────────────────────────────────────────

print_summary() {
    local end_time wall_time total_seconds
    end_time=$(date +%s)
    total_seconds=$(( end_time - PIPELINE_START_TIME ))
    wall_time=$(python3 -c "print(f'{${total_seconds}//3600}h {(${total_seconds}%3600)//60}m ${${total_seconds}%60}s')" 2>/dev/null || echo "${total_seconds}s")

    log_header "Pipeline Summary"
    log_info "  Wall time:     ${wall_time}"
    log_info "  GPU:           ${PARSED_GPU:-${VAST_GPU_NAME}}"
    log_info "  Contract:      ${PARSED_CONTRACT_ID:-N/A}"
    log_info "  SSH:           ${PARSED_SSH_HOST:-N/A}:${PARSED_SSH_PORT:-N/A}"
    log_info "  API:           http://${PARSED_SSH_HOST:-N/A}:${PARSED_PROXY_PORT:-N/A}/v1"
    log_info "  Model:         ${VAST_MODEL_FILE}"

    if [[ -n "${PARSED_INSTANCE_PRICE:-}" && "$PARSED_INSTANCE_PRICE" != "0" ]]; then
        local total_cost
        total_cost=$(python3 -c "print(round(${PARSED_INSTANCE_PRICE} * ${total_seconds} / 3600, 4))" 2>/dev/null) || total_cost="?"
        log_info "  Cost:          \$${total_cost} (@ \$${PARSED_INSTANCE_PRICE}/hr × ${wall_time})"
    fi
}

# ─── Main ──────────────────────────────────────────────────────────

main() {
    log_header "Linus Vast GPU — Provision + Bootstrap Pipeline"

    validate_driver_env

    # Phase 1: Provision
    if ! run_provision; then
        log_error "Pipeline failed at provisioning phase"
        exit 4
    fi

    # Phase 2: Bootstrap
    if ! run_bootstrap; then
        log_error "Pipeline failed at bootstrap phase"
        exit 5
    fi

    # Phase 3: Summary
    print_summary
    log_success "Pipeline completed successfully"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
