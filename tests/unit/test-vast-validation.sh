#!/usr/bin/env bash
# =============================================================================
# Linus — Unit Tests: validate_gpu_type
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
TOTAL=0; PASSED=0; FAILED=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VALIDATION="${PROJECT_ROOT}/shared/lib/validation.sh"

test_ok()  { ((TOTAL++)); ((PASSED++)); echo -e "  ${GREEN}✓${NC} $1"; }
test_fail() { ((TOTAL++)); ((FAILED++)); echo -e "  ${RED}✗${NC} $1 — $2"; }

echo "=========================================="
echo "Linus — Unit Tests: validate_gpu_type"
echo "=========================================="
echo ""

if [[ ! -f "$VALIDATION" ]]; then
    echo -e "${YELLOW}BLOCKED — validation.sh not found${NC}"
    exit 2
fi

source "$VALIDATION"

# Verify function exists
declare -F validate_gpu_type >/dev/null && test_ok "validate_gpu_type defined" \
    || { test_fail "validate_gpu_type defined" "function missing"; echo "Cannot continue"; exit 1; }

# ====== AC1: Known GPUs return 0 ======
echo ""
echo -e "${BLUE}AC1: Known GPUs${NC}"

for gpu in RTX_3090 RTX_4090 A5000 V100_16GB V100_32GB A6000 L40S A100_40GB A100_80GB H100; do
    if validate_gpu_type "$gpu" >/dev/null 2>&1; then
        test_ok "$gpu → valid (exit 0)"
    else
        test_fail "$gpu → valid" "exit=$?"
    fi
done

# ====== AC1: Unknown GPU ======
echo ""
echo -e "${BLUE}AC1b: Unknown GPUs${NC}"

set +e
validate_gpu_type GTX_1080 >/dev/null 2>&1
ec=$?
set -e
[[ $ec -eq 1 ]] && test_ok "GTX_1080 → invalid (exit 1)" \
    || test_fail "GTX_1080 → invalid" "exit=$ec expected 1"

set +e
validate_gpu_type "" >/dev/null 2>&1
ec=$?
set -e
[[ $ec -eq 1 ]] && test_ok "empty string → invalid (exit 1)" \
    || test_fail "empty string → invalid" "exit=$ec expected 1"

set +e
validate_gpu_type "not_a_gpu" >/dev/null 2>&1
ec=$?
set -e
[[ $ec -eq 1 ]] && test_ok "not_a_gpu → invalid (exit 1)" \
    || test_fail "not_a_gpu → invalid" "exit=$ec expected 1"

# ====== AC2: Architecture flag output ======
echo ""
echo -e "${BLUE}AC2: Architecture flags${NC}"

arch=$(validate_gpu_type RTX_3090)
[[ "$arch" == "86" ]] && test_ok "RTX_3090 → arch=86" \
    || test_fail "RTX_3090 → arch=86" "got $arch"

arch=$(validate_gpu_type RTX_4090)
[[ "$arch" == "89" ]] && test_ok "RTX_4090 → arch=89" \
    || test_fail "RTX_4090 → arch=89" "got $arch"

arch=$(validate_gpu_type H100)
[[ "$arch" == "90" ]] && test_ok "H100 → arch=90" \
    || test_fail "H100 → arch=90" "got $arch"

arch=$(validate_gpu_type V100_16GB)
[[ "$arch" == "70" ]] && test_ok "V100_16GB → arch=70" \
    || test_fail "V100_16GB → arch=70" "got $arch"

arch=$(validate_gpu_type A6000)
[[ "$arch" == "86" ]] && test_ok "A6000 → arch=86" \
    || test_fail "A6000 → arch=86" "got $arch"

# ====== AC3: No table duplication ======
echo ""
echo -e "${BLUE}AC3: No table duplication${NC}"

# Verify GPU_ARCH is accessible (was sourced from vast-sizing.sh)
[[ ${#GPU_ARCH[@]} -gt 0 ]] && test_ok "GPU_ARCH accessible from vast-sizing.sh (${#GPU_ARCH[@]} entries)" \
    || test_fail "GPU_ARCH accessible" "not found — may be duplicated instead of sourced"

# Verify validate_gpu_type uses GPU_ARCH, not a hardcoded case
grep -q 'GPU_ARCH' "$VALIDATION" && test_ok "validate_gpu_type references GPU_ARCH" \
    || test_fail "validate_gpu_type references GPU_ARCH" "no GPU_ARCH reference found"

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
