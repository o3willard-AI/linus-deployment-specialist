#!/usr/bin/env bash
# =============================================================================
# Quality Gate Helpers — shared between download_model and _try_model
# =============================================================================
# Provides deterministic quality checks (Content-Range parsing, disk space,
# 5-gram semantic gate) + non-deterministic LLM evaluation touch points.
#
# Source this in bootstrap scripts:
#   source "${SCRIPT_DIR}/../lib/quality-gate.sh"
# =============================================================================

# ─── Content-Range Size Parsing (P0.1 fix) ───────────────────────

# Fetches the actual file size from HuggingFace via Range request.
# Uses Python for robust header parsing (handles content-range AND
# content-length headers, trims CR/LF, extracts total after '/').
#
# Args: model_url
# Returns: size in bytes (or 0 if undetermined)
_linus_get_model_size_bytes() {
    local url="$1"
    python3 -c "
import urllib.request, sys
req = urllib.request.Request('${url}')
req.add_header('Range', 'bytes=0-0')
try:
    resp = urllib.request.urlopen(req, timeout=15)
    # Try Content-Range: 'bytes 0-0/TOTAL'
    cr = resp.headers.get('Content-Range', '') or resp.headers.get('content-range', '')
    if cr and '/' in cr:
        total = cr.rsplit('/', 1)[-1].strip()
        if total.isdigit():
            print(total)
            sys.exit(0)
    # Fallback: Content-Length
    cl = resp.headers.get('Content-Length', '') or resp.headers.get('content-length', '')
    if cl and cl.strip().isdigit():
        print(cl.strip())
        sys.exit(0)
    print('0')
except Exception as e:
    print('0', file=sys.stderr)
    print('0')
" 2>/dev/null
}

# ─── Disk Space Check ─────────────────────────────────────────────

# Checks if the instance has enough disk for the model download.
# Args: ssh_cmd, workspace_path, model_size_bytes
# Returns: 0 if OK, 1 if insufficient
_linus_check_disk_space() {
    local ssh_cmd="$1"
    local workspace="$2"
    local total_bytes="$3"

    if [[ "$total_bytes" -le 0 ]]; then
        log_warn "Model size is 0 bytes — skipping disk space check"
        return 0
    fi

    local disk_free
    # Use python3 to parse df output — avoids awk $4 expansion under set -u
    disk_free=$(eval "$ssh_cmd \"df -BG ${workspace} 2>/dev/null | python3 -c 'import sys; lines=[l.split() for l in sys.stdin if l.strip()]; print(lines[-1][3].rstrip(\\\"G\\\")) if len(lines)>0 and len(lines[-1])>3 else print(0)'\"") || disk_free=0

    if [[ "$disk_free" -le 0 ]]; then
        log_warn "Could not determine free disk space — proceeding anyway"
        return 0
    fi

    local needed_gb
    needed_gb=$(python3 -c "import math; print(math.ceil(${total_bytes} * 1.2 / 1073741824))" 2>/dev/null) || needed_gb=0

    if [[ "$needed_gb" -gt 0 && "$disk_free" -lt "$needed_gb" ]]; then
        log_error "Insufficient disk space: ${disk_free}GB free, need ~${needed_gb}GB"
        return 1
    fi

    log_info "Disk space OK: ${disk_free}GB free, need ~${needed_gb}GB"
    return 0
}

# ─── 5-Gram Semantic Degeneration Gate (P0.2 fix) ─────────────────

# Detects semantic degeneration (repeating word patterns) that char-level
# checks miss. Returns 0 (PASS) or 8 (FAIL:degeneration).
#
# Args: content_string
# Returns: 0 if quality OK, 8 if degeneration detected
_linus_check_5gram_degeneration() {
    local content="$1"
    local repeat_score

    repeat_score=$(python3 -c "
from collections import Counter
text = '''${content}'''
words = text.split()
if len(words) < 5:
    print(0)
else:
    grams = [' '.join(words[i:i+5]) for i in range(len(words)-4)]
    top_count = Counter(grams).most_common(1)[0][1] if grams else 0
    print(top_count)
" 2>/dev/null) || repeat_score=0

    if [[ "$repeat_score" -gt 10 ]]; then
        log_error "[quality] 5-gram semantic degeneration detected (max repeat: ${repeat_score}, threshold: 10)"
        return 8
    fi
    return 0
}

# ─── Combined Quality Gates ───────────────────────────────────────

# Runs all quality gates (char-level + semantic) on model output.
# Called by verify_inference() and _try_model().
#
# Args: content_string
# Returns: 0 if all gates PASS, 8 if any gate fails
_linus_run_quality_gates() {
    local content="$1"
    local total_chars=${#content}

    # Gate 0: Empty check
    if [[ -z "${content//[[:space:]]/}" ]]; then
        log_error "[quality] Model produced whitespace-only output"
        return 8
    fi

    # Gate 1: Slash character ratio (catch Qwen3.6-style / garbage)
    local slash_count
    slash_count=$(echo "$content" | tr -cd '/' | wc -c)
    local slash_ratio=$(( slash_count * 100 / total_chars ))
    if [[ $slash_ratio -gt 50 ]]; then
        log_error "[quality] Model producing garbage: ${slash_ratio}% slash characters (threshold: 50%)"
        log_error "[quality] Content sample: ${content:0:200}"
        return 8
    fi

    # Gate 2: Single-character dominance (catch repeated-char nonsense)
    local max_char_count
    max_char_count=$(echo "$content" | fold -w1 | sort | uniq -c | sort -rn | head -1 | awk '{print $1}')
    local max_char_pct=$(( max_char_count * 100 / total_chars ))
    if [[ $max_char_pct -gt 80 ]]; then
        log_error "[quality] Single character dominates ${max_char_pct}% of output (threshold: 80%)"
        log_error "[quality] Content sample: ${content:0:200}"
        return 8
    fi

    # Gate 3: 5-gram semantic degeneration (P0.2 — new)
    if ! _linus_check_5gram_degeneration "$content"; then
        log_error "[quality] Content sample: ${content:0:200}"
        return 8
    fi

    return 0
}

# ─── Non-Deterministic LLM Quality Judge (TP3) ────────────────────

# Uses a 2B model to evaluate semantic quality beyond what deterministic
# gates can catch — catches subtle incoherence, hallucinated content,
# and borderline cases where char-level checks pass but output is bad.
#
# Args: content_string
# Returns: 0 if LLM says PASS, 8 if LLM says FAIL
_linus_llm_quality_judge() {
    local content="$1"
    local llm_eval
    llm_eval="${SCRIPT_DIR}/../lib/llm-eval.py"

    if [[ ! -f "$llm_eval" ]]; then
        log_warn "[llm-eval] llm-eval.py not found — skipping LLM quality judge"
        return 0
    fi

    local result
    result=$(echo "$content" | python3 "$llm_eval" quality-judge 2>/dev/null) || true

    if [[ "$result" == PASS ]]; then
        log_info "[llm-eval] Quality judge: PASS"
        return 0
    elif [[ "$result" == FAIL:* ]]; then
        local reason="${result#FAIL:}"
        log_error "[llm-eval] Quality judge: FAIL (reason: ${reason})"
        return 8
    else
        log_warn "[llm-eval] Quality judge returned unexpected: '${result}' — allowing"
        return 0
    fi
}

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
