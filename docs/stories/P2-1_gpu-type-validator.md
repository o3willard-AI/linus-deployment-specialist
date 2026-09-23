# Story P2-1: GPU Type Validator

**Priority:** P0 (needed by vast.sh provision script)
**Estimate:** 0.5 day
**Phase:** Phase 2 — Vast Provider Foundation
**Depends on:** P1-1 (vast-sizing.sh library)

---

## User Story

As the **Vast provisioner script (`vast.sh`)**
I want a `validate_gpu_type()` function that maps a GPU model name to its CUDA architecture flag
So that I can verify the user's GPU choice is valid and auto-derive the correct `-DCMAKE_CUDA_ARCHITECTURES` flag

---

## Acceptance Criteria

### AC1: Function signature and behavior

- [ ] Added to `shared/lib/validation.sh` (appended before final line)
- [ ] `validate_gpu_type <gpu_name>` returns 0 for known GPUs, 1 for unknown
- [ ] Known GPUs include all entries in `GPU_ARCH` from `vast-sizing.sh`: RTX_3090, RTX_4090, A5000, V100_16GB, V100_32GB, A6000, L40S, A100_40GB, A100_80GB, H100
- [ ] Unknown GPU name → `log_error "Unknown GPU: $gpu_name"` then return 1
- [ ] Empty string → return 1 with appropriate error

### AC2: Architecture flag output

- [ ] `validate_gpu_type RTX_3090` echoes `86` to stdout
- [ ] `validate_gpu_type RTX_4090` echoes `89`
- [ ] `validate_gpu_type H100` echoes `90`
- [ ] `validate_gpu_type V100_16GB` echoes `70`
- [ ] `validate_gpu_type GTX_1080` returns 1, no stdout (or error on stderr only)

### AC3: Integration with vast-sizing.sh

- [ ] Function sources `vast-sizing.sh` using relative path from validation.sh location
- [ ] Does NOT duplicate the GPU_ARCH table — reads from the sourced array
- [ ] Works when validation.sh is sourced from any script in the project (uses SCRIPT_DIR pattern)

### AC4: Non-breaking

- [ ] Existing smoke tests pass: `bash tests/smoke/test-all-scripts.sh`
- [ ] Function does not execute on source — only when called
- [ ] No side effects when validation.sh is sourced

---

## Technical Notes

**Pattern to follow:** The existing `validate_os()` function at line 154 of validation.sh uses a `case` statement. Follow the same pattern but use the `GPU_ARCH` associative array from vast-sizing.sh instead of a hardcoded case.

**Sourcing vast-sizing.sh:** Use the same relative-path pattern as other lib files:
```bash
_VALIDATION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_VALIDATION_LIB_DIR}/vast-sizing.sh"
```

**DO NOT** duplicate the GPU_ARCH table. The single source of truth is in vast-sizing.sh.

**Placement:** Append to end of validation.sh, before any closing guards.

---

## Definition of Done

- [ ] All 4 AC sections passing
- [ ] `bash -n shared/lib/validation.sh` clean
- [ ] `bash tests/unit/test-vast-validation.sh` all passing
- [ ] `bash tests/smoke/test-all-scripts.sh` all passing (29 scripts, no regressions)
- [ ] Committed to `feat/vast-sizing-library` branch
