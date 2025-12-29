#!/usr/bin/env bash
# =============================================================================
# Integration Test: Development Tools Installation
# =============================================================================
# Purpose: Test dev-tools.sh on a live VM
# Duration: ~5 minutes (Docker install takes time)
# Requirements: Live Ubuntu VM with SSH access, ubuntu.sh already run
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

echo -e "${BLUE}=== Integration Test: Dev Tools Installation ===${NC}"
echo ""

# Configuration
VM_IP="${TEST_VM_IP:-192.168.101.113}"
VM_USER="${TEST_VM_USER:-ubuntu}"
VM_SSH_KEY="${TEST_VM_SSH_KEY:-$HOME/.ssh/id_rsa}"

echo "Configuration:"
echo "  VM: $VM_USER@$VM_IP"
echo "  SSH Key: $VM_SSH_KEY"
echo ""

# Check SSH connectivity
echo -e "${YELLOW}[1/6]${NC} Testing SSH connectivity..."
if ! ssh -o ConnectTimeout=5 \
         -o StrictHostKeyChecking=no \
         -o UserKnownHostsFile=/dev/null \
         -i "$VM_SSH_KEY" \
         "$VM_USER@$VM_IP" "exit 0" 2>/dev/null; then
    echo -e "${RED}❌ Cannot connect to VM${NC}"
    exit 1
fi
echo -e "${GREEN}✅ SSH connectivity verified${NC}"
echo ""

# Upload libraries (required dependencies)
echo -e "${YELLOW}[2/6]${NC} Uploading library dependencies..."
for lib in logging.sh validation.sh noninteractive.sh; do
    if ! scp -o StrictHostKeyChecking=no \
             -o UserKnownHostsFile=/dev/null \
             -i "$VM_SSH_KEY" \
             "shared/lib/$lib" \
             "$VM_USER@$VM_IP:/tmp/" 2>/dev/null; then
        echo -e "${RED}❌ Failed to upload $lib${NC}"
        exit 1
    fi
    echo "  Uploaded: $lib"
done
echo -e "${GREEN}✅ Libraries uploaded${NC}"
echo ""

# Upload dev-tools script
echo -e "${YELLOW}[3/6]${NC} Uploading dev-tools.sh..."
if ! scp -o StrictHostKeyChecking=no \
         -o UserKnownHostsFile=/dev/null \
         -i "$VM_SSH_KEY" \
         shared/configure/dev-tools.sh \
         "$VM_USER@$VM_IP:/tmp/dev-tools.sh" 2>/dev/null; then
    echo -e "${RED}❌ Failed to upload script${NC}"
    exit 1
fi
echo -e "${GREEN}✅ Script uploaded${NC}"
echo ""

# Create wrapper script to source libraries from /tmp
echo -e "${YELLOW}[4/6]${NC} Executing dev-tools.sh (this may take 3-5 minutes)..."
cat > /tmp/run-dev-tools.sh << 'WRAPPER'
#!/usr/bin/env bash
# Temporarily override SCRIPT_DIR to use /tmp for libraries
cd /tmp
sed 's|SCRIPT_DIR=".*"|SCRIPT_DIR="/tmp"|' dev-tools.sh > dev-tools-wrapped.sh
chmod +x dev-tools-wrapped.sh
sudo bash dev-tools-wrapped.sh
WRAPPER

if ! scp -o StrictHostKeyChecking=no \
         -o UserKnownHostsFile=/dev/null \
         -i "$VM_SSH_KEY" \
         /tmp/run-dev-tools.sh \
         "$VM_USER@$VM_IP:/tmp/run-dev-tools.sh" 2>/dev/null; then
    echo -e "${RED}❌ Failed to upload wrapper${NC}"
    exit 1
fi

if ! ssh -o StrictHostKeyChecking=no \
         -o UserKnownHostsFile=/dev/null \
         -i "$VM_SSH_KEY" \
         "$VM_USER@$VM_IP" \
         "bash /tmp/run-dev-tools.sh" > /tmp/dev-tools-output.txt 2>&1; then
    echo -e "${RED}❌ Dev tools installation failed${NC}"
    echo "Output:"
    cat /tmp/dev-tools-output.txt
    exit 1
fi

# Check for success marker
if grep -q "LINUS_RESULT:SUCCESS" /tmp/dev-tools-output.txt; then
    echo -e "${GREEN}✅ Dev tools installed successfully${NC}"
else
    echo -e "${RED}❌ Dev tools did not return success${NC}"
    echo "Output:"
    cat /tmp/dev-tools-output.txt
    exit 1
fi
echo ""

# Verify installations
echo -e "${YELLOW}[5/6]${NC} Verifying installations..."

# Check Python
if ssh -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       -i "$VM_SSH_KEY" \
       "$VM_USER@$VM_IP" \
       "python3 --version" &>/dev/null; then
    python_version=$(ssh -o StrictHostKeyChecking=no \
                         -o UserKnownHostsFile=/dev/null \
                         -i "$VM_SSH_KEY" \
                         "$VM_USER@$VM_IP" \
                         "python3 --version 2>&1")
    echo -e "  ${GREEN}✅${NC} Python: $python_version"
else
    echo -e "  ${RED}❌${NC} Python NOT installed"
    exit 1
fi

# Check Node.js
if ssh -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       -i "$VM_SSH_KEY" \
       "$VM_USER@$VM_IP" \
       "node --version" &>/dev/null; then
    node_version=$(ssh -o StrictHostKeyChecking=no \
                       -o UserKnownHostsFile=/dev/null \
                       -i "$VM_SSH_KEY" \
                       "$VM_USER@$VM_IP" \
                       "node --version 2>&1")
    echo -e "  ${GREEN}✅${NC} Node.js: $node_version"
else
    echo -e "  ${RED}❌${NC} Node.js NOT installed"
    exit 1
fi

# Check Docker
if ssh -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       -i "$VM_SSH_KEY" \
       "$VM_USER@$VM_IP" \
       "docker --version" &>/dev/null; then
    docker_version=$(ssh -o StrictHostKeyChecking=no \
                         -o UserKnownHostsFile=/dev/null \
                         -i "$VM_SSH_KEY" \
                         "$VM_USER@$VM_IP" \
                         "docker --version 2>&1")
    echo -e "  ${GREEN}✅${NC} Docker: $docker_version"
else
    echo -e "  ${RED}❌${NC} Docker NOT installed"
    exit 1
fi
echo ""

# Verify Docker service is running
echo -e "${YELLOW}[6/6]${NC} Verifying Docker service..."
if ssh -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       -i "$VM_SSH_KEY" \
       "$VM_USER@$VM_IP" \
       "sudo systemctl is-active docker" &>/dev/null; then
    echo -e "${GREEN}✅ Docker service is running${NC}"
else
    echo -e "${YELLOW}⚠${NC}  Docker service not running (may need manual start)"
fi
echo ""

echo -e "${GREEN}🎉 Integration Test PASSED${NC}"
echo ""
echo "Test Summary:"
echo "  ✅ SSH connectivity"
echo "  ✅ Library dependencies uploaded"
echo "  ✅ Dev tools installation"
echo "  ✅ Python verified"
echo "  ✅ Node.js verified"
echo "  ✅ Docker verified"

exit 0
