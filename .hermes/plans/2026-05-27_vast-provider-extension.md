# Plan: Vast.ai Provider Extension for Linus Deployment Specialist

**Goal:** Extend Linus to make the full lifecycle of GPU inference provisioning on Vast.ai as deterministic as the existing Proxmox/AWS/QEMU providers — structured output, EXIT-trap cleanup, known pitfall guards.

**Date:** 2026-05-27
**Author:** Hermes (Heph)

---

## 1. The CLI Question

**Pre-req: yes, the Vast CLI is mandatory.** Vast.ai removed their API endpoints for search/provisioning in May 2026. The CLI (`pip install vastai`) is the only terminal-based provisioning path. No curl-workaround exists.

**Strategy:** Follow the AWS provider pattern — auto-install if missing, not hard-fail.

```bash
# In validate_environment():
if ! command -v vastai &>/dev/null; then
    log_warn "vastai CLI not found — installing..."
    pip install --user vastai
    export PATH="$HOME/.local/bin:$PATH"
fi
```

This differs from Proxmox (curl-only, no CLI dep) and mirrors AWS (aws CLI assumed installed, but Linus could auto-install). The pip install is fast (<10s), idempotent, and the same command works on Linux/macOS.

---

## 2. New Files

### 2.1 `shared/provision/vast.sh` (~400 lines)

The core provider script. Follows exact same contract as proxmox.sh/aws.sh/qemu.sh.

**Functions (matching proxmox.sh structure):**

| Function | Purpose | Vast-specific logic |
|----------|---------|---------------------|
| `validate_environment()` | Verify CLI installed, API key set, SSH key registered | `vastai --version`, `vastai show ssh-keys`, check KeePass for `General/Vast API Key` |
| `search_offers()` | Search + select best offer | `vastai search offers` with filters. Algorithmic selection (not LLM) — sort by dlperf_usd, filter by constraints |
| `create_instance()` | Create instance with onstart script | `vastai create instance --image ... --onstart-cmd ... --ssh --direct` |
| `wait_for_running()` | Poll until status=running | `vastai show instance $CONTRACT_ID`, parse JSON status |
| `wait_for_ssh()` | Wait for SSH proxy to be reachable | Loop `ssh -p PORT root@sshN.vast.ai 'echo ok'` with 30 retries |
| `output_result()` | Structured output | `LINUS_RESULT:SUCCESS` + CONTRACT_ID, SSH_HOST, SSH_PORT, PROXY_PORT |
| `cleanup_on_error()` | Destroy on failure | `vastai destroy instance $CONTRACT_ID --yes` |

**Onstart script generation:**

The onstart script needs to be templated from a file. Create `shared/templates/onstart-vast.sh` (or inline-generate in the provision script). The template includes:

- `apt-get update -qq && apt-get install -y -qq cmake`
- `mkdir -p /workspace && cd /workspace`
- `git clone --depth 1 https://github.com/ggml-org/llama.cpp`
- `cmake -B build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCH}`
- `cmake --build build --config Release -j$(nproc)`
- Echo `BUILD_DONE` marker for detection

If the onstart script exceeds 16KB (Vast limit), gzip+base64 encode it and use a decoder preamble.

**Environment variables:**

| Variable | Default | Required | Notes |
|----------|---------|----------|-------|
| `VAST_API_KEY` | (from KeePass) | Yes | Vast.ai API key |
| `VAST_GPU_NAME` | `RTX_3090` | No | GPU model filter (wildcards: `RTX_*`) |
| `VAST_NUM_GPUS` | `1` | No | Number of GPUs |
| `VAST_MIN_RELIABILITY` | `0.99` | No | Host reliability floor |
| `VAST_MAX_PRICE` | — | No | Max $/hr (dph_total) |
| `VAST_MIN_DISK` | (auto-calculated) | No | Min disk GB — auto-derived from model size if VAST_MODEL_REPO set |
| `VAST_SORT_STRATEGY` | `value` | No | `value` (dlperf_usd), `cheapest` (dph), `fastest` (dlperf) |
| `VAST_IMAGE` | `nvidia/cuda:12.4.0-devel-ubuntu22.04` | No | Docker image |
| `VAST_CUDA_ARCH` | `86` | No | CUDA arch flag (86=RTX3090, 89=RTX4090, etc.) |
| `VAST_MODEL_REPO` | — | No | HF repo for model download |
| `VAST_MODEL_FILE` | — | No | GGUF filename |
| `VAST_MODEL_QUANT` | `Q4_K_M` | No | Quantization level |
| `VAST_CTX_SIZE` | `32768` | No | Context window |
| `VAST_API_KEY_NAME` | `linus-inference` | No | API key for inference server |

**Sort strategy semantics:**

| Strategy | Sort Key | Use Case |
|----------|----------|----------|
| `value` (default) | `dlperf / dph_total` descending | Best TFLOPS per dollar |
| `cheapest` | `dph_total` ascending | "Just give me the cheapest thing that works" |
| `fastest` | `dlperf` descending | "Max throughput, budget secondary" |

When `VAST_MAX_PRICE` is set, offers exceeding it are filtered BEFORE sorting. This means `fastest` + `VAST_MAX_PRICE=0.30` means "fastest GPU under $0.30/hr."

**Credential auto-discovery (matching proxmox.sh pattern):**

```bash
# Scan ~/.hermes/secrets/ for vast-api-key, vast-token, etc.
# Fall back to KeePass: echo "$kpw" | keepassxc-cli show -a Password secrets.kdbx "General/Vast API Key"
```

### 2.2 `shared/bootstrap/vast-gpu.sh` (~150 lines)

Post-provision bootstrap: download model + start inference server.

- `scp` model download script to `/workspace/`
- Trigger model download via `nohup`
- Start `llama-server` with correct flags
- Verify health endpoint responds
- Output `LINUS_RESULT:SUCCESS`

### 2.3 `shared/templates/onstart-vast.sh` (~50 lines)

The reusable onstart template. Variables substituted at provision time. Includes the exact build recipe from the battle-tested skill.

### 2.4 `shared/provision/vast-destroy.sh` (~50 lines)

Specialized destroy for Vast instances. Wraps `vastai destroy instance $CONTRACT_ID --yes`. The existing `shared/provision/destroy.sh` is provider-dispatched — it needs a Vast case.

---

## 2.5. The Four-Constraint Offer Selection Pipeline

This is the deterministic algorithm inside `search_offers()`. No LLM — pure filtering and arithmetic.

### Constraint Type Map

| Dimension | Vast CLI Field | Constraint Type | Guard |
|-----------|---------------|-----------------|-------|
| **Reliability** | `reliability` (0.0–1.0) | Hard floor | `< VAST_MIN_RELIABILITY` → reject |
| **Disk** | `disk` (GB) | Hard floor | `< required_disk` → reject |
| **Cost** | `dph_total` ($/hr) | Hard ceiling | `> VAST_MAX_PRICE` → reject (if set) |
| **Performance** | `dlperf` (normalized) | Soft objective | Used in sort, never rejects |

Additional hard constraints (always enforced):
- `verified=true` — only identity-checked hosts
- `rentable=true` — only rentable offers
- `direct_port_count >= 1` — SSH access required
- VRAM (GPU RAM) >= model_vram + kv_cache_vram + 1.5 GB overhead

### Pipeline

```
vastai search offers (JSON)
  │
  ├─ Filter 1: verified + rentable + ports ≥ 1
  ├─ Filter 2: GPU VRAM ≥ required_vram
  ├─ Filter 3: reliability ≥ VAST_MIN_RELIABILITY (default 0.99)
  ├─ Filter 4: disk ≥ required_disk
  ├─ Filter 5: dph_total ≤ VAST_MAX_PRICE (only if set)
  │
  ├─ Sort: by VAST_SORT_STRATEGY
  │    value    → dlperf / dph_total  DESC
  │    cheapest → dph_total           ASC
  │    fastest  → dlperf              DESC
  │
  └─ Pick: top 3, select #1 unless --interactive mode
```

### Disk Sizing Formula

```
required_disk = model_file_size * 2.5

Where:
  model_file_size = model_params_B × quant_factor (from GPU reference table)
  
Breakdown of the 2.5× multiplier:
  - model_file_size    (the GGUF)
  - OS + base image    ~5 GB
  - llama.cpp build    ~2 GB
  - Temp / headroom    ~0.5 × model_file_size
```

If `VAST_MIN_DISK` is explicitly set, it overrides the calculated value. This allows "I know I need 200 GB" without specifying a model.

### VRAM Sizing Formula

```
required_vram = model_file_size + kv_cache_size + 1.5

Where:
  kv_cache_size = ctx_size × model_params_B × 75 / 10_000_000
  (Approximation matching the GPU reference table to within 3%)

Example (RTX 3090, 24 GB):
  Qwen2.5-Coder-7B Q4_K_M + 32K ctx:
    model = 7 × 0.6 = 4.2 GB
    kv_cache = 32768 × 7 × 75 / 10000000 ≈ 1.7 GB
    total = 4.2 + 1.7 + 1.5 = 7.4 GB → RTX 3090 passes (24 > 7.4) ✓

  Llama-4-Maverick-17B Q4_K_M + 128K ctx:
    model = 17 × 0.6 = 10.2 GB
    kv_cache = 131072 × 17 × 75 / 10000000 ≈ 16.7 GB
    total = 10.2 + 16.7 + 1.5 = 28.4 GB → RTX 3090 FAILS (24 < 28.4) ✗
    → Needs A6000 (48 GB) or better
```

### DLPerf as TFLOPS Proxy

Vast reports `dlperf` — a normalized deep learning performance score. It's a single number that bakes in GPU architecture, clock speed, memory bandwidth, and tensor cores. Higher = faster inference.

| GPU | Approx DLPerf | Relative to RTX 3090 |
|-----|---------------|---------------------|
| RTX 3090 | ~100 | 1.0× (baseline) |
| RTX 4090 | ~125 | 1.25× |
| A6000 | ~130 | 1.30× |
| A100 80GB | ~200 | 2.0× |
| H100 SXM | ~300 | 3.0× |

Sorting by `dlperf / dph_total` (the `value` strategy) naturally balances these:
- RTX 3090 at $0.26/hr: 100/0.26 = **385** dlperf/$
- RTX 4090 at $0.40/hr: 125/0.40 = **313** dlperf/$
- A100 at $1.20/hr: 200/1.20 = **167** dlperf/$

The RTX 3090 wins on value despite being slower, because the performance gain of faster GPUs doesn't keep pace with the price premium. But when `VAST_MAX_PRICE` isn't a factor and `VAST_SORT_STRATEGY=fastest`, the H100 wins.

### Edge Cases

| Scenario | Behavior |
|----------|----------|
| No offers pass all filters | Exit code 5 ("VM creation failed"), log each filter's drop count |
| `VAST_MAX_PRICE` unset | Skip price filter entirely |
| `VAST_MODEL_REPO` unset | `required_vram` and `required_disk` can't be auto-calculated → skip VRAM/disk filters, rely on `VAST_MIN_DISK` if set |
| Multiple offers tie on sort key | Prefer higher reliability, then higher disk |
| User wants to see options | `VAST_INTERACTIVE=true` outputs top 3 as structured data, exits 0 with selection deferred to caller |

---

## 3. Modified Files

### 3.1 `shared/provision/destroy.sh`

Add `vast` case to the provider dispatch:
```bash
vast)
    vastai destroy instance "$VM_IDENTIFIER" --yes
    ;;
```

### 3.2 `shared/lib/paths.sh`

No changes needed — vast.sh will be in `shared/provision/` and will source paths.sh like all other provider scripts.

### 3.3 `shared/lib/validation.sh`

Add `validate_gpu_type()` — maps GPU name to CUDA arch. Add to `validate_os` or create a new function.

### 3.4 `PROVISIONING-OPS.md`

Add Phase 7: Vast GPU provisioning flow (matching the 6-phase Proxmox structure).

### 3.5 `docs/QUICK-REFERENCE.md`

Add Vast environment variables section.

---

## 4. Vast Lifecycle → Linus Phase Mapping

| Linus Phase | Vast Equivalent | Script |
|-------------|-----------------|--------|
| 0. Pre-flight | Destroy orphaned instances from previous runs; register EXIT trap | vast.sh (inline in main) |
| 1. Provision | Search offers → select → create instance → wait for running → wait for SSH → BUILD_DONE marker | vast.sh |
| 2. Bootstrap | Download model + start llama-server | vast-gpu.sh |
| 3. Configure | Set API key, adjust context, verify model loaded | vast-gpu.sh (or inline) |
| 4. Snapshot | **N/A** — Vast has no snapshot API | Skip |
| 5. Multi-instance | Loop vast.sh N times | multi-vm.sh (modified) |
| 6. Monitoring | `vastai logs`, health endpoint polling | Existing monitor pattern |
| Cleanup | `vastai destroy instance` via EXIT trap | vast.sh + vast-destroy.sh |

Key difference from Proxmox: the "bootstrap" (compilation) happens inside `--onstart-cmd` during provisioning, not after SSH. The post-provision bootstrap phase is model download + server start only.

---

## 5. Pitfall Guards to Encode

These are the 14 known Vast failure modes, translated into script guards:

| # | Pitfall | Guard |
|---|---------|-------|
| 1 | `vastai create ssh-key <filepath>` stores path, not content | After `validate_environment`, run `vastai show ssh-keys` and verify each entry starts with `ssh-ed25519`, not `/` |
| 2 | ghcr.io images never pull (stuck "loading") | Hardcoded image list — only allow `nvidia/cuda:*` or explicit whitelist |
| 3 | cmake not pre-installed in devel image | Onstart template includes `apt-get install -y cmake` |
| 4 | `/workspace` doesn't exist | Onstart template includes `mkdir -p /workspace` |
| 5 | Runtime image used (no nvcc) → "CUDA Toolkit not found" | Validate `--image` contains `devel` |
| 6 | Wrong CUDA arch → build succeeds, server crashes | `validate_gpu_type()` in validation.sh cross-references GPU→arch |
| 7 | Build takes 30+ min (all archs) | Onstart always sets `-DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCH}` |
| 8 | CDI passthrough failure → stuck "created", no logs | Poll `vastai logs` after `running` status; if empty after 2 min, destroy + retry |
| 9 | Vast SSH proxy rejects complex commands (exit 255) | All post-provision work uses `scp` + `nohup` pattern, not inline SSH |
| 10 | `nohup python3` buffers output → empty logfiles | Server start includes `PYTHONUNBUFFERED=1` |
| 11 | Instance stuck "loading" 10+ min → host degraded | Timeout at 10 min; destroy + retry different host |
| 12 | HF API returns 0 bytes for LFS files | Use Range-request trick in model download script |
| 13 | XetHub saves files under content hashes | Model download script renames after download |
| 14 | `vastai: command not found` in non-interactive SSH | Use `/home/<user>/.local/bin/vastai` full path |

---

## 6. Sizing Calculus Library: `shared/lib/vast-sizing.sh`

This is **v1 material** — the four constraints can't be enforced without the math. A new shared library that computes:

```bash
# Functions:
vast_calc_model_size()       # params_B × quant_factor → model GB
vast_calc_kv_cache()         # ctx_size × params_B × 75 / 10_000_000 → KV cache GB
vast_calc_required_vram()    # model + kv_cache + 1.5 → min GPU VRAM
vast_calc_required_disk()    # model_file_size_gb × 2.5 → min disk GB
vast_calc_dlperf_per_dollar()# dlperf / dph_total → value score
```

**Source of truth:** The GPU reference table from the `vast-ai-llama-cpp-provisioning` skill (`references/gpu-reference.md`) is encoded as a bash associative array:

```bash
declare -A GPU_VRAM=(  [RTX_3090]=24  [RTX_4090]=24  [A6000]=48  [A100]=80  [H100]=80 )
declare -A GPU_ARCH=(  [RTX_3090]=86  [RTX_4090]=89  [A6000]=86  [A100]=80  [H100]=90 )
declare -A QUANT_FACTORS=( [Q4_K_M]=0.6  [Q5_K_M]=0.7  [Q8_0]=0.95  [Q3_K_M]=0.5  [Q2_K]=0.4 )
```

This library is sourced by `vast.sh` and used in `validate_environment()` to compute constraints before `search_offers()` runs.

---

## 7. Test Strategy

| Level | Test | Script |
|-------|------|--------|
| Syntax | `bash -n shared/provision/vast.sh` | CI |
| Unit | `validate_gpu_type` cross-reference table | `tests/unit/test-vast-validation.sh` |
| Integration | Search offers (read-only, no charge) | `tests/integration/test-vast-search.sh` |
| E2E | Full provision → bootstrap → verify → destroy | `tests/e2e/test-vast-workflow.sh` |
| E2E | Multi-instance provision + destroy | `tests/e2e/test-vast-multi.sh` |

E2E tests will cost real Vast credits (~$0.50/run for RTX 3090). Gate them behind `VAST_RUN_E2E=true` env var and run on the `e2e-hardware` CI workflow.

---

## 8. Implementation Order

1. **`shared/lib/vast-sizing.sh`** — GPU reference table + sizing formulas (VRAM, disk, dlperf/$)
2. **`shared/lib/validation.sh`** — Add `validate_gpu_type()` with GPU→arch mapping from sizing table
3. **`shared/templates/onstart-vast.sh`** — Reusable onstart template
4. **`shared/provision/vast.sh`** — Core provider script (sources vast-sizing.sh, runs 5-filter pipeline, provisions, waits)
5. **`shared/bootstrap/vast-gpu.sh`** — Model download + server start
6. **`shared/provision/vast-destroy.sh`** — Teardown wrapper
7. **`shared/provision/destroy.sh`** — Add `vast` case to dispatch
8. **`shared/provision/multi-vm.sh`** — Add `vast` case to multi-provider loop
9. **Tests** — Unit (sizing formulas) → integration (search offers, read-only) → E2E (gated behind `VAST_RUN_E2E=true`)
10. **Docs** — `PROVISIONING-OPS.md` Phase 7, `QUICK-REFERENCE.md`

---

## 9. Risks & Open Questions

- **Vast CLI stability:** The CLI is the only path. If it changes, the provider breaks. Mitigation: pin `vastai` version in docs.
- **Cost accumulation:** A failed E2E test that doesn't destroy the instance costs money. The EXIT trap must be bulletproof before E2E tests run.
- **Model download time:** Large models (70B Q4_K_M = 42 GB) can take 30-60 min to download on Vast's network. The `wait_for_model()` function needs generous timeouts (60 min default).
- **`--onstart-cmd` 16KB limit:** For complex deployments, gzip+base64 encoding works but adds complexity. For v1, templates fit easily within 16KB.
- **Open question:** Should `vast-gpu.sh` handle vLLM as well as llama.cpp? vLLM uses pre-built Docker images (`vllm/vllm-openai:latest`), completely different lifecycle. Decision: **v1 is llama.cpp only.** vLLM is a separate bootstrap script for Phase 2.
