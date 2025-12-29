#!/usr/bin/env bash
# =============================================================================
# E2E Test: Full Provision + Bootstrap Workflow
# =============================================================================
# Purpose: Test complete workflow from VM creation to fully configured environment
# Duration: ~8-10 minutes
# Requirements: Proxmox host with SSH access, template VM configured
# =============================================================================

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
PROXMOX_USER="${PROXMOX_USER:-root}"
PROXMOX_SSH_KEY="${PROXMOX_SSH_KEY:-$HOME/.ssh/id_rsa}"

echo "Configuration:"
echo "  Proxmox: $PROXMOX_USER@$PROXMOX_HOST"
echo "  SSH Key: $PROXMOX_SSH_KEY"
echo ""

# Test variables (will be populated during execution)
VM_ID=""
VM_IP=""
VM_USER="ubuntu"

# Cleanup function
cleanup() {
    if [[ -n "${VM_ID}" ]]; then
        echo ""
        echo -e "${YELLOW}🧹 Cleaning up test VM ${VM_ID}...${NC}"
        ssh -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -i "$PROXMOX_SSH_KEY" \
            "$PROXMOX_USER@$PROXMOX_HOST" \
            "qm stop ${VM_ID} 2>/dev/null || true; qm destroy ${VM_ID} 2>/dev/null || true"
        echo -e "${GREEN}✅ Cleanup complete${NC}"
    fi
}

# Set trap for cleanup on exit
trap cleanup EXIT

# Step 1: Provision VM
echo -e "${YELLOW}[1/7]${NC} Provisioning VM on Proxmox..."
echo "  This will take 1-2 minutes..."

# Upload provisioning script
if ! scp -o StrictHostKeyChecking=no \
         -o UserKnownHostsFile=/dev/null \
         -i "$PROXMOX_SSH_KEY" \
         shared/provision/proxmox.sh \
         shared/lib/*.sh \
         "$PROXMOX_USER@$PROXMOX_HOST:/tmp/" 2>/dev/null; then
    echo -e "${RED}❌ Failed to upload provisioning script${NC}"
    exit 1
fi

# Execute provisioning
export VM_CPU=2
export VM_RAM=2048
export VM_DISK=20

if ! ssh -o StrictHostKeyChecking=no \
         -o UserKnownHostsFile=/dev/null \
         -i "$PROXMOX_SSH_KEY" \
         "$PROXMOX_USER@$PROXMOX_HOST" \
         "cd /tmp && VM_CPU=2 VM_RAM=2048 VM_DISK=20 bash proxmox.sh" > /tmp/provision-output.txt 2>&1; then
    echo -e "${RED}❌ VM provisioning failed${NC}"
    echo "Output:"
    cat /tmp/provision-output.txt
    exit 1
fi

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
