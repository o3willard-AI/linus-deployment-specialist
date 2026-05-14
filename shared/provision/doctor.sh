#!/usr/bin/env bash
# =============================================================================
# Linus Doctor — Pre-flight Diagnostic
# =============================================================================
# Answers: "Am I ready to provision VMs?" in under 5 seconds.
#
# Usage:
#   ./doctor.sh
#
# Exit: 0 if ready, 1 if issues found
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/paths.sh" 2>/dev/null || true
source_lib "logging.sh" 2>/dev/null || {
    echo "WARNING: logging.sh not found, using bare echo" >&2
}

# ---------------------------------------------------------------------------
# Configuration (from environment or secrets — same as proxmox.sh)
# ---------------------------------------------------------------------------
PROXMOX_HOST="${PROXMOX_HOST:-192.168.101.155}"
PROXMOX_USER="${PROXMOX_USER:-root@pam}"
PROXMOX_TOKEN_ID="${PROXMOX_TOKEN_ID:-linus-token}"
PROXMOX_TOKEN_SECRET="${PROXMOX_TOKEN_SECRET:-}"
PROXMOX_NODE="${PROXMOX_NODE:-moxy}"
PROXMOX_BRIDGE="${PROXMOX_BRIDGE:-vmbr0}"
PROXMOX_TEMPLATE_ID="${VM_TEMPLATE_ID:-9000}"

# Auto-discover credentials
for dir in "$HOME/.hermes/secrets" "$HOME/.hermes/env"; do
    for fname in "proxmox-token-${PROXMOX_HOST}" "proxmox-${PROXMOX_HOST}" "proxmox-token" "proxmox"; do
        if [[ -f "${dir}/${fname}" && -r "${dir}/${fname}" ]]; then
            # shellcheck disable=SC1090
            source "${dir}/${fname}" 2>/dev/null || true
        fi
    done
done

readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[0;33m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

PASS=0
FAIL=0
WARN=0

check_pass() { echo -e "  ${GREEN}✅${NC} $*"; ((PASS++)) || true; }
check_fail() { echo -e "  ${RED}❌${NC} $*"; ((FAIL++)) || true; }
check_warn() { echo -e "  ${YELLOW}⚠️ ${NC} $*"; ((WARN++)) || true; }

echo ""
echo -e "${CYAN}=== Linus Doctor — Pre-Flight Diagnostic ===${NC}"
echo ""

# ---- Check 1: Required environment variables ----
echo "1. Environment variables"
errors=0
for var in PROXMOX_HOST PROXMOX_USER PROXMOX_TOKEN_ID PROXMOX_TOKEN_SECRET; do
    if [[ -z "${!var:-}" ]]; then
        check_fail "$var is not set"
        ((errors++))
    else
        check_pass "$var is set"
    fi
done
[[ $errors -gt 0 ]] && echo "   Fix: export the missing variables or create ~/.hermes/secrets/proxmox-token"
echo ""

# ---- Check 2: Proxmox API connectivity ----
echo "2. Proxmox API connectivity"
API_URL="https://${PROXMOX_HOST}:8006/api2/json"
AUTH="Authorization: PVEAPIToken=${PROXMOX_USER}!${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}"

# Test basic connectivity
VERSION_JSON=$(curl -sk --connect-timeout 5 --max-time 10 \
    -H "$AUTH" "$API_URL/version" 2>/tmp/doctor-curl-err.txt)
CURL_EXIT=$?

if [[ $CURL_EXIT -ne 0 ]]; then
    CURL_ERR=$(cat /tmp/doctor-curl-err.txt 2>/dev/null || echo "unknown error")
    check_fail "Cannot reach Proxmox at ${PROXMOX_HOST}:8006"
    echo "   curl error: $CURL_ERR"
    echo "   Fix: verify PROXMOX_HOST is correct and the host is reachable"
else
    VERSION=$(echo "$VERSION_JSON" | jq -r '.data.version // "unknown"' 2>/dev/null || echo "error")
    if [[ "$VERSION" == "error" || "$VERSION" == "null" ]]; then
        check_fail "API returned unexpected response (auth failed?)"
        echo "   Raw response: $(echo "$VERSION_JSON" | head -c 200)"
        echo "   Fix: verify PROXMOX_USER, PROXMOX_TOKEN_ID, PROXMOX_TOKEN_SECRET"
    else
        check_pass "Proxmox VE $VERSION reachable"
    fi
fi
rm -f /tmp/doctor-curl-err.txt
echo ""

# ---- Check 3: Node status ----
echo "3. Node status"
NODE_JSON=$(curl -sk --connect-timeout 5 --max-time 10 \
    -H "$AUTH" "$API_URL/nodes/${PROXMOX_NODE}/status" 2>/dev/null)
NODE_UPTIME=$(echo "$NODE_JSON" | jq -r '.data.uptime // 0' 2>/dev/null || echo "0")

if [[ "$NODE_UPTIME" == "0" || "$NODE_UPTIME" == "null" ]]; then
    check_fail "Node '${PROXMOX_NODE}' is offline or unreachable"
    echo "   Fix: check node name (PROXMOX_NODE) and ensure the host is powered on"
else
    UPTIME_HOURS=$((NODE_UPTIME / 3600))
    check_pass "Node '${PROXMOX_NODE}' online (uptime: ${UPTIME_HOURS}h)"
fi
echo ""

# ---- Check 4: Template VM ----
echo "4. Template VM (ID: ${PROXMOX_TEMPLATE_ID})"
TEMPLATE_JSON=$(curl -sk --connect-timeout 5 --max-time 10 \
    -H "$AUTH" "$API_URL/nodes/${PROXMOX_NODE}/qemu/${PROXMOX_TEMPLATE_ID}/status/current" 2>/dev/null)
TEMPLATE_STATUS=$(echo "$TEMPLATE_JSON" | jq -r '.data.status // "not_found"' 2>/dev/null || echo "error")

if [[ "$TEMPLATE_STATUS" == "not_found" || "$TEMPLATE_STATUS" == "null" ]]; then
    check_fail "Template VM ${PROXMOX_TEMPLATE_ID} not found on node ${PROXMOX_NODE}"
    echo "   Fix: set VM_TEMPLATE_ID to an existing template, or create one"
else
    check_pass "Template VM ${PROXMOX_TEMPLATE_ID} exists (status: ${TEMPLATE_STATUS})"
fi
echo ""

# ---- Check 5: SSH key for VM injection ----
echo "5. SSH key for VM injection"
SSH_KEY_FOUND=""
for candidate in ~/.ssh/id_ed25519_qemu_test.pub ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub; do
    if [[ -f "$candidate" ]]; then
        SSH_KEY_FOUND="$candidate"
        break
    fi
done

if [[ -z "$SSH_KEY_FOUND" ]]; then
    check_fail "No SSH public key found in ~/.ssh/"
    echo "   Fix: ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_qemu_test"
else
    KEY_TYPE=$(awk '{print $1}' "$SSH_KEY_FOUND")
    KEY_COMMENT=$(awk '{print $NF}' "$SSH_KEY_FOUND")
    check_pass "SSH key found: ${SSH_KEY_FOUND##*/} (${KEY_TYPE}, ${KEY_COMMENT})"

    # Also check if the private key exists (needed for SSH connections)
    PRIV_KEY="${SSH_KEY_FOUND%.pub}"
    if [[ -f "$PRIV_KEY" ]]; then
        check_pass "Private key present: ${PRIV_KEY##*/}"
    else
        check_warn "Private key not found at ${PRIV_KEY} (needed for SSH to VMs)"
    fi
fi
echo ""

# ---- Check 6: Bridge network configuration ----
echo "6. Bridge network configuration"
BRIDGE_INFO=$(curl -sk --connect-timeout 5 --max-time 10 \
    -H "$AUTH" "$API_URL/nodes/${PROXMOX_NODE}/network" 2>/dev/null | \
    python3 -c "
import json, sys, ipaddress
data = json.load(sys.stdin).get('data', [])
for iface in data:
    if iface.get('iface') == '${PROXMOX_BRIDGE}' and iface.get('type') == 'bridge':
        cidr = iface.get('cidr', '')
        gw = iface.get('gateway', '')
        if cidr:
            net = ipaddress.ip_network(cidr, strict=False)
            prefix = '.'.join(str(net.network_address).split('.')[:3])
            print(f'CIDR={cidr}|GATEWAY={gw}|PREFIX={prefix}')
        break
" 2>/dev/null) || BRIDGE_INFO=""

if [[ -z "$BRIDGE_INFO" ]]; then
    check_warn "Bridge '${PROXMOX_BRIDGE}' not found or has no CIDR"
    echo "   VMs will use fallback: 192.168.101.0/24, gw=192.168.101.2"
else
    BRIDGE_CIDR=$(echo "$BRIDGE_INFO" | grep -oP 'CIDR=\K[^|]+')
    BRIDGE_GW=$(echo "$BRIDGE_INFO" | grep -oP 'GATEWAY=\K[^|]+')
    BRIDGE_PREFIX=$(echo "$BRIDGE_INFO" | grep -oP 'PREFIX=\K[^|]+')
    check_pass "Bridge '${PROXMOX_BRIDGE}': ${BRIDGE_CIDR} (gateway: ${BRIDGE_GW})"
    echo "   VM IP range: ${BRIDGE_PREFIX}.113 — ${BRIDGE_PREFIX}.199 (87 available)"
fi
echo ""

# ---- Check 7: Required CLI tools ----
echo "7. Required CLI tools"
for tool in curl jq python3 ssh scp sshpass; do
    if command -v "$tool" &>/dev/null; then
        check_pass "$tool: $(command -v "$tool")"
    else
        check_fail "$tool: not found"
        echo "   Fix: apt-get install $tool (or equivalent)"
    fi
done
echo ""

# ---- Summary ----
echo -e "${CYAN}=== Summary ===${NC}"
echo "  Passes:  $PASS"
echo "  Failures: $FAIL"
echo "  Warnings: $WARN"
echo ""

if [[ $FAIL -gt 0 ]]; then
    echo -e "${RED}❌ NOT READY — $FAIL issue(s) must be fixed before provisioning${NC}"
    echo ""
    exit 1
elif [[ $WARN -gt 0 ]]; then
    echo -e "${YELLOW}⚠️  READY WITH WARNINGS — provisioning will likely succeed, review warnings${NC}"
    echo ""
    exit 0
else
    echo -e "${GREEN}✅ ALL CHECKS PASSED — ready to provision${NC}"
    echo ""
    exit 0
fi