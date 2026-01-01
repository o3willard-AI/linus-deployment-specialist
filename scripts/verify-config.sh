#!/usr/bin/env bash
# verify-config.sh - Verify Linus provider configuration
#
# Purpose: Autonomous verification of provider credentials and connectivity
# Exit Codes: 0 = configuration valid, 1 = configuration incomplete/invalid

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "========================================="
echo "Linus Configuration Verification"
echo "========================================="
echo ""

# Function: Check environment variable
check_var() {
    local var_name=$1
    local required=$2

    if [ -z "${!var_name:-}" ]; then
        if [ "$required" = "true" ]; then
            echo -e "${RED}✗${NC} $var_name not set (REQUIRED)"
            return 1
        else
            echo -e "${YELLOW}⊘${NC} $var_name not set (optional)"
            return 0
        fi
    else
        # Mask sensitive values
        local display_value="${!var_name}"
        if [[ "$var_name" =~ (SECRET|PASS|KEY) ]] && [[ "$var_name" != *"_ID"* ]] && [[ "$var_name" != *"_NAME"* ]]; then
            display_value="***masked***"
        fi
        echo -e "${GREEN}✓${NC} $var_name set: $display_value"
        return 0
    fi
}

# Detect provider based on environment variables
PROVIDER=""
if [ -n "${PROXMOX_HOST:-}" ]; then
    PROVIDER="proxmox"
elif [ -n "${AWS_REGION:-}" ]; then
    PROVIDER="aws"
elif [ -n "${QEMU_HOST:-}" ]; then
    PROVIDER="qemu"
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
echo ""

# Provider-specific verification
CONFIG_VALID=true

if [ "$PROVIDER" = "proxmox" ]; then
    echo "Proxmox Configuration"
    echo "-----------------------------------------"
    check_var PROXMOX_HOST true || CONFIG_VALID=false
    check_var PROXMOX_USER true || CONFIG_VALID=false
    check_var PROXMOX_TOKEN_ID true || CONFIG_VALID=false
    check_var PROXMOX_TOKEN_SECRET true || CONFIG_VALID=false
    check_var PROXMOX_NODE false
    check_var PROXMOX_STORAGE false
    check_var PROXMOX_TEMPLATE_ID false
    echo ""

    if [ "$CONFIG_VALID" = "true" ]; then
        # Test API connectivity
        echo "Testing Proxmox API connectivity..."
        echo "-----------------------------------------"

        if ! command -v curl &> /dev/null; then
            echo -e "${RED}✗${NC} curl not installed (required for Proxmox)"
            CONFIG_VALID=false
        else
            local api_url="https://${PROXMOX_HOST}:8006/api2/json/version"
            local auth_header="Authorization: PVEAPIToken=${PROXMOX_USER}!${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}"

            if curl -k -s -f -H "$auth_header" "$api_url" > /dev/null 2>&1; then
                echo -e "${GREEN}✓${NC} Proxmox API connection successful"

                # Get version info
                local version_info
                version_info=$(curl -k -s -H "$auth_header" "$api_url" 2>/dev/null | grep -o '"version":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
                echo "  Proxmox version: $version_info"
            else
                echo -e "${RED}✗${NC} Proxmox API connection failed"
                echo ""
                echo "Troubleshooting:"
                echo "  1. Verify PROXMOX_HOST is reachable: ping $PROXMOX_HOST"
                echo "  2. Verify Proxmox web UI is accessible: https://$PROXMOX_HOST:8006"
                echo "  3. Verify API token is valid (re-create if needed)"
                echo "  4. Check PROXMOX_TOKEN_SECRET is correct"
                CONFIG_VALID=false
            fi
        fi
    fi

elif [ "$PROVIDER" = "aws" ]; then
    echo "AWS Configuration"
    echo "-----------------------------------------"
    check_var AWS_REGION true || CONFIG_VALID=false
    check_var AWS_KEY_NAME true || CONFIG_VALID=false
    check_var AWS_INSTANCE_TYPE false
    check_var AWS_AMI_ID false
    check_var AWS_SUBNET_ID false
    check_var AWS_SECURITY_GROUP false
    echo ""

    if [ "$CONFIG_VALID" = "true" ]; then
        # Test AWS credentials
        echo "Testing AWS credentials..."
        echo "-----------------------------------------"

        if ! command -v aws &> /dev/null; then
            echo -e "${RED}✗${NC} AWS CLI not installed (required for AWS provider)"
            echo "Install: See INSTALL.md"
            CONFIG_VALID=false
        else
            if aws sts get-caller-identity > /dev/null 2>&1; then
                echo -e "${GREEN}✓${NC} AWS credentials valid"

                # Get account info
                local account_id
                account_id=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "unknown")
                echo "  AWS Account: $account_id"
                echo "  AWS Region: $AWS_REGION"
            else
                echo -e "${RED}✗${NC} AWS credentials invalid or not configured"
                echo ""
                echo "Troubleshooting:"
                echo "  1. Run: aws configure"
                echo "  2. Verify credentials in ~/.aws/credentials"
                echo "  3. Test with: aws sts get-caller-identity"
                CONFIG_VALID=false
            fi

            # Check key pair exists
            if [ "$CONFIG_VALID" = "true" ]; then
                echo ""
                echo "Checking EC2 key pair..."
                echo "-----------------------------------------"

                if aws ec2 describe-key-pairs --key-names "$AWS_KEY_NAME" --region "$AWS_REGION" > /dev/null 2>&1; then
                    echo -e "${GREEN}✓${NC} EC2 key pair '$AWS_KEY_NAME' exists in $AWS_REGION"
                else
                    echo -e "${RED}✗${NC} EC2 key pair '$AWS_KEY_NAME' not found in $AWS_REGION"
                    echo ""
                    echo "Create key pair:"
                    echo "  aws ec2 create-key-pair --key-name $AWS_KEY_NAME --region $AWS_REGION \\"
                    echo "    --query 'KeyMaterial' --output text > ~/.ssh/${AWS_KEY_NAME}.pem"
                    echo "  chmod 400 ~/.ssh/${AWS_KEY_NAME}.pem"
                    CONFIG_VALID=false
                fi
            fi
        fi
    fi

elif [ "$PROVIDER" = "qemu" ]; then
    echo "QEMU Configuration"
    echo "-----------------------------------------"
    check_var QEMU_HOST true || CONFIG_VALID=false
    check_var QEMU_USER true || CONFIG_VALID=false
    check_var QEMU_SUDO_PASS true || CONFIG_VALID=false
    check_var QEMU_POOL false
    check_var QEMU_NETWORK false
    echo ""

    if [ "$CONFIG_VALID" = "true" ]; then
        # Test SSH access
        echo "Testing QEMU host SSH access..."
        echo "-----------------------------------------"

        if ! command -v sshpass &> /dev/null; then
            echo -e "${RED}✗${NC} sshpass not installed (required for QEMU provider)"
            echo "Install:"
            echo "  Ubuntu/Debian: sudo apt-get install -y sshpass"
            echo "  macOS: brew install sshpass"
            CONFIG_VALID=false
        else
            if sshpass -p "$QEMU_SUDO_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
                ${QEMU_USER}@${QEMU_HOST} 'echo SSH_OK' 2>/dev/null | grep -q "SSH_OK"; then
                echo -e "${GREEN}✓${NC} SSH access to QEMU host successful"
            else
                echo -e "${RED}✗${NC} SSH access to QEMU host failed"
                echo ""
                echo "Troubleshooting:"
                echo "  1. Verify QEMU_HOST is reachable: ping $QEMU_HOST"
                echo "  2. Verify SSH is running on QEMU host"
                echo "  3. Verify QEMU_USER and QEMU_SUDO_PASS are correct"
                echo "  4. Test manual SSH: ssh ${QEMU_USER}@${QEMU_HOST}"
                CONFIG_VALID=false
            fi

            # Test libvirt access
            if [ "$CONFIG_VALID" = "true" ]; then
                echo ""
                echo "Testing libvirt access..."
                echo "-----------------------------------------"

                if sshpass -p "$QEMU_SUDO_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
                    ${QEMU_USER}@${QEMU_HOST} 'echo yes | sudo -S virsh version' 2>/dev/null | grep -q "libvirt"; then
                    echo -e "${GREEN}✓${NC} libvirt access successful"

                    # Get libvirt version
                    local libvirt_version
                    libvirt_version=$(sshpass -p "$QEMU_SUDO_PASS" ssh -o StrictHostKeyChecking=no \
                        ${QEMU_USER}@${QEMU_HOST} 'echo yes | sudo -S virsh version' 2>/dev/null | grep "Using library" | awk '{print $3}' || echo "unknown")
                    echo "  libvirt version: $libvirt_version"
                else
                    echo -e "${RED}✗${NC} libvirt access failed"
                    echo ""
                    echo "Troubleshooting:"
                    echo "  1. Check libvirtd is running: sudo systemctl status libvirtd"
                    echo "  2. Verify user has libvirt permissions: sudo usermod -a -G libvirt ${QEMU_USER}"
                    echo "  3. Verify sudo password is correct"
                    CONFIG_VALID=false
                fi

                # Check SSH key on QEMU host
                if [ "$CONFIG_VALID" = "true" ]; then
                    echo ""
                    echo "Checking SSH key on QEMU host..."
                    echo "-----------------------------------------"

                    if sshpass -p "$QEMU_SUDO_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
                        ${QEMU_USER}@${QEMU_HOST} 'test -f ~/.ssh/id_rsa.pub' 2>/dev/null; then
                        echo -e "${GREEN}✓${NC} SSH key exists on QEMU host (~/.ssh/id_rsa.pub)"
                    else
                        echo -e "${RED}✗${NC} SSH key not found on QEMU host"
                        echo ""
                        echo "Generate SSH key on QEMU host:"
                        echo "  ssh ${QEMU_USER}@${QEMU_HOST}"
                        echo "  ssh-keygen -t rsa -b 4096 -N \"\""
                        CONFIG_VALID=false
                    fi
                fi

                # Check default network and pool
                if [ "$CONFIG_VALID" = "true" ]; then
                    echo ""
                    echo "Checking libvirt resources..."
                    echo "-----------------------------------------"

                    local pool_name="${QEMU_POOL:-default}"
                    local network_name="${QEMU_NETWORK:-default}"

                    # Check pool
                    if sshpass -p "$QEMU_SUDO_PASS" ssh -o StrictHostKeyChecking=no \
                        ${QEMU_USER}@${QEMU_HOST} "echo yes | sudo -S virsh pool-list --all" 2>/dev/null | grep -q "$pool_name"; then
                        echo -e "${GREEN}✓${NC} Storage pool '$pool_name' exists"
                    else
                        echo -e "${YELLOW}⊘${NC} Storage pool '$pool_name' not found"
                        echo "  Will be created during provisioning"
                    fi

                    # Check network
                    if sshpass -p "$QEMU_SUDO_PASS" ssh -o StrictHostKeyChecking=no \
                        ${QEMU_USER}@${QEMU_HOST} "echo yes | sudo -S virsh net-list --all" 2>/dev/null | grep -q "$network_name"; then
                        echo -e "${GREEN}✓${NC} Network '$network_name' exists"
                    else
                        echo -e "${YELLOW}⊘${NC} Network '$network_name' not found"
                        echo "  Will be created during provisioning"
                    fi
                fi
            fi
        fi
    fi
fi

# Final summary
echo ""
echo "========================================="
if [ "$CONFIG_VALID" = "true" ]; then
    echo -e "${GREEN}✓ ALL CONFIGURATION CHECKS PASSED${NC}"
    echo "========================================="
    echo ""
    echo "Provider '$PROVIDER' is ready for VM provisioning"
    echo ""
    echo "NEXT STEP: Provision a test VM"
    echo "  See AGENT-GUIDE.md for provisioning workflows"
    echo ""
    echo "Quick test (minimal VM):"
    if [ "$PROVIDER" = "proxmox" ]; then
        echo "  VM_CPU=1 VM_RAM=1024 VM_DISK=10 ./shared/provision/proxmox.sh"
    elif [ "$PROVIDER" = "aws" ]; then
        echo "  VM_CPU=1 VM_RAM=1024 VM_DISK=8 ./shared/provision/aws.sh"
    elif [ "$PROVIDER" = "qemu" ]; then
        echo "  VM_CPU=1 VM_RAM=1024 VM_DISK=10 ./shared/provision/qemu.sh"
    fi
    exit 0
else
    echo -e "${RED}✗ CONFIGURATION INCOMPLETE${NC}"
    echo "========================================="
    echo ""
    echo "Review error messages above and fix configuration issues"
    echo "See CONFIGURATION.md for detailed setup instructions"
    exit 1
fi
