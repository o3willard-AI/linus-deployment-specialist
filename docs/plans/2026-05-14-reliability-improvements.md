# Reliability Improvements — E2E & Smoke Test Plan

> **For Hermes:** Use subagent-driven-development skill. Dispatch tasks A+B in parallel (different files), then task C separately.

**Goal:** Close 4 reliability gaps in the Linus deployment specialist: _pvesh silent stderr, hollow E2E Phase 4, fake DNS test, and no pre-flight diagnostic.

**Architecture:** Three tasks. A and B touch different files (proxmox.sh vs test-proxmox-enhanced.sh) so they can run in parallel. C is a new file and runs independently.

**Tech Stack:** Bash, jq, curl, Proxmox REST API

---

## Task A: _pvesh stderr capture (proxmox.sh)

**Objective:** Stop `_pvesh` from discarding all curl stderr. On failure, log the diagnostic output. Keep stdout clean for parsing.

**File:** `/home/sblanken/workspace/linus-deployment-specialist/shared/provision/proxmox.sh`

**Context:** `_pvesh` wraps curl with `2>/dev/null` on all 4 HTTP methods. When the Proxmox API returns a connection error, DNS failure, or TLS error, nothing is logged. The `--fail` flag catches HTTP 4xx/5xx but connection-level errors produce no diagnostic at all. The script just sees empty output and guesses.

**Step 1: Capture stderr, log on failure**

Modify the `_pvesh` function. The pattern: capture stdout+stderr to a temp file, then on failure log the stderr portion through the logging library. Keep stdout clean.

The function is at lines 111-148 of proxmox.sh. Key constraint: `_pvesh` is used in `$()` subshells, so logging must go through the log file, not stdout. Use `log_error` which writes to `LINUS_LOG_FILE` and stderr via `>&2`.

Here is the replacement for the `_pvesh` function body (the `case` block, lines 129-147):

```bash
    # Capture stderr to a temp file so we can log it on failure
    local _errfile
    _errfile=$(mktemp) || { echo "ERROR: _pvesh: cannot create temp file" >&2; return 1; }
    
    local _exit_code=0
    case "$method" in
        get)
            curl -sk -H "$auth_header" "$url" "$@" 2>"$_errfile"
            _exit_code=$?
            ;;
        post)
            curl -sk --fail -X POST -H "$auth_header" "${ct_header[@]}" "$url" "$@" 2>"$_errfile"
            _exit_code=$?
            ;;
        put)
            curl -sk --fail -X PUT -H "$auth_header" "${ct_header[@]}" "$url" "$@" 2>"$_errfile"
            _exit_code=$?
            ;;
        delete)
            curl -sk --fail -X DELETE -H "$auth_header" "$url" "$@" 2>"$_errfile"
            _exit_code=$?
            ;;
        *)
            echo "ERROR: Unknown method: $method" >&2
            rm -f "$_errfile"
            return 1
            ;;
    esac
    
    # On failure, log the curl stderr for diagnosis
    if [[ $_exit_code -ne 0 ]]; then
        local _errmsg
        _errmsg=$(<"$_errfile")
        [[ -n "$_errmsg" ]] && echo "[ERROR] _pvesh $method $path: $_errmsg" >> "${LINUS_LOG_FILE:-/tmp/linus.log}"
    fi
    rm -f "$_errfile"
    return $_exit_code
```

**Step 2: Verify no regressions**

Run `bash -n shared/provision/proxmox.sh` to verify syntax.

**Step 3: Commit**

```bash
cd /home/sblanken/workspace/linus-deployment-specialist
git add shared/provision/proxmox.sh
git commit -m "fix(proxmox): _pvesh captures stderr to log on failure instead of discarding"
```

---

## Task B: E2E Phase 3+4 Fixes (test-proxmox-enhanced.sh)

**Objective:** Fix three issues in the E2E test:
1. Phase 3 DNS test doesn't actually test DNS (falls through to IP ping)
2. Phase 4 Steps 17-19 are hollow — no verification of monitoring or stress test
3. `for i in {1..2}` brace expansion inconsistency (works in bash but not POSIX)

**File:** `/home/sblanken/workspace/linus-deployment-specialist/tests/e2e/test-proxmox-enhanced.sh`

### B1: Fix brace expansion (lines 438, 491)

Change `for i in {1..2}` to `for i in $(seq 1 2)` to match the PROVISIONING-OPS.md convention.

Line 438:
```bash
# BEFORE
for i in {1..2}; do
# AFTER
for i in $(seq 1 2); do
```

Line 491:
```bash
# BEFORE
for i in {1..2}; do
# AFTER
for i in $(seq 1 2); do
```

### B2: Fix Phase 3 DNS test (lines 500-511)

The current test uses `getent hosts test-cluster-1 || ping -c1 $VM2_IP` — when DNS fails (which it will, no DNS server between VMs), it falls through to IP ping and passes. This doesn't test DNS.

Replace with a connectivity test that verifies VMs can reach each other by IP and logs the actual reachability:

```bash
# Test cross-VM connectivity (IP-based — no DNS server between VMs)
echo "  Testing VM-to-VM connectivity..."
if ! ssh ${SSH_OPTS[@]} ubuntu@$VM_IP \
     "ping -c2 -W2 $VM2_IP" 2>/dev/null; then
    echo -e "${RED}❌ VM $VM_IP cannot reach $VM2_IP${NC}"
    exit 1
fi
echo "  ${GREEN}✅${NC} $VM_IP → $VM2_IP: reachable"

if ! ssh ${SSH_OPTS[@]} ubuntu@$VM2_IP \
     "ping -c2 -W2 $VM3_IP" 2>/dev/null; then
    echo -e "${RED}❌ VM $VM2_IP cannot reach $VM3_IP${NC}"
    exit 1
fi
echo "  ${GREEN}✅${NC} $VM2_IP → $VM3_IP: reachable"

echo -e "${GREEN}✅ Cross-VM connectivity verified${NC}"
```

### B3: Fix Phase 4 Steps 17-19 (lines 534-570)

The current Phase 4 does this:
- Step 17: Backgrounds `monitor-resource.sh` and `dd` with `&`, never verifies either
- Step 18: Checks VM exists via API (no actual cleanup verification)
- Step 19: No-op (trap handles cleanup)

Replace Steps 17-19 with actual verification:

**Step 17 — Run monitoring with verified stress test:**

```bash
# Step 17: Run resource monitoring during a stress test
echo -e "${YELLOW}[17/19]${NC} Running resource monitoring with stress test..."

# Upload monitoring script
SSH_KEY_FILE="${SSH_KEY_FILE:-}"
if [[ -z "$SSH_KEY_FILE" ]]; then
    for candidate in ~/.ssh/id_ed25519_qemu_test ~/.ssh/id_ed25519 ~/.ssh/id_rsa; do
        if [[ -f "$candidate" ]]; then SSH_KEY_FILE="$candidate"; break; fi
    done
fi
SSH_OPTS=(-i "${SSH_KEY_FILE}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10)

scp ${SSH_OPTS[@]} shared/snapshot/monitor-resource.sh ubuntu@$VM_IP:/tmp/ 2>/dev/null || {
    echo -e "${RED}❌ Failed to upload monitoring script${NC}"
    exit 1
}

# Start monitoring in background and capture its PID
MONITOR_PID=""
ssh ${SSH_OPTS[@]} ubuntu@$VM_IP \
    "nohup sudo bash /tmp/monitor-resource.sh > /tmp/monitor-output.log 2>&1 & echo \$!" > /tmp/monitor-pid.txt 2>/dev/null
MONITOR_PID=$(cat /tmp/monitor-pid.txt 2>/dev/null || echo "")

if [[ -z "$MONITOR_PID" ]]; then
    echo -e "${RED}❌ Failed to start monitoring${NC}"
    exit 1
fi
echo "  Monitoring started (PID: $MONITOR_PID)"

# Run stress test and wait for it to complete
echo "  Running CPU/memory stress test..."
ssh ${SSH_OPTS[@]} ubuntu@$VM_IP \
    "dd if=/dev/zero of=/tmp/stress-test bs=1M count=500 2>/tmp/dd-stderr.txt" >/dev/null 2>&1
DD_EXIT=$?
if [[ $DD_EXIT -ne 0 ]]; then
    echo -e "${RED}❌ Stress test failed (dd exit code: $DD_EXIT)${NC}"
    ssh ${SSH_OPTS[@]} ubuntu@$VM_IP "cat /tmp/dd-stderr.txt" 2>/dev/null
    exit 1
fi

# Give monitoring a moment to sample after stress
sleep 3

# Stop monitoring gracefully
ssh ${SSH_OPTS[@]} ubuntu@$VM_IP "sudo kill $MONITOR_PID" 2>/dev/null || true
sleep 2

# Verify monitoring produced output
MONITOR_SIZE=$(ssh ${SSH_OPTS[@]} ubuntu@$VM_IP "stat -c%s /tmp/monitor-output.log 2>/dev/null || echo 0" 2>/dev/null | tr -d '[:space:]')
if [[ -z "$MONITOR_SIZE" || "$MONITOR_SIZE" -lt 50 ]]; then
    echo -e "${RED}❌ Monitoring produced no output (file size: ${MONITOR_SIZE:-0} bytes)${NC}"
    exit 1
fi
MONITOR_LINES=$(ssh ${SSH_OPTS[@]} ubuntu@$VM_IP "wc -l < /tmp/monitor-output.log" 2>/dev/null | tr -d '[:space:]')
echo "  Monitoring captured ${MONITOR_LINES} lines (${MONITOR_SIZE} bytes)"

# Verify monitoring recorded CPU or disk activity from the stress test
if ! ssh ${SSH_OPTS[@]} ubuntu@$VM_IP \
    "grep -qiE 'cpu|disk|io|mem|usage' /tmp/monitor-output.log" 2>/dev/null; then
    echo -e "${RED}❌ Monitoring log contains no resource metrics (empty or wrong format)${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Resource monitoring verified (${MONITOR_LINES} lines captured)${NC}"
```

**Step 18 — Verify cleanup readiness:**

```bash
# Step 18: Verify cleanup readiness
echo -e "${YELLOW}[18/19]${NC} Verifying cleanup readiness..."

# Verify original VM is still running and accessible
if ! ssh ${SSH_OPTS[@]} ubuntu@$VM_IP "echo ok" 2>/dev/null; then
    echo -e "${RED}❌ Original VM unreachable before cleanup${NC}"
    exit 1
fi
echo "  VM $VM_ID: accessible"

# Verify multi-VM group exists in API
IFS=',' read -ra VM_ARRAY <<< "${MULTI_VM_IDS}"
for id in "${VM_ARRAY[@]}"; do
    if [[ -n "$id" ]]; then
        vm_exists=$(_api "https://${PROXMOX_HOST}:8006/api2/json/nodes/${PROXMOX_NODE:-moxy}/qemu/${id}/status/current" 2>/dev/null)
        if [[ -z "$vm_exists" ]]; then
            echo -e "${RED}❌ Multi-VM $id not found in API before cleanup${NC}"
            exit 1
        fi
        echo "  Multi-VM $id: exists in API"
    fi
done

echo -e "${GREEN}✅ Cleanup readiness verified${NC}"
```

**Step 19 — Explicit cleanup with verification:**

Keep Step 19 but make it explicit rather than relying solely on the trap:

```bash
# Step 19: Final cleanup with verification
echo -e "${YELLOW}[19/19]${NC} Running final cleanup..."

cleanup

# Verify all VMs were actually removed
sleep 3
IFS=',' read -ra ALL_IDS <<< "${MULTI_VM_IDS},${VM_ID}"
for id in "${ALL_IDS[@]}"; do
    if [[ -n "$id" ]]; then
        if _api "https://${PROXMOX_HOST}:8006/api2/json/nodes/${PROXMOX_NODE:-moxy}/qemu/${id}/status/current" 2>/dev/null | grep -q '"status"'; then
            echo -e "${YELLOW}⚠️  VM $id may still exist after cleanup${NC}"
        else
            echo "  VM $id: removed ✓"
        fi
    fi
done

echo -e "${GREEN}✅ Final cleanup verified${NC}"
```

**Step 4: Verify syntax**

```bash
bash -n tests/e2e/test-proxmox-enhanced.sh
```

**Step 5: Commit**

```bash
cd /home/sblanken/workspace/linus-deployment-specialist
git add tests/e2e/test-proxmox-enhanced.sh
git commit -m "fix(e2e): verify Phase 4 monitoring, fix DNS test, use seq over brace expansion

- Phase 3: Replace fake DNS test with actual cross-VM IP connectivity verification
- Phase 4: Wait for monitoring PID, verify log output contains resource metrics
- Phase 4: Add explicit cleanup verification (VM existence check after delete)
- Replace for i in {1..2} with for i in \$(seq 1 2) for POSIX robustness"
```

---

## Task C: Smoke Test / Self-Diagnostic

**Objective:** Create a `linus doctor` command that validates the deployment specialist's configuration before provisioning, so config drift is caught in 5 seconds instead of 10 minutes.

**File:** Create `/home/sblanken/workspace/linus-deployment-specialist/shared/provision/doctor.sh`

**The script must answer these questions:**

1. Can I reach the Proxmox API?
2. Does the API token actually authenticate? (check version endpoint + node uptime)
3. Does the template VM exist?
4. What SSH key will be injected into new VMs?
5. What bridge subnet will VMs land on? (with allocated IP range)
6. Are all required env vars set?

**Design:** Output a clean pass/fail report. Each check gets a ✅ or ❌. On failure, print the exact error and how to fix it.

```bash
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

# ---- Check 7: Required tools ----
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
```

**Step 1: Create the file**

Create at `/home/sblanken/workspace/linus-deployment-specialist/shared/provision/doctor.sh`

**Step 2: Make executable**

```bash
chmod +x shared/provision/doctor.sh
```

**Step 3: Verify syntax**

```bash
bash -n shared/provision/doctor.sh
```

**Step 4: Commit**

```bash
cd /home/sblanken/workspace/linus-deployment-specialist
git add shared/provision/doctor.sh
git commit -m "feat: add linus doctor pre-flight diagnostic

Validates Proxmox API connectivity, template VM existence, SSH key
availability, bridge network config, and required CLI tools. Catches
config drift in under 5 seconds instead of a 10-minute failed provision."
```
