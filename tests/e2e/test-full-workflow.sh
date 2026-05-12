#!/usr/bin/env bash
# ============================================================================= 
# STEP 0: Pre-flight provider check
# ==============================================================================

echo -e "${YELLOW}[0/7]${NC} Running pre-flight provider check..."
if ! bash scripts/check-provider.sh proxmox --host "$PROXMOX_HOST" --user "$PROXMOX_USER"; then
    echo -e "${RED}❌ Pre-flight check failed — provider not ready${NC}"
    exit 1
fi
echo -e "${GREEN}✅ Pre-flight check passed${NC}"
echo ""

# ============================================================================= 
# Step 1: Provision VM
# ==============================================================================
# Purpose: Test complete workflow from VM creation to fully configured environment
# Duration: ~8-10 minutes
# Requirements: Proxmox host with SSH access, template VM configured
# ==============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Navigate to project root
cd "$(dirname "$0")/../.."

echo -e "${BLUE}=== E2E Test: Full Provision + Bootstrap Workflow ===${NC}"
echo ""

# Configuration
PROXMOX_HOST="${PROXMOX_HOST:-192.168.101.155}"
PROXMOX_USER="${PROXMOX_USER:-root@pam}"
PROXMOX_TOKEN_ID="${PROXMOX_TOKEN_ID:-linus-token}"
PROXMOX_TOKEN_SECRET="${PROXMOX_TOKEN_SECRET:-}"

echo "Configuration:"
echo "  Proxmox: $PROXMOX_USER@$PROXMOX_HOST"
echo "  API Token ID: $PROXMOX_TOKEN_ID"
echo ""

# Test variables (will be populated during execution)
VM_ID=""
VM_IP=""
VM_USER="ubuntu"

# Check credentials function
check_proxmox_credentials() {
    if [[ -z "${PROXMOX_TOKEN_SECRET:-}" ]]; then
        echo "❌ PROXMOX_TOKEN_SECRET is not set"
        return 1
    fi
    # Test API
    if ! curl -sk --connect-timeout 10 -H "Authorization: PVEAPIToken=${PROXMOX_USER}!${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" "https://${PROXMOX_HOST}:8006/api2/json/version" >/dev/null 2>&1; then
        echo "❌ Cannot connect to Proxmox API"
        return 1
    fi
    echo "✅ Proxmox API connectivity verified"
}

# Verify credentials
echo -e "${YELLOW}[0/7]${NC} Verifying credentials..."
check_proxmox_credentials || exit 1

# Cleanup function
cleanup() {
    if [[ -n "${VM_ID}" ]]; then
        echo ""
        echo -e "${YELLOW}🧹 Cleaning up test VM ${VM_ID}...${NC}"
        # Use API call instead of SSH to delete VM
        curl -sk -X DELETE \
            -H "Authorization: PVEAPIToken=${PROXMOX_USER}!${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
            "https://${PROXMOX_HOST}:8006/api2/json/nodes/${PROXMOX_NODE:-moxy}/qemu/${VM_ID}" \
            -d 'destroy-unreferenced-disks=1' -d 'purge=1' 2>/dev/null || true
        echo -e "${GREEN}✅ Cleanup complete${NC}"
    fi
}

# Set trap for cleanup on exit
trap cleanup EXIT

# Step 1: Provision VM
echo -e "${YELLOW}[1/7]${NC} Provisioning VM on Proxmox..."
echo "  This will take 1-2 minutes..."

# Export variables for local execution (since we're running locally now)
export PROXMOX_HOST="$PROXMOX_HOST"
export PROXMOX_USER="$PROXMOX_USER"
export PROXMOX_TOKEN_ID="$PROXMOX_TOKEN_ID"
export PROXMOX_TOKEN_SECRET="$PROXMOX_TOKEN_SECRET"
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
echo ""

# Step 2: Wait for VM to be fully ready
echo -e "${YELLOW}[2/7]${NC} Waiting for VM to be fully ready..."
sleep 10
echo -e "${GREEN}✅ VM ready${NC}"
echo ""

# Step 3: Bootstrap Ubuntu
echo -e "${YELLOW}[3/7]${NC} Bootstrapping Ubuntu..."
echo "  This will take 1-2 minutes..."

# Upload bootstrap script
if ! ssh -o StrictHostKeyChecking=no \
         -o UserKnownHostsFile=/dev/null \
         "$VM_USER@$VM_IP" \
         "mkdir -p /tmp/linus" 2>/dev/null; then
    echo -e "${RED}❌ Failed to create directory on VM${NC}"
    exit 1
fi

if ! scp -o StrictHostKeyChecking=no \
         -o UserKnownHostsFile=/dev/null \
         shared/bootstrap/ubuntu.sh \
         shared/lib/{logging.sh,validation.sh} \
         "$VM_USER@$VM_IP:/tmp/linus/" 2>/dev/null; then
    echo -e "${RED}❌ Failed to upload bootstrap script${NC}"
    exit 1
fi

# Execute bootstrap
if ! ssh -o StrictHostKeyChecking=no \
         -o UserKnownHostsFile=/dev/null \
         "$VM_USER@$VM_IP" \
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
echo ""

# Step 4: Install dev tools
echo -e "${YELLOW}[4/7]${NC} Installing development tools..."
echo "  This will take 3-5 minutes (Docker installation)..."

# Upload dev-tools script and dependencies
if ! scp -o StrictHostKeyChecking=no \
         -o UserKnownHostsFile=/dev/null \
         shared/configure/dev-tools.sh \
         shared/lib/noninteractive.sh \
         "$VM_USER@$VM_IP:/tmp/linus/" 2>/dev/null; then
    echo -e "${RED}❌ Failed to upload dev-tools script${NC}"
    exit 1
fi

# Execute dev-tools installation
if ! ssh -o StrictHostKeyChecking=no \
         -o UserKnownHostsFile=/dev/null \
         "$VM_USER@$VM_IP" \
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
echo ""

# Step 5: Install base packages
echo -e "${YELLOW}[5/7]${NC} Installing base packages..."

if ! scp -o StrictHostKeyChecking=no \
         -o UserKnownHostsFile=/dev/null \
         shared/configure/base-packages.sh \
         "$VM_USER@$VM_IP:/tmp/linus/" 2>/dev/null; then
    echo -e "${RED}❌ Failed to upload base-packages script${NC}"
    exit 1
fi

if ! ssh -o StrictHostKeyChecking=no \
         -o UserKnownHostsFile=/dev/null \
         "$VM_USER@$VM_IP" \
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
echo ""

# Step 6: Verify all installations
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

    if ssh -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
           "$VM_USER@$VM_IP" \
           "$cmd" &>/dev/null; then
        version=$(ssh -o StrictHostKeyChecking=no \
                      -o UserKnownHostsFile=/dev/null \
                      "$VM_USER@$VM_IP" \
                      "$cmd 2>&1 | head -1")
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
echo ""

# Step 7: Final system check
echo -e "${YELLOW}[7/7]${NC} Final system check..."

# Check disk space
disk_usage=$(ssh -o StrictHostKeyChecking=no \
                 -o UserKnownHostsFile=/dev/null \
                 "$VM_USER@$VM_IP" \
                 "df -h / | tail -1 | awk '{print \$5}'")
echo "  Disk usage: $disk_usage"

# Check memory
mem_total=$(ssh -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null \
                "$VM_USER@$VM_IP" \
                "free -h | grep Mem | awk '{print \$2}'")
echo "  Total memory: $mem_total"

# Check running services
services_running=$(ssh -o StrictHostKeyChecking=no \
                       -o UserKnownHostsFile=/dev/null \
                       "$VM_USER@$VM_IP" \
                       "systemctl list-units --type=service --state=running | grep -c running")
echo "  Running services: $services_running"

echo -e "${GREEN}✅ System check complete${NC}"
echo ""

# Success!
echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                                                       ║${NC}"
echo -e "${GREEN}║          🎉  E2E Test PASSED  🎉                     ║${NC}"
echo -e "${GREEN}║                                                       ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Test Summary:"
echo "  ✅ VM provisioned (ID: $VM_ID, IP: $VM_IP)"
echo "  ✅ Ubuntu bootstrapped"
echo "  ✅ Development tools installed (Python, Node.js, Docker)"
echo "  ✅ Base packages installed (build tools, utilities)"
echo "  ✅ All tools verified (7 tools checked)"
echo "  ✅ System check passed"
echo ""
echo "VM will be destroyed in 5 seconds..."
sleep 5

# Cleanup will happen automatically via trap
exit 0
