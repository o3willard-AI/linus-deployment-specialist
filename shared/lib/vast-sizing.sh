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
    [RTX_A6000]=48
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
    [RTX_A6000]=86
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

# KV cache quantization → memory multiplier (relative to f16 baseline)
# f16 = 2 bytes/element, q8_0 = 1 byte/element (+scale overhead), q4_0 = 0.5 byte/element
declare -A KV_CACHE_MULTIPLIERS=(
    [f16]=1.00
    [q8_0]=0.55
    [q4_0]=0.30
)

# Valid cache types for validation
readonly VALID_CACHE_TYPES="f16 q8_0 q4_0"

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

# vast_calc_kv_cache <ctx_size> <params_B> [cache_type]
#   Computes approximate KV cache size in GB, adjusted for cache quantization.
#   Formula (f16 baseline): ctx_size × params_B × 75 / 10_000_000
#   For q8_0/q4_0 the result is scaled by the KV_CACHE_MULTIPLIERS table.
#   ctx_size:  context window size in tokens (e.g., 32768, 131072)
#   params_B:  model parameter count in billions
#   cache_type: f16 (default), q8_0, or q4_0
#   Output:    KV cache size in GB (2 decimal places) to stdout
#   Errors:    non-numeric input or invalid cache_type → stderr, exit 1
vast_calc_kv_cache() {
    local ctx_size="$1"
    local params_B="$2"
    local cache_type="${3:-f16}"

    # Validate numeric input
    if ! [[ "$ctx_size" =~ ^[0-9]+$ ]] || ! [[ "$params_B" =~ ^[0-9]+$ ]]; then
        echo "ERROR: Expected numeric values, got ctx_size='${ctx_size}' params_B='${params_B}'" >&2
        return 1
    fi

    # Validate cache type
    local multiplier="${KV_CACHE_MULTIPLIERS[$cache_type]:-}"
    if [[ -z "$multiplier" ]]; then
        echo "ERROR: Unknown cache type '${cache_type}'. Valid: ${VALID_CACHE_TYPES}" >&2
        return 1
    fi

    bc <<< "scale=6; ${ctx_size} * ${params_B} * 75 / 10000000 * ${multiplier}" | xargs printf "%.2f"
}

# vast_calc_required_vram <params_B> <quant> <ctx_size> [cache_type_k] [cache_type_v]
#   Computes minimum GPU VRAM needed for model + KV cache + overhead.
#   Formula: model_size + kv_cache + 1.5 (CUDA runtime overhead)
#   Uses the WORST (largest) cache type for VRAM budgeting when K≠V.
#   params_B:     model parameter count in billions
#   quant:        quantization level
#   ctx_size:     context window size in tokens
#   cache_type_k: KV cache key quantization (default: f16)
#   cache_type_v: KV cache value quantization (default: f16)
#   Output:       required VRAM in GB (2 decimal places) to stdout
#   Errors:       unknown quantization or non-numeric → stderr, exit 1
vast_calc_required_vram() {
    local params_B="$1"
    local quant="$2"
    local ctx_size="$3"
    local cache_type_k="${4:-f16}"
    local cache_type_v="${5:-f16}"

    local model_gb
    model_gb=$(vast_calc_model_size "$params_B" "$quant") || return 1

    # Use the larger of K and V caches for safe VRAM budgeting
    local kv_k_gb kv_v_gb kv_gb
    kv_k_gb=$(vast_calc_kv_cache "$ctx_size" "$params_B" "$cache_type_k") || return 1
    kv_v_gb=$(vast_calc_kv_cache "$ctx_size" "$params_B" "$cache_type_v") || return 1
    kv_gb=$(bc <<< "scale=6; if (${kv_k_gb} > ${kv_v_gb}) ${kv_k_gb} else ${kv_v_gb}" | xargs printf "%.2f")

    bc <<< "scale=6; ${model_gb} + ${kv_gb} + 1.5" | xargs printf "%.2f"
}

# vast_validate_cache_type <cache_type>
#   Validates a cache type string against VALID_CACHE_TYPES.
#   Returns 0 for valid types, 1 for invalid with error to stderr.
vast_validate_cache_type() {
    local cache_type="$1"
    if [[ -z "${KV_CACHE_MULTIPLIERS[$cache_type]:-}" ]]; then
        echo "ERROR: Unknown cache type '${cache_type}'. Valid: ${VALID_CACHE_TYPES}" >&2
        return 1
    fi
    return 0
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
