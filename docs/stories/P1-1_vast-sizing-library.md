# Story P1-1: Vast GPU Sizing Calculus Library

**Priority:** P0 (all downstream Vast provider scripts depend on these formulas)
**Estimate:** 1 day
**Phase:** Phase 1 — Vast Provider Foundation

---

## User Story

As a **Vast provisioner script (`vast.sh`)**
I want **a sourced library of pure sizing functions that compute VRAM, disk, and cost-value requirements from model parameters**
So that **offer filtering is deterministic arithmetic with no LLM inference needed at decision time**

---

## Acceptance Criteria

### AC1: GPU Reference Table

- [ ] File: `shared/lib/vast-sizing.sh` — new library, follows existing lib conventions (sources `logging.sh`, sets `LINUS_VAST_SIZING_LOADED=1` guard)
- [ ] Bash associative array `GPU_VRAM` mapping GPU model names to VRAM in GB:
  `RTX_3090=24, RTX_4090=24, A5000=24, V100_16GB=16, V100_32GB=32, A6000=48, L40S=48, A100_40GB=40, A100_80GB=80, H100=80`
- [ ] Bash associative array `GPU_ARCH` mapping GPU model names to CUDA architecture flags:
  `RTX_3090=86, RTX_4090=89, A5000=86, V100_16GB=70, V100_32GB=70, A6000=86, L40S=89, A100_40GB=80, A100_80GB=80, H100=90`
- [ ] Bash associative array `QUANT_FACTORS` mapping quantization names to model-size multipliers:
  `Q2_K=0.4, Q3_K_M=0.5, Q4_K_M=0.6, Q5_K_M=0.7, Q8_0=0.95`
- [ ] Library is sourceable without side effects (no output, no exit, no state mutation)

### AC2: Model Size Calculator

- [ ] `vast_calc_model_size <params_B> <quant>` echoes the model file size in GB (2 decimal places)
- [ ] `vast_calc_model_size 7 Q4_K_M` → `4.20`
- [ ] `vast_calc_model_size 27 Q3_K_M` → `13.50`
- [ ] `vast_calc_model_size 70 Q8_0` → `66.50`
- [ ] Returns error message to stderr and exit code 1 for unknown quantization

### AC3: KV Cache Calculator

- [ ] `vast_calc_kv_cache <ctx_size> <params_B>` echoes the KV cache size in GB (2 decimal places)
- [ ] Formula: `ctx_size × params_B × 75 / 10_000_000`
- [ ] `vast_calc_kv_cache 32768 7` → `1.72` (matches GPU reference table: ~1.7 GB for 7B@32K)
- [ ] `vast_calc_kv_cache 32768 14` → `3.44` (matches table: ~3.4 GB for 14B@32K)
- [ ] `vast_calc_kv_cache 32768 27` → `6.64` (matches table: ~6.5 GB for 27B@32K)
- [ ] `vast_calc_kv_cache 131072 7` → `6.88` (matches table: ~6.7 GB for 7B@128K)
- [ ] Accepts integer args only — non-numeric input returns error to stderr, exit 1

### AC4: VRAM Requirement Calculator

- [ ] `vast_calc_required_vram <params_B> <quant> <ctx_size>` echoes minimum GPU VRAM in GB (2 decimal places)
- [ ] Formula: `model_size + kv_cache_size + 1.5` (1.5 GB CUDA runtime overhead)
- [ ] `vast_calc_required_vram 7 Q4_K_M 32768` → `7.42`
- [ ] `vast_calc_required_vram 17 Q4_K_M 131072` → `28.41`
- [ ] `vast_calc_required_vram 70 Q4_K_M 32768` → `60.70`

### AC5: Disk Requirement Calculator

- [ ] `vast_calc_required_disk <model_file_size_gb>` echoes minimum disk in GB (2 decimal places)
- [ ] Formula: `model_file_size × 2.5` (covers OS ~5GB, build ~2GB, model, temp headroom)
- [ ] `vast_calc_required_disk 4.2` → `10.50`
- [ ] `vast_calc_required_disk 42.0` → `105.00`
- [ ] Accepts floating point — uses `bc` for arithmetic

### AC6: DLPerf Value Score Calculator

- [ ] `vast_calc_dlperf_per_dollar <dlperf> <dph_total>` echoes the value score (2 decimal places)
- [ ] Formula: `dlperf / dph_total`
- [ ] `vast_calc_dlperf_per_dollar 100 0.26` → `384.61`
- [ ] `vast_calc_dlperf_per_dollar 125 0.40` → `312.50`
- [ ] Division by zero returns error to stderr, exit 1

### AC7: Integration — Library Is Sourceable by Test Harness

- [ ] `source shared/lib/vast-sizing.sh` from a test script produces no stdout, no stderr, exit 0
- [ ] After sourcing, all 5 functions are available
- [ ] After sourcing, all 3 associative arrays are populated

---

## Technical Notes

**Why `bc` not pure bash:** KV cache and disk calculations need floating point. bash can't do `32768 × 7 × 75 / 10000000` natively. Use `bc` with `scale=2` throughout. `bc` is available on all target platforms (Linux/macOS/WSL).

**Why `echo` not `printf` for function output:** The functions are designed for command substitution: `model_gb=$(vast_calc_model_size 7 Q4_K_M)`. `echo` is acceptable here since we control the output format. Errors go to stderr so they don't contaminate substitution.

**Cross-reference with GPU reference table:** The existing skill `vast-ai-llama-cpp-provisioning` has `references/gpu-reference.md` which contains the canonical GPU↔arch↔VRAM mapping. The library encodes a SUBSET of that table (the GPUs available on Vast.ai). The skill doc remains the source of truth for addition — update both if adding a new GPU.

**Library guard pattern:** Follow `logging.sh` and `validation.sh` conventions:
```bash
if [[ -n "${LINUS_VAST_SIZING_LOADED:-}" ]]; then
    return 0
fi
LINUS_VAST_SIZING_LOADED=1
```

**No bash 4.3+ features:** Use `declare -A` for associative arrays (requires bash 4.0+). Do not use namerefs (`declare -n`, bash 4.3+) or other newer features.

**Edge cases to handle:**
- Unknown quantization → stderr: `"ERROR: Unknown quantization 'Q9_X'. Valid: Q2_K Q3_K_M Q4_K_M Q5_K_M Q8_0"`, exit 1
- Non-numeric input → stderr: `"ERROR: Expected numeric value, got 'abc'"`, exit 1
- Division by zero (dph_total=0) → stderr: `"ERROR: dph_total cannot be zero"`, exit 1

---

## Definition of Done

- [ ] All 7 AC sections with all checkboxes passing
- [ ] `bash -n shared/lib/vast-sizing.sh` clean
- [ ] Unit tests (`tests/unit/test-vast-sizing.sh`) all passing
- [ ] Library sources cleanly (zero stdout/stderr, exit 0)
- [ ] Smoke test list in `tests/smoke/test-all-scripts.sh` updated to include `shared/lib/vast-sizing.sh`
