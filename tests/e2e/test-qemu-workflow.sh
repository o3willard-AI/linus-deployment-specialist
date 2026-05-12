#!/usr/bin/env bash
# =============================================================================
# E2E Test: QEMU/libvirt Full Workflow
# =============================================================================
# Purpose: Test complete QEMU/libvirt provisioning + bootstrap workflow
# Duration: ~10-15 minutes
# Requirements: QEMU/KVM host with SSH access (see below)
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

echo -e "${BLUE}=== E2E Test: QEMU/libvirt Full Workflow ===${NC}"
echo ""

# =============================================================================
# CREDENTIAL CONFIGURATION
# =============================================================================
# Credentials can be provided via environment variables
#
# Required environment variables:
#   QEMU_HOST    - QEMU/KVM host IP address
#   QEMU_USER    - SSH username (must have sudo privileges)
#   QEMU_SUDO_PASS - User password for sudo (or use SSH key)
#
# Optional environment variables:
#   QEMU_SSH_KEY     - SSH private key path (default: ~/.ssh/id_rsa)
#   QEMU_POOL        - Storage pool name (default: default)
#   QEMU_NETWORK     - Network name (default: default)
#
# For GitHub Actions, add these as secrets:
#   QEMU_HOST
#   QEMU_USER  
#   QEMU_SUDO_PASS (or use QEMU_SSH_KEY with stored private key)
#
# Note: QEMU tests typically require a self-hosted runner with access
# to the QEMU/KVM infrastructure, not standard GitHub Actions runners.
# =============================================================================

# Configuration
QEMU_HOST="${QEMU_HOST:-192.168.101.59}"
QEMU_USER="${QEMU_USER:-}"
QEMU_SUDO_PASS="${QEMU_SUDO_PASS:-}"
QEMU_SSH_KEY="${QEMU_SSH_KEY:-$HOME/.ssh/id_ed25519_qemu_test}"
QEMU_POOL="${QEMU_POOL:-default}"
QEMU_NETWORK="${QEMU_NETWORK:-default}"
VM_USER="ubuntu"

echo "Configuration:"
echo "  QEMU Host: $QEMU_HOST"
echo "  QEMU User: ${QEMU_USER:-<not set>}"
echo "  SSH Key: $QEMU_SSH_KEY"
echo "  Pool: $QEMU_POOL"
echo "  Network: $QEMU_NETWORK"
echo ""

# =============================================================================
# CREDENTIAL VALIDATION
# =============================================================================

check_qemu_credentials() {
    echo -e "${YELLOW}Validating QEMU credentials...${NC}"
    
    # Check required variables
    if [[ -z "${QEMU_HOST:-}" ]]; then
        echo -e "${RED}❌ QEMU_HOST is not set${NC}"
        echo ""
        echo "Please set QEMU credentials using environment variables:"
        echo ""
        echo "  export QEMU_HOST=192.168.101.59"
        echo "  export QEMU_USER=your_username"
        echo "  export QEMU_SUDO_PASS=your_password"
        echo ""
        echo "For GitHub Actions with self-hosted runners:"
        echo "  Add QEMU_HOST, QEMU_USER, QEMU_SUDO_PASS as secrets"
        echo ""
        return 1
    fi
    
    if [[ -z "${QEMU_USER:-}" ]]; then
        echo -e "${RED}❌ QEMU_USER is not set${NC}"
        return 1
    fi
    
    if [[ -z "${QEMU_SUDO_PASS:-}" && ! -f "$QEMU_SSH_KEY" ]]; then
        echo -e "${RED}❌ Neither QEMU_SUDO_PASS nor valid SSH key provided${NC}"
        echo "Please either:"
        echo "  - Set QEMU_SUDO_PASS environment variable"
        echo "  - Provide a valid SSH key at QEMU_SSH_KEY"
        return 1
    fi
    
    # Verify SSH connectivity
    echo "  Testing SSH connection to $QEMU_USER@$QEMU_HOST..."
    
    if ssh -o StrictHostKeyChecking=no \
           -o ConnectTimeout=10 \
           -o UserKnownHostsFile=/dev/null \
           ${QEMU_SSH_KEY:+-i "$QEMU_SSH_KEY"} \
           "$QEMU_USER@$QEMU_HOST" \
           "echo 'SSH connection successful'" &>/dev/null; then
        echo -e "${GREEN}✅ QEMU host SSH connectivity verified${NC}"
        return 0
    else
        echo -e "${RED}❌ Cannot connect to QEMU host via SSH${NC}"
        echo "Please verify:"
        echo "  - QEMU_HOST is reachable"
        echo "  - QEMU_USER has SSH access"
        echo "  - SSH key is valid or password is correct"
        return 1
    fi
}

# Check credentials before proceeding
if ! check_qemu_credentials; then
    echo ""
    echo -e "${YELLOW}⚠ QEMU E2E test requires credentials to run${NC}"
    echo "This test is designed to run:"
    echo "  - Locally with environment variables set"
    echo "  - On a self-hosted GitHub Actions runner with QEMU access"
    echo ""
    echo "Standard GitHub Actions runners cannot run QEMU tests"
    echo "because they lack access to QEMU/KVM infrastructure."
    exit 1
fi

echo ""

# =============================================================================
# TEST VARIABLES
# =============================================================================

VM_NAME=""
VM_IP=""

# =============================================================================
# CLEANUP FUNCTION
# =============================================================================

cleanup() {
    if [[ -n "${VM_NAME}" ]]; then
        echo ""
        echo -e "${YELLOW}🧹 Cleaning up test VM ${VM_NAME}...${NC}"
        
        # Try to destroy and undefine the VM
        ssh -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            ${QEMU_SSH_KEY:+-i "$QEMU_SSH_KEY"} \
            "$QEMU_USER@$QEMU_HOST" \
            "echo '$QEMU_SUDO_PASS' | sudo -S virsh destroy ${VM_NAME} 2>/dev/null || true; echo '$QEMU_SUDO_PASS' | sudo -S virsh undefine ${VM_NAME} --remove-all-storage 2>/dev/null || true" \
            &>/dev/null || true
        
        echo -e "${GREEN}✅ Cleanup complete${NC}"
    fi
}

# Set trap for cleanup on exit
trap cleanup EXIT

# =============================================================================
# STEP 1: PROVISION VM
# ==============================================================================

echo -e "${YELLOW}[1/7]${NC} Provisioning VM on QEMU/KVM..."
echo "  This will take 2-5 minutes..."

# Export variables for the provisioning script — run locally, not on QEMU host.
# qemu.sh uses ssh_sudo()/ssh_exec() to connect to QEMU_HOST internally.
export QEMU_HOST="$QEMU_HOST"
export QEMU_USER="$QEMU_USER"
export QEMU_SUDO_PASS="$QEMU_SUDO_PASS"
export QEMU_SSH_KEY="$QEMU_SSH_KEY"
export VM_CPU=2
export VM_RAM=2048
export VM_DISK=20

# Execute provisioning script locally
bash shared/provision/qemu.sh > /tmp/qemu-provision-output.txt 2>&1 || {
    echo -e "${RED}❌ VM provisioning failed${NC}"
    echo "Output:"
    cat /tmp/qemu-provision-output.txt
    exit 1
}

# Parse VM details from output
VM_NAME=$(grep "LINUS_VM_NAME:" /tmp/qemu-provision-output.txt | cut -d: -f2 | tr -d ' ' || true)
VM_IP=$(grep "LINUS_VM_IP:" /tmp/qemu-provision-output.txt | cut -d: -f2 | tr -d ' ' || true)

if [[ -z "$VM_IP" ]]; then
    echo -e "${RED}❌ Failed to parse VM IP from output${NC}"
    echo "Output:"
    cat /tmp/qemu-provision-output.txt
    exit 1
fi

echo -e "${GREEN}✅ VM provisioned: Name=$VM_NAME, IP=$VM_IP${NC}"
echo ""

# =============================================================================
# STEP 2: WAIT FOR VM TO BE READY
# ==============================================================================

echo -e "${YELLOW}[2/7]${NC} Waiting for VM to be fully ready..."
echo "  (QEMU cloud-init takes longer than other providers)..."

# Cloud-init on QEMU can take 5-7 minutes (15-20 min with software emulation / no KVM)
max_attempts=300
attempt=0
while [[ $attempt -lt $max_attempts ]]; do
    if ssh -o StrictHostKeyChecking=no \
           -o ConnectTimeout=10 \
           -o UserKnownHostsFile=/dev/null \
           ${QEMU_SSH_KEY:+-i "$QEMU_SSH_KEY"} \
           "$QEMU_USER@$QEMU_HOST" \
           "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $VM_USER@$VM_IP 'echo SSH ready'" &>/dev/null; then
        echo -e "${GREEN}✅ VM is ready for SSH (after $((attempt * 5 / 60)) min)${NC}"
        break
    fi
    
    attempt=$((attempt + 1))
    if [[ $((attempt % 12)) -eq 0 ]]; then
        echo "  Waiting... ($attempt/$max_attempts, ~$((attempt * 5 / 60)) min elapsed)"
    fi
    sleep 5
done

if [[ $attempt -eq $max_attempts ]]; then
    echo -e "${RED}❌ VM did not become ready in time${NC}"
    echo "Note: QEMU cloud-init typically takes 5-7 minutes"
    exit 1
fi

echo ""

# ============================================================================= 
# STEP 3-7: BOOTSTRAP, DEV TOOLS, BASE PACKAGES, VERIFY  
# =============================================================================

echo -e "${YELLOW}[3/7]${NC} Bootstrapping Ubuntu..."

# Upload bootstrap script using jump-host pattern
ssh -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    ${QEMU_SSH_KEY:+-i "$QEMU_SSH_KEY"} \
    "$QEMU_USER@$QEMU_HOST" \
    "mkdir -p /tmp/linus-qemu" || exit 1

# Upload bootstrap script and dependencies to QEMU host
scp -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    ${QEMU_SSH_KEY:+-i "$QEMU_SSH_KEY"} \
    shared/bootstrap/ubuntu.sh \
    shared/lib/{logging.sh,validation.sh} \
    "$QEMU_USER@$QEMU_HOST:/tmp/linus-qemu/" || exit 1

# Copy to VM with proper directory structure
ssh -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    ${QEMU_SSH_KEY:+-i "$QEMU_SSH_KEY"} \
    "$QEMU_USER@$QEMU_HOST" \
    "mkdir -p /tmp/linus/lib && cp /tmp/linus-qemu/ubuntu.sh /tmp/linus/ && cp /tmp/linus-qemu/*.sh /tmp/linus/lib/ 2>/dev/null; scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -r /tmp/linus/ $VM_USER@$VM_IP:/tmp/ && ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $VM_USER@$VM_IP 'mkdir -p /tmp/lib && cp /tmp/linus/lib/* /tmp/lib/ 2>/dev/null; cd /tmp/linus && sudo bash ubuntu.sh'" > /tmp/bootstrap-output.txt 2>&1 || {
    echo -e "${RED}❌ Bootstrap failed${NC}"
    cat /tmp/bootstrap-output.txt
    exit 1
}

if ! grep -q "LINUS_RESULT:SUCCESS" /tmp/bootstrap-output.txt; then
    echo -e "${RED}❌ Bootstrap did not return success${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Ubuntu bootstrapped${NC}"
echo ""

# ============================================================================= 
# STEP 4: Install dev tools
# =============================================================================

echo -e "${YELLOW}[4/7]${NC} Installing development tools..."
echo "  This will take 3-5 minutes (Docker installation)..."

# Upload dev-tools script and dependencies using jump-host pattern
scp -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    ${QEMU_SSH_KEY:+-i "$QEMU_SSH_KEY"} \
    shared/configure/dev-tools.sh \
    shared/lib/{noninteractive.sh,logging.sh,validation.sh} \
    "$QEMU_USER@$QEMU_HOST:/tmp/linus-qemu/" || exit 1

ssh -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    ${QEMU_SSH_KEY:+-i "$QEMU_SSH_KEY"} \
    "$QEMU_USER@$QEMU_HOST" \
    "mkdir -p /tmp/linus/lib && cp /tmp/linus-qemu/dev-tools.sh /tmp/linus/ && cp /tmp/linus-qemu/*.sh /tmp/linus/lib/ 2>/dev/null; scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -r /tmp/linus/ $VM_USER@$VM_IP:/tmp/ && ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $VM_USER@$VM_IP 'mkdir -p /tmp/lib && cp /tmp/linus/lib/* /tmp/lib/ 2>/dev/null; cd /tmp/linus && sudo bash dev-tools.sh'" > /tmp/dev-tools-output.txt 2>&1 || {
    echo -e "${RED}❌ Dev tools installation failed${NC}"
    echo "Output:"
    cat /tmp/dev-tools-output.txt
    exit 1
}

if ! grep -q "LINUS_RESULT:SUCCESS" /tmp/dev-tools-output.txt; then
    echo -e "${RED}❌ Dev tools did not return success${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Dev tools installed${NC}"
echo ""

# ============================================================================= 
# STEP 5: Install base packages
# =============================================================================

echo -e "${YELLOW}[5/7]${NC} Installing base packages..."

# Upload base-packages script and dependencies using jump-host pattern
scp -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    ${QEMU_SSH_KEY:+-i "$QEMU_SSH_KEY"} \
    shared/configure/base-packages.sh \
    shared/lib/{logging.sh,validation.sh,noninteractive.sh} \
    "$QEMU_USER@$QEMU_HOST:/tmp/linus-qemu/" || exit 1

ssh -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    ${QEMU_SSH_KEY:+-i "$QEMU_SSH_KEY"} \
    "$QEMU_USER@$QEMU_HOST" \
    "mkdir -p /tmp/linus/lib && cp /tmp/linus-qemu/base-packages.sh /tmp/linus/ && cp /tmp/linus-qemu/*.sh /tmp/linus/lib/ 2>/dev/null; scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -r /tmp/linus/ $VM_USER@$VM_IP:/tmp/ && ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $VM_USER@$VM_IP 'mkdir -p /tmp/lib && cp /tmp/linus/lib/* /tmp/lib/ 2>/dev/null; cd /tmp/linus && sudo bash base-packages.sh'" > /tmp/base-packages-output.txt 2>&1 || {
    echo -e "${RED}❌ Base packages installation failed${NC}"
    echo "Output:"
    cat /tmp/base-packages-output.txt
    exit 1
}

if ! grep -q "LINUS_RESULT:SUCCESS" /tmp/base-packages-output.txt; then
    echo -e "${RED}❌ Base packages did not return success${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Base packages installed${NC}"
echo ""

# ============================================================================= 
# STEP 6: Verify installations
# =============================================================================

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
           ${QEMU_SSH_KEY:+-i "$QEMU_SSH_KEY"} \
           "$QEMU_USER@$QEMU_HOST" \
           "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $VM_USER@$VM_IP '$cmd'" &>/dev/null; then
        version=$(ssh -o StrictHostKeyChecking=no \
                      -o UserKnownHostsFile=/dev/null \
                      ${QEMU_SSH_KEY:+-i "$QEMU_SSH_KEY"} \
                      "$QEMU_USER@$QEMU_HOST" \
                      "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $VM_USER@$VM_IP '$cmd 2>&1 | head -1'")
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

# ============================================================================= 
# STEP 7: Final system check
# =============================================================================

echo -e "${YELLOW}[7/7]${NC} Final system check..."

# Check disk space using jump-host pattern
disk_usage=$(ssh -o StrictHostKeyChecking=no \
                 -o UserKnownHostsFile=/dev/null \
                 ${QEMU_SSH_KEY:+-i "$QEMU_SSH_KEY"} \
                 "$QEMU_USER@$QEMU_HOST" \
                 "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $VM_USER@$VM_IP 'df -h / | tail -1 | awk \"{print \\$5}\"'")

echo "  Disk usage: $disk_usage"

# Check memory using jump-host pattern
mem_total=$(ssh -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null \
                ${QEMU_SSH_KEY:+-i "$QEMU_SSH_KEY"} \
                "$QEMU_USER@$QEMU_HOST" \
                "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $VM_USER@$VM_IP 'free -h | grep Mem | awk \"{print \\$2}\"'")

echo "  Total memory: $mem_total"

# Check running services using jump-host pattern
services_running=$(ssh -o StrictHostKeyChecking=no \
                       -o UserKnownHostsFile=/dev/null \
                       ${QEMU_SSH_KEY:+-i "$QEMU_SSH_KEY"} \
                       "$QEMU_USER@$QEMU_HOST" \
                       "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $VM_USER@$VM_IP 'systemctl list-units --type=service --state=running | grep -c running'")

echo "  Running services: $services_running"

echo -e "${GREEN}✅ System check complete${NC}"
echo ""

# =============================================================================
# SUCCESS
# ==============================================================================

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                                                       ║${NC}"
echo -e "${GREEN}║          🎉  QEMU E2E Test PASSED  🎉               ║${NC}"
echo -e "${GREEN}║                                                       ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Test Summary:"
echo "  ✅ QEMU VM provisioned (Name: $VM_NAME, IP: $VM_IP)"
echo "  ✅ SSH connectivity verified"
echo "  ✅ Ubuntu bootstrapped"
echo "  ✅ Development tools installed"
echo "  ✅ Base packages installed"
echo "  ✅ All tools verified"
echo "  ✅ System check passed"
echo ""
echo "VM will be destroyed in 5 seconds..."
sleep 5

exit 0
