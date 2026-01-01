#!/usr/bin/env bash
# quick-test.sh - Quick test of Linus VM provisioning
#
# Purpose: Autonomous end-to-end test with minimal VM specifications
# Exit Codes: 0 = test successful, 1 = test failed

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "========================================="
echo "Linus Quick Test"
echo "========================================="
echo ""
echo "This will provision a minimal VM to test your configuration."
echo "VM specifications: 1 CPU, 1GB RAM, 10GB disk"
echo ""

# Get script directory (parent of scripts/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Detect provider
PROVIDER=""
PROVISION_SCRIPT=""

if [ -n "${PROXMOX_HOST:-}" ]; then
    PROVIDER="proxmox"
    PROVISION_SCRIPT="$SCRIPT_DIR/shared/provision/proxmox.sh"
elif [ -n "${AWS_REGION:-}" ]; then
    PROVIDER="aws"
    PROVISION_SCRIPT="$SCRIPT_DIR/shared/provision/aws.sh"
elif [ -n "${QEMU_HOST:-}" ]; then
    PROVIDER="qemu"
    PROVISION_SCRIPT="$SCRIPT_DIR/shared/provision/qemu.sh"
else
    echo -e "${RED}✗ No provider configured${NC}"
    echo ""
    echo "Set one of the following:"
    echo "  - PROXMOX_HOST for Proxmox provider"
    echo "  - AWS_REGION for AWS provider"
    echo "  - QEMU_HOST for QEMU provider"
    echo ""
    echo "See CONFIGURATION.md for setup instructions"
    exit 1
fi

echo "Detected provider: $PROVIDER"
echo "Provisioning script: $PROVISION_SCRIPT"
echo ""

# Verify provision script exists
if [ ! -f "$PROVISION_SCRIPT" ]; then
    echo -e "${RED}✗ Provisioning script not found: $PROVISION_SCRIPT${NC}"
    exit 1
fi

# Set minimal VM specs
export VM_NAME="linus-quicktest-$(date +%s)"
export VM_CPU=1
export VM_RAM=1024
export VM_DISK=10

echo "Test VM name: $VM_NAME"
echo ""

# Run provisioning
echo "========================================="
echo "Starting VM provisioning..."
echo "========================================="
echo ""

START_TIME=$(date +%s)

# Capture output and exit code
set +e
OUTPUT=$("$PROVISION_SCRIPT" 2>&1)
EXIT_CODE=$?
set -e

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo ""
echo "========================================="
echo "Provisioning completed in ${DURATION}s"
echo "========================================="
echo ""

# Parse results
if echo "$OUTPUT" | grep -q "LINUS_RESULT:SUCCESS"; then
    echo -e "${GREEN}✓ PROVISIONING SUCCESSFUL${NC}"
    echo ""

    # Extract VM details
    VM_IP=$(echo "$OUTPUT" | grep "LINUS_VM_IP:" | cut -d: -f2 | xargs)
    VM_USER=$(echo "$OUTPUT" | grep "LINUS_VM_USER:" | cut -d: -f2 | xargs)
    VM_CPU_ACTUAL=$(echo "$OUTPUT" | grep "LINUS_VM_CPU:" | cut -d: -f2 | xargs)
    VM_RAM_ACTUAL=$(echo "$OUTPUT" | grep "LINUS_VM_RAM:" | cut -d: -f2 | xargs)
    VM_DISK_ACTUAL=$(echo "$OUTPUT" | grep "LINUS_VM_DISK:" | cut -d: -f2 | xargs)

    echo "VM Details:"
    echo "  Name: $VM_NAME"
    echo "  IP: $VM_IP"
    echo "  User: $VM_USER"
    echo "  CPU: $VM_CPU_ACTUAL cores"
    echo "  RAM: $VM_RAM_ACTUAL MB"
    echo "  Disk: $VM_DISK_ACTUAL GB"
    echo ""

    # Provide SSH command
    echo "SSH Access:"
    if [ "$PROVIDER" = "qemu" ]; then
        echo "  Jump host: ssh ${QEMU_USER}@${QEMU_HOST}"
        echo "  Then: ssh ${VM_USER}@${VM_IP}"
        echo ""
        echo "  Direct (from QEMU host):"
        echo "    ssh ${QEMU_USER}@${QEMU_HOST} 'ssh ${VM_USER}@${VM_IP}'"
    else
        echo "  ssh ${VM_USER}@${VM_IP}"
    fi
    echo ""

    echo "========================================="
    echo -e "${GREEN}✓ QUICK TEST PASSED${NC}"
    echo "========================================="
    echo ""
    echo "Your Linus installation is working correctly!"
    echo ""
    echo "NEXT STEPS:"
    echo "  1. SSH to the VM and verify it's functional"
    echo "  2. Test bootstrap script: See AGENT-GUIDE.md"
    echo "  3. Test dev tools installation: See AGENT-GUIDE.md"
    echo "  4. Clean up test VM when done (destroy manually on provider)"
    echo ""

    if [ "$PROVIDER" = "proxmox" ]; then
        echo "Cleanup command (Proxmox):"
        echo "  qm stop <VM_ID> && qm destroy <VM_ID>"
    elif [ "$PROVIDER" = "aws" ]; then
        echo "Cleanup command (AWS):"
        INSTANCE_ID=$(echo "$OUTPUT" | grep "LINUS_INSTANCE_ID:" | cut -d: -f2 | xargs || echo "")
        if [ -n "$INSTANCE_ID" ]; then
            echo "  aws ec2 terminate-instances --instance-ids $INSTANCE_ID"
        fi
    elif [ "$PROVIDER" = "qemu" ]; then
        echo "Cleanup command (QEMU):"
        echo "  ssh ${QEMU_USER}@${QEMU_HOST} 'sudo virsh destroy $VM_NAME && sudo virsh undefine $VM_NAME --remove-all-storage'"
    fi

    exit 0
else
    echo -e "${RED}✗ PROVISIONING FAILED${NC}"
    echo ""
    echo "Exit code: $EXIT_CODE"
    echo ""
    echo "Error output:"
    echo "========================================="
    echo "$OUTPUT"
    echo "========================================="
    echo ""

    echo "TROUBLESHOOTING:"
    echo "  1. Review error messages above"
    echo "  2. Verify configuration: scripts/verify-config.sh"
    echo "  3. Check provider-specific issues in CONFIGURATION.md"
    echo "  4. Enable debug mode: add 'set -x' to provisioning script"
    echo ""

    exit 1
fi
