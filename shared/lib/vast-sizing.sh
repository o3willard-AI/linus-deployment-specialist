#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist — Vast GPU Sizing Calculus Library
# =============================================================================
# Purpose: Deterministic sizing formulas for Vast.ai GPU offer selection.
#   Computes model size, KV cache, VRAM requirements, disk requirements,
#   and DLPerf-per-dollar value scores from model parameters.
#
# Source this file in Vast provider scripts:
#   source "$SCRIPT_DIR/../lib/vast-sizing.sh"
#
# All functions use bc for floating-point arithmetic (scale=2).
# Output to stdout, errors to stderr, exit codes for parseability.
#
# GPU reference data sourced from the vast-ai-llama-cpp-provisioning skill
# (references/gpu-reference.md). Update both when adding new GPUs.
# =============================================================================

# Library guard — prevent double-sourcing
if [[ -n "${LINUS_VAST_SIZING_LOADED:-}" ]]; then
    return 0
fi
LINUS_VAST_SIZING_LOADED=1

# -----------------------------------------------------------------------------
# GPU Reference Tables
# -----------------------------------------------------------------------------

# GPU model → VRAM in GB
declare -A GPU_VRAM=(
    [RTX_3090]=24
    [RTX_4090]=24
    [A5000]=24
    [V100_16GB]=16
    [V100_32GB]=32
    [A6000]=48
    [L40S]=48
    [A100_40GB]=40
    [A100_80GB]=80
    [H100]=80
)

# GPU model → CUDA architecture flag (for -DCMAKE_CUDA_ARCHITECTURES)
declare -A GPU_ARCH=(
    [RTX_3090]=86
    [RTX_4090]=89
    [A5000]=86
    [V100_16GB]=70
    [V100_32GB]=70
    [A6000]=86
    [L40S]=89
    [A100_40GB]=80
    [A100_80GB]=80
    [H100]=90
)

# Quantization → model size multiplier (GB per 1B params)
declare -A QUANT_FACTORS=(
    [Q2_K]=0.4
    [Q3_K_M]=0.5
    [Q4_K_M]=0.6
    [Q5_K_M]=0.7
    [Q8_0]=0.95
)

# -----------------------------------------------------------------------------
# Sizing Functions
# -----------------------------------------------------------------------------

# vast_calc_model_size <params_B> <quant>
#   Computes GGUF model file size in GB.
#   params_B: model parameter count in billions (e.g., 7, 14, 70)
#   quant:    quantization level (Q2_K, Q3_K_M, Q4_K_M, Q5_K_M, Q8_0)
#   Output:   model size in GB (2 decimal places) to stdout
#   Errors:   unknown quantization → stderr, exit 1
vast_calc_model_size() {
    local params_B="$1"
    local quant="$2"

    local factor="${QUANT_FACTORS[$quant]:-}"
    if [[ -z "$factor" ]]; then
        echo "ERROR: Unknown quantization '${quant}'. Valid: Q2_K Q3_K_M Q4_K_M Q5_K_M Q8_0" >&2
        return 1
    fi

    bc <<< "scale=6; ${params_B} * ${factor}" | xargs printf "%.2f"
}

# vast_calc_kv_cache <ctx_size> <params_B>
#   Computes approximate KV cache size in GB.
#   Formula: ctx_size × params_B × 75 / 10_000_000
#   Matches the GPU reference table to within 3%.
#   ctx_size: context window size in tokens (e.g., 32768, 131072)
#   params_B: model parameter count in billions
#   Output:   KV cache size in GB (2 decimal places) to stdout
#   Errors:   non-numeric input → stderr, exit 1
vast_calc_kv_cache() {
    local ctx_size="$1"
    local params_B="$2"

    # Validate numeric input
    if ! [[ "$ctx_size" =~ ^[0-9]+$ ]] || ! [[ "$params_B" =~ ^[0-9]+$ ]]; then
        echo "ERROR: Expected numeric values, got ctx_size='${ctx_size}' params_B='${params_B}'" >&2
        return 1
    fi

    bc <<< "scale=6; ${ctx_size} * ${params_B} * 75 / 10000000" | xargs printf "%.2f"
}

# vast_calc_required_vram <params_B> <quant> <ctx_size>
#   Computes minimum GPU VRAM needed for model + KV cache + overhead.
#   Formula: model_size + kv_cache + 1.5 (CUDA runtime overhead)
#   params_B: model parameter count in billions
#   quant:    quantization level
#   ctx_size: context window size in tokens
#   Output:   required VRAM in GB (2 decimal places) to stdout
#   Errors:   unknown quantization or non-numeric → stderr, exit 1
vast_calc_required_vram() {
    local params_B="$1"
    local quant="$2"
    local ctx_size="$3"

    local model_gb
    model_gb=$(vast_calc_model_size "$params_B" "$quant") || return 1

    local kv_gb
    kv_gb=$(vast_calc_kv_cache "$ctx_size" "$params_B") || return 1

    bc <<< "scale=6; ${model_gb} + ${kv_gb} + 1.5" | xargs printf "%.2f"
}

# vast_calc_required_disk <model_file_size_gb>
#   Computes minimum disk space needed for model + OS + build + headroom.
#   Formula: model_file_size × 2.5
#   Breakdown: model + OS(~5GB) + build(~2GB) + temp headroom(0.5×model)
#   model_file_size_gb: GGUF file size in GB (floating point OK)
#   Output:   required disk in GB (2 decimal places) to stdout
#   Errors:   non-numeric input → stderr, exit 1
vast_calc_required_disk() {
    local model_gb="$1"

    # Validate numeric (floating point OK)
    if ! [[ "$model_gb" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "ERROR: Expected numeric value, got '${model_gb}'" >&2
        return 1
    fi

    bc <<< "scale=6; ${model_gb} * 2.5" | xargs printf "%.2f"
}

# vast_calc_dlperf_per_dollar <dlperf> <dph_total>
#   Computes DLPerf-per-dollar value score for offer comparison.
#   Higher = better value (more performance per dollar).
#   Formula: dlperf / dph_total
#   dlperf:    Vast.ai normalized deep learning performance score
#   dph_total: total dollars per hour (including storage/network fees)
#   Output:    value score (2 decimal places) to stdout
#   Errors:    dph_total is zero → stderr, exit 1
vast_calc_dlperf_per_dollar() {
    local dlperf="$1"
    local dph_total="$2"

    # Guard against division by zero
    if [[ "$(bc <<< "${dph_total} == 0")" == "1" ]]; then
        echo "ERROR: dph_total cannot be zero" >&2
        return 1
    fi

    bc <<< "scale=6; ${dlperf} / ${dph_total}" | xargs printf "%.2f"
}
