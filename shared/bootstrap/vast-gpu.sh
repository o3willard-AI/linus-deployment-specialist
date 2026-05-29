#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist — Vast GPU Bootstrap (Model + Server Start)
# =============================================================================
# Purpose: Post-provisioning bootstrap for Vast.ai GPU instances.
#   Downloads model, starts llama-server, verifies health + inference.
#
# Required Environment Variables:
#   SSH_HOST         — Vast SSH hostname (from vast.sh output)
#   SSH_PORT         — Vast SSH port (from vast.sh output)
#   PROXY_PORT       — Vast proxy port for inference API (SSH port + 1)
#   CONTRACT_ID      — Vast contract ID (for logging + cleanup)
#   VAST_MODEL_REPO  — HuggingFace repo (e.g., Qwen/Qwen2.5-Coder-7B-Instruct-GGUF)
#   VAST_MODEL_FILE  — GGUF filename (e.g., qwen2.5-coder-7b-instruct-q4_k_m.gguf)
#
# Optional:
#   VAST_CTX_SIZE    — Context window size (default: 32768)
#   VAST_API_KEY     — API key for llama-server (default: linus-inference)
#   VAST_SERVER_PORT — llama-server port (default: 8080)
#
# Usage:
#   # After vast.sh succeeds:
#   export SSH_HOST=ssh1.vast.ai
#   export SSH_PORT=12345
#   export PROXY_PORT=12346
#   export CONTRACT_ID=37210893
#   export VAST_MODEL_REPO=Qwen/Qwen2.5-Coder-7B-Instruct-GGUF
#   export VAST_MODEL_FILE=qwen2.5-coder-7b-instruct-q4_k_m.gguf
#   ./vast-gpu.sh
#
# Exit Codes:
#   0 — Success
#   1 — General error
#   2 — Missing dependencies
#   3 — Invalid configuration
#   4 — Build not found (provisioning incomplete)
#   5 — Model download failed
#   6 — Server start failed
#   7 — Health check timeout
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

readonly SSH_HOST="${SSH_HOST:-}"
readonly SSH_PORT="${SSH_PORT:-}"
readonly PROXY_PORT="${PROXY_PORT:-}"
readonly CONTRACT_ID="${CONTRACT_ID:-}"
readonly VAST_MODEL_REPO="${VAST_MODEL_REPO:-}"
readonly VAST_MODEL_FILE="${VAST_MODEL_FILE:-}"
readonly VAST_CTX_SIZE="${VAST_CTX_SIZE:-32768}"
readonly VAST_API_KEY="${VAST_API_KEY:-linus-inference}"
readonly VAST_SERVER_PORT="${VAST_SERVER_PORT:-8080}"
readonly VAST_CACHE_TYPE_K="${VAST_CACHE_TYPE_K:-q8_0}"
readonly VAST_CACHE_TYPE_V="${VAST_CACHE_TYPE_V:-q8_0}"
readonly VAST_FLASH_ATTN="${VAST_FLASH_ATTN:-true}"

readonly INSTANCE_WORKSPACE="/workspace"
readonly LLAMA_DIR="${INSTANCE_WORKSPACE}/llama.cpp"
readonly MODEL_DIR="${LLAMA_DIR}/models"
readonly LLAMA_SERVER_BIN="${LLAMA_DIR}/build/bin/llama-server"
readonly LLAMA_SERVER_LOG="/var/log/llama-server.log"
readonly MODEL_PATH="${MODEL_DIR}/${VAST_MODEL_FILE}"

# Derived URLs
readonly MODEL_URL="https://huggingface.co/${VAST_MODEL_REPO}/resolve/main/${VAST_MODEL_FILE}"
readonly HEALTH_URL="http://${SSH_HOST}:${PROXY_PORT}/health"
readonly MODELS_URL="http://${SSH_HOST}:${PROXY_PORT}/v1/models"
readonly CHAT_URL="http://${SSH_HOST}:${PROXY_PORT}/v1/chat/completions"

# -----------------------------------------------------------------------------
# SSH helper — auto-discovers key, builds args
# -----------------------------------------------------------------------------

_ssh_args() {
    local ssh_key=""
    for candidate in ~/.ssh/vast-ai-inference ~/.ssh/id_ed25519 ~/.ssh/id_rsa; do
        if [[ -f "$candidate" ]]; then
            ssh_key="$candidate"
            break
        fi
    done

    local args=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
    [[ -n "$ssh_key" ]] && args+=(-i "$ssh_key")

    printf '%q ' "${args[@]}"
}

# -----------------------------------------------------------------------------
# Function: validate_environment
# -----------------------------------------------------------------------------

validate_environment() {
    log_step "1" "Validating bootstrap environment"

    # Check required variables
    local missing=()
    [[ -z "$SSH_HOST" ]] && missing+=("SSH_HOST")
    [[ -z "$SSH_PORT" ]] && missing+=("SSH_PORT")
    [[ -z "$PROXY_PORT" ]] && missing+=("PROXY_PORT")
    [[ -z "$CONTRACT_ID" ]] && missing+=("CONTRACT_ID")
    [[ -z "$VAST_MODEL_REPO" ]] && missing+=("VAST_MODEL_REPO")
    [[ -z "$VAST_MODEL_FILE" ]] && missing+=("VAST_MODEL_FILE")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required variables: ${missing[*]}"
        return 3
    fi

    # Verify SSH connectivity (quick probe)
    log_info "Testing SSH to root@${SSH_HOST}:${SSH_PORT}..."
    local ssh_cmd
    ssh_cmd="ssh $(_ssh_args) -p ${SSH_PORT} root@${SSH_HOST} \"echo ok\""
    if ! eval "$ssh_cmd" >/dev/null 2>&1; then
        log_error "SSH to root@${SSH_HOST}:${SSH_PORT} failed"
        return 3
    fi
    log_info "SSH connectivity confirmed"

    # Validate cache types against allowed values
    if ! vast_validate_cache_type "$VAST_CACHE_TYPE_K" 2>/dev/null; then
        log_error "Invalid VAST_CACHE_TYPE_K: '${VAST_CACHE_TYPE_K}'. Valid: ${VALID_CACHE_TYPES}"
        return 3
    fi
    if ! vast_validate_cache_type "$VAST_CACHE_TYPE_V" 2>/dev/null; then
        log_error "Invalid VAST_CACHE_TYPE_V: '${VAST_CACHE_TYPE_V}'. Valid: ${VALID_CACHE_TYPES}"
        return 3
    fi
    log_info "KV cache: K=${VAST_CACHE_TYPE_K} V=${VAST_CACHE_TYPE_V} flash_attn=${VAST_FLASH_ATTN}"

    # Verify required tools locally
    check_dependencies curl ssh scp || return 2

    log_success "Environment validation passed"
    return 0
}

# -----------------------------------------------------------------------------
# Function: verify_build
# -----------------------------------------------------------------------------
# Checks that the onstart script successfully compiled llama.cpp.
# Must find the llama-server binary or we can't proceed.
# -----------------------------------------------------------------------------

verify_build() {
    log_step "2" "Verifying llama.cpp build"

    local ssh_cmd
    ssh_cmd="ssh $(_ssh_args) -p ${SSH_PORT} root@${SSH_HOST}"

    # Check for the binary
    local binary_check
    if eval "$ssh_cmd \"test -x ${LLAMA_SERVER_BIN} && echo FOUND\"" 2>/dev/null | grep -q "FOUND"; then
        log_success "llama-server binary found"
    else
        # Check if build was attempted
        local build_log
        build_log=$(eval "$ssh_cmd \"cat /var/log/onstart.log 2>/dev/null || echo NO_LOG\"" 2>/dev/null) || true

        if echo "$build_log" | grep -q "BUILD_DONE"; then
            log_error "BUILD_DONE marker found but binary missing at ${LLAMA_SERVER_BIN}"
        elif echo "$build_log" | grep -q "NO_LOG"; then
            log_error "No onstart log found — provisioning likely incomplete or build never started"
        else
            log_error "Build failed. onstart log:\n${build_log}"
        fi
        return 4
    fi

    # Ensure models directory exists
    eval "$ssh_cmd \"mkdir -p ${MODEL_DIR}\"" 2>/dev/null || true

    return 0
}

# -----------------------------------------------------------------------------
# Function: download_model
# -----------------------------------------------------------------------------
# Downloads GGUF via curl with pitfall guards:
#   - Range-request to verify file size BEFORE full download (pitfall #12)
#   - XetHub hash rename guard (pitfall #13)
#   - scp + nohup pattern for robustness (pitfall #9)
# -----------------------------------------------------------------------------

download_model() {
    log_step "3" "Downloading model"

    # --- Pre-flight: check if model already exists ---
    local ssh_cmd
    ssh_cmd="ssh $(_ssh_args) -p ${SSH_PORT} root@${SSH_HOST}"

    local existing_size
    existing_size=$(eval "$ssh_cmd \"stat -c%s ${MODEL_PATH} 2>/dev/null || echo 0\"" 2>/dev/null) || existing_size=0

    if [[ "$existing_size" -gt 1048576 ]]; then  # > 1MB = probably real
        local existing_size_gb
        existing_size_gb=$(bc <<< "scale=2; ${existing_size} / 1073741824" 2>/dev/null || echo "?")
        log_info "Model already downloaded (${existing_size_gb} GB). Skipping."
        return 0
    fi

    # --- Range-request size check (pitfall guard #12) ---
    log_info "Checking model file size via Range request..."
    local content_range
    content_range=$(curl -sI -H "Range: bytes=0-0" "$MODEL_URL" 2>/dev/null | grep -i "content-range" | tr -d '\r') || true

    local total_bytes=0
    if [[ -n "$content_range" ]]; then
        total_bytes=$(echo "$content_range" | grep -oP '/\K[0-9]+')
        local total_gb
        total_gb=$(bc <<< "scale=2; ${total_bytes} / 1073741824" 2>/dev/null || echo "?")
        log_info "Model size: ${total_gb} GB (${total_bytes} bytes)"
    else
        log_warn "Could not determine model size via Range request — proceeding anyway"
    fi

    # --- Check disk space ---
    local disk_free
    disk_free=$(eval "$ssh_cmd \"df -BG ${INSTANCE_WORKSPACE} 2>/dev/null | tail -1 | awk '{print \\$4}' | tr -d 'G'\"" 2>/dev/null) || disk_free=0
    if [[ "$disk_free" -gt 0 && "$total_bytes" -gt 0 ]]; then
        local needed_gb
        needed_gb=$(bc <<< "scale=0; (${total_bytes} * 1.2) / 1073741824" 2>/dev/null || echo "0")
        if [[ "$disk_free" -lt "$needed_gb" ]]; then
            log_error "Insufficient disk space: ${disk_free}GB free, need ~${needed_gb}GB"
            return 5
        fi
        log_info "Disk space OK: ${disk_free}GB free, need ~${needed_gb}GB"
    fi

    # --- Download with multi-strategy retry ---
    # retry_model_download handles: curl with resume, wget fallback,
    # size verification, 5 attempts with exponential backoff
    log_info "Starting model download (multi-strategy, up to 5 attempts)..."
    if ! retry_model_download "$SSH_HOST" "$SSH_PORT" "none" "$MODEL_URL" "$MODEL_PATH" 5; then
        log_error "Model download failed after 5 attempts"
        return 5
    fi

    log_success "Model downloaded"
    return 0
}
# -----------------------------------------------------------------------------

start_server() {
    log_step "4" "Starting llama-server"

    local ssh_cmd
    ssh_cmd="ssh $(_ssh_args) -p ${SSH_PORT} root@${SSH_HOST}"

    # Check if server is already running
    if eval "$ssh_cmd \"curl -s http://localhost:${VAST_SERVER_PORT}/health 2>/dev/null\"" 2>/dev/null | grep -q "ok"; then
        log_info "llama-server already running on port ${VAST_SERVER_PORT}"
        return 0
    fi

    log_info "Launching llama-server: model=${VAST_MODEL_FILE}, ctx=${VAST_CTX_SIZE}, port=${VAST_SERVER_PORT}, cache=K${VAST_CACHE_TYPE_K}/V${VAST_CACHE_TYPE_V}, flash=${VAST_FLASH_ATTN}"

    # Build optional flags
    local extra_flags=""
    [[ "$VAST_FLASH_ATTN" == "true" ]] && extra_flags="$extra_flags --flash-attn on"
    [[ "$VAST_CACHE_TYPE_K" != "f16" ]] && extra_flags="$extra_flags --cache-type-k ${VAST_CACHE_TYPE_K}"
    [[ "$VAST_CACHE_TYPE_V" != "f16" ]] && extra_flags="$extra_flags --cache-type-v ${VAST_CACHE_TYPE_V}"

    # Start via nohup (pitfall guard #9)
    local start_cmd="nohup ${LLAMA_SERVER_BIN} \
        -m ${MODEL_PATH} \
        --host 0.0.0.0 \
        --port ${VAST_SERVER_PORT} \
        --n-gpu-layers all \
        --ctx-size ${VAST_CTX_SIZE} \
        --api-key ${VAST_API_KEY} \
        ${extra_flags} \
        > ${LLAMA_SERVER_LOG} 2>&1 &"

    if ! eval "$ssh_cmd \"$start_cmd\"" 2>/dev/null; then
        log_error "Failed to start llama-server"
        return 6
    fi

    log_info "Server start command sent"
    return 0
}

# -----------------------------------------------------------------------------
# Function: wait_for_server
# -----------------------------------------------------------------------------

wait_for_server() {
    log_step "5" "Waiting for llama-server to become healthy"

    # Check server log for crash indicators before polling health
    local ssh_cmd
    ssh_cmd="ssh $(_ssh_args) -p ${SSH_PORT} root@${SSH_HOST}"
    sleep 5  # Give server a moment to start (or crash)

    local server_log
    server_log=$(eval "$ssh_cmd \"tail -10 ${LLAMA_SERVER_LOG} 2>/dev/null\"" 2>/dev/null) || true
    if echo "$server_log" | grep -qi "error\|failed\|segfault\|cannot\|OOM\|out of memory"; then
        log_error "Server crashed on startup. Log:\n${server_log}"
        return 6
    fi

    # Multi-attempt health check: 24 attempts × 5s = 2 min
    if retry_health_check "$HEALTH_URL" 24 5; then
        log_success "Server healthy at ${HEALTH_URL}"
        return 0
    fi

    # If still not healthy, check logs one final time
    server_log=$(eval "$ssh_cmd \"tail -20 ${LLAMA_SERVER_LOG} 2>/dev/null\"" 2>/dev/null) || true
    log_error "Server did not become healthy. Log:\n${server_log}"
    return 7
}

# -----------------------------------------------------------------------------
# Function: verify_inference
# -----------------------------------------------------------------------------
# Runs a test inference to confirm the model works.
# -----------------------------------------------------------------------------

verify_inference() {
    log_step "6" "Verifying inference"

    local prompt="Hello, this is a Linus deployment test. Please respond with OK."

    # Retry up to 3 times — model may still be loading (HTTP 503)
    # with 15s backoff between attempts
    local attempt=0
    while [[ $attempt -lt 3 ]]; do
        ((attempt++))

        if [[ $attempt -gt 1 ]]; then
            local wait_time=$((15 * attempt))
            log_warn "[inference] Attempt ${attempt}/3 — waiting ${wait_time}s for model to warm up..."
            sleep "$wait_time"
        fi

        local resp
        resp=$(curl -s --max-time 30 "$CHAT_URL" \
            -H "Authorization: Bearer ${VAST_API_KEY}" \
            -H "Content-Type: application/json" \
            -d "{
                \"model\": \"${VAST_MODEL_FILE}\",
                \"messages\": [{\"role\": \"user\", \"content\": \"${prompt}\"}],
                \"max_tokens\": 20
            }" 2>/dev/null) || true

        # Check if we got a valid completion
        if echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'])" >/dev/null 2>&1; then
            local content
            content=$(echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'][:100])" 2>/dev/null) || content="(parse error)"
            log_success "Inference verified (attempt ${attempt}). Response: ${content}"
            return 0
        fi

        # Check for transient errors (503 = model loading, 429 = rate limit)
        if echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('error',{}).get('code',''))" 2>/dev/null | grep -q "503\|429"; then
            log_warn "[inference] Model still loading or rate limited — retrying"
            continue
        fi

        log_warn "[inference] Attempt ${attempt} failed. Response: ${resp}"
    done

    log_error "Inference verification failed after 3 attempts"
    return 6
}

# -----------------------------------------------------------------------------
# Function: output_result
# -----------------------------------------------------------------------------

output_result() {
    log_step "7" "Generating output"

    linus_success \
        "API_URL:${CHAT_URL}" \
        "HEALTH_URL:${HEALTH_URL}" \
        "API_KEY:${VAST_API_KEY}" \
        "MODEL:${VAST_MODEL_FILE}" \
        "CTX_SIZE:${VAST_CTX_SIZE}" \
        "SSH_HOST:${SSH_HOST}" \
        "SSH_PORT:${SSH_PORT}" \
        "PROXY_PORT:${PROXY_PORT}" \
        "CONTRACT_ID:${CONTRACT_ID}"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    log_header "Linus Vast GPU Bootstrap"

    validate_environment || exit $?
    verify_build || exit $?
    download_model || exit $?
    start_server || exit $?
    wait_for_server || exit $?
    verify_inference || exit $?
    output_result

    log_success "GPU bootstrap completed successfully"
    return 0
}

# Only run main if script is executed (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
