#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist — Jetson Orin Nano Inference Setup
# =============================================================================
# Purpose: Set up llama.cpp inference on NVIDIA Jetson Orin Nano (aarch64).
#   Builds both standard llama.cpp AND PrismML fork (for ternary/1-bit models).
#   Downloads models, runs benchmarks, and optionally starts a server.
#
# Required Environment Variables:
#   JETSON_HOST         — SSH target (e.g., 192.168.101.10)
#   JETSON_USER         — SSH username (default: sblanken)
#   JETSON_PASSWORD     — SSH/sudo password
#
# Optional Environment Variables:
#   JETSON_MODELS       — Comma-separated model URLs to download (default: none)
#   JETSON_PORT         — Server port (default: 1234)
#   JETSON_CTX_SIZE     — Context window (default: 4096)
#   JETSON_N_GPU_LAYERS — GPU layers to offload (default: 99)
#   JETSON_INSTALL_DIR  — Install directory (default: ~/)
#   JETSON_MODEL_DIR    — Model directory (default: ~/models)
#   JETSON_SKIP_PRISM   — Skip PrismML fork build (default: false)
#   JETSON_SKIP_SERVE   — Skip server start (default: true — just build+benchmark)
#   JETSON_BENCH_MODEL  — Model path to benchmark (default: first downloaded)
#
# Model URLs (copy-paste ready):
#   Ternary-Bonsai-27B:
#     https://huggingface.co/prism-ml/Ternary-Bonsai-27B-gguf/resolve/main/Ternary-Bonsai-27B-dspark-Q4_1.gguf
#   Qwen3.5-4B-Super-Coder:
#     https://huggingface.co/jica98/qwen3.5-4B-super-coder/resolve/main/qwen3.5-4B-super-coder.Q4_0.gguf
#   Gemma-3-1B F16:
#     https://huggingface.co/Andycurrent/Gemma-3-1B-it-GLM-4.7-Flash-Heretic-Uncensored-Thinking_GGUF/resolve/main/Gemma-3-1B-it-GLM-4.7-Flash-Heretic-Uncensored-Thinking_F16.gguf
#
# Usage:
#   JETSON_HOST=192.168.101.10 JETSON_PASSWORD=xxx ./jetson-orin-setup.sh
#
#   # With models:
#   JETSON_HOST=192.168.101.10 JETSON_PASSWORD=xxx \
#     JETSON_MODELS="https://huggingface.co/.../model.gguf" \
#     JETSON_SKIP_SERVE=false \
#     ./jetson-orin-setup.sh
#
# Exit Codes:
#   0 — Success
#   1 — General error
#   2 — Missing dependencies (sshpass)
#   3 — Invalid configuration (missing JETSON_HOST or JETSON_PASSWORD)
#   4 — SSH connection failed
#   5 — Build failed
#   6 — Model download failed
#   7 — Benchmark failed
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# -----------------------------------------------------------------------------
# Configuration from environment with defaults
# -----------------------------------------------------------------------------

readonly JETSON_HOST="${JETSON_HOST:-}"
readonly JETSON_USER="${JETSON_USER:-sblanken}"
readonly JETSON_PASSWORD="${JETSON_PASSWORD:-}"
readonly JETSON_MODELS="${JETSON_MODELS:-}"
readonly JETSON_PORT="${JETSON_PORT:-1234}"
readonly JETSON_CTX_SIZE="${JETSON_CTX_SIZE:-4096}"
readonly JETSON_N_GPU_LAYERS="${JETSON_N_GPU_LAYERS:-99}"
readonly JETSON_INSTALL_DIR="${JETSON_INSTALL_DIR:-/home/${JETSON_USER}}"
readonly JETSON_MODEL_DIR="${JETSON_MODEL_DIR:-${JETSON_INSTALL_DIR}/models}"
readonly JETSON_SKIP_PRISM="${JETSON_SKIP_PRISM:-false}"
readonly JETSON_SKIP_SERVE="${JETSON_SKIP_SERVE:-true}"
readonly JETSON_BENCH_MODEL="${JETSON_BENCH_MODEL:-}"

# Per-benchmark model configs (path : label)
# The label is purely cosmetic — override with JETSON_LABEL if you prefer
readonly JETSON_BENCH_LABEL="${JETSON_BENCH_LABEL:-}"

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $(date +%H:%M:%S) $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date +%H:%M:%S) $*" >&2; }
log_step()  { echo -e "${GREEN}[STEP $1]${NC} $(date +%H:%M:%S) $2"; }
log_success() { echo -e "${GREEN}[OK]${NC}   $(date +%H:%M:%S) $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $(date +%H:%M:%S) $*"; }
log_header() { echo; echo "=== $* ==="; echo; }

# -----------------------------------------------------------------------------
# SSH helper
# -----------------------------------------------------------------------------

jetson_ssh() {
    sshpass -p "${JETSON_PASSWORD}" ssh \
        -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=10 \
        "${JETSON_USER}@${JETSON_HOST}" \
        "export LD_LIBRARY_PATH='/usr/local/cuda-13.2/targets/sbsa-linux/lib:\$LD_LIBRARY_PATH'; $*"
}

jetson_sudo() {
    jetson_ssh "echo '${JETSON_PASSWORD}' | sudo -S $*"
}

# -----------------------------------------------------------------------------
# Function: validate
# -----------------------------------------------------------------------------

validate() {
    log_step "1" "Validating configuration"

    if [[ -z "$JETSON_HOST" ]]; then
        log_error "JETSON_HOST is required"
        return 3
    fi
    if [[ -z "$JETSON_PASSWORD" ]]; then
        log_error "JETSON_PASSWORD is required"
        return 3
    fi

    command -v sshpass &>/dev/null || {
        log_error "sshpass is required. Install: sudo apt-get install sshpass"
        return 2
    }

    log_info "Testing SSH to ${JETSON_USER}@${JETSON_HOST}..."
    if ! jetson_ssh "echo OK" 2>/dev/null | grep -q OK; then
        log_error "SSH connection failed"
        return 4
    fi

    log_info "Checking system..."
    jetson_ssh "uname -a; cat /proc/device-tree/model 2>/dev/null | tr -d '\0'; echo; free -h | head -2"

    log_success "Configuration valid"
    return 0
}

# -----------------------------------------------------------------------------
# Function: install_dependencies
# -----------------------------------------------------------------------------

install_dependencies() {
    log_step "2" "Installing system dependencies"

    jetson_sudo "apt-get update -qq" 2>&1 | tail -1
    jetson_sudo "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cmake build-essential git wget" 2>&1 | tail -3

    log_info "Installing CUDA development toolkit..."
    jetson_sudo "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cuda-compiler-13-2 cuda-command-line-tools-13-2 libcublas-dev-13-2" 2>&1 | tail -3

    log_info "Setting up CUDA library path..."
    jetson_sudo "echo '/usr/local/cuda-13.2/targets/sbsa-linux/lib' > /etc/ld.so.conf.d/cuda-13-2.conf"
    jetson_sudo "ldconfig" 2>&1

    log_success "Dependencies installed"
    return 0
}

# -----------------------------------------------------------------------------
# Function: build_llama_cpp_standard
# -----------------------------------------------------------------------------

build_llama_cpp_standard() {
    log_step "3" "Building standard llama.cpp"

    local build_dir="${JETSON_INSTALL_DIR}/llama.cpp"

    # Check if already built
    if jetson_ssh "test -x ${build_dir}/build/bin/llama-cli" 2>/dev/null; then
        local ver
        ver=$(jetson_ssh "${build_dir}/build/bin/llama-cli --version 2>&1 | head -1" 2>/dev/null || echo "unknown")
        log_info "llama.cpp already built: ${ver}"
        return 0
    fi

    jetson_ssh "
        cd ${JETSON_INSTALL_DIR}
        if [[ ! -d llama.cpp ]]; then
            git clone https://github.com/ggml-org/llama.cpp.git
        fi
        cd llama.cpp
        cmake -B build \
            -DGGML_CUDA=ON \
            -DCMAKE_CUDA_ARCHITECTURES='87' \
            -DCUDAToolkit_ROOT=/usr/local/cuda-13.2 \
            2>&1 | tail -5
    " || { log_error "CMake configure failed"; return 5; }

    log_info "Building (this takes 3-5 minutes)..."
    jetson_ssh "
        cd ${build_dir}
        cmake --build build --config Release -j4 2>&1 | tail -10
    " || { log_error "Build failed"; return 5; }

    # Verify
    local ver
    ver=$(jetson_ssh "${build_dir}/build/bin/llama-cli --version 2>&1 | head -1" 2>/dev/null || echo "")
    if [[ -z "$ver" ]]; then
        log_error "Build verification failed — llama-cli not runnable"
        return 5
    fi

    log_success "Standard llama.cpp built: ${ver}"

    # Verify CUDA
    log_info "Checking CUDA device detection..."
    jetson_ssh "${build_dir}/build/bin/llama-cli --list-devices 2>&1" | head -5

    return 0
}

# -----------------------------------------------------------------------------
# Function: build_llama_cpp_prism
# -----------------------------------------------------------------------------

build_llama_cpp_prism() {
    if [[ "$JETSON_SKIP_PRISM" == "true" ]]; then
        log_info "Skipping PrismML fork (JETSON_SKIP_PRISM=true)"
        return 0
    fi

    log_step "4" "Building PrismML llama.cpp fork (ternary/1-bit support)"

    local build_dir="${JETSON_INSTALL_DIR}/llama.cpp-prism"

    if jetson_ssh "test -x ${build_dir}/build/bin/llama-cli" 2>/dev/null; then
        local ver
        ver=$(jetson_ssh "${build_dir}/build/bin/llama-cli --version 2>&1 | head -1" 2>/dev/null || echo "unknown")
        log_info "PrismML fork already built: ${ver}"
        return 0
    fi

    jetson_ssh "
        cd ${JETSON_INSTALL_DIR}
        if [[ ! -d llama.cpp-prism ]]; then
            git clone -b prism https://github.com/PrismML-Eng/llama.cpp.git llama.cpp-prism
        fi
        cd llama.cpp-prism
        cmake -B build \
            -DGGML_CUDA=ON \
            -DCMAKE_CUDA_ARCHITECTURES='87' \
            -DCUDAToolkit_ROOT=/usr/local/cuda-13.2 \
            2>&1 | tail -5
    " || { log_error "PrismML CMake configure failed"; return 5; }

    log_info "Building (this takes 40-50 minutes)..."
    jetson_ssh "
        cd ${build_dir}
        cmake --build build --config Release -j4 2>&1 | tail -10
    " || {
        log_warn "Build may have partial failures (tests often hang). Checking core binaries..."
    }

    # Verify — kill any hung test processes
    jetson_ssh "pkill -f 'test-chat\|test-jinja\|test-tokenizer' 2>/dev/null; true"

    if jetson_ssh "test -x ${build_dir}/build/bin/llama-cli" 2>/dev/null; then
        local ver
        ver=$(jetson_ssh "${build_dir}/build/bin/llama-cli --version 2>&1 | head -1" 2>/dev/null || echo "unknown")
        log_success "PrismML fork built: ${ver}"
    else
        log_warn "llama-cli not found, but llama-simple may work. Check ${build_dir}/build/bin/"
        jetson_ssh "ls ${build_dir}/build/bin/llama-* 2>/dev/null | head -5" || true
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Function: download_models
# -----------------------------------------------------------------------------

download_models() {
    if [[ -z "$JETSON_MODELS" ]]; then
        log_info "No models specified (JETSON_MODELS empty) — skipping download"
        return 0
    fi

    log_step "5" "Downloading models"

    jetson_ssh "mkdir -p ${JETSON_MODEL_DIR}"

    IFS=',' read -ra MODEL_URLS <<< "$JETSON_MODELS"
    for url in "${MODEL_URLS[@]}"; do
        url=$(echo "$url" | xargs)  # trim whitespace
        local fname="${url##*/}"
        local dest="${JETSON_MODEL_DIR}/${fname}"

        # Check if already downloaded and correct size
        local skip=false
        local existing_size
        existing_size=$(jetson_ssh "stat -c%s '${dest}' 2>/dev/null || echo 0" 2>/dev/null)
        if [[ "$existing_size" -gt 104857600 ]]; then  # > 100 MB
            log_info "Model already downloaded: ${fname} ($((existing_size / 1073741824)) GB)"
            skip=true
        fi

        if [[ "$skip" == "false" ]]; then
            log_info "Downloading: ${fname}"
            jetson_ssh "wget -q --show-progress -O '${dest}' '${url}' 2>&1 | tail -1" || {
                log_error "Download failed: ${fname}"
                return 6
            }
            local final_size
            final_size=$(jetson_ssh "stat -c%s '${dest}' 2>/dev/null || echo 0")
            log_success "Downloaded: ${fname} ($((final_size / 1073741824)) GB)"
        fi
    done

    # Show model directory
    log_info "Models installed:"
    jetson_ssh "ls -lh ${JETSON_MODEL_DIR}/*.gguf 2>/dev/null" || true

    return 0
}

# -----------------------------------------------------------------------------
# Function: run_benchmarks
# -----------------------------------------------------------------------------

run_benchmarks() {
    log_step "6" "Running benchmarks"

    local bench_bin=""
    local models_to_bench=""

    # Determine which binary to use (standard or prism)
    # Find all .gguf files and bench them
    local gguf_files
    gguf_files=$(jetson_ssh "ls ${JETSON_MODEL_DIR}/*.gguf 2>/dev/null" 2>/dev/null || echo "")

    if [[ -z "$gguf_files" ]]; then
        log_info "No GGUF models found — skipping benchmarks"
        return 0
    fi

    while IFS= read -r model_path; do
        [[ -z "$model_path" ]] && continue
        local fname=$(basename "$model_path")

        # Determine which binary to use
        if echo "$fname" | grep -qi "dspark\|bonsai\|ternary"; then
            bench_bin="${JETSON_INSTALL_DIR}/llama.cpp-prism/build/bin/llama-bench"
        else
            bench_bin="${JETSON_INSTALL_DIR}/llama.cpp/build/bin/llama-bench"
        fi

        # Check binary exists
        if ! jetson_ssh "test -x ${bench_bin}" 2>/dev/null; then
            log_warn "Bench binary not found: ${bench_bin} — skipping ${fname}"
            continue
        fi

        log_info "Benchmarking: ${fname} (CPU + GPU)"
        echo "  --- CPU ---"
        jetson_ssh "${bench_bin} -m '${model_path}' -ngl 0 -p 0 -n 1 2>&1" | grep -E "model|t/s|build" || true
        echo "  --- GPU ---"
        jetson_ssh "${bench_bin} -m '${model_path}' -ngl 99 -p 0 -n 1 2>&1" | grep -E "model|t/s|build" || true
        echo
    done <<< "$gguf_files"

    log_success "Benchmarks complete"
    return 0
}

# -----------------------------------------------------------------------------
# Function: start_server
# -----------------------------------------------------------------------------

start_server() {
    if [[ "$JETSON_SKIP_SERVE" == "true" ]]; then
        log_info "Skipping server start (JETSON_SKIP_SERVE=true)"
        return 0
    fi

    log_step "7" "Starting inference server"

    # Find the first model
    local first_model
    first_model=$(jetson_ssh "ls ${JETSON_MODEL_DIR}/*.gguf 2>/dev/null | head -1" 2>/dev/null || echo "")

    if [[ -z "$first_model" ]]; then
        log_error "No models found to serve"
        return 1
    fi

    # Determine which llama-server to use
    local server_bin
    local fname=$(basename "$first_model")
    if echo "$fname" | grep -qi "dspark\|bonsai\|ternary"; then
        server_bin="${JETSON_INSTALL_DIR}/llama.cpp-prism/build/bin/llama-server"
    else
        server_bin="${JETSON_INSTALL_DIR}/llama.cpp/build/bin/llama-server"
    fi

    log_info "Starting server with model: ${fname}"

    # Kill any existing server
    jetson_ssh "pkill -f llama-server 2>/dev/null; true"
    sleep 2

    # Start in background via nohup
    jetson_ssh "
        nohup ${server_bin} \
            -m '${first_model}' \
            --host 0.0.0.0 \
            --port ${JETSON_PORT} \
            --n-gpu-layers ${JETSON_N_GPU_LAYERS} \
            --ctx-size ${JETSON_CTX_SIZE} \
            --batch-size 512 \
            > /tmp/llama-server.log 2>&1 &
        sleep 3
        echo \"Server PID: \$(pgrep -f llama-server)\"
    "

    log_success "Server starting on ${JETSON_HOST}:${JETSON_PORT}"
    log_info "Logs: ssh ${JETSON_USER}@${JETSON_HOST} 'tail -f /tmp/llama-server.log'"
    log_info "Test: curl http://${JETSON_HOST}:${JETSON_PORT}/health"

    return 0
}

# -----------------------------------------------------------------------------
# Function: output_summary
# -----------------------------------------------------------------------------

output_summary() {
    log_step "8" "Setup summary"

    echo
    printf '=%.0s' {1..60}
    echo
    echo "  JETSON ORIN NANO — INFERENCE SETUP COMPLETE"
    printf '=%.0s' {1..60}
    echo
    echo
    echo "  Host:      ${JETSON_HOST}"
    echo "  User:      ${JETSON_USER}"
    echo "  Port:      ${JETSON_PORT}"
    echo

    jetson_ssh "
        echo '  GPU:'
        nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || echo '    (nvidia-smi not available)'
        echo
        echo '  Disk:'
        df -h / | tail -1 | awk '{print \"    \" \$2 \" total, \" \$3 \" used, \" \$4 \" free (\" \$5 \")\"}'
        echo
        echo '  Models:'
        ls -lh ${JETSON_MODEL_DIR}/*.gguf 2>/dev/null | awk '{print \"    \" \$9 \"  \" \$5}' || echo '    (none)'
        echo
        echo '  Builds:'
        test -x ${JETSON_INSTALL_DIR}/llama.cpp/build/bin/llama-cli && echo '    llama.cpp (standard):  OK' || echo '    llama.cpp (standard):  MISSING'
        test -x ${JETSON_INSTALL_DIR}/llama.cpp-prism/build/bin/llama-cli && echo '    llama.cpp (PrismML):   OK' || echo '    llama.cpp (PrismML):   MISSING'
    " 2>/dev/null

    echo
    printf '=%.0s' {1..60}
    echo

    return 0
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    log_header "Jetson Orin Nano — Inference Provider Setup"

    validate              || exit $?
    install_dependencies  || exit $?
    build_llama_cpp_standard || exit $?
    build_llama_cpp_prism    || exit $?
    download_models       || exit $?
    run_benchmarks        || exit $?
    start_server          || exit $?
    output_summary

    log_success "All done!"
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
