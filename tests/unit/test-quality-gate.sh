#!/usr/bin/env bash
# =============================================================================
# Linus — Unit Tests: MUSTFIX backlog fixes (P0-1, P0-2, P1-4, P2-6)
# =============================================================================
# Covers the deterministic helpers promoted into shared/lib/quality-gate.sh
# and shared/lib/quality-gate-vast.sh by the MUSTFIX backlog fixes:
#   P0-1  Content-Range size parsing (bytes 0-0/TOTAL)
#   P0-2  5-gram semantic degeneration gate in _linus_run_quality_gates
#   P1-4  _linus_cost_summary math
#   P2-6  fatal build pattern detection
# No live Vast.ai / GPU instance required.
# =============================================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
TOTAL=0; PASSED=0; FAILED=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

test_ok()  { ((TOTAL++)); ((PASSED++)); echo -e "  ${GREEN}✓${NC} $1"; }
test_fail() { ((TOTAL++)); ((FAILED++)); echo -e "  ${RED}✗${NC} $1 — $2"; }

echo "=========================================="
echo "Linus — Unit Tests: quality gate (MUSTFIX)"
echo "=========================================="
echo ""

# --- Stubs for logging dependencies (quality-gate.sh calls log_*) ---
log_info()  { :; }
log_warn()  { :; }
log_error() { :; }
_warn_tag() { :; }

source "$REPO_ROOT/shared/lib/quality-gate.sh"
source "$REPO_ROOT/shared/lib/quality-gate-vast.sh"

# ====== P0-1: Content-Range parsing ======
echo -e "${BLUE}P0-1: Content-Range size parsing${NC}"

# Server A: answers Range requests with Content-Range: bytes 0-0/TOTAL
cat > /tmp/linus_range_server.py <<'PYEOF'
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(206)
        self.send_header('Content-Range', 'bytes 0-0/1879048192')
        self.send_header('Content-Length', '1')
        self.end_headers()
        self.wfile.write(b'x')
    def log_message(self, *a):
        pass
HTTPServer(('127.0.0.1', 18765), H).serve_forever()
PYEOF
python3 /tmp/linus_range_server.py & SRV_A=$!
sleep 1

SIZE_A="$(_linus_get_model_size_bytes "http://127.0.0.1:18765/model.gguf")"
kill "$SRV_A" 2>/dev/null || true

[[ "$SIZE_A" == "1879048192" ]] \
    && test_ok "Content-Range 'bytes 0-0/1879048192' parsed to 1879048192" \
    || test_fail "Content-Range parse" "got '${SIZE_A}'"

# Server B: plain static file server (Content-Length only, no Range support)
mkdir -p /tmp/linus_static
head -c 1234567 /dev/zero > /tmp/linus_static/model.gguf
python3 -m http.server 18766 --directory /tmp/linus_static >/dev/null 2>&1 & SRV_B=$!
sleep 1

SIZE_B="$(_linus_get_model_size_bytes "http://127.0.0.1:18766/model.gguf")"
kill "$SRV_B" 2>/dev/null || true
rm -rf /tmp/linus_static /tmp/linus_range_server.py

[[ "$SIZE_B" == "1234567" ]] \
    && test_ok "Content-Length fallback parsed to 1234567" \
    || test_fail "Content-Length fallback" "got '${SIZE_B}'"

SIZE_C="$(_linus_get_model_size_bytes "http://127.0.0.1:9/unreachable")"
[[ "$SIZE_C" == "0" ]] \
    && test_ok "Unreachable URL returns 0 (not a crash)" \
    || test_fail "Unreachable URL" "got '${SIZE_C}'"

echo ""

# ====== P0-2: 5-gram semantic degeneration gate ======
echo -e "${BLUE}P0-2: 5-gram degeneration gate${NC}"

DEGENERATE="$(printf '.card-row %.0s' $(seq 1 60))"
if _linus_run_quality_gates "$DEGENERATE" >/dev/null 2>&1; then
    test_fail "Degenerate '.card-row' x60 rejected" "gates passed (exit 0)"
else
    test_ok "Degenerate '.card-row' repetition rejected (exit 8)"
fi

GOOD="The quick brown fox jumps over the lazy dog near the river bank today."
if _linus_run_quality_gates "$GOOD" >/dev/null 2>&1; then
    test_ok "Normal sentence passes quality gates"
else
    test_fail "Normal sentence passes" "gates rejected good content"
fi

if _linus_run_quality_gates "   " >/dev/null 2>&1; then
    test_fail "Whitespace-only output rejected" "gates passed (exit 0)"
else
    test_ok "Whitespace-only output rejected (exit 8)"
fi

GARBAGE_SLASH="//////////////////////////////////// no real answer"
if _linus_run_quality_gates "$GARBAGE_SLASH" >/dev/null 2>&1; then
    test_fail "Slash-dominated output rejected" "gates passed (exit 0)"
else
    test_ok "Slash-dominated output rejected (exit 8)"
fi

echo ""

# ====== P1-4: Cost summary ======
echo -e "${BLUE}P1-4: LINUS_COST summary${NC}"

COST="$(_linus_cost_summary "0.50" 3600)"
[[ "$COST" == "COST:total_usd=0.5,instance_price=0.50,wall_time_s=3600" ]] \
    && test_ok "1h @ \$0.50/hr → total_usd=0.5" \
    || test_fail "Cost math (1h @ 0.50)" "got '${COST}'"

COST2="$(_linus_cost_summary "0.25" 1800)"
[[ "$COST2" == "COST:total_usd=0.125,instance_price=0.25,wall_time_s=1800" ]] \
    && test_ok "30m @ \$0.25/hr → total_usd=0.125" \
    || test_fail "Cost math (30m @ 0.25)" "got '${COST2}'"

COST3="$(_linus_cost_summary "" 600)"
[[ "$COST3" == "COST:wall_time_s=600" ]] \
    && test_ok "Unknown price → wall_time only" \
    || test_fail "Cost with unknown price" "got '${COST3}'"

echo ""

# ====== P2-6: Fatal build patterns ======
echo -e "${BLUE}P2-6: Fatal build pattern detection${NC}"

FATAL_LOG="-- Configuring done
-- Generating done
CMake Error at CMakeLists.txt:42 (message):
  CUDA architecture 999 not supported
error: no kernel image is available"

if _linus_check_fatal_build_errors "$FATAL_LOG"; then
    test_fail "CUDA arch failure detected as fatal" "returned 0 (not fatal)"
else
    test_ok "CUDA arch failure detected as fatal (return 1)"
fi

BUILDING_LOG="-- The CXX compiler identification is GNU 11.4.0
[ 12%] Building CXX object src/CMakeFiles/llama.dir/main.cpp.o
[ 25%] Building CXX object src/CMakeFiles/llama.dir/model.cpp.o
Linking CXX executable llama-server"

if _linus_check_fatal_build_errors "$BUILDING_LOG"; then
    test_ok "Clean build log passes (return 0)"
else
    test_fail "Clean build log passes" "flagged healthy build as fatal"
fi

DISK_LOG="cp: write error: No space left on device"
if _linus_check_fatal_build_errors "$DISK_LOG"; then
    test_fail "Disk-full detected as fatal" "returned 0 (not fatal)"
else
    test_ok "Disk-full detected as fatal (return 1)"
fi

echo ""

echo "=========================================="
echo -e "Results: ${PASSED}/${TOTAL} passed, ${FAILED} failed"
echo "=========================================="

[[ $FAILED -eq 0 ]] || exit 1
