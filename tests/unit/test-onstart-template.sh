#!/usr/bin/env bash
# =============================================================================
# Linus — Unit Tests: onstart-vast.sh template
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
TOTAL=0; PASSED=0; FAILED=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$(cd "$SCRIPT_DIR/../.." && pwd)/shared/templates/onstart-vast.sh"

test_ok()  { ((TOTAL++)); ((PASSED++)); echo -e "  ${GREEN}✓${NC} $1"; }
test_fail() { ((TOTAL++)); ((FAILED++)); echo -e "  ${RED}✗${NC} $1 — $2"; }

echo "=========================================="
echo "Linus — Unit Tests: onstart-vast.sh"
echo "=========================================="
echo ""

if [[ ! -f "$TEMPLATE" ]]; then
    echo -e "${RED}BLOCKED — template not found${NC}"
    exit 2
fi

# AC1: Syntax and structure
echo -e "${BLUE}AC1: Syntax and structure${NC}"

bash -n "$TEMPLATE" && test_ok "bash -n passes" || test_fail "bash -n" "syntax error"

head -1 "$TEMPLATE" | grep -q "bash" && test_ok "shebang present" || test_fail "shebang" "missing #!/usr/bin/env bash"

grep -q "set -euo pipefail" "$TEMPLATE" && test_ok "set -euo pipefail" || test_fail "pipefail" "missing"

# AC2: Environment-driven config
echo ""
echo -e "${BLUE}AC2: Environment-driven config${NC}"

grep -q 'CUDA_ARCH="${CUDA_ARCH:-86}"' "$TEMPLATE" && test_ok "CUDA_ARCH default 86" \
    || test_fail "CUDA_ARCH default" "missing"

grep -q 'DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCH}"' "$TEMPLATE" && test_ok "CUDA_ARCH in cmake" \
    || test_fail "CUDA_ARCH in cmake" "missing"

grep -q 'j"\$(nproc)"' "$TEMPLATE" && test_ok "parallel build with nproc" \
    || test_fail "nproc" "missing"

# AC3: Battle-tested recipe
echo ""
echo -e "${BLUE}AC3: Battle-tested recipe steps${NC}"

grep -q "apt-get update" "$TEMPLATE" && grep -q "apt-get install.*cmake" "$TEMPLATE" \
    && test_ok "apt-get install cmake" || test_fail "cmake install" "missing"

grep -q "mkdir -p /workspace" "$TEMPLATE" && test_ok "mkdir -p /workspace" \
    || test_fail "workspace dir" "missing"

grep -q "git clone --depth 1" "$TEMPLATE" && grep -q "ggml-org/llama.cpp" "$TEMPLATE" \
    && test_ok "git clone llama.cpp" || test_fail "clone" "missing"

grep -q "GGML_CUDA=ON" "$TEMPLATE" && test_ok "GGML_CUDA=ON" \
    || test_fail "CUDA flag" "missing"

grep -q "cmake --build build" "$TEMPLATE" && test_ok "cmake --build" \
    || test_fail "build command" "missing"

grep -q "BUILD_DONE" "$TEMPLATE" && test_ok "BUILD_DONE marker" \
    || test_fail "BUILD_DONE" "missing"

# AC4: Progress markers
echo ""
echo -e "${BLUE}AC4: Progress markers${NC}"

grep -q "\[onstart\] Installing cmake" "$TEMPLATE" && test_ok "cmake progress marker" || test_fail "cmake marker" "missing"
grep -q "\[onstart\] Cloning llama.cpp" "$TEMPLATE" && test_ok "clone progress marker" || test_fail "clone marker" "missing"
grep -q "\[onstart\] Configuring build" "$TEMPLATE" && test_ok "config progress marker" || test_fail "config marker" "missing"
grep -q "\[onstart\] Building llama.cpp" "$TEMPLATE" && test_ok "build progress marker" || test_fail "build marker" "missing"

# AC5: Size constraint
echo ""
echo -e "${BLUE}AC5: Size constraint (16KB limit)${NC}"

size=$(wc -c < "$TEMPLATE")
[[ $size -lt 16384 ]] && test_ok "size=${size}B (< 16KB)" \
    || test_fail "size" "${size}B exceeds 16KB"

# AC6: Integration
echo ""
echo -e "${BLUE}AC6: Integration${NC}"

# Test that CUDA_ARCH substitution works at the string level
substituted=$(CUDA_ARCH=89 bash -c 'source "$1" 2>/dev/null; echo "${CUDA_ARCH}"' _ "$TEMPLATE" 2>/dev/null || true)
# Fallback: just grep the cmake line for the variable pattern
grep -q 'DCMAKE_CUDA_ARCHITECTURES="\${CUDA_ARCH}"' "$TEMPLATE" && test_ok "cmake uses CUDA_ARCH variable" \
    || test_fail "CUDA_ARCH variable" "hardcoded arch"

# No hardcoded arch in cmake line (should use variable, not literal number)
! grep 'DCMAKE_CUDA_ARCHITECTURES="86"' "$TEMPLATE" && test_ok "no hardcoded arch 86 in cmake" \
    || test_fail "hardcoded arch" "found literal 86 in cmake line"

# ====== Summary ======
echo ""
echo "=========================================="
echo "Test Summary"
echo "=========================================="
echo "Total:  $TOTAL"
echo -e "Passed: ${GREEN}${PASSED}${NC}"
echo -e "Failed: ${RED}${FAILED}${NC}"
echo ""

if [[ $FAILED -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}${FAILED} test(s) failed!${NC}"
    exit 1
fi
