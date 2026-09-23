#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist — llama.cpp Benchmark Script
# =============================================================================
# Purpose: Measure tokens/second and time-to-first-token for a llama.cpp server.
#   Helps determine appropriate timeouts and compare model speeds.
#
# Required Environment Variables:
#   BENCH_URL     — Chat completions endpoint
#                   (e.g., http://192.168.101.21:1234/v1/chat/completions)
#
# Optional Environment Variables (all have defaults):
#   BENCH_API_KEY      — API key (default: none)
#   BENCH_PROMPT_TOKENS — Approximate prompt length in tokens (default: 500)
#   BENCH_MAX_TOKENS   — Max tokens to generate (default: 512)
#   BENCH_TEMPERATURE  — Sampling temperature (default: 0)
#   BENCH_RUNS         — Number of benchmark runs (default: 3)
#   BENCH_MODEL        — Model name to pass in request (default: not sent)
#
# Usage:
#   BENCH_URL=http://192.168.101.21:1234/v1/chat/completions ./llama-bench.sh
#
#   # Long context test:
#   BENCH_URL=... BENCH_PROMPT_TOKENS=4000 BENCH_MAX_TOKENS=1024 ./llama-bench.sh
#
# Exit Codes:
#   0 — Success
#   1 — General error
#   2 — Missing dependencies (curl, python3, bc)
#   3 — Invalid configuration (BENCH_URL not set or unreachable)
#   4 — Benchmark failed (no tokens generated)
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib/paths.sh" 2>/dev/null || true
source_lib "logging.sh" "validation.sh" 2>/dev/null || {
    # Fallback if lib not found (standalone use)
    log_info()  { echo "[INFO]  $(date +%H:%M:%S) $*"; }
    log_error() { echo "[ERROR] $(date +%H:%M:%S) $*" >&2; }
    log_step()  { echo "[STEP $1] $(date +%H:%M:%S) $2"; }
    log_success() { echo "[OK]   $(date +%H:%M:%S) $*"; }
    log_warn()  { echo "[WARN] $(date +%H:%M:%S) $*"; }
    log_header() { echo; echo "=== $* ==="; }
    check_dependencies() {
        local missing=()
        for cmd in "$@"; do
            command -v "$cmd" &>/dev/null || missing+=("$cmd")
        done
        if [[ ${#missing[@]} -gt 0 ]]; then
            log_error "Missing dependencies: ${missing[*]}"
            return 2
        fi
        return 0
    }
}

# -----------------------------------------------------------------------------
# Configuration from environment with defaults
# -----------------------------------------------------------------------------

readonly BENCH_URL="${BENCH_URL:-}"
readonly BENCH_API_KEY="${BENCH_API_KEY:-}"
readonly BENCH_PROMPT_TOKENS="${BENCH_PROMPT_TOKENS:-500}"
readonly BENCH_MAX_TOKENS="${BENCH_MAX_TOKENS:-512}"
readonly BENCH_TEMPERATURE="${BENCH_TEMPERATURE:-0}"
readonly BENCH_RUNS="${BENCH_RUNS:-3}"
readonly BENCH_MODEL="${BENCH_MODEL:-}"

# -----------------------------------------------------------------------------
# Function: validate
# -----------------------------------------------------------------------------

validate() {
    log_step "1" "Validating configuration"

    if [[ -z "$BENCH_URL" ]]; then
        log_error "BENCH_URL is required"
        return 3
    fi

    check_dependencies curl python3 bc || return 2

    # Test connectivity
    log_info "Testing connectivity to ${BENCH_URL}..."
    local health_url="${BENCH_URL%/v1/chat/completions}/health"
    if curl -s --connect-timeout 5 "$health_url" 2>/dev/null | grep -q 'ok'; then
        log_info "Health check: OK"
    else
        log_info "Health check: skipped (no /health endpoint or auth required)"
    fi

    log_success "Configuration valid"
    return 0
}

# -----------------------------------------------------------------------------
# Function: generate_prompt
# -----------------------------------------------------------------------------

generate_prompt() {
    local target_tokens="$1"
    
    # Generate a prompt of approximately target_tokens length
    # Use a repeating pattern that tokenizes consistently
    local base="The quick brown fox jumps over the lazy dog. "
    local repeats=$((target_tokens / 7))  # ~7 tokens per sentence
    
    local prompt=""
    for _ in $(seq 1 $repeats); do
        prompt+="$base"
    done
    
    # Add an actual question at the end so the model has something to respond to
    prompt+="\n\nBased on the text above, write a detailed summary of the key themes and patterns. Be thorough."
    
    echo "$prompt"
}

# -----------------------------------------------------------------------------
# Function: run_benchmark
# -----------------------------------------------------------------------------

run_benchmark() {
    local run_num="$1"
    local prompt="$2"
    
    local prompt_chars=${#prompt}
    local prompt_words=$(echo "$prompt" | wc -w)
    
    log_info "Run ${run_num}/${BENCH_RUNS}: prompt=${prompt_chars} chars (~${BENCH_PROMPT_TOKENS} tokens), max_tokens=${BENCH_MAX_TOKENS}"
    
    # Build JSON payload
    local model_json=""
    [[ -n "$BENCH_MODEL" ]] && model_json="\"model\": \"${BENCH_MODEL}\","
    
    local auth_header=""
    [[ -n "$BENCH_API_KEY" ]] && auth_header="-H \"Authorization: Bearer ${BENCH_API_KEY}\""
    
    local payload
    payload=$(cat <<EOF
{
  ${model_json}
  "messages": [{"role": "user", "content": $(echo "$prompt" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))")}],
  "max_tokens": ${BENCH_MAX_TOKENS},
  "temperature": ${BENCH_TEMPERATURE},
  "stream": false
}
EOF
)
    
    # Time the request
    local start_time end_time elapsed_ms ttft_ms total_tokens prompt_tokens tokens_per_sec
    
    start_time=$(python3 -c "import time; print(int(time.time() * 1000))")
    
    local resp
    resp=$(eval "curl -s --max-time 300 ${auth_header} -H 'Content-Type: application/json' -d '${payload}' \"${BENCH_URL}\"" 2>/dev/null) || {
        log_error "Run ${run_num}: curl failed"
        return 4
    }
    
    end_time=$(python3 -c "import time; print(int(time.time() * 1000))")
    elapsed_ms=$((end_time - start_time))
    
    # Parse response
    local content
    content=$(echo "$resp" | python3 -c "
import json, sys
d = json.load(sys.stdin)
c = d['choices'][0]
msg = c['message']
print(json.dumps({
    'content': msg.get('content', ''),
    'reasoning': msg.get('reasoning_content', ''),
    'finish': c.get('finish_reason', '?'),
    'prompt_tokens': d.get('usage', {}).get('prompt_tokens', 0),
    'completion_tokens': d.get('usage', {}).get('completion_tokens', 0),
    'total_tokens': d.get('usage', {}).get('total_tokens', 0),
    'timings': d.get('timings', {}),
}))
" 2>/dev/null) || {
        log_error "Run ${run_num}: failed to parse response"
        log_error "Raw (first 300 chars): ${resp:0:300}"
        return 4
    }
    
    prompt_tokens=$(echo "$content" | python3 -c "import json,sys; print(json.load(sys.stdin)['prompt_tokens'])")
    completion_tokens=$(echo "$content" | python3 -c "import json,sys; print(json.load(sys.stdin)['completion_tokens'])")
    total_tokens=$(echo "$content" | python3 -c "import json,sys; print(json.load(sys.stdin)['total_tokens'])")
    
    # TTFT from server timings if available (use bc for float comparison)
    local server_prompt_ms server_predicted_ms has_timings
    server_prompt_ms=$(echo "$content" | python3 -c "import json,sys; print(json.load(sys.stdin)['timings'].get('prompt_ms', 0))" 2>/dev/null || echo 0)
    server_predicted_ms=$(echo "$content" | python3 -c "import json,sys; print(json.load(sys.stdin)['timings'].get('predicted_ms', 0))" 2>/dev/null || echo 0)
    
    has_timings=$(echo "$server_prompt_ms > 0" | bc -l 2>/dev/null || echo 0)
    if [[ "$has_timings" == "1" ]]; then
        ttft_ms=$(printf "%.0f" "$server_prompt_ms")
        if [[ "$completion_tokens" -gt 0 ]]; then
            tokens_per_sec=$(echo "scale=1; ${completion_tokens} / (${server_predicted_ms} / 1000)" | bc -l 2>/dev/null || echo "?")
        else
            tokens_per_sec="?"
        fi
    else
        ttft_ms="?"
        if [[ "$completion_tokens" -gt 0 ]]; then
            tokens_per_sec=$(echo "scale=1; ${completion_tokens} / (${elapsed_ms} / 1000)" | bc -l 2>/dev/null || echo "?")
        else
            tokens_per_sec="?"
        fi
    fi
    
    # Show snippet
    local snippet
    snippet=$(echo "$content" | python3 -c "import json,sys; print(json.load(sys.stdin)['content'][:80])" 2>/dev/null || echo "")
    
    printf "    prompt_tok=%-6s comp_tok=%-6s elapsed=%-6s ms ttft=%-6s ms tok/s=%-8s | %s...\n" \
        "$prompt_tokens" "$completion_tokens" "$elapsed_ms" "$ttft_ms" "$tokens_per_sec" "$snippet"
    
    # Return results as JSON line
    echo "$content" | python3 -c "
import json, sys
d = json.load(sys.stdin)
t = d['timings']
print(json.dumps({
    'run': ${run_num},
    'prompt_tokens': d['prompt_tokens'],
    'completion_tokens': d['completion_tokens'],
    'total_tokens': d['total_tokens'],
    'ttft_ms': t.get('prompt_ms', 0),
    'generation_ms': t.get('predicted_ms', 0),
    'wall_ms': ${elapsed_ms},
    'tok_per_sec': ${tokens_per_sec:-0},
}))
"
    return 0
}

# -----------------------------------------------------------------------------
# Function: print_summary
# -----------------------------------------------------------------------------

print_summary() {
    local results="$1"
    
    echo
    printf '=%.0s' {1..60}
    echo
    echo "  LLAMA.CPP BENCHMARK RESULTS"
    printf '=%.0s' {1..60}
    echo
    
    # Compute aggregates
    echo "$results" | python3 -c "
import json, sys

lines = [line.strip() for line in sys.stdin if line.strip()]
runs = []
for line in lines:
    try:
        runs.append(json.loads(line))
    except json.JSONDecodeError:
        pass  # skip non-JSON lines

n = len(runs)

if n == 0:
    print('  No valid runs')
    sys.exit(0)

# Compute stats
prompt_tokens = [r['prompt_tokens'] for r in runs]
comp_tokens = [r['completion_tokens'] for r in runs]
ttfts = [r['ttft_ms'] for r in runs if r['ttft_ms'] > 0]
gen_ms = [r['generation_ms'] for r in runs if r['generation_ms'] > 0]
tps = [r['tok_per_sec'] for r in runs if r['tok_per_sec'] > 0]
walls = [r['wall_ms'] for r in runs]

def avg(lst): return sum(lst) / len(lst) if lst else 0
def pct(lst, p): 
    s = sorted(lst)
    idx = int(len(s) * p / 100)
    return s[min(idx, len(s)-1)] if s else 0

print()
print(f'  Runs:                {n}')
print(f'  Prompt tokens/run:   {avg(prompt_tokens):.0f}')
print(f'  Completion tokens:   {avg(comp_tokens):.0f}')
print()

if ttfts:
    print(f'  Time to First Token:')
    print(f'    Avg:  {avg(ttfts):.0f} ms')
    print(f'    P50:  {pct(ttfts, 50):.0f} ms')
    print(f'    P95:  {pct(ttfts, 95):.0f} ms')
    print()

if tps:
    print(f'  Tokens per Second:')
    print(f'    Avg:  {avg(tps):.1f} tok/s')
    print(f'    P50:  {pct(tps, 50):.1f} tok/s')
    print(f'    P95:  {pct(tps, 95):.1f} tok/s')
    print()

if walls:
    print(f'  Wall clock (total req):')
    print(f'    Avg:  {avg(walls):.0f} ms ({avg(walls)/1000:.1f}s)')
    print(f'    P50:  {pct(walls, 50):.0f} ms')
    print()

# Timeout recommendation
if tps and comp_tokens:
    avg_tps = avg(tps)
    avg_comp = avg(comp_tokens)
    # For a typical agent task with 4096 output tokens
    typical_4096 = 4096 / avg_tps if avg_tps > 0 else 0
    # For a large task with 8192 output tokens
    large_8192 = 8192 / avg_tps if avg_tps > 0 else 0
    
    print(f'  Timeout recommendations:')
    print(f'    4K output tokens:  ~{typical_4096:.0f}s')
    print(f'    8K output tokens:  ~{large_8192:.0f}s')
    print(f'    Agent timeout:     ~{max(typical_4096 * 3, 120):.0f}s (3x 4K + overhead)')

print()
print(f'  Per-run details:')
for r in runs:
    tps_str = f'{r[\"tok_per_sec\"]:.1f} tok/s' if r['tok_per_sec'] > 0 else 'N/A'
    ttft_str = f'{r[\"ttft_ms\"]:.0f}ms' if r['ttft_ms'] > 0 else 'N/A'
    print(f'    Run {r[\"run\"]}: prompt={r[\"prompt_tokens\"]} comp={r[\"completion_tokens\"]} ttft={ttft_str} tps={tps_str} wall={r[\"wall_ms\"]}ms')
" 2>&1
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    log_header "llama.cpp Benchmark"
    
    validate || exit $?
    
    log_step "2" "Generating prompt (~${BENCH_PROMPT_TOKENS} tokens)"
    local prompt
    prompt=$(generate_prompt "$BENCH_PROMPT_TOKENS")
    log_info "Prompt: $(echo "$prompt" | wc -w) words, $(echo "$prompt" | wc -c) chars"
    
    log_step "3" "Running ${BENCH_RUNS} benchmark(s)"
    echo
    
    local results=""
    for run in $(seq 1 "$BENCH_RUNS"); do
        local result
        if result=$(run_benchmark "$run" "$prompt"); then
            results+="$result"$'\n'
        else
            log_warn "Run ${run} failed — skipping in summary"
        fi
        
        # Brief pause between runs
        [[ "$run" -lt "$BENCH_RUNS" ]] && sleep 2
    done
    
    print_summary "$results"
    
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
