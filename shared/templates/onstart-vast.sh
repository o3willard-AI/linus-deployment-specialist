#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist — Vast Onstart Build Template
# =============================================================================
# Purpose: Battle-tested llama.cpp build recipe for Vast.ai GPU instances.
#   Runs inside the container during provisioning via --onstart-cmd.
#
# Environment Variables:
#   CUDA_ARCH   — CUDA architecture flag (default: 86 for RTX 3090)
#                 RTX_3090=86  RTX_4090=89  A100=80  H100=90  V100=70
#   BUILD_DIR   — Build directory (default: /workspace/llama.cpp)
#
# Output: Echoes "BUILD_DONE" on success. Exits non-zero on failure.
#
# This recipe survived 7 failed iterations. Do not deviate.
# =============================================================================

set -euo pipefail

CUDA_ARCH="${CUDA_ARCH:-86}"
BUILD_DIR="${BUILD_DIR:-/workspace/llama.cpp}"

# ---------------------------------------------------------------------------
# Step 1: Install cmake (git + build-essential pre-installed by Vast)
# ---------------------------------------------------------------------------
echo "[onstart] Installing cmake..."
apt-get update -qq
apt-get install -y -qq cmake

# ---------------------------------------------------------------------------
# Step 2: Clone llama.cpp (shallow, depth 1 for speed)
# ---------------------------------------------------------------------------
echo "[onstart] Cloning llama.cpp..."
mkdir -p /workspace
cd /workspace
git clone --depth 1 https://github.com/ggml-org/llama.cpp
cd llama.cpp

# ---------------------------------------------------------------------------
# Step 3: Configure build — CUDA ON, target specific arch only (~5 min)
# ---------------------------------------------------------------------------
echo "[onstart] Configuring build for arch ${CUDA_ARCH}..."
cmake -B build \
    -DGGML_CUDA=ON \
    -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCH}"

# ---------------------------------------------------------------------------
# Step 4: Build — parallel, Release mode
# ---------------------------------------------------------------------------
echo "[onstart] Building llama.cpp..."
cmake --build build --config Release -j"$(nproc)"

# ---------------------------------------------------------------------------
# Signal completion (parsed by vast.sh wait loop)
# ---------------------------------------------------------------------------
echo "BUILD_DONE"
