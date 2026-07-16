# Jetson Orin Nano — Inference Provider Setup

> **Hardware profile, build instructions, and operational notes for deploying llama.cpp on NVIDIA Jetson Orin Nano Developer Kit (8 GB).**

---

## Hardware Profile

| Spec | Detail |
|------|--------|
| **Model** | NVIDIA Jetson Orin Nano Developer Kit |
| **SoC** | Orin (Ampere architecture, SM 8.7) |
| **GPU** | 1024 CUDA cores, 32 Tensor cores @ 306–625 MHz |
| **CPU** | 6× Cortex-A78AE @ up to 1.51 GHz |
| **RAM** | 7.3 GiB LPDDR5 (unified CPU+GPU memory) |
| **Storage** | 56 GB eMMC (~30 MB/s read) |
| **OS** | Ubuntu 24.04, JetPack 39.2 (L4T R39.2), kernel 6.8.12-tegra |
| **CUDA** | 13.2 (driver 595.78), nvgpu backend |
| **Power** | 15W max (7W mode available — 4 cores, GPU capped 408 MHz) |
| **Architecture** | aarch64 (ARM64) |
| **GPU memory** | ~6.4 GB usable for models (unified, shared with CPU) |

---

## Prerequisites

### 1. System Packages

```bash
sudo apt-get update
sudo apt-get install -y cmake build-essential git wget
```

### 2. CUDA Development Toolkit

JetPack ships CUDA runtime but NOT development headers. Install separately:

```bash
sudo apt-get install -y cuda-compiler-13-2 cuda-command-line-tools-13-2 libcublas-dev-13-2
```

> **⚠️ Package naming:** Use `libcublas-dev-13-2` NOT `cuda-cublas-dev-13-2`. JetPack follows a different naming convention from desktop CUDA.

### 3. Library Path

```bash
# Add to ld.so.conf
echo "/usr/local/cuda-13.2/targets/sbsa-linux/lib" | sudo tee /etc/ld.so.conf.d/cuda-13-2.conf
sudo ldconfig

# Set for current session
export LD_LIBRARY_PATH="/usr/local/cuda-13.2/targets/sbsa-linux/lib:$LD_LIBRARY_PATH"
```

> **⚠️ Target path is `sbsa-linux` not `aarch64-linux`.** JetPack 39.2 uses SBSA-compliant kernel.

---

## Building llama.cpp

### Standard Build (for standard GGUF models)

```bash
git clone https://github.com/ggml-org/llama.cpp.git
cd llama.cpp
cmake -B build \
    -DGGML_CUDA=ON \
    -DCMAKE_CUDA_ARCHITECTURES="87" \
    -DCUDAToolkit_ROOT=/usr/local/cuda-13.2
cmake --build build --config Release -j4
```

**Binary location:** `build/bin/llama-cli`, `build/bin/llama-server`, `build/bin/llama-bench`

### PrismML Fork (for ternary/1-bit Bonsai models)

```bash
git clone -b prism https://github.com/PrismML-Eng/llama.cpp.git llama.cpp-prism
cd llama.cpp-prism
cmake -B build \
    -DGGML_CUDA=ON \
    -DCMAKE_CUDA_ARCHITECTURES="87" \
    -DCUDAToolkit_ROOT=/usr/local/cuda-13.2
cmake --build build --config Release -j4
```

> **⚠️ Build time:** ~47 minutes on the Jetson's 4 ARM cores. Tests may hang — kill the test targets if needed (`kill $(pgrep -f test-char)`). Core binaries (`llama-cli`, `llama-server`, `llama-simple`) compile fine.

---

## Model Compatibility

### Standard llama.cpp

| Model | Size | Speed (GPU) | Notes |
|-------|------|-------------|-------|
| Qwen3.5-4B-Super-Coder (Q4_0) | 2.42 GB | ~10.9 t/s | Distilled from Claude, tool-calling trained |
| Gemma-3-1B (F16) | 1.86 GB | ~15.6 t/s | Uncensored, lightweight chat |

### PrismML Fork (ternary/1-bit)

| Model | Size | Speed (GPU) | Notes |
|-------|------|-------------|-------|
| Ternary-Bonsai-27B (dspark-Q4_1) | 1.81 GB | ~33.6 t/s | 27B ternary, 95% FP16 quality, DSpark drafter |
| Bonsai-8B (Q1_0) | 1.07 GB | ~10.8 t/s | 8B 1-bit, phone-class |

### Won't Fit

- Models > 5.6 GB leave no room for KV cache (350–400 MB used at 256 ctx, grows linearly)
- Practical ceiling: ~5 GB per model with 1 GB for system + KV cache

---

## Benchmarking

Use `llama-bench` for quick tests — it loads models much faster than `llama-cli`:

```bash
# CPU-only
~/llama.cpp/build/bin/llama-bench -m model.gguf -ngl 0 -p 0 -n 1

# GPU offload (all layers)
~/llama.cpp/build/bin/llama-bench -m model.gguf -ngl 99 -p 0 -n 1
```

### Example Results (GPU, ngl=99, tg1 test)

| Model | t/s |
|-------|-----|
| Ternary-Bonsai-27B dspark-Q4_1 | 33.64 ± 2.00 |
| Gemma-3-1B F16 | 15.56 ± 1.02 |
| Qwen3.5-4B-Super-Coder Q4_0 | 10.91 ± 1.07 |
| Bonsai-8B Q1_0 | 10.80 ± 0.79 |

---

## Operational Notes

### Pitfalls

1. **eMMC is slow** — Model loading takes 60–120s for a 2 GB file. An NVMe SSD would cut this to 5–10s. The M.2 slot is available on the carrier board.

2. **Default context is enormous** — Models like Bonsai default to 262K context. KV cache allocation fails (9.2 GB requested!). Always pass `-c 2048` or `-c 4096` for interactive use.

3. **Zombie processes** — SSH-dispatched `llama-cli` processes don't always die when the SSH session ends. Check with `ps aux | grep llama` and `kill -9` stragglers.

4. **No swap** — OOM is instant. Keep at least 1 GB free for KV cache.

5. **`sudo` needs password** — Use `echo 'password' | sudo -S` for scripted commands.

### Production Serving

```bash
# Start server with GPU offload
~/llama.cpp/build/bin/llama-server \
    -m ~/models/Ternary-Bonsai-27B-dspark-Q4_1.gguf \
    --host 0.0.0.0 --port 1234 \
    --n-gpu-layers 99 \
    --ctx-size 4096 \
    --batch-size 512

# Test
curl http://192.168.101.10:1234/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"messages":[{"role":"user","content":"Hello"}],"max_tokens":50}'
```

### Power Modes

```bash
# Check current mode
nvpmodel -q

# Switch to 7W (lower power, 4 cores, GPU 408 MHz)
sudo nvpmodel -m 1

# Switch to 15W (max performance, 6 cores, GPU 625 MHz)
sudo nvpmodel -m 0
```

---

## Quick Setup Summary

```bash
# 1. Install deps
sudo apt-get install -y cmake build-essential git wget
sudo apt-get install -y cuda-compiler-13-2 cuda-command-line-tools-13-2 libcublas-dev-13-2
echo "/usr/local/cuda-13.2/targets/sbsa-linux/lib" | sudo tee /etc/ld.so.conf.d/cuda-13-2.conf
sudo ldconfig
export LD_LIBRARY_PATH="/usr/local/cuda-13.2/targets/sbsa-linux/lib:$LD_LIBRARY_PATH"

# 2. Build standard llama.cpp
git clone https://github.com/ggml-org/llama.cpp.git
cd llama.cpp && cmake -B build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES="87" -DCUDAToolkit_ROOT=/usr/local/cuda-13.2
cmake --build build --config Release -j4

# 3. Build PrismML fork (ternary/1-bit models)
cd ~ && git clone -b prism https://github.com/PrismML-Eng/llama.cpp.git llama.cpp-prism
cd llama.cpp-prism && cmake -B build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES="87" -DCUDAToolkit_ROOT=/usr/local/cuda-13.2
cmake --build build --config Release -j4

# 4. Download models
mkdir -p ~/models
wget -P ~/models "https://huggingface.co/prism-ml/Ternary-Bonsai-27B-gguf/resolve/main/Ternary-Bonsai-27B-dspark-Q4_1.gguf"
# ... (repeat for other models)

# 5. Benchmark
~/llama.cpp/build/bin/llama-bench -m ~/models/Ternary-Bonsai-27B-dspark-Q4_1.gguf -ngl 99 -p 0 -n 1

# 6. Serve
~/llama.cpp/build/bin/llama-server -m ~/models/Ternary-Bonsai-27B-dspark-Q4_1.gguf --host 0.0.0.0 --port 1234 --n-gpu-layers 99 --ctx-size 4096
```
