#!/usr/bin/env bash
# =============================================================================
# Linus — Unit Tests: driver LINUS_RESULT parsing (P1-3) + offer picker (P2-7)
# =============================================================================
# P1-3: vast-provision-and-bootstrap.sh must parse LINUS_RESULT output
#       (one LINUS_<pair> per line) into PARSED_* vars incl. LINUS_COST.
# P2-7: shared/lib/pick-vast-offer.py must honor host/machine exclusions
#       and prefer geolocation diversity on retry.
# No live Vast.ai / GPU instance required.
# =============================================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
TOTAL=0; PASSED=0; FAILED=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

test_ok()  { ((TOTAL++)); ((PASSED++)); echo -e "  ${GREEN}✓${NC} $1"; }
test_fail() { ((TOTAL++)); ((FAILED++)); echo -e "  ${RED}✗${NC} $1 — $2"; }

echo "=========================================="
echo "Linus — Unit Tests: driver parse + picker"
echo "=========================================="
echo ""

# ====== P1-3: Driver parse_linus_result ======
echo -e "${BLUE}P1-3: Driver LINUS_RESULT parsing${NC}"

PARSE_OUT="$(
cd "$REPO_ROOT" && bash -c '
  export VAST_MODEL_REPO=test/repo VAST_MODEL_FILE=test.gguf
  source shared/provision/vast-provision-and-bootstrap.sh >/dev/null 2>&1
  SAMPLE="LINUS_RESULT:SUCCESS
LINUS_CONTRACT_ID:37210893
LINUS_SSH_HOST:ssh1.vast.ai
LINUS_SSH_PORT:12345
LINUS_PROXY_PORT:12346
LINUS_INSTANCE_PRICE:0.42
LINUS_COST:total_usd=0.098,instance_price=0.42,wall_time_s=840
LINUS_GPU:RTX_3090
LINUS_OPERATOR:test"
  parse_linus_result "$SAMPLE"
  echo "CONTRACT_ID=${PARSED_CONTRACT_ID:-}"
  echo "SSH_HOST=${PARSED_SSH_HOST:-}"
  echo "SSH_PORT=${PARSED_SSH_PORT:-}"
  echo "PROXY_PORT=${PARSED_PROXY_PORT:-}"
  echo "INSTANCE_PRICE=${PARSED_INSTANCE_PRICE:-}"
  echo "LINUS_COST=${PARSED_LINUS_COST:-}"
  echo "GPU=${PARSED_GPU:-}"
' 2>/dev/null)"

get_var() { echo "$PARSE_OUT" | grep "^$1=" | cut -d= -f2-; }

[[ "$(get_var CONTRACT_ID)" == "37210893" ]] \
    && test_ok "CONTRACT_ID parsed" \
    || test_fail "CONTRACT_ID parsed" "got '$(get_var CONTRACT_ID)'"
[[ "$(get_var SSH_HOST)" == "ssh1.vast.ai" ]] \
    && test_ok "SSH_HOST parsed" \
    || test_fail "SSH_HOST parsed" "got '$(get_var SSH_HOST)'"
[[ "$(get_var SSH_PORT)" == "12345" ]] \
    && test_ok "SSH_PORT parsed" \
    || test_fail "SSH_PORT parsed" "got '$(get_var SSH_PORT)'"
[[ "$(get_var PROXY_PORT)" == "12346" ]] \
    && test_ok "PROXY_PORT parsed" \
    || test_fail "PROXY_PORT parsed" "got '$(get_var PROXY_PORT)'"
[[ "$(get_var INSTANCE_PRICE)" == "0.42" ]] \
    && test_ok "INSTANCE_PRICE parsed" \
    || test_fail "INSTANCE_PRICE parsed" "got '$(get_var INSTANCE_PRICE)'"
[[ "$(get_var LINUS_COST)" == "total_usd=0.098,instance_price=0.42,wall_time_s=840" ]] \
    && test_ok "LINUS_COST parsed (P1-4)" \
    || test_fail "LINUS_COST parsed" "got '$(get_var LINUS_COST)'"

echo ""

# ====== P2-7: Deterministic offer picker ======
echo -e "${BLUE}P2-7: Offer picker (exclusion + diversity)${NC}"

PICKER="$REPO_ROOT/shared/lib/pick-vast-offer.py"
OFFERS='[
  {"id": 101, "host_id": 11, "machine_id": 111, "geolocation": "Iceland", "dph_total": 0.30},
  {"id": 102, "host_id": 22, "machine_id": 222, "geolocation": "Iceland", "dph_total": 0.32},
  {"id": 103, "host_id": 33, "machine_id": 333, "geolocation": "Germany", "dph_total": 0.35}
]'

PICKED="$(echo "$OFFERS" | python3 "$PICKER")"
[[ "$PICKED" == "101 0.3" ]] \
    && test_ok "No exclusions → first offer" \
    || test_fail "No exclusions" "got '${PICKED}'"

# Excluding top offer's machine_id → next offer, same geolocation
OFFERS_SAMEGEO='[
  {"id": 101, "host_id": 11, "machine_id": 111, "geolocation": "Iceland", "dph_total": 0.30},
  {"id": 102, "host_id": 22, "machine_id": 222, "geolocation": "Iceland", "dph_total": 0.32},
  {"id": 103, "host_id": 33, "machine_id": 333, "geolocation": "Iceland", "dph_total": 0.35}
]'
PICKED="$(echo "$OFFERS_SAMEGEO" | python3 "$PICKER" 111)"
[[ "$PICKED" == "102 0.32" ]] \
    && test_ok "machine_id exclusion drops failed host" \
    || test_fail "machine_id exclusion" "got '${PICKED}'"

# Retry diversity: top remaining is Iceland, prefer Germany offer
PICKED="$(echo "$OFFERS" | python3 "$PICKER" 111)"
[[ "$PICKED" == "103 0.35" ]] \
    && test_ok "Retry prefers different geolocation over next same-geo offer" \
    || test_fail "Retry diversity (machine excl)" "got '${PICKED}'"

# Offer-id exclusion + machine exclusion → only diverse offer remains
PICKED="$(echo "$OFFERS" | python3 "$PICKER" offer:101 222)"
[[ "$PICKED" == "103 0.35" ]] \
    && test_ok "Offer + machine exclusions leave only diverse offer" \
    || test_fail "Offer + machine exclusions" "got '${PICKED}'"

# Diversity without exclusion of top: exclude nothing but force retry via offer: on a dup
PICKED="$(echo "$OFFERS" | python3 "$PICKER" offer:999)"
# No real exclusion; retry flag set → prefer non-Iceland (103 Germany)
[[ "$PICKED" == "103 0.35" ]] \
    && test_ok "Retry prefers different geolocation" \
    || test_fail "Retry diversity" "got '${PICKED}'"

# host_id exclusion also works (provisioner records machine_id, search keys host_id)
PICKED="$(echo "$OFFERS" | python3 "$PICKER" 11)"
[[ "$PICKED" == "103 0.35" ]] \
    && test_ok "host_id exclusion + diversity → Germany offer" \
    || test_fail "host_id exclusion" "got '${PICKED}'"

# All excluded → nonzero exit
if echo "$OFFERS" | python3 "$PICKER" 111 222 333 >/dev/null 2>&1; then
    test_fail "All-excluded exits nonzero" "exit 0"
else
    test_ok "All-excluded exits nonzero"
fi

# Invalid JSON → nonzero exit
if echo "not json" | python3 "$PICKER" >/dev/null 2>&1; then
    test_fail "Invalid JSON exits nonzero" "exit 0"
else
    test_ok "Invalid JSON exits nonzero"
fi

echo ""

echo "=========================================="
echo -e "Results: ${PASSED}/${TOTAL} passed, ${FAILED} failed"
echo "=========================================="

[[ $FAILED -eq 0 ]] || exit 1
