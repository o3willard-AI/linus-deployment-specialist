#!/usr/bin/env bash
# =============================================================================
# Integration Test: Ubuntu Bootstrap
# =============================================================================
# Purpose: Test ubuntu.sh on a live VM
# Duration: ~2 minutes
# Requirements: Live Ubuntu VM with SSH access
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

echo -e "${BLUE}=== Integration Test: Ubuntu Bootstrap ===${NC}"
echo ""

# Configuration (can be overridden via environment)
VM_IP="${TEST_VM_IP:-192.168.101.113}"
VM_USER="${TEST_VM_USER:-ubuntu}"
VM_SSH_KEY="${TEST_VM_SSH_KEY:-$HOME/.ssh/id_rsa}"

echo "Configuration:"
echo "  VM: $VM_USER@$VM_IP"
echo "  SSH Key: $VM_SSH_KEY"
echo ""

# Check SSH connectivity
echo -e "${YELLOW}[1/5]${NC} Testing SSH connectivity..."
if ! ssh -o ConnectTimeout=5 \
         -o StrictHostKeyChecking=no \
         -o UserKnownHostsFile=/dev/null \
         -i "$VM_SSH_KEY" \
         "$VM_USER@$VM_IP" "exit 0" 2>/dev/null; then
    echo -e "${RED}❌ Cannot connect to VM${NC}"
    echo "Fix: Ensure VM is running and SSH is accessible"
    exit 1
fi
echo -e "${GREEN}✅ SSH connectivity verified${NC}"
echo ""

# Upload bootstrap script
echo -e "${YELLOW}[2/5]${NC} Uploading ubuntu.sh to VM..."
if ! scp -o StrictHostKeyChecking=no \
         -o UserKnownHostsFile=/dev/null \
         -i "$VM_SSH_KEY" \
         shared/bootstrap/ubuntu.sh \
         "$VM_USER@$VM_IP:/tmp/ubuntu.sh" 2>/dev/null; then
    echo -e "${RED}❌ Failed to upload script${NC}"
    exit 1
fi
echo -e "${GREEN}✅ Script uploaded${NC}"
echo ""

# Execute bootstrap script
echo -e "${YELLOW}[3/5]${NC} Executing ubuntu.sh (this may take 1-2 minutes)..."
if ! ssh -o StrictHostKeyChecking=no \
         -o UserKnownHostsFile=/dev/null \
         -i "$VM_SSH_KEY" \
         "$VM_USER@$VM_IP" \
         "sudo bash /tmp/ubuntu.sh" > /tmp/bootstrap-output.txt 2>&1; then
    echo -e "${RED}❌ Bootstrap script failed${NC}"
    echo "Output:"
    cat /tmp/bootstrap-output.txt
    exit 1
fi

# Check for success marker
if grep -q "LINUS_RESULT:SUCCESS" /tmp/bootstrap-output.txt; then
    echo -e "${GREEN}✅ Bootstrap completed successfully${NC}"
else
    echo -e "${RED}❌ Bootstrap did not return success${NC}"
    echo "Output:"
    cat /tmp/bootstrap-output.txt
    exit 1
fi
echo ""

# Verify package installations
echo -e "${YELLOW}[4/5]${NC} Verifying package installations..."

packages=(curl wget git vim tmux htop)
failed_packages=()

for pkg in "${packages[@]}"; do
    if ssh -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
           -i "$VM_SSH_KEY" \
           "$VM_USER@$VM_IP" \
           "command -v $pkg" &>/dev/null; then
        echo -e "  ${GREEN}✅${NC} $pkg installed"
    else
        echo -e "  ${RED}❌${NC} $pkg NOT installed"
        failed_packages+=("$pkg")
    fi
done

if [[ ${#failed_packages[@]} -gt 0 ]]; then
    echo -e "${RED}❌ Failed to verify: ${failed_packages[*]}${NC}"
    exit 1
fi
echo ""

# Test idempotency (run again, should not fail)
echo -e "${YELLOW}[5/5]${NC} Testing idempotency (running again)..."
if ssh -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       -i "$VM_SSH_KEY" \
       "$VM_USER@$VM_IP" \
       "sudo bash /tmp/ubuntu.sh" > /tmp/bootstrap-output-2.txt 2>&1; then
    echo -e "${GREEN}✅ Idempotency test passed (can run multiple times)${NC}"
else
    echo -e "${RED}❌ Idempotency test failed${NC}"
    echo "Output:"
    cat /tmp/bootstrap-output-2.txt
    exit 1
fi
echo ""

echo -e "${GREEN}🎉 Integration Test PASSED${NC}"
echo ""
echo "Test Summary:"
echo "  ✅ SSH connectivity"
echo "  ✅ Script upload"
echo "  ✅ Bootstrap execution"
echo "  ✅ Package verification (${#packages[@]} packages)"
echo "  ✅ Idempotency"

exit 0
