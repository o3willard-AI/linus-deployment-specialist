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
#   8 — Model quality failure (garbage output)
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# Ensure Python subprocess output is unbuffered for background visibility
export PYTHONUNBUFFERED=1

# -----------------------------------------------------------------------------
# ERR trap — auto-destroy instance on failure (unless LINUS_KEEP_INSTANCE=true)
# -----------------------------------------------------------------------------
_cleanup_on_failure() {
    local ec=$?
    if [[ $ec -ne 0 ]] && [[ -n "${CONTRACT_ID:-}" ]] && [[ "${LINUS_KEEP_INSTANCE:-}" != "true" ]]; then
        log_warn "Bootstrap failed (exit ${ec}). Auto-destroying instance ${CONTRACT_ID}..."
        echo "y" | /home/sblanken/.local/bin/vastai destroy instance "$CONTRACT_ID" 2>/dev/null || true
        log_info "Instance ${CONTRACT_ID} destroyed"
    fi
    exit $ec
}
trap _cleanup_on_failure EXIT

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

# Model fallback chain — comma-separated "repo:file:quant" entries.
# If the primary model produces garbage output (exit 8), the script
# tries each fallback in order before giving up.
# Example: VAST_MODEL_FALLBACKS="unsloth/OtherModel-GGUF:model-f16.gguf:Q4_K_M,bartowski/Backup-GGUF:backup-q4.gguf:Q4_K_M"
readonly VAST_MODEL_FALLBACKS="${VAST_MODEL_FALLBACKS:-}"

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

_ssh_key() {
    for candidate in ~/.ssh/vast-ai-inference ~/.ssh/id_ed25519 ~/.ssh/id_rsa; do
        if [[ -f "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    echo "none"
}

_ssh_args() {
    local ssh_key
    ssh_key=$(_ssh_key)
    [[ "$ssh_key" == "none" ]] && ssh_key=""

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
        # Build may still be in progress (Vast onstart can take 5-10 min)
        # Wait for it rather than failing immediately
        log_info "llama-server not found yet — build may still be in progress. Waiting..."

        local waited=0
        local max_build_wait=600  # 10 minutes
        local poll_interval=15

        while [[ $waited -lt $max_build_wait ]]; do
            sleep "$poll_interval"
            waited=$((waited + poll_interval))

            if eval "$ssh_cmd \"test -x ${LLAMA_SERVER_BIN} && echo FOUND\"" 2>/dev/null | grep -q "FOUND"; then
                log_success "llama-server binary found (waited ${waited}s)"
                break
            fi

            # Check if build is still running
            local build_active
            build_active=$(eval "$ssh_cmd \"pgrep -f 'cmake|make|cc1plus|nvcc' >/dev/null 2>&1 && echo BUILDING || echo IDLE\"" 2>/dev/null) || true

            log_info "Waiting... (${waited}s/${max_build_wait}s, build=${build_active:-UNKNOWN})"
        done

        # Re-check after wait loop
        if ! eval "$ssh_cmd \"test -x ${LLAMA_SERVER_BIN} && echo FOUND\"" 2>/dev/null | grep -q "FOUND"; then
            # Check build log for diagnostics
            local build_log
            build_log=$(eval "$ssh_cmd \"cat /var/log/onstart.log 2>/dev/null || echo NO_LOG\"" 2>/dev/null) || true

            if echo "$build_log" | grep -q "BUILD_DONE"; then
                log_error "BUILD_DONE marker found but binary missing at ${LLAMA_SERVER_BIN}"
            elif echo "$build_log" | grep -q "NO_LOG"; then
                log_error "No onstart log found — provisioning likely incomplete or build never started"
            else
                log_error "Build timed out after ${max_build_wait}s. Last log:\n$(echo "$build_log" | tail -20)"
            fi
            return 4
        fi
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

    # --- HF reachability pre-flight ---
    # Some Vast hosts have restricted networks that can't reach huggingface.co.
    # Test before attempting an 18GB download that's doomed to fail.
    log_info "Checking HuggingFace reachability from instance..."
    if ! eval "$ssh_cmd \"curl -sI --connect-timeout 15 https://huggingface.co >/dev/null 2>&1\"" 2>/dev/null; then
        log_error "Instance cannot reach huggingface.co — host network may be restricted"
        return 5
    fi
    log_info "HuggingFace reachable"

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

    # --- Check disk space (only if we got a real size) ---
    if [[ "$total_bytes" -gt 0 ]]; then
        local disk_free
        # Use single quotes for awk to prevent bash $4 expansion under set -u
        disk_free=$(eval "$ssh_cmd \"df -BG ${INSTANCE_WORKSPACE} 2>/dev/null | tail -1 | awk '{print \$4}' | tr -d 'G'\"" 2>/dev/null) || disk_free=0
        if [[ "$disk_free" -gt 0 ]]; then
            local needed_gb
            needed_gb=$(bc <<< "scale=0; (${total_bytes} * 1.2) / 1073741824" 2>/dev/null || echo "0")
            if [[ "$disk_free" -lt "$needed_gb" ]]; then
                log_error "Insufficient disk space: ${disk_free}GB free, need ~${needed_gb}GB"
                return 5
            fi
            log_info "Disk space OK: ${disk_free}GB free, need ~${needed_gb}GB"
        fi
    else
        log_warn "Could not determine model size — skipping disk space check"
    fi

    # --- Download with multi-strategy retry ---
    # retry_model_download handles: curl with resume, wget fallback,
    # size verification, 5 attempts with exponential backoff
    local ssh_key
    ssh_key=$(_ssh_key)
    log_info "Starting model download (multi-strategy, up to 5 attempts)..."
    if ! retry_model_download "$SSH_HOST" "$SSH_PORT" "$ssh_key" "$MODEL_URL" "$MODEL_PATH" 5; then
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
# Runs a test inference to confirm the model works AND produces sane output.
# Quality gates: slash ratio <50%, output not empty, no char >80% repeated.
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
                \"max_tokens\": 30
            }" 2>/dev/null) || true

        # Check if we got a valid completion
        local content
        content=$(echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'])" 2>/dev/null) || true

        if [[ -z "$content" ]]; then
            # Check for transient errors (503 = model loading, 429 = rate limit)
            if echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('error',{}).get('code',''))" 2>/dev/null | grep -q "503\|429"; then
                log_warn "[inference] Model still loading or rate limited — retrying"
                continue
            fi
            log_warn "[inference] Attempt ${attempt}: no content. Raw response: ${resp:0:200}"
            continue
        fi

        # ─── Quality Gates ──────────────────────────────────────────
        local total_chars=${#content}

        # Gate 1: Slash character ratio (catch Qwen3.6-style / garbage)
        local slash_count
        slash_count=$(echo "$content" | tr -cd '/' | wc -c)
        local slash_ratio=$(( slash_count * 100 / total_chars ))
        if [[ $slash_ratio -gt 50 ]]; then
            log_error "[quality] Model producing garbage: ${slash_ratio}% slash characters (threshold: 50%)"
            log_error "[quality] Content sample: ${content:0:200}"
            return 8
        fi

        # Gate 2: Single-character dominance (catch repeated-char nonsense)
        local max_char_pct
        max_char_pct=$(echo "$content" | fold -w1 | sort | uniq -c | sort -rn | head -1 | awk '{print $1}')
        max_char_pct=$(( max_char_pct * 100 / total_chars ))
        if [[ $max_char_pct -gt 80 ]]; then
            log_error "[quality] Single character dominates ${max_char_pct}% of output (threshold: 80%)"
            log_error "[quality] Content sample: ${content:0:200}"
            return 8
        fi

        # Gate 3: Empty or whitespace-only output
        if [[ -z "${content//[[:space:]]/}" ]]; then
            log_error "[quality] Model produced whitespace-only output"
            return 8
        fi
        # ─── End Quality Gates ──────────────────────────────────────

        log_success "Inference verified (attempt ${attempt}). Response: ${content:0:100}"
        return 0
    done

    log_error "Inference verification failed after 3 attempts"
    return 6
}

# -----------------------------------------------------------------------------
# Function: _try_model
# -----------------------------------------------------------------------------
# Internal: downloads, serves, and verifies a single model.
# Args: repo file quant — all optional (defaults to VAST_MODEL_* vars)
# Returns: 0 on success, non-zero on failure
# -----------------------------------------------------------------------------

_try_model() {
    local repo="${1:-$VAST_MODEL_REPO}"
    local file="${2:-$VAST_MODEL_FILE}"
    local quant="${3:-${VAST_MODEL_QUANT:-}}"
    local label="${4:-$file}"

    # Override derived paths for this attempt
    local try_model_url="https://huggingface.co/${repo}/resolve/main/${file}"
    local try_model_path="${MODEL_DIR}/${file}"
    local try_chat_url="http://${SSH_HOST}:${PROXY_PORT}/v1/chat/completions"

    log_info "Trying model: ${label}"

    # Download with alternate model
    local ssh_key
    ssh_key=$(_ssh_key)
    if ! retry_model_download "$SSH_HOST" "$SSH_PORT" "$ssh_key" "$try_model_url" "$try_model_path" 5; then
        log_error "Failed to download ${label}"
        return 5
    fi

    # Start server with this model
    local ssh_cmd
    ssh_cmd="ssh $(_ssh_args) -p ${SSH_PORT} root@${SSH_HOST}"

    # Kill any existing server
    eval "$ssh_cmd \"pkill -f llama-server 2>/dev/null\"" 2>/dev/null || true
    sleep 2

    log_info "Starting server with ${label}..."
    local start_cmd="nohup ${LLAMA_SERVER_BIN} \
        -m ${try_model_path} \
        --host 0.0.0.0 \
        --port ${VAST_SERVER_PORT} \
        --n-gpu-layers all \
        --ctx-size ${VAST_CTX_SIZE} \
        --api-key ${VAST_API_KEY} \
        > ${LLAMA_SERVER_LOG} 2>&1 &"
    eval "$ssh_cmd \"$start_cmd\"" 2>/dev/null || { log_error "Failed to start server with ${label}"; return 6; }

    # Wait for health
    if ! retry_health_check "$HEALTH_URL" 24 5; then
        log_error "Server not healthy with ${label}"
        return 7
    fi
    log_success "Server healthy with ${label}"

    # Run quality-gated inference
    # Use the try-specific URL
    local prompt="Hello, this is a Linus deployment test. Please respond with OK."
    local resp
    resp=$(curl -s --max-time 30 "$try_chat_url" \
        -H "Authorization: Bearer ${VAST_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"${file}\",
            \"messages\": [{\"role\": \"user\", \"content\": \"${prompt}\"}],
            \"max_tokens\": 30
        }" 2>/dev/null) || true

    local content
    content=$(echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'])" 2>/dev/null) || true

    if [[ -z "$content" ]]; then
        log_error "No output from ${label}"
        return 8
    fi

    # Quality gates (same as verify_inference)
    local total_chars=${#content}
    local slash_count
    slash_count=$(echo "$content" | tr -cd '/' | wc -c)
    local slash_ratio=$(( slash_count * 100 / total_chars ))
    if [[ $slash_ratio -gt 50 ]]; then
        log_error "[quality] ${label} producing garbage: ${slash_ratio}% slashes"
        return 8
    fi

    local max_char_pct
    max_char_pct=$(echo "$content" | fold -w1 | sort | uniq -c | sort -rn | head -1 | awk '{print $1}')
    max_char_pct=$(( max_char_pct * 100 / total_chars ))
    if [[ $max_char_pct -gt 80 ]]; then
        log_error "[quality] ${label}: single char dominates ${max_char_pct}%"
        return 8
    fi

    log_success "Model ${label} verified: ${content:0:100}"
    return 0
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

    # Try primary model
    download_model || exit $?
    start_server || exit $?
    wait_for_server || exit $?
    verify_inference
    local verify_ec=$?

    # If primary model passes quality, we're done
    if [[ $verify_ec -eq 0 ]]; then
        output_result
        log_success "GPU bootstrap completed successfully"
        return 0
    fi

    # Quality failure (exit 8) — try fallbacks
    if [[ $verify_ec -eq 8 ]] && [[ -n "$VAST_MODEL_FALLBACKS" ]]; then
        log_warn "Primary model failed quality check. Trying fallbacks..."
        IFS=',' read -ra FALLBACKS <<< "$VAST_MODEL_FALLBACKS"
        for fb in "${FALLBACKS[@]}"; do
            IFS=':' read -r fb_repo fb_file fb_quant <<< "$fb"
            log_info "Fallback: ${fb_repo}/${fb_file}"
            if _try_model "$fb_repo" "$fb_file" "${fb_quant:-}" "${fb_file}"; then
                output_result
                log_success "GPU bootstrap completed with fallback model"
                return 0
            fi
            log_warn "Fallback ${fb_file} failed — trying next..."
        done
        log_error "All models exhausted (primary + ${#FALLBACKS[@]} fallbacks)"
        exit 8
    fi

    # Non-quality failure — propagate
    exit $verify_ec
}

# Only run main if script is executed (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
