# Story P3-1: Vast Onstart Build Template

**Priority:** P0 (required by vast.sh provision script)
**Estimate:** 0.5 day
**Phase:** Phase 3 — Vast Provider Foundation
**Depends on:** P1-1 (vast-sizing.sh), P2-1 (validate_gpu_type)

---

## User Story

As the **Vast provisioner script (`vast.sh`)**
I want a reusable onstart script template that builds llama.cpp from source on a Vast GPU instance
So that I can inject a battle-tested, deterministic build into any `--onstart-cmd` without copy-paste errors

---

## Acceptance Criteria

### AC1: Script exists and is valid

- [ ] File: `shared/templates/onstart-vast.sh`
- [ ] `bash -n` clean
- [ ] Starts with `#!/usr/bin/env bash` and `set -euo pipefail`
- [ ] Has header comment block explaining purpose and env vars

### AC2: Environment-driven configuration

- [ ] Reads `CUDA_ARCH` from environment (default: `86` for RTX 3090)
- [ ] Reads `BUILD_DIR` from environment (default: `/workspace/llama.cpp`)
- [ ] Uses `CUDA_ARCH` in cmake: `-DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCH}`
- [ ] Uses `-j$(nproc)` for parallel build

### AC3: Correct build recipe (battle-tested)

- [ ] `apt-get update -qq && apt-get install -y -qq cmake`
- [ ] `mkdir -p /workspace && cd /workspace`
- [ ] `git clone --depth 1 https://github.com/ggml-org/llama.cpp`
- [ ] `cmake -B build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCH}`
- [ ] `cmake --build build --config Release -j$(nproc)`
- [ ] Echoes `BUILD_DONE` on success

### AC4: Failure handling

- [ ] `set -euo pipefail` causes exit on any error
- [ ] Each major step has an echo marker so Vast logs show progress:
  - `[onstart] Installing cmake...`
  - `[onstart] Cloning llama.cpp...`
  - `[onstart] Configuring build for arch ${CUDA_ARCH}...`
  - `[onstart] Building llama.cpp...`
- [ ] Final output: `BUILD_DONE` (parsed by vast.sh wait loop)

### AC5: Size constraint

- [ ] Script is under 16KB (Vast's `--onstart-cmd` limit)
- [ ] No unnecessary comments or verbose logging

### AC6: Integration test

- [ ] `bash -n shared/templates/onstart-vast.sh` clean
- [ ] Can be sourced or executed — sourcing just defines functions, execution runs the build
- [ ] When `CUDA_ARCH=89` is set, cmake line contains `89` not `86`

---

## Technical Notes

The onstart script runs INSIDE the Vast container during provisioning. It has no access to the Linus project files — it must be entirely self-contained. The `vast.sh` provision script will read this template, substitute any remaining variables, and pass it as `--onstart-cmd`.

**Why template not generated inline:** The onstart recipe has 7 failed iterations behind it (ghcr.io pull failures, cmake missing, CUDA arch wrong, workspace missing). Encoding it as a file makes it testable and reviewable.

**16KB limit:** The template should be ~1KB. If future versions need to be larger, use gzip+base64 encoding with a decoder preamble.

---

## Definition of Done

- [ ] All 6 AC sections passing
- [ ] `bash -n shared/templates/onstart-vast.sh` clean
- [ ] Manual verification: `CUDA_ARCH=89 bash -x shared/templates/onstart-vast.sh | grep -c "89"` shows arch substitution
- [ ] Smoke tests still pass
- [ ] Committed to branch
