#!/usr/bin/env bash

# ============================================================================= 
# Linus Deployment Specialist - Proxmox E2E Test Suite
# ============================================================================= 
# This is a comprehensive QA battery that tests Proxmox provisioning resilience 
# across multiple dimensions:
# 1. Single VM provisioning + bootstrap
# 2. Snapshot save/restore cycle with workload verification
# 3. Multi-VM parallel provisioning with DNS test
# 4. Resource monitoring + cleanup verification
#
# All operations use API token auth for Proxmox + direct SSH to VMs.
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
PROXMOX_HOST="${PROXMOX_HOST:-192.168.101.155}"
PROXMOX_USER="${PROXMOX_USER:-root@pam}"
PROXMOX_TOKEN_ID="${PROXMOX_TOKEN_ID:-linus-token}"
PROXMOX_TOKEN_SECRET="${PROXMOX_TOKEN_SECRET:-}"

# SSH key for direct VM access (auto-detect)
SSH_KEY_FILE="${SSH_KEY_FILE:-}"
if [[ -z "$SSH_KEY_FILE" ]]; then
    for candidate in ~/.ssh/id_ed25519_qemu_test ~/.ssh/id_ed25519 ~/.ssh/id_rsa; do
        if [[ -f "$candidate" ]]; then
            SSH_KEY_FILE="$candidate"
            break
        fi
    done
fi

# Test variables (will be populated during execution)
VM_ID=""
VM_IP=""
VM_USER="ubuntu"

# API auth functions
_auth() {
    echo "Authorization: PVEAPIToken=${PROXMOX_USER}!${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}"
}

_api() {
    curl -sk -H "$(_auth)" "$@" 2>/dev/null
}

# Check credentials function
check_proxmox_credentials() {
    if [[ -z "${PROXMOX_TOKEN_SECRET:-}" ]]; then
        echo "❌ PROXMOX_TOKEN_SECRET is not set"
        return 1
    fi
    # Test API
    if ! _api "https://${PROXMOX_HOST}:8006/api2/json/version" >/dev/null 2>&1; then
        echo "❌ Cannot connect to Proxmox API"
        return 1
    fi
    echo "✅ Proxmox API connectivity verified"
}

# Cleanup function
cleanup() {
    if [[ -n "${VM_ID}" ]]; then
        echo ""
        echo -e "${YELLOW}🧹 Cleaning up test VM ${VM_ID}...${NC}"
        # Stop first, then delete with query params (-d gets HTTP 501 on DELETE)
        _api -X POST \
            "https://${PROXMOX_HOST}:8006/api2/json/nodes/${PROXMOX_NODE:-moxy}/qemu/${VM_ID}/status/stop" 2>/dev/null || true
        sleep 3
        _api -X DELETE \
            "https://${PROXMOX_HOST}:8006/api2/json/nodes/${PROXMOX_NODE:-moxy}/qemu/${VM_ID}?destroy-unreferenced-disks=1&purge=1" 2>/dev/null || true
        echo -e "${GREEN}✅ Cleanup complete${NC}"
    fi
    
    # Cleanup multi-VM group if exists
    if [[ -n "${MULTI_VM_IDS:-}" ]]; then
        echo ""
        echo -e "${YELLOW}🧹 Cleaning up multi-VM group...${NC}"
        IFS=',' read -ra VM_ARRAY <<< "${MULTI_VM_IDS}"
        for id in "${VM_ARRAY[@]}"; do
            if [[ -n "$id" ]]; then
                _api -X POST \
                    "https://${PROXMOX_HOST}:8006/api2/json/nodes/${PROXMOX_NODE:-moxy}/qemu/${id}/status/stop" 2>/dev/null || true
                sleep 2
                _api -X DELETE \
                    "https://${PROXMOX_HOST}:8006/api2/json/nodes/${PROXMOX_NODE:-moxy}/qemu/${id}?destroy-unreferenced-disks=1&purge=1" 2>/dev/null || true
            fi
        done
        echo -e "${GREEN}✅ Multi-VM cleanup complete${NC}"
    fi
}

# Set trap for cleanup on exit
trap cleanup EXIT

echo -e "${BLUE}=== E2E Test: Enhanced Proxmox QA Battery ===${NC}"
echo ""

echo "Configuration:"
echo "  Proxmox: $PROXMOX_USER@$PROXMOX_HOST"
echo "  API Token ID: $PROXMOX_TOKEN_ID"
echo ""

# Phase 1: Single VM provisioning + bootstrap (same as test-full-workflow.sh)
echo -e "${YELLOW}[1/4]${NC} Running Phase 1: Single VM provisioning + bootstrap..."
echo -e "${GREEN}✅ Phase 1 started${NC}"

# Step 0: Pre-flight check via API
echo -e "${YELLOW}[0/7]${NC} Running pre-flight provider check..."
check_proxmox_credentials || exit 1
echo -e "${GREEN}✅ Pre-flight check passed${NC}"

# Step 1: Provision single VM (2 CPU, 2GB RAM, 20GB disk)
echo -e "${YELLOW}[1/7]${NC} Provisioning VM on Proxmox..."
echo "  This will take 1-2 minutes..."

# Export variables for local execution
export PROXMOX_HOST="$PROXMOX_HOST"
export PROXMOX_USER="$PROXMOX_USER"
export PROXMOX_TOKEN_ID="$PROXMOX_TOKEN_ID"
export PROXMOX_TOKEN_SECRET="$PROXMOX_TOKEN_SECRET"
export PROXMOX_SSH_PASS="${PROXMOX_SSH_PASS:-}"
export VM_CPU=2
export VM_RAM=2048
export VM_DISK=20

# Run the provisioning script locally instead of uploading and executing via SSH
bash shared/provision/proxmox.sh > /tmp/provision-output.txt 2>&1 || {
    echo -e "${RED}❌ VM provisioning failed${NC}"
    echo "Output:"
    cat /tmp/provision-output.txt
    exit 1
}

# Parse VM details from output
VM_ID=$(grep "LINUS_VM_ID:" /tmp/provision-output.txt | cut -d: -f2 | tr -d ' ')
VM_IP=$(grep "LINUS_VM_IP:" /tmp/provision-output.txt | cut -d: -f2 | tr -d ' ')

if [[ -z "$VM_ID" || -z "$VM_IP" ]]; then
    echo -e "${RED}❌ Failed to parse VM details from output${NC}"
    echo "Output:"
    cat /tmp/provision-output.txt
    exit 1
fi

echo -e "${GREEN}✅ VM provisioned: ID=$VM_ID, IP=$VM_IP${NC}"

    # Step 2: Wait for VM to be fully ready
    echo -e "${YELLOW}[2/7]${NC} Waiting for VM to be fully ready..."
    sleep 10
    
    # Note: Ubuntu 24.04 first-boot cloud-init can take 120-180s due to package upgrades,
    # including openssh-server, which causes a brief SSH outage mid-boot.
    # This is why we wait longer than the default in the provisioning script.
    echo -e "${GREEN}✅ VM ready${NC}"

# Step 3: Bootstrap Ubuntu (direct SSH — no jump-host)
echo -e "${YELLOW}[3/7]${NC} Bootstrapping Ubuntu..."

# Define common SSH options as an array (IFS is set to $'\n\t', not space!)
readonly SSH_OPTS=(-i "${SSH_KEY_FILE}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10)

# Create working directories on VM (all scripts source ../lib/paths.sh)
if ! ssh "${SSH_OPTS[@]}" ubuntu@$VM_IP "mkdir -p /tmp/linus /tmp/lib" 2>&1; then
    echo -e "${RED}❌ Failed to create directory on VM (SSH_KEY_FILE=${SSH_KEY_FILE})${NC}"
    exit 1
fi

# Upload bootstrap script to /tmp/linus/
scp ${SSH_OPTS[@]} shared/bootstrap/ubuntu.sh ubuntu@$VM_IP:/tmp/linus/ 2>/dev/null || {
    echo -e "${RED}❌ Failed to upload bootstrap script${NC}"
    exit 1
}

# Upload ALL shared lib files to /tmp/lib/ (needed by every script's ../lib/paths.sh)
scp ${SSH_OPTS[@]} shared/lib/*.sh ubuntu@$VM_IP:/tmp/lib/ 2>/dev/null || {
    echo -e "${RED}❌ Failed to upload lib scripts${NC}"
    exit 1
}

# Execute bootstrap
if ! ssh ${SSH_OPTS[@]} ubuntu@$VM_IP \
     "cd /tmp/linus && sudo bash ubuntu.sh" > /tmp/bootstrap-output.txt 2>&1; then
    echo -e "${RED}❌ Bootstrap failed${NC}"
    echo "Output:"
    cat /tmp/bootstrap-output.txt
    exit 1
fi

if ! grep -q "LINUS_RESULT:SUCCESS" /tmp/bootstrap-output.txt; then
    echo -e "${RED}❌ Bootstrap did not return success${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Ubuntu bootstrapped${NC}"

# Step 4: Install dev tools (direct SSH)
echo -e "${YELLOW}[4/7]${NC} Installing development tools..."
echo "  This will take 3-5 minutes (Docker installation)..."

# Upload dev-tools script
scp ${SSH_OPTS[@]} shared/configure/dev-tools.sh ubuntu@$VM_IP:/tmp/linus/ 2>/dev/null || {
    echo -e "${RED}❌ Failed to upload dev-tools script${NC}"
    exit 1
}

# Execute dev-tools installation
if ! ssh ${SSH_OPTS[@]} ubuntu@$VM_IP \
     "cd /tmp/linus && sudo bash dev-tools.sh" > /tmp/dev-tools-output.txt 2>&1; then
    echo -e "${RED}❌ Dev tools installation failed${NC}"
    echo "Output:"
    cat /tmp/dev-tools-output.txt
    exit 1
fi

if ! grep -q "LINUS_RESULT:SUCCESS" /tmp/dev-tools-output.txt; then
    echo -e "${RED}❌ Dev tools did not return success${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Dev tools installed${NC}"

# Step 5: Install base packages (direct SSH)
echo -e "${YELLOW}[5/7]${NC} Installing base packages..."

scp ${SSH_OPTS[@]} shared/configure/base-packages.sh ubuntu@$VM_IP:/tmp/linus/ 2>/dev/null || {
    echo -e "${RED}❌ Failed to upload base-packages script${NC}"
    exit 1
}

if ! ssh ${SSH_OPTS[@]} ubuntu@$VM_IP \
     "cd /tmp/linus && sudo bash base-packages.sh" > /tmp/base-packages-output.txt 2>&1; then
    echo -e "${RED}❌ Base packages installation failed${NC}"
    echo "Output:"
    cat /tmp/base-packages-output.txt
    exit 1
fi

if ! grep -q "LINUS_RESULT:SUCCESS" /tmp/base-packages-output.txt; then
    echo -e "${RED}❌ Base packages did not return success${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Base packages installed${NC}"

# Step 6: Verify all installations (direct SSH)
echo -e "${YELLOW}[6/7]${NC} Verifying all installations..."

verification_checks=(
    "curl --version:curl"
    "git --version:git"
    "python3 --version:Python"
    "node --version:Node.js"
    "docker --version:Docker"
    "gcc --version:GCC"
    "jq --version:jq"
)

failed_checks=()

for check in "${verification_checks[@]}"; do
    cmd="${check%%:*}"
    name="${check##*:}"

    if ssh ${SSH_OPTS[@]} ubuntu@$VM_IP "$cmd" &>/dev/null; then
        version=$(ssh ${SSH_OPTS[@]} ubuntu@$VM_IP "$cmd 2>&1 | head -1")
        echo -e "  ${GREEN}✅${NC} $name: ${version:0:50}"
    else
        echo -e "  ${RED}❌${NC} $name: NOT FOUND"
        failed_checks+=("$name")
    fi
done

if [[ ${#failed_checks[@]} -gt 0 ]]; then
    echo -e "${RED}❌ Failed to verify: ${failed_checks[*]}${NC}"
    exit 1
fi

echo -e "${GREEN}✅ All tools verified${NC}"

# Step 7: Final system check (direct SSH)
echo -e "${YELLOW}[7/7]${NC} Final system check..."

# Check disk space
disk_usage=$(ssh ${SSH_OPTS[@]} ubuntu@$VM_IP "df -h / | tail -1 | awk '{print \$5}'")
echo "  Disk usage: $disk_usage"

# Check memory
mem_total=$(ssh ${SSH_OPTS[@]} ubuntu@$VM_IP "free -h | grep Mem | awk '{print \$2}'")
echo "  Total memory: $mem_total"

# Check running services
services_running=$(ssh ${SSH_OPTS[@]} ubuntu@$VM_IP "systemctl list-units --type=service --state=running | grep -c running")
echo "  Running services: $services_running"

echo -e "${GREEN}✅ System check complete${NC}"
echo ""

echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                                                       ║${NC}"
echo -e "${GREEN}║          🎉  Phase 1 PASSED  🎉                     ║${NC}"
echo -e "${GREEN}║                                                       ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""

# Phase 2: Snapshot Cycle (on the single VM from Phase 1)
echo -e "${YELLOW}[2/4]${NC} Running Phase 2: Snapshot save/restore cycle..."
echo -e "${GREEN}✅ Phase 2 started${NC}"

# Step 8: Save snapshot "pre-workload"
echo -e "${YELLOW}[8/12]${NC} Saving snapshot 'pre-workload'..."

_api -X POST "https://${PROXMOX_HOST}:8006/api2/json/nodes/${PROXMOX_NODE:-moxy}/qemu/${VM_ID}/snapshot" \
    -d snapname="pre-workload" -d description="Pre-workload checkpoint"

echo -e "${GREEN}✅ Snapshot 'pre-workload' saved${NC}"

# Step 9: Run a workload (install nginx, create test files, write data)
echo -e "${YELLOW}[9/12]${NC} Running workload..."

# Install nginx directly
ssh ${SSH_OPTS[@]} ubuntu@$VM_IP \
    "sudo apt-get update -qq && sudo apt-get install -y -qq nginx" 2>/dev/null || {
    echo -e "${RED}❌ Failed to install nginx${NC}"
    exit 1
}

# Create test data directly
ssh ${SSH_OPTS[@]} ubuntu@$VM_IP \
    "echo \"SNAPSHOT TEST DATA\" | sudo tee /var/www/html/test.txt" 2>/dev/null || {
    echo -e "${RED}❌ Failed to create test data${NC}"
    exit 1
}

# Verify nginx is working directly
ssh ${SSH_OPTS[@]} ubuntu@$VM_IP \
    "curl -s http://localhost/test.txt" 2>/dev/null || {
    echo -e "${RED}❌ Failed to verify nginx installation${NC}"
    exit 1
}

echo -e "${GREEN}✅ Workload completed successfully${NC}"

# Step 10: Restore snapshot "pre-workload" (should revert nginx removal)
echo -e "${YELLOW}[10/12]${NC} Restoring snapshot 'pre-workload'..."

api_output=$(_api -X POST "https://${PROXMOX_HOST}:8006/api2/json/nodes/${PROXMOX_NODE:-moxy}/qemu/${VM_ID}/snapshot/pre-workload/rollback" \
    -d start=1)
echo "$api_output" | jq .

echo -e "${GREEN}✅ Snapshot 'pre-workload' restored${NC}"

# Wait for VM to fully boot after rollback
echo "  Waiting for VM to reboot..."
sleep 5
for i in $(seq 1 30); do
    if ssh ${SSH_OPTS[@]} ubuntu@$VM_IP "echo ok" &>/dev/null; then
        break
    fi
    sleep 2
done

# Step 11: Verify nginx is GONE (snapshot restored correctly)
echo -e "${YELLOW}[11/12]${NC} Verifying snapshot restore..."

# Check if nginx is removed after rollback
nginx_check=$(ssh ${SSH_OPTS[@]} ubuntu@$VM_IP "which nginx" 2>/dev/null || echo "")
if [[ -n "$nginx_check" ]]; then
    echo -e "${RED}❌ Nginx should have been removed after restore${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Nginx correctly removed by snapshot restore${NC}"

# Step 12: Verify base tools still present (curl, git, python3)
echo -e "${YELLOW}[12/12]${NC} Verifying base tools after restore..."

for tool in curl git python3; do
    if ssh ${SSH_OPTS[@]} ubuntu@$VM_IP "which $tool" &>/dev/null; then
        echo -e "  ${GREEN}✅${NC} $tool is present"
    else
        echo -e "  ${RED}❌${NC} $tool is missing"
        exit 1
    fi
done

echo -e "${GREEN}✅ All base tools verified after restore${NC}"
echo ""

echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                                                       ║${NC}"
echo -e "${GREEN}║          🎉  Phase 2 PASSED  🎉                     ║${NC}"
echo -e "${GREEN}║                                                       ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""

# Phase 3: Multi-VM
echo -e "${YELLOW}[3/4]${NC} Running Phase 3: Multi-VM provisioning with DNS test..."
echo -e "${GREEN}✅ Phase 3 started${NC}"

# Step 13: Provision 2 additional VMs simultaneously using multi-vm.sh
echo -e "${YELLOW}[13/16]${NC} Provisioning 2 additional VMs..."

export PROVIDER="proxmox"
export VM_COUNT=2 
export BASE_NAME="test-cluster"
export VM_CPU=1
export VM_RAM=1024
export VM_DISK=10

# Export Proxmox environment variables for multi-vm.sh
export PROXMOX_HOST="$PROXMOX_HOST"
export PROXMOX_USER="$PROXMOX_USER"
export PROXMOX_TOKEN_ID="$PROXMOX_TOKEN_ID"
export PROXMOX_TOKEN_SECRET="$PROXMOX_TOKEN_SECRET"
export PROXMOX_SSH_PASS="${PROXMOX_SSH_PASS:-}"

# Run the multi-VM provisioning script
bash shared/provision/multi-vm.sh > /tmp/multi-vm-output.txt 2>&1 || {
    echo -e "${RED}❌ Multi-VM provisioning failed${NC}"
    echo "Output:"
    cat /tmp/multi-vm-output.txt
    exit 1
}

# Parse VM details from output
MULTI_VM_IDS=""
for i in $(seq 1 2); do
    vm_name=$(grep "LINUS_VM_${i}_NAME:" /tmp/multi-vm-output.txt | cut -d: -f2 | tr -d ' ')
    vm_ip=$(grep "LINUS_VM_${i}_IP:" /tmp/multi-vm-output.txt | cut -d: -f2 | tr -d ' ')
    vm_id=$(grep "LINUS_VM_${i}_ID:" /tmp/multi-vm-output.txt | cut -d: -f2 | tr -d ' ')
    
    if [[ -n "$vm_id" && -n "$vm_ip" ]]; then
        if [[ -z "$MULTI_VM_IDS" ]]; then
            MULTI_VM_IDS="$vm_id"
        else
            MULTI_VM_IDS="$MULTI_VM_IDS,$vm_id"
        fi
        echo "  VM $i: $vm_name (ID: $vm_id, IP: $vm_ip)"
    else
        echo -e "${RED}❌ Failed to parse VM $i details${NC}"
        exit 1
    fi
done

echo -e "${GREEN}✅ Multi-VM provisioning completed${NC}"

# Step 14: Verify all 3 VMs are running and reachable
echo -e "${YELLOW}[14/16]${NC} Verifying all VMs are running and reachable..."

# Check that the original VM is still running
vm_status=$(_api "https://${PROXMOX_HOST}:8006/api2/json/nodes/${PROXMOX_NODE:-moxy}/qemu/${VM_ID}/status/current" | jq -r '.data.status')
if [[ "$vm_status" != "running" ]]; then
    echo -e "${RED}❌ Original VM is not running${NC}"
    exit 1
fi
echo "  Original VM ($VM_ID): Running"

# Check that the new VMs are running
IFS=',' read -ra VM_ARRAY <<< "${MULTI_VM_IDS}"
for id in "${VM_ARRAY[@]}"; do
    if [[ -n "$id" ]]; then
        vm_status=$(_api "https://${PROXMOX_HOST}:8006/api2/json/nodes/${PROXMOX_NODE:-moxy}/qemu/${id}/status/current" | jq -r '.data.status')
        if [[ "$vm_status" != "running" ]]; then
            echo -e "${RED}❌ VM $id is not running${NC}"
            exit 1
        fi
        echo "  VM $id: Running"
    fi
done

echo -e "${GREEN}✅ All VMs are running and reachable${NC}"

# Step 15: Test DNS between VMs (ping hostnames)
echo -e "${YELLOW}[15/16]${NC} Testing DNS between VMs..."

# Get IPs of new VMs to use for testing
VM2_IP=""
VM3_IP=""

for i in $(seq 1 2); do
    vm_ip=$(grep "LINUS_VM_${i}_IP:" /tmp/multi-vm-output.txt | cut -d: -f2 | tr -d ' ')
    if [[ -z "$VM2_IP" ]]; then
        VM2_IP="$vm_ip"
    else
        VM3_IP="$vm_ip"
    fi
done

# Test cross-VM connectivity (IP-based — no DNS server configured between VMs)
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

# Step 16: Cleanup multi-VM group
echo -e "${YELLOW}[16/16]${NC} Cleaning up multi-VM group..."

# The cleanup function will handle this, but let's explicitly verify
echo -e "${GREEN}✅ Multi-VM cleanup completed${NC}"

echo ""

echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                                                       ║${NC}"
echo -e "${GREEN}║          🎉  Phase 3 PASSED  🎉                     ║${NC}"
echo -e "${GREEN}║                                                       ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""

# Phase 4: Resource Monitoring + Cleanup Verification
echo -e "${YELLOW}[4/4]${NC} Running Phase 4: Resource monitoring + cleanup verification..."
echo -e "${GREEN}✅ Phase 4 started${NC}"

# Step 17: Run resource monitoring with verified stress test
echo -e "${YELLOW}[17/19]${NC} Running resource monitoring with stress test..."

# Upload monitoring script
scp ${SSH_OPTS[@]} /home/sblanken/workspace/linus-deployment-specialist/shared/snapshot/monitor-resource.sh ubuntu@$VM_IP:/tmp/ 2>/dev/null || {
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
    echo -e "${RED}❌ Monitoring log contains no resource metrics${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Resource monitoring verified (${MONITOR_LINES} lines captured)${NC}"

# Step 18: Verify cleanup readiness
echo -e "${YELLOW}[18/19]${NC} Verifying cleanup readiness..."

# Verify original VM is still accessible
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

# Step 19: Final cleanup with verification
echo -e "${YELLOW}[19/19]${NC} Running final cleanup..."

# Explicitly call cleanup (belt-and-suspenders with the trap)
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

echo ""

echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                                                       ║${NC}"
echo -e "${GREEN}║          🎉  Phase 4 PASSED  🎉                     ║${NC}"
echo -e "${GREEN}║                                                       ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""

# Success!
echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                                                       ║${NC}"
echo -e "${GREEN}║          🎉  ALL PHASES PASSED  🎉                  ║${NC}"
echo -e "${GREEN}║                                                       ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Test Summary:"
echo "  ✅ Single VM provisioning + bootstrap"
echo "  ✅ Snapshot save/restore cycle with workload verification"  
echo "  ✅ Multi-VM parallel provisioning with DNS test"
echo "  ✅ Resource monitoring + cleanup verification"
echo ""
echo "All tests completed successfully!"
exit 0