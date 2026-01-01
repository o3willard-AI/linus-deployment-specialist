#!/usr/bin/env bash
# verify-install.sh - Verify Linus installation and prerequisites
#
# Purpose: Autonomous verification of all required dependencies for AI agents
# Exit Codes: 0 = all checks passed, 1 = missing dependencies

set -euo pipefail

# Colors for output (optional, works in most terminals)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "========================================="
echo "Linus Installation Verification"
echo "========================================="
echo ""

MISSING_TOOLS=()
MISSING_OPTIONAL=()

# Function: Check command exists
check_command() {
    local cmd=$1
    local required=$2
    local min_version=${3:-}

    if command -v "$cmd" &> /dev/null; then
        local version
        version=$("$cmd" --version 2>&1 | head -1 || echo "unknown")

        if [ -n "$min_version" ]; then
            echo -e "${GREEN}✓${NC} $cmd installed: $version"
        else
            echo -e "${GREEN}✓${NC} $cmd installed"
        fi
        return 0
    else
        if [ "$required" = "true" ]; then
            echo -e "${RED}✗${NC} $cmd not found (REQUIRED)"
            MISSING_TOOLS+=("$cmd")
            return 1
        else
            echo -e "${YELLOW}⊘${NC} $cmd not found (optional)"
            MISSING_OPTIONAL+=("$cmd")
            return 0
        fi
    fi
}

# Function: Check Node.js version
check_nodejs() {
    if command -v node &> /dev/null; then
        local node_version
        node_version=$(node --version | sed 's/v//')
        local node_major
        node_major=$(echo "$node_version" | cut -d. -f1)

        if [ "$node_major" -ge 24 ]; then
            echo -e "${GREEN}✓${NC} Node.js v$node_version (OK, required: 24.12+)"
            return 0
        else
            echo -e "${RED}✗${NC} Node.js v$node_version (UPGRADE REQUIRED: Need v24.12+)"
            MISSING_TOOLS+=("nodejs-upgrade")
            return 1
        fi
    else
        echo -e "${RED}✗${NC} Node.js not found (REQUIRED: v24.12+)"
        MISSING_TOOLS+=("nodejs")
        return 1
    fi
}

# Function: Check npm packages
check_npm_package() {
    local package=$1
    local required=$2

    if npm list -g "$package" &> /dev/null; then
        local version
        version=$(npm list -g "$package" 2>/dev/null | grep "$package" | head -1 | sed 's/.*@//' || echo "unknown")
        echo -e "${GREEN}✓${NC} npm package: $package@$version"
        return 0
    else
        if [ "$required" = "true" ]; then
            echo -e "${RED}✗${NC} npm package: $package not found (REQUIRED)"
            MISSING_TOOLS+=("npm-$package")
            return 1
        else
            echo -e "${YELLOW}⊘${NC} npm package: $package not found (optional)"
            MISSING_OPTIONAL+=("npm-$package")
            return 0
        fi
    fi
}

# Function: Verify project scripts exist
check_script() {
    local script_path=$1

    if [ -f "$script_path" ]; then
        # Check if executable
        if [ -x "$script_path" ]; then
            echo -e "${GREEN}✓${NC} Script exists and executable: $script_path"
        else
            echo -e "${YELLOW}⊘${NC} Script exists but not executable: $script_path"
            echo "    Fix: chmod +x $script_path"
        fi

        # Check syntax
        if bash -n "$script_path" &> /dev/null; then
            echo -e "${GREEN}✓${NC} Syntax valid: $script_path"
        else
            echo -e "${RED}✗${NC} Syntax error in: $script_path"
            MISSING_TOOLS+=("syntax-$script_path")
            return 1
        fi
        return 0
    else
        echo -e "${RED}✗${NC} Script not found: $script_path"
        MISSING_TOOLS+=("script-$script_path")
        return 1
    fi
}

echo "1. Core System Tools"
echo "-----------------------------------------"
check_command bash true
check_command git true
check_command ssh true
check_command curl true
check_command grep true
check_command sed true
check_command awk true
check_command cut true
echo ""

echo "2. Node.js Environment"
echo "-----------------------------------------"
check_nodejs
check_command npm true
echo ""

echo "3. MCP SSH Server"
echo "-----------------------------------------"
check_npm_package ssh-mcp true
echo ""

echo "4. Optional Tools"
echo "-----------------------------------------"
check_command jq false
check_command sshpass false
check_command wget false
echo ""

echo "5. Provider-Specific Tools"
echo "-----------------------------------------"
echo "Checking for provider tools (at least one provider should be available):"
echo ""

# AWS tools
if command -v aws &> /dev/null; then
    echo -e "${GREEN}✓${NC} AWS CLI available"
    aws --version 2>&1 | head -1
else
    echo -e "${YELLOW}⊘${NC} AWS CLI not found (install if using AWS provider)"
fi

# Check if we can access Proxmox (only if PROXMOX_HOST is set)
if [ -n "${PROXMOX_HOST:-}" ]; then
    echo -e "${GREEN}✓${NC} Proxmox configuration detected (PROXMOX_HOST set)"
else
    echo -e "${YELLOW}⊘${NC} Proxmox not configured (set PROXMOX_HOST if using Proxmox)"
fi

# Check if we can access QEMU (only if QEMU_HOST is set)
if [ -n "${QEMU_HOST:-}" ]; then
    echo -e "${GREEN}✓${NC} QEMU configuration detected (QEMU_HOST set)"
    # Check sshpass for QEMU
    if command -v sshpass &> /dev/null; then
        echo -e "${GREEN}✓${NC} sshpass available (required for QEMU)"
    else
        echo -e "${RED}✗${NC} sshpass not found (REQUIRED for QEMU provider)"
        MISSING_TOOLS+=("sshpass")
    fi
else
    echo -e "${YELLOW}⊘${NC} QEMU not configured (set QEMU_HOST if using QEMU)"
fi
echo ""

echo "6. Project Scripts"
echo "-----------------------------------------"
# Get script directory (parent of scripts/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

check_script "$SCRIPT_DIR/shared/provision/proxmox.sh"
check_script "$SCRIPT_DIR/shared/provision/aws.sh"
check_script "$SCRIPT_DIR/shared/provision/qemu.sh"
check_script "$SCRIPT_DIR/shared/bootstrap/ubuntu.sh"
check_script "$SCRIPT_DIR/shared/configure/dev-tools.sh"
echo ""

echo "========================================="
if [ ${#MISSING_TOOLS[@]} -eq 0 ]; then
    echo -e "${GREEN}✓ ALL REQUIRED CHECKS PASSED${NC}"
    echo "========================================="

    if [ ${#MISSING_OPTIONAL[@]} -gt 0 ]; then
        echo ""
        echo "Optional tools not installed:"
        for tool in "${MISSING_OPTIONAL[@]}"; do
            echo "  - $tool"
        done
        echo ""
        echo "These are optional. Install if needed for your use case."
    fi

    echo ""
    echo "NEXT STEP: Configure provider using CONFIGURATION.md"
    echo "THEN: Run scripts/verify-config.sh to verify provider setup"
    exit 0
else
    echo -e "${RED}✗ INSTALLATION INCOMPLETE${NC}"
    echo "========================================="
    echo ""
    echo "Missing required tools:"
    for tool in "${MISSING_TOOLS[@]}"; do
        echo "  - $tool"
    done
    echo ""
    echo "NEXT STEP: Install missing dependencies"
    echo "See INSTALL.md for installation instructions"
    exit 1
fi
