#!/usr/bin/env bash
# =============================================================================
# Quality Gate Helpers — Vast.ai GPU Provider Specific
# =============================================================================
# Vast-specific quality checks: build watch, fatal build pattern detection.
# Sources the shared quality-gate.sh for base gates + LLM judge.
#
# Source in Vast bootstrap scripts:
#   source "${SCRIPT_DIR}/../lib/quality-gate.sh"
#   source "${SCRIPT_DIR}/../lib/quality-gate-vast.sh"
# =============================================================================

# ─── Fatal Build Pattern Detection (P2.6) ─────────────────────────

# Checks onstart.log for fatal build errors that mean the build is
# dead and we should abort immediately rather than waiting 900s.
#
# Args: onstart_log_tail (string)
# Returns: 0 if no fatal patterns found, 1 if fatal pattern detected
_linus_check_fatal_build_errors() {
    local log_tail="$1"
    local log_lower
    log_lower=$(echo "$log_tail" | tr '[:upper:]' '[:lower:]')

    # Fatal patterns that mean the build is dead
    local fatal_patterns=(
        "cmake error"
        "cuda compiler not found"
        "cuda toolkit not found"
        "fatal error"
        "compilation terminated"
        "nvcc fatal"
        "unsupported gpu architecture"
        "error: cuda"
        "no space left on device"
        "cannot create directory"
        "permission denied"
        "build_done"  # Not fatal but means build finished — check for binary
    )

    for pattern in "${fatal_patterns[@]}"; do
        if echo "$log_lower" | grep -qF "$pattern"; then
            if [[ "$pattern" == "build_done" ]]; then
                # BUILD_DONE means build finished — that's not fatal
                continue
            fi
            log_warn "[build] Fatal pattern detected: '${pattern}'"
            _warn_tag "build_fatal_${pattern// /_}"
            return 1
        fi
    done

    return 0
}

# ─── Non-Deterministic LLM Build Watch (TP2) ──────────────────────

# Uses a 2B model to decide whether to keep waiting or abort during
# the build watch loop. More nuanced than fatal pattern detection —
# can recognize slow-but-progressing vs truly-stalled.
#
# Args: elapsed_seconds, build_active_status, onstart_log_tail
# Returns: "WAIT" or "ABORT:<reason>" on stdout
_linus_llm_build_watch() {
    local elapsed="$1"
    local build_status="$2"
    local log_tail="$3"
    local llm_eval
    llm_eval="${SCRIPT_DIR}/../lib/llm-eval.py"

    if [[ ! -f "$llm_eval" ]]; then
        # Deterministic fallback
        if ! _linus_check_fatal_build_errors "$log_tail"; then
            echo "ABORT:fatal_pattern"
        else
            echo "WAIT"
        fi
        return
    fi

    local prompt
    prompt=$(cat <<EOF
Build status at ${elapsed}s of 900s timeout:
- Build processes: ${build_status}
- Last build output:
${log_tail}

Wait longer or abort?
EOF
)

    local result
    result=$(echo "$prompt" | python3 "$llm_eval" build-watch 2>/dev/null) || true
    echo "${result:-WAIT}"
}
