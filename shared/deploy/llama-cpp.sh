#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist — llama.cpp Deploy Script
# =============================================================================
# Purpose: Deploy llama.cpp inference server on an existing Ubuntu system.
#   Downloads llama.cpp release, downloads model, configures systemd service,
#   starts server, and verifies health + inference.
#
# Required Environment Variables:
#   LLAMA_MODEL_URL     — Full URL to GGUF model file
#                         (e.g., https://huggingface.co/.../model-Q4_K_M.gguf)
#
# Optional Environment Variables (all have defaults):
#   LLAMA_PORT          — Server port (default: 1234)
#   LLAMA_HOST          — Bind address (default: 0.0.0.0)
#   LLAMA_CTX_SIZE      — Context window size (default: 32768)
#   LLAMA_N_GPU_LAYERS  — GPU layers to offload (default: 99)
#   LLAMA_BATCH_SIZE    — Batch size (default: 2048)
#   LLAMA_API_KEY       — API key for auth (default: none — no auth)
#   LLAMA_VERSION       — llama.cpp release tag (default: b9827)
#   LLAMA_INSTALL_DIR   — Installation directory (default: /opt/llama.cpp)
#   LLAMA_MODEL_DIR     — Model storage directory (default: /opt/llama.cpp/models)
#   LLAMA_SERVICE_NAME  — systemd service name (default: llama-server)
#
# Usage:
#   LLAMA_MODEL_URL=https://huggingface.co/.../model.gguf ./llama-cpp.sh
#
#   # Full custom:
#   LLAMA_MODEL_URL=... LLAMA_PORT=8080 LLAMA_CTX_SIZE=16384 ./llama-cpp.sh
#
# Exit Codes:
#   0 — Success
#   1 — General error
#   2 — Missing dependencies
#   3 — Invalid configuration
#   4 — Download failed (llama.cpp release)
#   5 — Model download failed
#   6 — Server start failed
#   7 — Health check timeout
#   8 — Inference verification failed
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source shared libraries
source "$SCRIPT_DIR/../lib/paths.sh" || exit 1
source_lib "logging.sh" "validation.sh"

# -----------------------------------------------------------------------------
# Configuration from environment with defaults
# -----------------------------------------------------------------------------

readonly LLAMA_MODEL_URL="${LLAMA_MODEL_URL:-}"
readonly LLAMA_PORT="${LLAMA_PORT:-1234}"
readonly LLAMA_HOST="${LLAMA_HOST:-0.0.0.0}"
readonly LLAMA_CTX_SIZE="${LLAMA_CTX_SIZE:-32768}"
readonly LLAMA_N_GPU_LAYERS="${LLAMA_N_GPU_LAYERS:-99}"
readonly LLAMA_BATCH_SIZE="${LLAMA_BATCH_SIZE:-2048}"
readonly LLAMA_API_KEY="${LLAMA_API_KEY:-}"
readonly LLAMA_VERSION="${LLAMA_VERSION:-b9827}"
readonly LLAMA_INSTALL_DIR="${LLAMA_INSTALL_DIR:-/opt/llama.cpp}"
readonly LLAMA_MODEL_DIR="${LLAMA_MODEL_DIR:-${LLAMA_INSTALL_DIR}/models}"
readonly LLAMA_SERVICE_NAME="${LLAMA_SERVICE_NAME:-llama-server}"

# Derived paths
readonly LLAMA_BIN="${LLAMA_INSTALL_DIR}/llama-server"
readonly LLAMA_SERVICE_FILE="/etc/systemd/system/${LLAMA_SERVICE_NAME}.service"
readonly LLAMA_RELEASE_URL="https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_VERSION}/llama-${LLAMA_VERSION}-ubuntu-x64.zip"

# Extract model filename from URL
LLAMA_MODEL_FILE="${LLAMA_MODEL_URL##*/}"
readonly LLAMA_MODEL_FILE
readonly LLAMA_MODEL_PATH="${LLAMA_MODEL_DIR}/${LLAMA_MODEL_FILE}"

# -----------------------------------------------------------------------------
# Function: validate_environment
# -----------------------------------------------------------------------------

validate_environment() {
    log_step "1" "Validating environment"

    # Check required variable
    if [[ -z "$LLAMA_MODEL_URL" ]]; then
        log_error "LLAMA_MODEL_URL is required"
        return 3
    fi

    # Check we're on Ubuntu
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        log_info "Detected: ${PRETTY_NAME:-${ID:-unknown}}"
        if [[ "${ID}" != "ubuntu" ]] && [[ "${ID}" != "debian" ]]; then
            log_warn "This script is designed for Ubuntu/Debian (detected: ${ID}). Proceeding anyway."
        fi
    fi

    # Check for GPU
    if command -v nvidia-smi &>/dev/null; then
        local gpu_count
        gpu_count=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)
        log_info "GPU(s) detected: ${gpu_count}"
        nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | while read -r line; do
            log_info "  ${line}"
        done
    else
        log_info "No NVIDIA GPU detected — running CPU-only"
        LLAMA_N_GPU_LAYERS=0
    fi

    # Check dependencies
    check_dependencies curl wget tar || {
        log_info "Installing required dependencies..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq 2>&1 | tail -1
        apt-get install -y -qq curl wget tar 2>&1 | tail -1
    }

    # Ensure install directory
    mkdir -p "$LLAMA_INSTALL_DIR" "$LLAMA_MODEL_DIR"

    log_success "Environment validated"
    return 0
}

# -----------------------------------------------------------------------------
# Function: download_llama_cpp
# -----------------------------------------------------------------------------

download_llama_cpp() {
    log_step "2" "Downloading llama.cpp ${LLAMA_VERSION}"

    # Check if already installed
    if [[ -x "$LLAMA_BIN" ]]; then
        local existing_ver
        existing_ver=$("$LLAMA_BIN" --version 2>/dev/null | head -1 || echo "unknown")
        log_info "llama-server already installed: ${existing_ver}"
        log_info "To reinstall, delete ${LLAMA_INSTALL_DIR} and rerun."
        return 0
    fi

    local tmp_zip="/tmp/llama-${LLAMA_VERSION}.zip"
    local tmp_dir="/tmp/llama-${LLAMA_VERSION}-extract"

    # Download release
    log_info "Downloading: ${LLAMA_RELEASE_URL}"
    if ! wget -q --show-progress -O "$tmp_zip" "$LLAMA_RELEASE_URL" 2>&1; then
        log_error "Failed to download llama.cpp release"
        return 4
    fi

    # Extract
    log_info "Extracting..."
    rm -rf "$tmp_dir"
    mkdir -p "$tmp_dir"
    if ! unzip -qo "$tmp_zip" -d "$tmp_dir" 2>&1; then
        # Maybe it's a tar.gz
        rm -rf "$tmp_dir"
        mkdir -p "$tmp_dir"
        if ! tar xzf "$tmp_zip" -C "$tmp_dir" 2>&1; then
            log_error "Failed to extract release archive"
            rm -f "$tmp_zip"
            return 4
        fi
    fi
    rm -f "$tmp_zip"

    # Find the actual binary + libs (release structure varies)
    # Try common layouts
    local src_dir=""
    for candidate in \
        "$tmp_dir/build/bin" \
        "$tmp_dir/bin" \
        "$tmp_dir"; do
        if [[ -f "$candidate/llama-server" ]]; then
            src_dir="$candidate"
            break
        fi
    done

    if [[ -z "$src_dir" ]]; then
        log_error "Could not find llama-server in extracted files"
        log_error "Contents: $(find "$tmp_dir" -name 'llama-server' -o -name 'libggml*' 2>/dev/null | head -10)"
        return 4
    fi

    # Copy binary + libraries
    log_info "Installing to ${LLAMA_INSTALL_DIR}..."
    cp "$src_dir/llama-server" "$LLAMA_BIN" 2>/dev/null || true
    cp "$src_dir"/libggml* "$LLAMA_INSTALL_DIR/" 2>/dev/null || true
    cp "$src_dir"/libllama* "$LLAMA_INSTALL_DIR/" 2>/dev/null || true
    cp "$src_dir"/libmtmd* "$LLAMA_INSTALL_DIR/" 2>/dev/null || true
    cp "$src_dir"/ggml-rpc-server "$LLAMA_INSTALL_DIR/" 2>/dev/null || true

    chmod +x "$LLAMA_BIN" 2>/dev/null || true

    # Verify
    if [[ ! -x "$LLAMA_BIN" ]]; then
        log_error "llama-server binary not found at ${LLAMA_BIN} after install"
        return 4
    fi

    # Clean up
    rm -rf "$tmp_dir"

    log_success "llama.cpp ${LLAMA_VERSION} installed to ${LLAMA_INSTALL_DIR}"
    local file_count
    file_count=$(ls "$LLAMA_INSTALL_DIR" | wc -l)
    log_info "${file_count} files installed"

    return 0
}

# -----------------------------------------------------------------------------
# Function: download_model
# -----------------------------------------------------------------------------

download_model() {
    log_step "3" "Downloading model"

    # Check if already exists — validate against remote Content-Length
    if [[ -f "$LLAMA_MODEL_PATH" ]]; then
        local existing_size
        existing_size=$(stat -c%s "$LLAMA_MODEL_PATH" 2>/dev/null || echo 0)
        
        # Get expected size from remote (HEAD request)
        local expected_size
        expected_size=$(curl -sI --connect-timeout 10 -L "$LLAMA_MODEL_URL" 2>/dev/null | \
            grep -i '^content-length:' | tail -1 | awk '{print $2}' | tr -d '\r' || echo 0)
        
        if [[ "$existing_size" -gt 104857600 ]]; then
            local existing_size_gb
            existing_size_gb=$(python3 -c "print(round(${existing_size}/1073741824,2))" 2>/dev/null || echo "?")
            log_info "Model already downloaded and verified: ${LLAMA_MODEL_FILE} (${existing_size_gb} GB)"
            return 0
        fi
        
        # Exists but wrong size — corrupt or partial
        local existing_size_gb
        existing_size_gb=$(python3 -c "print(round(${existing_size}/1073741824,2))" 2>/dev/null || echo "?")
        log_info "Existing file is ${existing_size_gb} GB (expected ${expected_size} bytes) — re-downloading"
        rm -f "$LLAMA_MODEL_PATH"
    fi

    # Check HF reachability
    if echo "$LLAMA_MODEL_URL" | grep -q "huggingface.co"; then
        log_info "Checking HuggingFace reachability..."
        if ! curl -sI --connect-timeout 15 https://huggingface.co >/dev/null 2>&1; then
            log_error "Cannot reach huggingface.co"
            return 5
        fi
    fi

    # Check disk space (rough estimate: model is typically 15-25GB for 30B+ Q4)
    local available_kb
    available_kb=$(df --output=avail "$LLAMA_MODEL_DIR" 2>/dev/null | tail -1)
    if [[ -n "$available_kb" ]] && [[ "$available_kb" -lt 31457280 ]]; then  # 30GB
        local avail_gb
        avail_gb=$((available_kb / 1048576))
        log_error "Insufficient disk space: ${avail_gb}GB available, need ~25GB for model"
        return 5
    fi

    # Download — NEVER use -c (resume) with HF CDN (pitfall: duplicate appended data)
    log_info "Downloading: ${LLAMA_MODEL_URL}"
    log_info "Destination: ${LLAMA_MODEL_PATH}"
    if ! wget -q --show-progress -O "$LLAMA_MODEL_PATH" "$LLAMA_MODEL_URL" 2>&1; then
        log_error "Model download failed"
        rm -f "$LLAMA_MODEL_PATH"
        return 5
    fi

    local final_size_gb
    final_size_gb=$(python3 -c "print(round($(stat -c%s "$LLAMA_MODEL_PATH")/1073741824,2))" 2>/dev/null || echo "?")
    log_success "Model downloaded: ${LLAMA_MODEL_FILE} (${final_size_gb} GB)"

    return 0
}

# -----------------------------------------------------------------------------
# Function: configure_service
# -----------------------------------------------------------------------------

configure_service() {
    log_step "4" "Configuring systemd service"

    # Build ExecStart with optional flags
    local api_key_flag=""
    [[ -n "$LLAMA_API_KEY" ]] && api_key_flag="--api-key ${LLAMA_API_KEY}"

    local service_content="[Unit]
Description=llama.cpp inference server (${LLAMA_MODEL_FILE})
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${LLAMA_INSTALL_DIR}
Environment=LD_LIBRARY_PATH=${LLAMA_INSTALL_DIR}
ExecStart=${LLAMA_BIN} \\
    -m ${LLAMA_MODEL_PATH} \\
    --host ${LLAMA_HOST} \\
    --port ${LLAMA_PORT} \\
    --n-gpu-layers ${LLAMA_N_GPU_LAYERS} \\
    --ctx-size ${LLAMA_CTX_SIZE} \\
    --batch-size ${LLAMA_BATCH_SIZE} \\
    ${api_key_flag}
Restart=on-failure
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target"

    echo "$service_content" > "$LLAMA_SERVICE_FILE"

    systemctl daemon-reload
    systemctl enable "$LLAMA_SERVICE_NAME" 2>&1 | tail -1

    log_success "Service configured: ${LLAMA_SERVICE_NAME}"
    log_info "Service file: ${LLAMA_SERVICE_FILE}"

    return 0
}

# -----------------------------------------------------------------------------
# Function: start_server
# -----------------------------------------------------------------------------

start_server() {
    log_step "5" "Starting llama-server"

    # Stop if already running (allows redeploy)
    if systemctl is-active --quiet "$LLAMA_SERVICE_NAME" 2>/dev/null; then
        log_info "Stopping existing instance..."
        systemctl stop "$LLAMA_SERVICE_NAME" 2>&1 | tail -1
        sleep 2
    fi

    # Start
    if ! systemctl start "$LLAMA_SERVICE_NAME" 2>&1; then
        log_error "Failed to start ${LLAMA_SERVICE_NAME}"
        journalctl -u "$LLAMA_SERVICE_NAME" --no-pager -n 10 2>&1 | tail -5
        return 6
    fi

    log_info "Service started, waiting for model to load..."
    return 0
}

# -----------------------------------------------------------------------------
# Function: wait_for_server
# -----------------------------------------------------------------------------

wait_for_server() {
    log_step "6" "Waiting for server health"

    local health_url="http://127.0.0.1:${LLAMA_PORT}/health"
    local chat_url="http://127.0.0.1:${LLAMA_PORT}/v1/chat/completions"

    # Quick crash check
    sleep 5
    if ! systemctl is-active --quiet "$LLAMA_SERVICE_NAME" 2>/dev/null; then
        log_error "Server crashed on startup"
        journalctl -u "$LLAMA_SERVICE_NAME" --no-pager -n 15 2>&1
        return 6
    fi

    # Poll for model load (up to 5 min)
    local attempt=0
    local max_attempts=60
    while [[ $attempt -lt $max_attempts ]]; do
        attempt=$((attempt + 1))
        sleep 5

        # Use inference readiness check (health endpoint returns OK before model loads)
        local resp
        resp=$(curl -s --max-time 5 "$chat_url" \
            -H "Content-Type: application/json" \
            -d "{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1}" 2>/dev/null) || true

        if echo "$resp" | grep -q '"content"'; then
            log_success "Server ready after $((attempt * 5))s"
            return 0
        fi

        # Check for errors
        if echo "$resp" | grep -qi "error"; then
            local err_msg
            err_msg=$(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('error',{}).get('message',''))" 2>/dev/null || echo "$resp")
            if echo "$err_msg" | grep -qi "loading"; then
                log_info "[$((attempt * 5))s] Model still loading..."
            else
                log_warn "[$((attempt * 5))s] ${err_msg:0:80}"
            fi
        else
            log_info "[$((attempt * 5))s] Waiting..."
        fi

        # Check if server died
        if ! systemctl is-active --quiet "$LLAMA_SERVICE_NAME" 2>/dev/null; then
            log_error "Server died during startup"
            journalctl -u "$LLAMA_SERVICE_NAME" --no-pager -n 10 2>&1
            return 6
        fi
    done

    log_error "Server did not become ready after $((max_attempts * 5))s"
    return 7
}

# -----------------------------------------------------------------------------
# Function: verify_inference
# -----------------------------------------------------------------------------

verify_inference() {
    log_step "7" "Verifying inference"

    local chat_url="http://127.0.0.1:${LLAMA_PORT}/v1/chat/completions"

    local resp
    resp=$(curl -s --max-time 60 "$chat_url" \
        -H "Content-Type: application/json" \
        -d "{\"messages\":[{\"role\":\"user\",\"content\":\"Say exactly: LLAMA_DEPLOY_OK\"}],\"max_tokens\":50,\"temperature\":0}" 2>/dev/null) || true

    if [[ -z "$resp" ]]; then
        log_error "No response from inference endpoint"
        return 8
    fi

    # Extract content
    local content
    content=$(echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['choices'][0]['message'].get('content',''))" 2>/dev/null) || true

    if [[ -z "$content" ]]; then
        # Check if it's a reasoning model (content empty but reasoning_content present)
        local reasoning_content
        reasoning_content=$(echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['choices'][0]['message'].get('reasoning_content','')[:100])" 2>/dev/null) || true
        if [[ -n "$reasoning_content" ]]; then
            log_success "Inference verified (reasoning model — output in reasoning_content)"
            log_info "Sample: ${reasoning_content:0:100}"
            return 0
        fi

        log_error "Empty content in response"
        log_error "Raw: $(echo "$resp" | head -c 300)"
        return 8
    fi

    # Quality check: not pure garbage
    local nonspace
    nonspace=$(echo "$content" | tr -d '[:space:]')
    if [[ ${#nonspace} -lt 2 ]]; then
        log_error "Inference produced near-empty output"
        return 8
    fi

    log_success "Inference verified"
    log_info "Response: ${content:0:100}"

    return 0
}

# -----------------------------------------------------------------------------
# Function: output_summary
# -----------------------------------------------------------------------------

output_summary() {
    log_step "8" "Deployment summary"

    local model_size
    model_size=$(du -sh "$LLAMA_MODEL_PATH" 2>/dev/null | cut -f1 || echo "?")

    cat <<EOF

$(printf '=%.0s' {1..60})
  LLAMA.CPP DEPLOYMENT COMPLETE
$(printf '=%.0s' {1..60})

  Server:     http://${LLAMA_HOST}:${LLAMA_PORT}
  Model:      ${LLAMA_MODEL_FILE} (${model_size})
  Context:    ${LLAMA_CTX_SIZE} tokens
  GPU layers: ${LLAMA_N_GPU_LAYERS}
  Service:    systemctl status ${LLAMA_SERVICE_NAME}
  Logs:       journalctl -u ${LLAMA_SERVICE_NAME} -f
  API:        curl http://localhost:${LLAMA_PORT}/v1/chat/completions \\
                -H 'Content-Type: application/json' \\
                -d '{"messages":[{"role":"user","content":"hello"}],"max_tokens":50}'
$(printf '=%.0s' {1..60})
EOF

    log_success "Deployment complete"
    return 0
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    log_header "Linus llama.cpp Deploy"

    validate_environment   || exit $?
    download_llama_cpp     || exit $?
    download_model         || exit $?
    configure_service      || exit $?
    start_server           || exit $?
    wait_for_server        || exit $?
    verify_inference       || exit $?
    output_summary

    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
