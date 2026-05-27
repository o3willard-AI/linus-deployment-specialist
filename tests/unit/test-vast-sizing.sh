#!/usr/bin/env bash
# =============================================================================
# Linus — Unit Tests: vast-sizing.sh
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
TOTAL=0; PASSED=0; FAILED=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIBRARY="$(cd "$SCRIPT_DIR/../.." && pwd)/shared/lib/vast-sizing.sh"

test_ok()  { ((TOTAL++)); ((PASSED++)); echo -e "  ${GREEN}✓${NC} $1"; }
test_fail() { ((TOTAL++)); ((FAILED++)); echo -e "  ${RED}✗${NC} $1 — $2"; }

echo "=========================================="
echo "Linus — Unit Tests: vast-sizing.sh"
echo "=========================================="
echo ""

# Block if library missing (TDD RED state)
if [[ ! -f "$LIBRARY" ]]; then
    echo -e "${YELLOW}BLOCKED — library not yet implemented${NC}"
    exit 2
fi

source "$LIBRARY"

# ====== AC1: GPU Reference Tables ======
echo -e "${BLUE}AC1: GPU Reference Tables${NC}"

[[ ${#GPU_VRAM[@]} -gt 0 ]] && test_ok "GPU_VRAM populated ($((${#GPU_VRAM[@]})) entries)" \
    || test_fail "GPU_VRAM populated" "array is empty"

[[ -n "${GPU_VRAM[RTX_3090]:-}" ]] && test_ok "GPU_VRAM[RTX_3090] exists" \
    || test_fail "GPU_VRAM[RTX_3090] exists" "key missing"

[[ "${GPU_VRAM[RTX_3090]}" == "24" ]] && test_ok "GPU_VRAM[RTX_3090] = 24" \
    || test_fail "GPU_VRAM[RTX_3090] = 24" "got ${GPU_VRAM[RTX_3090]}"

[[ "${GPU_ARCH[RTX_3090]}" == "86" ]] && test_ok "GPU_ARCH[RTX_3090] = 86" \
    || test_fail "GPU_ARCH[RTX_3090] = 86" "got ${GPU_ARCH[RTX_3090]}"

[[ "${GPU_ARCH[RTX_4090]}" == "89" ]] && test_ok "GPU_ARCH[RTX_4090] = 89" \
    || test_fail "GPU_ARCH[RTX_4090] = 89" "got ${GPU_ARCH[RTX_4090]}"

[[ "${GPU_ARCH[H100]}" == "90" ]] && test_ok "GPU_ARCH[H100] = 90" \
    || test_fail "GPU_ARCH[H100] = 90" "got ${GPU_ARCH[H100]}"

[[ "${QUANT_FACTORS[Q4_K_M]}" == "0.6" ]] && test_ok "QUANT_FACTORS[Q4_K_M] = 0.6" \
    || test_fail "QUANT_FACTORS[Q4_K_M] = 0.6" "got ${QUANT_FACTORS[Q4_K_M]}"

[[ "${QUANT_FACTORS[Q8_0]}" == "0.95" ]] && test_ok "QUANT_FACTORS[Q8_0] = 0.95" \
    || test_fail "QUANT_FACTORS[Q8_0] = 0.95" "got ${QUANT_FACTORS[Q8_0]}"

[[ "${QUANT_FACTORS[Q2_K]}" == "0.4" ]] && test_ok "QUANT_FACTORS[Q2_K] = 0.4" \
    || test_fail "QUANT_FACTORS[Q2_K] = 0.4" "got ${QUANT_FACTORS[Q2_K]}"

[[ "${LINUS_VAST_SIZING_LOADED:-}" == "1" ]] && test_ok "Library guard set" \
    || test_fail "Library guard set" "LINUS_VAST_SIZING_LOADED=${LINUS_VAST_SIZING_LOADED:-unset}"

declare -F vast_calc_model_size >/dev/null && test_ok "vast_calc_model_size defined" \
    || test_fail "vast_calc_model_size defined" "function missing"

declare -F vast_calc_kv_cache >/dev/null && test_ok "vast_calc_kv_cache defined" \
    || test_fail "vast_calc_kv_cache defined" "function missing"

declare -F vast_calc_required_vram >/dev/null && test_ok "vast_calc_required_vram defined" \
    || test_fail "vast_calc_required_vram defined" "function missing"

declare -F vast_calc_required_disk >/dev/null && test_ok "vast_calc_required_disk defined" \
    || test_fail "vast_calc_required_disk defined" "function missing"

declare -F vast_calc_dlperf_per_dollar >/dev/null && test_ok "vast_calc_dlperf_per_dollar defined" \
    || test_fail "vast_calc_dlperf_per_dollar defined" "function missing"

# ====== AC2: Model Size Calculator ======
echo ""
echo -e "${BLUE}AC2: Model Size Calculator${NC}"

r=$(vast_calc_model_size 7 Q4_K_M)
[[ "$r" == "4.20" ]] && test_ok "7B Q4_K_M → $r" || test_fail "7B Q4_K_M → 4.20" "got $r"

r=$(vast_calc_model_size 27 Q3_K_M)
[[ "$r" == "13.50" ]] && test_ok "27B Q3_K_M → $r" || test_fail "27B Q3_K_M → 13.50" "got $r"

r=$(vast_calc_model_size 70 Q8_0)
[[ "$r" == "66.50" ]] && test_ok "70B Q8_0 → $r" || test_fail "70B Q8_0 → 66.50" "got $r"

r=$(vast_calc_model_size 32 Q5_K_M)
[[ "$r" == "22.40" ]] && test_ok "32B Q5_K_M → $r" || test_fail "32B Q5_K_M → 22.40" "got $r"

r=$(vast_calc_model_size 7 Q9_X 2>&1) || ec=$?
[[ ${ec:-0} -eq 1 ]] && echo "$r" | grep -qi "unknown" && test_ok "Unknown quant → error" \
    || test_fail "Unknown quant → error" "exit=${ec:-0} output=$r"

# ====== AC3: KV Cache Calculator ======
echo ""
echo -e "${BLUE}AC3: KV Cache Calculator${NC}"

r=$(vast_calc_kv_cache 32768 7)
[[ "$r" == "1.72" ]] && test_ok "7B@32K → $r" || test_fail "7B@32K → 1.72" "got $r"

r=$(vast_calc_kv_cache 32768 14)
[[ "$r" == "3.44" ]] && test_ok "14B@32K → $r" || test_fail "14B@32K → 3.44" "got $r"

r=$(vast_calc_kv_cache 32768 27)
[[ "$r" == "6.64" ]] && test_ok "27B@32K → $r" || test_fail "27B@32K → 6.64" "got $r"

r=$(vast_calc_kv_cache 131072 7)
[[ "$r" == "6.88" ]] && test_ok "7B@128K → $r" || test_fail "7B@128K → 6.88" "got $r"

r=$(vast_calc_kv_cache 131072 17)
[[ "$r" == "16.71" ]] && test_ok "17B@128K → $r" || test_fail "17B@128K → 16.71" "got $r"

r=$(vast_calc_kv_cache abc 7 2>&1) || ec=$?
[[ ${ec:-0} -eq 1 ]] && test_ok "Non-numeric ctx → error" \
    || test_fail "Non-numeric ctx → error" "exit=${ec:-0}"

# ====== AC4: VRAM Requirement Calculator ======
echo ""
echo -e "${BLUE}AC4: VRAM Requirement Calculator${NC}"

r=$(vast_calc_required_vram 7 Q4_K_M 32768)
[[ "$r" == "7.42" ]] && test_ok "7B Q4_K_M @32K → $r" || test_fail "7B Q4_K_M @32K → 7.42" "got $r"

r=$(vast_calc_required_vram 17 Q4_K_M 131072)
[[ "$r" == "28.41" ]] && test_ok "17B Q4_K_M @128K → $r" || test_fail "17B Q4_K_M @128K → 28.41" "got $r"

r=$(vast_calc_required_vram 70 Q4_K_M 32768)
[[ "$r" == "60.70" ]] && test_ok "70B Q4_K_M @32K → $r" || test_fail "70B Q4_K_M @32K → 60.70" "got $r"

r=$(vast_calc_required_vram 14 Q4_K_M 32768)
[[ "$r" == "13.34" ]] && test_ok "14B Q4_K_M @32K → $r" || test_fail "14B Q4_K_M @32K → 13.34" "got $r"

# ====== AC5: Disk Requirement Calculator ======
echo ""
echo -e "${BLUE}AC5: Disk Requirement Calculator${NC}"

r=$(vast_calc_required_disk 4.2)
[[ "$r" == "10.50" ]] && test_ok "4.2G model → $r" || test_fail "4.2G model → 10.50" "got $r"

r=$(vast_calc_required_disk 42.0)
[[ "$r" == "105.00" ]] && test_ok "42G model → $r" || test_fail "42G model → 105.00" "got $r"

r=$(vast_calc_required_disk 0)
[[ "$r" == "0.00" ]] && test_ok "0G model → $r" || test_fail "0G model → 0.00" "got $r"

r=$(vast_calc_required_disk abc 2>&1) || ec=$?
[[ ${ec:-0} -eq 1 ]] && test_ok "Non-numeric disk → error" \
    || test_fail "Non-numeric disk → error" "exit=${ec:-0}"

# ====== AC6: DLPerf Value Score ======
echo ""
echo -e "${BLUE}AC6: DLPerf Value Score${NC}"

r=$(vast_calc_dlperf_per_dollar 100 0.26)
[[ "$r" == "384.62" ]] && test_ok "100dlperf @ 0.26 → $r" || test_fail "100dlperf @ 0.26 → 384.62" "got $r"

r=$(vast_calc_dlperf_per_dollar 125 0.40)
[[ "$r" == "312.50" ]] && test_ok "125dlperf @ 0.40 → $r" || test_fail "125dlperf @ 0.40 → 312.50" "got $r"

r=$(vast_calc_dlperf_per_dollar 200 1.20)
[[ "$r" == "166.67" ]] && test_ok "200dlperf @ 1.20 → $r" || test_fail "200dlperf @ 1.20 → 166.67" "got $r"

set +e; r=$(vast_calc_dlperf_per_dollar 100 0 2>&1); ec=$?; set -e
[[ $ec -eq 1 ]] && echo "$r" | grep -qi "zero" && test_ok "Div-by-zero → error" \
    || test_fail "Div-by-zero → error" "exit=$ec output=$r"

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
