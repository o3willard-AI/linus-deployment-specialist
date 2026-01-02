# Linus Deployment Specialist - Agent Installation Guide

> **Autonomous Installation Protocol for AI Coding Agents**

This document provides explicit, sequential installation steps for AI agents to install Linus Deployment Specialist without human intervention.

---

## Platform Compatibility

### Supported Platforms

| Platform | Status | Requirements | Notes |
|----------|--------|--------------|-------|
| **Linux** (Ubuntu/Debian) | ✅ Fully Supported | bash, ssh, sshpass | Native support, all features work |
| **Linux** (RHEL/Fedora/CentOS) | ✅ Fully Supported | bash, ssh, sshpass | Native support, all features work |
| **macOS** | ✅ Supported | bash, ssh, Homebrew | Needs `brew install sshpass` for QEMU |
| **Windows WSL** | ✅ Supported | WSL 2 with Ubuntu | Full Linux environment required |
| **Windows Native** | ❌ Not Supported | N/A | Scripts require bash - use WSL instead |

### Quick Platform Setup

<details>
<summary><b>Linux (Ubuntu/Debian)</b> - Click to expand</summary>

**Status:** ✅ Works out of the box

All required tools are available via apt:
```bash
sudo apt-get update
sudo apt-get install -y bash openssh-client curl git sshpass
```
</details>

<details>
<summary><b>macOS</b> - Click to expand</summary>

**Status:** ✅ Works with Homebrew

Required tools:
```bash
# Install Homebrew if not present
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install sshpass for QEMU provider (optional)
brew install sshpass

# Other tools (ssh, curl, bash) are pre-installed
```

**Note:** sshpass is only needed if you plan to use the QEMU/libvirt provider.
</details>

<details>
<summary><b>Windows</b> - Click to expand</summary>

**Status:** ⚠️ Requires WSL (Windows Subsystem for Linux)

**Native Windows (PowerShell/cmd.exe) will NOT work** - bash scripts required.

**Setup WSL:**
```powershell
# Run in PowerShell as Administrator
wsl --install -d Ubuntu-24.04

# Restart computer when prompted

# After restart, open "Ubuntu" app and setup user account
# Then inside WSL terminal:
sudo apt-get update
sudo apt-get install -y bash openssh-client curl git sshpass nodejs npm
```

**For AI Agents on Windows:**
- Claude Code: Must be configured to use WSL terminal (not PowerShell)
- Gemini: Must execute commands in WSL bash environment
- All file paths should use Linux-style forward slashes
</details>

### AI Agent Platform Notes

**Claude Code:**
- **macOS:** ✅ Works natively in Terminal.app (bash/zsh)
- **Linux:** ✅ Works natively in all terminals
- **Windows:** ⚠️ Configure to use WSL terminal, not PowerShell

**Gemini Code Assist:**
- **macOS:** ✅ Works with bash environment
- **Linux:** ✅ Works natively
- **Windows:** ⚠️ Must use WSL bash

**Cursor / Other AI IDEs:**
- Same requirements as above - needs bash environment
- Windows users must configure IDE to use WSL terminal

---

## Installation Protocol

### Protocol Overview

```
[START] → [Prerequisites] → [Clone] → [Dependencies] → [Verification] → [Configuration] → [END]
         ↓ if missing                  ↓ if fail       ↓ if fail         ↓ if fail
         [Install Missing] → [Retry]   [Report Error]  [Diagnostic]      [Manual Config Required]
```

### Execution Mode

**IMPORTANT:** Execute commands in the exact order shown. Do not proceed to next step until current step reports success.

---

## Step 1: System Prerequisites

### 1.1: Check Operating System

```bash
# Detect OS
OS_TYPE=$(uname -s)
OS_VERSION=$(uname -r)

echo "Detected OS: $OS_TYPE $OS_VERSION"

# Check if running in WSL
if grep -qi microsoft /proc/version 2>/dev/null; then
    echo "ℹ Running in Windows Subsystem for Linux (WSL)"
    WSL_DETECTED=true
else
    WSL_DETECTED=false
fi

# Verify supported OS
case "$OS_TYPE" in
  Linux)
    echo "✓ Linux OS detected"
    if $WSL_DETECTED; then
        echo "✓ WSL environment - compatible"
    fi
    ;;
  Darwin)
    echo "✓ macOS detected"
    ;;
  *)
    echo "✗ Unsupported OS: $OS_TYPE"
    echo "REQUIRED: Linux, macOS, or Windows with WSL"
    echo ""
    echo "Windows users: Install WSL with:"
    echo "  wsl --install -d Ubuntu-24.04"
    exit 1
    ;;
esac
```

### 1.2: Verify Required Tools

**Execute this verification block:**

```bash
#!/bin/bash
# Tool verification script

MISSING_TOOLS=()

# Check Node.js (v24.12+)
if command -v node &> /dev/null; then
    NODE_VERSION=$(node --version | sed 's/v//')
    NODE_MAJOR=$(echo $NODE_VERSION | cut -d. -f1)
    if [ "$NODE_MAJOR" -ge 24 ]; then
        echo "✓ Node.js $NODE_VERSION (OK)"
    else
        echo "✗ Node.js $NODE_VERSION (UPGRADE REQUIRED: Need v24.12+)"
        MISSING_TOOLS+=("nodejs-upgrade")
    fi
else
    echo "✗ Node.js not found"
    MISSING_TOOLS+=("nodejs")
fi

# Check Git
if command -v git &> /dev/null; then
    echo "✓ Git $(git --version | awk '{print $3}')"
else
    echo "✗ Git not found"
    MISSING_TOOLS+=("git")
fi

# Check Bash (v4.0+)
BASH_VERSION=$(bash --version | head -1 | grep -oP '\d+\.\d+' | head -1)
BASH_MAJOR=$(echo $BASH_VERSION | cut -d. -f1)
if [ "$BASH_MAJOR" -ge 4 ]; then
    echo "✓ Bash $BASH_VERSION"
else
    echo "✗ Bash $BASH_VERSION (UPGRADE REQUIRED: Need 4.0+)"
    MISSING_TOOLS+=("bash-upgrade")
fi

# Check SSH
if command -v ssh &> /dev/null; then
    echo "✓ SSH $(ssh -V 2>&1 | awk '{print $1}')"
else
    echo "✗ SSH not found"
    MISSING_TOOLS+=("openssh-client")
fi

# Check curl
if command -v curl &> /dev/null; then
    echo "✓ curl $(curl --version | head -1 | awk '{print $2}')"
else
    echo "✗ curl not found"
    MISSING_TOOLS+=("curl")
fi

# Report results
if [ ${#MISSING_TOOLS[@]} -eq 0 ]; then
    echo "========================================="
    echo "✓ ALL PREREQUISITES SATISFIED"
    echo "========================================="
    exit 0
else
    echo "========================================="
    echo "✗ MISSING TOOLS: ${MISSING_TOOLS[@]}"
    echo "========================================="
    echo "NEXT STEP: Execute installation for missing tools"
    exit 1
fi
```

### 1.3: Install Missing Prerequisites

**IF Step 1.2 reported missing tools, execute appropriate installation:**

#### Linux (Debian/Ubuntu):
```bash
sudo apt-get update
sudo apt-get install -y git curl openssh-client

# Install Node.js 24.x
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
sudo apt-get install -y nodejs

# Verify installation
node --version && git --version && ssh -V
```

#### Linux (RHEL/CentOS/Fedora):
```bash
sudo yum install -y git curl openssh-clients

# Install Node.js 24.x
curl -fsSL https://rpm.nodesource.com/setup_24.x | sudo bash -
sudo yum install -y nodejs

# Verify installation
node --version && git --version && ssh -V
```

#### macOS:
```bash
# Install Homebrew if not present
if ! command -v brew &> /dev/null; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Install tools
brew install git node@24 curl openssh

# Verify installation
node --version && git --version && ssh -V
```

**After installation, re-run Step 1.2 to verify all tools present.**

---

## Step 2: Clone Repository

### 2.1: Choose Installation Directory

```bash
# Default: Install in current user's home directory
INSTALL_DIR="${HOME}/linus-deployment-specialist"

# Alternative: Install in /opt (requires sudo)
# INSTALL_DIR="/opt/linus-deployment-specialist"

echo "Installation directory: $INSTALL_DIR"
```

### 2.2: Clone from GitHub

```bash
# Clone repository
git clone https://github.com/yourusername/linusstr.git "$INSTALL_DIR"

# Verify clone success
if [ -d "$INSTALL_DIR" ]; then
    echo "✓ Repository cloned to $INSTALL_DIR"
else
    echo "✗ Clone failed"
    exit 1
fi

# Change to project directory
cd "$INSTALL_DIR"

# Verify critical files exist
REQUIRED_FILES=(
    "shared/provision/proxmox.sh"
    "shared/provision/aws.sh"
    "shared/provision/qemu.sh"
    "shared/bootstrap/ubuntu.sh"
    "shared/configure/dev-tools.sh"
    "AGENT-GUIDE.md"
)

ALL_PRESENT=true
for file in "${REQUIRED_FILES[@]}"; do
    if [ -f "$file" ]; then
        echo "✓ Found: $file"
    else
        echo "✗ Missing: $file"
        ALL_PRESENT=false
    fi
done

if $ALL_PRESENT; then
    echo "✓ All required files present"
else
    echo "✗ Repository incomplete"
    exit 1
fi
```

---

## Step 3: Install Dependencies

### 3.1: Install MCP SSH Server

```bash
# Install globally
npm install -g ssh-mcp

# Verify installation
if npm list -g ssh-mcp | grep -q 'ssh-mcp'; then
    echo "✓ ssh-mcp installed successfully"
    ssh-mcp --version
else
    echo "✗ ssh-mcp installation failed"
    exit 1
fi
```

### 3.2: Install Provider-Specific Dependencies

**Decision Point: Which provider(s) will you use?**

```bash
# Set this based on your requirements
# Options: "proxmox", "aws", "qemu", or "all"
PROVIDER_CHOICE="all"
```

#### Install for Proxmox:
```bash
if [[ "$PROVIDER_CHOICE" == "proxmox" || "$PROVIDER_CHOICE" == "all" ]]; then
    echo "Proxmox provider: No additional dependencies required"
    echo "✓ Proxmox ready (uses SSH + pvesh on remote host)"
fi
```

#### Install for AWS:
```bash
if [[ "$PROVIDER_CHOICE" == "aws" || "$PROVIDER_CHOICE" == "all" ]]; then
    echo "Installing AWS CLI..."

    # Check if already installed
    if command -v aws &> /dev/null; then
        echo "✓ AWS CLI already installed: $(aws --version)"
    else
        # Detect OS and install
        if [[ "$OS_TYPE" == "Linux" ]]; then
            curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
            unzip -q /tmp/awscliv2.zip -d /tmp
            sudo /tmp/aws/install
            rm -rf /tmp/aws /tmp/awscliv2.zip
        elif [[ "$OS_TYPE" == "Darwin" ]]; then
            curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "/tmp/AWSCLIV2.pkg"
            sudo installer -pkg /tmp/AWSCLIV2.pkg -target /
            rm /tmp/AWSCLIV2.pkg
        fi

        # Verify installation
        if command -v aws &> /dev/null; then
            echo "✓ AWS CLI installed: $(aws --version)"
        else
            echo "✗ AWS CLI installation failed"
            exit 1
        fi
    fi
fi
```

#### Install for QEMU:
```bash
if [[ "$PROVIDER_CHOICE" == "qemu" || "$PROVIDER_CHOICE" == "all" ]]; then
    echo "Installing sshpass for QEMU provider..."

    # Check if already installed
    if command -v sshpass &> /dev/null; then
        echo "✓ sshpass already installed"
    else
        # Detect OS and install
        if command -v apt-get &> /dev/null; then
            sudo apt-get update && sudo apt-get install -y sshpass
        elif command -v yum &> /dev/null; then
            sudo yum install -y sshpass
        elif command -v brew &> /dev/null; then
            brew install sshpass
        else
            echo "✗ Cannot install sshpass: Unknown package manager"
            exit 1
        fi

        # Verify installation
        if command -v sshpass &> /dev/null; then
            echo "✓ sshpass installed"
        else
            echo "✗ sshpass installation failed"
            exit 1
        fi
    fi
fi
```

---

## Step 4: Configure Permissions

### 4.1: Make Scripts Executable

```bash
# Set execute permissions on all shell scripts
chmod +x shared/provision/*.sh
chmod +x shared/bootstrap/*.sh
chmod +x shared/configure/*.sh
chmod +x shared/lib/*.sh

# Verify permissions
echo "Verifying script permissions..."
for script in shared/provision/*.sh shared/bootstrap/*.sh shared/configure/*.sh; do
    if [ -x "$script" ]; then
        echo "✓ $script is executable"
    else
        echo "✗ $script is NOT executable"
        exit 1
    fi
done

echo "✓ All scripts are executable"
```

---

## Step 5: Syntax Validation

### 5.1: Validate All Shell Scripts

```bash
# Validate bash syntax for all scripts
echo "Validating Bash syntax..."

SYNTAX_ERRORS=()

for script in shared/provision/*.sh shared/bootstrap/*.sh shared/configure/*.sh shared/lib/*.sh; do
    if bash -n "$script" 2>/dev/null; then
        echo "✓ $script: Syntax OK"
    else
        echo "✗ $script: Syntax ERROR"
        SYNTAX_ERRORS+=("$script")
    fi
done

if [ ${#SYNTAX_ERRORS[@]} -eq 0 ]; then
    echo "========================================="
    echo "✓ ALL SCRIPTS VALIDATED SUCCESSFULLY"
    echo "========================================="
else
    echo "========================================="
    echo "✗ SYNTAX ERRORS IN: ${SYNTAX_ERRORS[@]}"
    echo "========================================="
    exit 1
fi
```

---

## Step 6: Installation Verification

### 6.1: Comprehensive System Check

```bash
#!/bin/bash
# Final installation verification

echo "========================================="
echo "LINUS DEPLOYMENT SPECIALIST"
echo "Installation Verification Report"
echo "========================================="
echo ""

# Check 1: Project directory
echo "[1/7] Project Directory..."
if [ -d "$(pwd)/shared" ]; then
    echo "  ✓ Location: $(pwd)"
else
    echo "  ✗ Not in project directory"
    exit 1
fi

# Check 2: Required tools
echo "[2/7] Required Tools..."
command -v node &> /dev/null && echo "  ✓ Node.js: $(node --version)" || echo "  ✗ Node.js missing"
command -v git &> /dev/null && echo "  ✓ Git: $(git --version | awk '{print $3}')" || echo "  ✗ Git missing"
command -v ssh &> /dev/null && echo "  ✓ SSH: Installed" || echo "  ✗ SSH missing"

# Check 3: MCP server
echo "[3/7] MCP SSH Server..."
if npm list -g ssh-mcp 2>/dev/null | grep -q 'ssh-mcp'; then
    echo "  ✓ ssh-mcp: Installed globally"
else
    echo "  ✗ ssh-mcp: Not found"
fi

# Check 4: Provider tools
echo "[4/7] Provider Tools..."
command -v aws &> /dev/null && echo "  ✓ AWS CLI: $(aws --version 2>&1 | awk '{print $1}')" || echo "  ℹ AWS CLI: Not installed (optional)"
command -v sshpass &> /dev/null && echo "  ✓ sshpass: Installed" || echo "  ℹ sshpass: Not installed (required for QEMU)"

# Check 5: Script permissions
echo "[5/7] Script Permissions..."
EXEC_COUNT=$(find shared -name "*.sh" -executable | wc -l)
TOTAL_COUNT=$(find shared -name "*.sh" | wc -l)
echo "  ✓ Executable scripts: $EXEC_COUNT/$TOTAL_COUNT"

# Check 6: Syntax validation
echo "[6/7] Syntax Validation..."
SYNTAX_OK=true
for script in shared/provision/*.sh shared/lib/*.sh; do
    bash -n "$script" 2>/dev/null || SYNTAX_OK=false
done
if $SYNTAX_OK; then
    echo "  ✓ All scripts pass syntax check"
else
    echo "  ✗ Syntax errors detected"
fi

# Check 7: Documentation
echo "[7/7] Documentation..."
[ -f "AGENT-GUIDE.md" ] && echo "  ✓ AGENT-GUIDE.md present" || echo "  ✗ AGENT-GUIDE.md missing"
[ -f "README.md" ] && echo "  ✓ README.md present" || echo "  ✗ README.md missing"

echo ""
echo "========================================="
echo "✓ INSTALLATION COMPLETE"
echo "========================================="
echo ""
echo "NEXT STEPS:"
echo "1. Configure provider credentials (see AGENT-GUIDE.md)"
echo "2. Run provider-specific verification tests"
echo "3. Provision your first VM"
echo ""
echo "Quick Start:"
echo "  See: AGENT-GUIDE.md#provider-configuration"
echo ""
```

---

## Step 7: Post-Installation Configuration

### 7.1: Provider Configuration Required

**Installation is complete, but you MUST configure at least one provider before use.**

**Choose your provider and follow the configuration guide:**

1. **For Proxmox:** See [AGENT-GUIDE.md#proxmox-configuration](AGENT-GUIDE.md#proxmox-configuration)
2. **For AWS:** See [AGENT-GUIDE.md#aws-configuration](AGENT-GUIDE.md#aws-configuration)
3. **For QEMU:** See [AGENT-GUIDE.md#qemu-configuration](AGENT-GUIDE.md#qemu-configuration)

### 7.2: Environment Variables Setup

**Agent Action Required:**

```bash
# Determine which provider configuration to use
# Then execute the appropriate configuration commands from AGENT-GUIDE.md

# After configuration, verify with:
env | grep -E "PROXMOX|AWS|QEMU" && echo "✓ Provider variables set" || echo "✗ No provider configured"
```

---

## Installation Complete Checklist

Before proceeding to use Linus, verify:

- [ ] All prerequisites installed (Node.js, Git, SSH, curl)
- [ ] Repository cloned successfully
- [ ] MCP SSH server installed globally
- [ ] Provider-specific tools installed (AWS CLI and/or sshpass)
- [ ] All scripts have execute permissions
- [ ] All scripts pass syntax validation
- [ ] At least one provider configured with credentials
- [ ] Environment variables set and persisted

**If ALL boxes checked:** ✓ Ready to provision VMs

**If ANY box unchecked:** Review failed step and re-execute

---

## Troubleshooting Installation Issues

### Issue: npm permission errors

```bash
# Fix npm global permissions
mkdir -p ~/.npm-global
npm config set prefix '~/.npm-global'
echo 'export PATH=~/.npm-global/bin:$PATH' >> ~/.bashrc
source ~/.bashrc

# Retry installation
npm install -g ssh-mcp
```

### Issue: Git clone fails with authentication error

```bash
# Use HTTPS instead of SSH
git clone https://github.com/yourusername/linusstr.git

# Or configure Git credentials
git config --global credential.helper store
```

### Issue: AWS CLI installation fails

```bash
# Manual installation fallback
pip3 install awscli --upgrade --user

# Verify
aws --version
```

### Issue: Cannot make scripts executable (permission denied)

```bash
# Use sudo for system-wide installation
sudo chmod +x shared/**/*.sh

# Or change ownership first
sudo chown -R $(whoami) .
chmod +x shared/**/*.sh
```

---

## Quick Installation Script

**For fully autonomous installation, execute this single script:**

```bash
#!/bin/bash
# Autonomous installation script for AI agents

set -euo pipefail

echo "Linus Deployment Specialist - Autonomous Installation"
echo "======================================================"

# Step 1: Install prerequisites
if ! command -v node &> /dev/null || ! command -v git &> /dev/null; then
    echo "Installing prerequisites..."
    if command -v apt-get &> /dev/null; then
        sudo apt-get update && sudo apt-get install -y git curl openssh-client
        curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
        sudo apt-get install -y nodejs
    elif command -v brew &> /dev/null; then
        brew install git node@24 curl openssh
    fi
fi

# Step 2: Clone repository
INSTALL_DIR="${HOME}/linus-deployment-specialist"
if [ ! -d "$INSTALL_DIR" ]; then
    git clone https://github.com/yourusername/linusstr.git "$INSTALL_DIR"
fi
cd "$INSTALL_DIR"

# Step 3: Install dependencies
npm install -g ssh-mcp

# Step 4: Set permissions
chmod +x shared/**/*.sh

# Step 5: Validate
bash -n shared/provision/proxmox.sh && echo "✓ Scripts validated"

echo "======================================================"
echo "✓ Installation complete!"
echo "Next: Configure provider credentials (see AGENT-GUIDE.md)"
```

---

**Installation Guide Version:** 1.0.0
**Target:** AI Coding Agents
**Last Updated:** 2025-12-31
