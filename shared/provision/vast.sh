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
source_lib "logging.sh" "validation.sh" "retry.sh"
# vast-sizing.sh must be sourced directly — its declare -A arrays
# don't survive source_lib's subshell-based directory walk
source "$SCRIPT_DIR/../lib/vast-sizing.sh"

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
readonly VAST_CACHE_TYPE_K="${VAST_CACHE_TYPE_K:-q8_0}"
readonly VAST_CACHE_TYPE_V="${VAST_CACHE_TYPE_V:-q8_0}"
readonly VAST_FLASH_ATTN="${VAST_FLASH_ATTN:-true}"
readonly VAST_MIN_DISK="${VAST_MIN_DISK:-}"
readonly VAST_IMAGE="${VAST_IMAGE:-nvidia/cuda:12.4.0-devel-ubuntu22.04}"
readonly VAST_API_KEY_NAME="${VAST_API_KEY_NAME:-linus-inference}"

# Instance state (populated during provisioning)
ALLOCATED_OFFER_ID=""
ALLOCATED_CONTRACT_ID=""
ALLOCATED_SSH_HOST=""
ALLOCATED_SSH_PORT=""
ALLOCATED_PROXY_PORT=""
CALCULATED_DISK_GB=""

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
    local cred_files=("vast-api-key" "vast-ai-api-key" "vast-token" "vast")

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
    # Use temp script to avoid pipefail issues with inline Python
    cat > /tmp/linus-check-ssh.py << 'PYEOF'
import ast, sys
data = sys.stdin.read()
# Parse Vast CLI's Python list-of-dicts output
# Look for any key starting with ssh-ed25519 or ssh-rsa
# (not a file path like /home/user/.ssh/key.pub — pitfall #1)
found = False
try:
    keys = ast.literal_eval(data)
    for k in keys:
        pk = k.get('public_key','').strip()
        if pk.startswith('ssh-ed25519') or pk.startswith('ssh-rsa'):
            found = True
            break
except Exception:
    pass
# Exit 0 if at least one valid key found
sys.exit(0 if found else 1)
PYEOF
    if ! (vastai show ssh-keys 2>/dev/null || true) | python3 /tmp/linus-check-ssh.py; then
        log_error "No valid SSH key found. Register one with: vastai create ssh-key \"\$(cat ~/.ssh/id_ed25519.pub)\""
        return 3
    fi
    rm -f /tmp/linus-check-ssh.py
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
        required_vram=$(vast_calc_required_vram "$model_params_b" "$VAST_MODEL_QUANT" "$VAST_CTX_SIZE" "$VAST_CACHE_TYPE_K" "$VAST_CACHE_TYPE_V") || true
        if [[ -n "$required_vram" ]]; then
            log_info "Model VRAM requirement: ${required_vram}GB (${VAST_MODEL_QUANT} @ ${VAST_CTX_SIZE} ctx, KV=${VAST_CACHE_TYPE_K}/${VAST_CACHE_TYPE_V})"
        fi
    fi

    # ---- Check 7: Disk sizing ----
    # Priority: 1) explicit VAST_MIN_DISK, 2) calculate from model, 3) fallback 80GB
    if [[ -n "$VAST_MIN_DISK" ]]; then
        CALCULATED_DISK_GB="$VAST_MIN_DISK"
        log_info "Disk: ${CALCULATED_DISK_GB}GB (explicit VAST_MIN_DISK)"
    elif [[ -n "${VAST_MODEL_REPO:-}" && -n "${VAST_MODEL_QUANT:-}" ]]; then
        local model_params_b="${VAST_MODEL_PARAMS_B:-7}"
        local model_size_gb
        model_size_gb=$(vast_calc_model_size "$model_params_b" "$VAST_MODEL_QUANT") || true
        if [[ -n "$model_size_gb" ]]; then
            CALCULATED_DISK_GB=$(vast_calc_required_disk "$model_size_gb") || CALCULATED_DISK_GB=80
            log_info "Disk: ${CALCULATED_DISK_GB}GB (model=${model_size_gb}GB × 2.5)"
        else
            CALCULATED_DISK_GB=80
            log_info "Disk: ${CALCULATED_DISK_GB}GB (fallback, model size unknown)"
        fi
    else
        CALCULATED_DISK_GB=80
        log_info "Disk: ${CALCULATED_DISK_GB}GB (fallback, no model specified)"
    fi

    log_success "Environment validation passed"
    return 0
}

# -----------------------------------------------------------------------------
# Function: search_offers
# -----------------------------------------------------------------------------

search_offers() {
    log_step "2" "Searching Vast.ai offers"

    local gpu_filter="gpu_name=${VAST_GPU_NAME} num_gpus=${VAST_NUM_GPUS} verified=true rentable=true direct_port_count>=1"
    local reliability_filter="reliability>=${VAST_MIN_RELIABILITY}"
    local disk_filter="disk_space>=${CALCULATED_DISK_GB}"

    if [[ -n "${LINUS_EXCLUDED_HOSTS:-}" ]]; then
        log_info "Excluding hosts: ${LINUS_EXCLUDED_HOSTS}"
    fi
    log_info "Filters: ${gpu_filter} ${reliability_filter} ${disk_filter}"

    local sort_flag
    case "$VAST_SORT_STRATEGY" in
        cheapest) sort_flag="dph_total" ;;
        fastest)  sort_flag="dlperf-" ;;
        *)        sort_flag="dlperf_usd-" ;;
    esac

    local search_output
    search_output=$(vastai search offers "${gpu_filter} ${reliability_filter} ${disk_filter}" -o "$sort_flag" --limit 10 --raw 2>/dev/null) || {
        log_error "Offer search failed. Check VAST_API_KEY and network."
        return 4
    }

    if [[ -z "$search_output" || "$search_output" == "[]" ]]; then
        log_error "No offers match: GPU=${VAST_GPU_NAME} reliability>=${VAST_MIN_RELIABILITY} disk>=${CALCULATED_DISK_GB}"
        return 5
    fi

    # Filter out previously failed hosts
    if [[ -n "${LINUS_EXCLUDED_HOSTS:-}" ]]; then
        local filtered_json
        filtered_json=$(echo "$search_output" | python3 -c "
import json, sys
excluded = set('${LINUS_EXCLUDED_HOSTS}'.split())
offers = json.load(sys.stdin)
filtered = [o for o in offers if str(o.get('host_id','')) not in excluded]
json.dump(filtered, sys.stdout)
" 2>/dev/null) || true

        if [[ -z "$filtered_json" || "$filtered_json" == "[]" ]]; then
            log_error "All offers excluded by host blocklist (${LINUS_EXCLUDED_HOSTS})"
            return 5
        fi
        search_output="$filtered_json"
        log_info "After host exclusion: $(echo "$filtered_json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null) offers remain"
    fi

    local offer_id
    offer_id=$(echo "$search_output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['id'])" 2>/dev/null) || true

    if [[ -z "$offer_id" ]]; then
        log_error "Failed to parse offer ID from search results"
        return 5
    fi

    ALLOCATED_OFFER_ID="$offer_id"
    log_success "Selected offer: $offer_id"
    return 0
}

# -----------------------------------------------------------------------------
# Function: create_instance
# -----------------------------------------------------------------------------

create_instance() {
    log_step "3" "Creating Vast instance"

    local offer_id="$ALLOCATED_OFFER_ID"
    # Vast --onstart-cmd runs a single shell command during provisioning.
    # Use a proven inline build recipe. The onstart-vast.sh template is
    # the reference doc — keep in sync if changing this command.
    local onstart_cmd
    onstart_cmd="apt-get update -qq && apt-get install -y -qq cmake && mkdir -p /workspace && cd /workspace && git clone --depth 1 https://github.com/ggml-org/llama.cpp && cd llama.cpp && cmake -B build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=${VAST_CUDA_ARCH} && cmake --build build --config Release -j\$(nproc) && echo BUILD_DONE"

    log_info "Creating instance from offer ${offer_id}..."
    local disk_gb="${CALCULATED_DISK_GB:-80}"

    local create_output
    create_output=$(vastai create instance "$offer_id" \
        --image "$VAST_IMAGE" \
        --disk "$disk_gb" \
        --onstart-cmd "$onstart_cmd" \
        --ssh --direct 2>&1) || {
        log_error "Instance creation failed: $create_output"
        return 5
    }

    local contract_id
    contract_id=$(echo "$create_output" | grep -oP 'contract.*?(\d+)' | grep -oP '\d+' | head -1) || true
    if [[ -z "$contract_id" ]]; then
        contract_id=$(echo "$create_output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('contract_id',''))" 2>/dev/null) || true
    fi

    if [[ -z "$contract_id" ]]; then
        log_error "Failed to parse contract ID from: $create_output"
        return 5
    fi

    ALLOCATED_CONTRACT_ID="$contract_id"
    log_success "Instance created: contract $contract_id"
    return 0
}

# -----------------------------------------------------------------------------
# Function: wait_for_running
# -----------------------------------------------------------------------------

wait_for_running() {
    log_step "4" "Waiting for instance to reach 'running' state"

    local contract_id="$ALLOCATED_CONTRACT_ID"
    local max_wait=900  # 15 min — llama.cpp build + SSH startup can take 8-10 min
    local elapsed=0

    while [[ $elapsed -lt $max_wait ]]; do
        local status
        # vastai show instance outputs table format, not JSON.
        # First table section: row# ID Machine Status Num Model ...
        # Status is column 4. Match row by contract ID to be precise.
        status=$(vastai show instance "$contract_id" 2>/dev/null | \
            awk -v cid="$contract_id" '$2 == cid {print $4}' 2>/dev/null) || status="unknown"
        # Handle empty/whitespace status during loading (awk prints nothing but exits 0)
        [[ -z "${status// }" ]] && status="loading"

        case "$status" in
            running)
                log_success "Instance running (${elapsed}s)"
                return 0
                ;;
            created)
                if [[ $elapsed -gt 120 ]]; then
                    local logs
                    logs=$(vastai logs "$contract_id" 2>/dev/null) || true
                    if [[ -z "$logs" ]]; then
                        log_error "Instance stuck at 'created' with no logs — likely CDI/GPU passthrough failure"
                        return 5
                    fi
                fi
                ;;
        esac

        sleep 10
        elapsed=$((elapsed + 10))
        if [[ $((elapsed % 60)) -eq 0 ]]; then
            log_info "Waiting... (${elapsed}s/${max_wait}s, status=$status)"
        fi
    done

    log_error "Instance did not reach 'running' within ${max_wait}s"
    return 6
}

# -----------------------------------------------------------------------------
# Function: wait_for_ssh
# -----------------------------------------------------------------------------

wait_for_ssh() {
    log_step "5" "Waiting for SSH access"

    local contract_id="$ALLOCATED_CONTRACT_ID"

    # Fetch SSH details from Vast API
    local instance_json
    instance_json=$(vastai show instance "$contract_id" 2>/dev/null) || true

    local ssh_host ssh_port
    ssh_host=$(echo "$instance_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('ssh_host',''))" 2>/dev/null) || true
    ssh_port=$(echo "$instance_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('ssh_port',''))" 2>/dev/null) || true

    if [[ -z "$ssh_host" || -z "$ssh_port" ]]; then
        log_error "Failed to parse SSH details"
        return 6
    fi

    ALLOCATED_SSH_HOST="$ssh_host"
    ALLOCATED_SSH_PORT="$ssh_port"
    ALLOCATED_PROXY_PORT="$((ssh_port + 1))"

    log_info "SSH: ${ssh_host}:${ssh_port} (proxy: ${ALLOCATED_PROXY_PORT})"

    # Auto-discover SSH key
    local ssh_key="none"
    for candidate in ~/.ssh/vast-ai-inference ~/.ssh/id_ed25519 ~/.ssh/id_rsa; do
        if [[ -f "$candidate" ]]; then
            ssh_key="$candidate"
            break
        fi
    done

    # Multi-strategy SSH retry: 4 strategies × 3 attempts with backoff
    if retry_ssh_with_backoff 3 "$ssh_host" "$ssh_port" "$ssh_key" "echo ok"; then
        log_success "SSH ready at ${ssh_host}:${ssh_port}}"
        return 0
    fi

    log_error "SSH not accessible after multi-strategy retry"
    return 6
}

# -----------------------------------------------------------------------------
# Function: output_result
# -----------------------------------------------------------------------------

output_result() {
    log_step "6" "Generating output"

    linus_success \
        "CONTRACT_ID:${ALLOCATED_CONTRACT_ID}" \
        "SSH_HOST:${ALLOCATED_SSH_HOST}" \
        "SSH_PORT:${ALLOCATED_SSH_PORT}" \
        "PROXY_PORT:${ALLOCATED_PROXY_PORT}" \
        "GPU:${VAST_GPU_NAME}" \
        "CUDA_ARCH:${VAST_CUDA_ARCH}" \
        "IMAGE:${VAST_IMAGE}"
}

# -----------------------------------------------------------------------------
# Function: cleanup_on_error
# -----------------------------------------------------------------------------

cleanup_on_error() {
    local exit_code=$?
    if [[ $exit_code -ne 0 && -n "${ALLOCATED_CONTRACT_ID:-}" ]]; then
        log_warn "Cleaning up instance ${ALLOCATED_CONTRACT_ID} due to error..."
        vastai destroy instance "$ALLOCATED_CONTRACT_ID" --yes 2>/dev/null || true
    fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    log_header "Linus Vast GPU Provisioning"

    validate_environment || exit $?

    local max_hosts=3
    local host_attempt=0
    LINUS_EXCLUDED_HOSTS="${LINUS_EXCLUDED_HOSTS:-}"

    while [[ $host_attempt -lt $max_hosts ]]; do
        host_attempt=$((host_attempt + 1))

        if [[ $host_attempt -gt 1 ]]; then
            log_warn "=== Host attempt ${host_attempt}/${max_hosts} — previous host failed, trying different host ==="
        fi

        # Search for offers (excluding previously failed hosts)
        retry_with_backoff "offer_search" 3 10 search_offers || {
            log_error "No viable offers (attempt ${host_attempt}/${max_hosts})"
            continue
        }

        # Create the instance
        create_instance || {
            log_error "Instance creation failed (attempt ${host_attempt})"
            exit $?
        }

        # Set trap AFTER instance exists (so destroy-on-error works)
        trap cleanup_on_error EXIT

        # Wait for instance to be running
        if wait_for_running; then
            # Success! Break out of host loop
            log_success "Instance running on attempt ${host_attempt}"
            break
        fi

        local run_exit=$?

        # Extract host info before destroying
        local bad_host=""
        bad_host=$(vastai show instance "$ALLOCATED_CONTRACT_ID" 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('host_id',''))
" 2>/dev/null) || true

        # Classify the failure
        case $run_exit in
            5)  # CDI passthrough failure — host is bad
                log_warn "CDI/GPU passthrough failure on host ${bad_host} — excluding from future searches"
                ;;
            6)  # Timeout — might be host or might be transient
                log_warn "Instance timed out on host ${bad_host} — excluding for safety"
                ;;
            *)  # Unknown failure
                log_warn "Instance failed with exit ${run_exit} on host ${bad_host}"
                ;;
        esac

        # Add to exclusion list
        if [[ -n "$bad_host" ]]; then
            LINUS_EXCLUDED_HOSTS="$LINUS_EXCLUDED_HOSTS $bad_host"
        fi

        # Destroy the bad instance and clear state
        log_warn "Destroying bad instance ${ALLOCATED_CONTRACT_ID}..."
        vastai destroy instance "$ALLOCATED_CONTRACT_ID" --yes 2>/dev/null || true
        ALLOCATED_CONTRACT_ID=""
        ALLOCATED_OFFER_ID=""

        # Clear trap before next loop iteration
        trap - EXIT
    done

    # Did we get a working instance?
    if [[ -z "${ALLOCATED_CONTRACT_ID:-}" ]]; then
        log_error "Failed to provision a working instance after ${max_hosts} host attempts"
        log_error "Excluded hosts: ${LINUS_EXCLUDED_HOSTS}"
        exit 5
    fi

    # Instance is running — proceed with SSH and output
    wait_for_ssh || exit $?
    output_result

    trap - EXIT
    log_success "GPU instance provisioning completed successfully"
    return 0
}

# Only run main if script is executed (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
