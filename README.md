# Linus Deployment Specialist

> **Provision ephemeral Linux environments for AI agent development and QA testing**

An infrastructure automation tool that enables AI agents to create, configure, and manage disposable Linux VMs across multiple providers (Proxmox, AWS EC2, QEMU/libvirt).

[![Version](https://img.shields.io/badge/version-1.0.0-blue.svg)](https://github.com/o3willard-AI/linus-deployment-specialist/releases)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Providers](https://img.shields.io/badge/providers-3-success.svg)](README.md#supported-providers)
[![GitHub](https://img.shields.io/badge/GitHub-o3willard--AI%2Flinus--deployment--specialist-blue.svg)](https://github.com/o3willard-AI/linus-deployment-specialist)

---

## 🤖 For AI Coding Agents

**This project is designed for autonomous use by AI coding and QA agents.**

If you are an AI agent (Claude, Gemini, etc.) tasked with provisioning Linux VMs, you can autonomously install and use this entire project without human intervention:

### Quick Start for Agents

1. **Installation:** Follow [INSTALL.md](INSTALL.md) for autonomous installation protocol
   - Includes verification steps with exit codes
   - OS-specific dependency installation
   - Complete system validation

2. **Usage:** Follow [AGENT-GUIDE.md](AGENT-GUIDE.md) for autonomous operation
   - Provider configuration with verification
   - VM provisioning workflows with output parsing
   - Troubleshooting decision trees
   - End-to-end examples

### Key Features for Autonomous Operation

- **Structured Output:** All scripts output `LINUS_RESULT:SUCCESS|FAILURE` with parseable key-value pairs
- **Exit Codes:** All operations return proper exit codes for success/failure detection
- **Non-Interactive:** All scripts use `-y`, `-f`, `-q` flags for autonomous execution
- **Verification Commands:** Every step includes verification commands with expected outputs
- **Decision Trees:** Comprehensive troubleshooting procedures for autonomous error resolution

### Human Users

If you are a human wanting to use this tool:
- Point your AI coding agent to this repository
- Ensure the agent has tool use enabled
- The agent will handle installation, configuration, and operation autonomously

---

## 🎯 What Is This?

**Linus** helps AI agents (Claude, Gemini, etc.) provision fresh Linux development environments on demand. Perfect for:

- **AI Agent Developers** - Test agents in clean, isolated environments
- **QA Engineers** - Spin up disposable test VMs
- **DevOps Teams** - Prototype infrastructure quickly

**Philosophy:** Simplicity > Security | Reliability > Features | Speed > Perfection

---

## ✨ Features

### Supported Providers (All ✅ Implemented in v1.0)

| Provider | Type | Use Case | Status |
|----------|------|----------|--------|
| **Proxmox VE** | On-premise/Homelab | Primary production | ✅ |
| **AWS EC2** | Cloud | Scalable cloud instances | ✅ |
| **QEMU/libvirt** | Local/Homelab | Local development | ✅ |

### Core Capabilities

- **VM Provisioning** - Create VMs with custom CPU/RAM/disk specifications
- **OS Bootstrapping** - Ubuntu 24.04 LTS with essential packages (~2 min)
- **Dev Tools Setup** - Python 3.12, Node.js 22, Docker CE (~5-7 min)
- **Automated Configuration** - Cloud-init based, fully non-interactive
- **MCP Integration** - Works with Claude Code via ssh-mcp server

---

## 🚀 Quick Start

### Platform Requirements

**Local Machine (where AI agent runs):**

| Platform | Status | Setup Required |
|----------|--------|----------------|
| **Linux** | ✅ Fully Supported | Install: `bash`, `ssh`, `sshpass`, `nodejs` |
| **macOS** | ✅ Supported | Install: `brew install sshpass` (for QEMU only) |
| **Windows** | ⚠️ WSL Required | Must use WSL 2 with Ubuntu - **native Windows not supported** |

### AI Agent Compatibility

| AI Agent | Linux | macOS | Windows |
|----------|-------|-------|---------|
| **Claude Code** | ✅ Native | ✅ Native | ⚠️ Needs WSL terminal |
| **GitHub Copilot** | ✅ Native | ✅ Native | ⚠️ VS Code terminal → WSL |
| **Gemini Code Assist** | ✅ Native | ✅ Native | ⚠️ Needs WSL terminal |
| **Cursor** | ✅ Native | ✅ Native | ⚠️ Needs WSL terminal |

<details>
<summary><b>Why doesn't Windows work natively?</b></summary>

All provisioning scripts use bash with Linux-specific features:
- bash shebangs (`#!/usr/bin/env bash`)
- bash-specific syntax (`set -euo pipefail`, process substitution, etc.)
- Linux path separators (forward slashes)
- SSH/SCP with Unix-style permissions

**Solution:** Use WSL (Windows Subsystem for Linux) - provides full Ubuntu environment on Windows.

**Setup:** `wsl --install -d Ubuntu-24.04` (PowerShell as Administrator)
</details>

### Prerequisites

- **Local Machine:**
  - Node.js 24.12+ (for MCP server)
  - bash 4.0+ (native on Linux/macOS, WSL on Windows)
  - ssh/scp (openssh-client)
  - sshpass (for QEMU provider only)

- **For Proxmox:**
  - Proxmox VE 8.x with cloud-init template
  - API token credentials

- **For AWS:**
  - AWS CLI configured with credentials
  - EC2 key pair created

- **For QEMU:**
  - QEMU/KVM host with libvirt 10.0+
  - SSH access with sudo privileges

### Installation

<details>
<summary><b>Linux Installation</b></summary>

```bash
# 1. Install dependencies
sudo apt-get update
sudo apt-get install -y bash openssh-client sshpass curl git

# 2. Install Node.js 24.x
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
sudo apt-get install -y nodejs

# 3. Clone repository
git clone https://github.com/o3willard-AI/linus-deployment-specialist.git
cd linus-deployment-specialist

# 4. Install MCP server
npm install -g ssh-mcp

# 5. Configure Claude Code (if using)
# Add to ~/.config/claude-code/mcp.json:
# {
#   "mcpServers": {
#     "ssh": {
#       "command": "ssh-mcp"
#     }
#   }
# }
```
</details>

<details>
<summary><b>macOS Installation</b></summary>

```bash
# 1. Install Homebrew (if not already installed)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 2. Install sshpass (optional, for QEMU provider only)
brew install sshpass

# 3. Install Node.js 24 (if not already installed)
brew install node@24

# 4. Clone repository
git clone https://github.com/o3willard-AI/linus-deployment-specialist.git
cd linus-deployment-specialist

# 5. Install MCP server
npm install -g ssh-mcp

# 6. Configure Claude Code (if using)
# Add to ~/.config/claude-code/mcp.json:
# {
#   "mcpServers": {
#     "ssh": {
#       "command": "ssh-mcp"
#     }
#   }
# }
```

**Note:** bash and ssh are pre-installed on macOS.
</details>

<details>
<summary><b>Windows Installation (via WSL)</b></summary>

**Step 1: Install WSL (PowerShell as Administrator)**
```powershell
wsl --install -d Ubuntu-24.04
# Restart computer when prompted
```

**Step 2: Setup inside WSL (open "Ubuntu" app)**
```bash
# 1. Update package lists
sudo apt-get update

# 2. Install dependencies
sudo apt-get install -y bash openssh-client sshpass curl git

# 3. Install Node.js 24.x
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
sudo apt-get install -y nodejs

# 4. Clone repository
cd ~
git clone https://github.com/o3willard-AI/linus-deployment-specialist.git
cd linus-deployment-specialist

# 5. Install MCP server
npm install -g ssh-mcp

# 6. Configure Claude Code to use WSL terminal
# In Claude Code settings, set terminal to WSL bash
```

**Important for AI Agents on Windows:**
- Claude Code must be configured to use WSL terminal (not PowerShell)
- All commands must run in WSL bash environment
- File paths use Linux format: `/home/user/project`
</details>

---

## 🤖 GitHub Copilot Setup (Windows Users)

**If you're using GitHub Copilot in VS Code on Windows, follow these steps:**

### Critical Requirement
VS Code's integrated terminal MUST use WSL bash, not PowerShell or cmd.exe. Our scripts use bash syntax and will fail in PowerShell.

<details>
<summary><b>For Copilot Agent: Automated Configuration</b></summary>

**Copilot should execute these commands to verify/configure the environment:**

```bash
# Step 1: Verify WSL is installed
wsl --status

# If WSL not installed, install it (requires admin PowerShell):
# wsl --install -d Ubuntu-24.04
# (System will require restart)

# Step 2: Check VS Code terminal configuration
code --version

# Step 3: Verify current shell in VS Code terminal
echo $SHELL
# Expected output: /bin/bash (WSL) or /bin/zsh (macOS)
# If output is blank or shows PowerShell path, terminal needs reconfiguration

# Step 4: Quick bash compatibility test
bash -c 'set -euo pipefail && echo "✓ Bash environment compatible"'
# Expected output: ✓ Bash environment compatible
# If error: Terminal is not using bash
```

**If tests fail, inform user to follow manual configuration steps below.**
</details>

<details>
<summary><b>For Users: Manual VS Code Terminal Configuration</b></summary>

**Step-by-step instructions to configure VS Code terminal for WSL:**

### Prerequisites Check
1. Open PowerShell as Administrator
2. Run: `wsl --status`
3. If error "WSL is not installed":
   ```powershell
   wsl --install -d Ubuntu-24.04
   ```
4. **Restart your computer** when prompted
5. After restart, open "Ubuntu" app and create username/password

### Configure VS Code Terminal (Method 1: Settings UI)

1. **Open VS Code**
2. Press `Ctrl + ,` (or File → Preferences → Settings)
3. Search for: `terminal.integrated.defaultProfile.windows`
4. Click dropdown and select: **Ubuntu (WSL)**
5. Close and reopen VS Code
6. Open new terminal: `Ctrl + `` ` (backtick)
7. Terminal prompt should show: `username@COMPUTERNAME:~$`

### Configure VS Code Terminal (Method 2: Command Palette)

1. **Open VS Code**
2. Press `Ctrl + Shift + P`
3. Type: `Terminal: Select Default Profile`
4. Select: **Ubuntu (WSL)**
5. Close current terminal (`Ctrl + Shift + `` ` then click trash icon)
6. Open new terminal: `Ctrl + `` `
7. Verify bash prompt appears

### Configure VS Code Terminal (Method 3: settings.json)

1. **Open VS Code**
2. Press `Ctrl + Shift + P`
3. Type: `Preferences: Open User Settings (JSON)`
4. Add this line:
   ```json
   {
     "terminal.integrated.defaultProfile.windows": "Ubuntu (WSL)"
   }
   ```
5. Save file (`Ctrl + S`)
6. Restart VS Code

### Verification

Open VS Code terminal and run:
```bash
# Should show /bin/bash (WSL) or /usr/bin/bash
echo $SHELL

# Should show your username@hostname
whoami

# Should output: ✓ Bash environment compatible
bash -c 'set -euo pipefail && echo "✓ Bash environment compatible"'

# Should show Ubuntu version
cat /etc/os-release | grep PRETTY_NAME
```

**All commands successful?** ✅ You're ready to use Linus!

**Any commands failed?** ⚠️ See troubleshooting below.
</details>

<details>
<summary><b>Troubleshooting: Common Copilot Issues on Windows</b></summary>

### Issue 1: "bash: command not found"

**Symptoms:**
- VS Code terminal shows `PS C:\Users\...>` (PowerShell)
- Running `bash` shows error

**Fix:**
1. WSL not installed → Run `wsl --install -d Ubuntu-24.04` in admin PowerShell
2. VS Code terminal not configured → Follow manual configuration steps above
3. Restart VS Code after configuration changes

---

### Issue 2: "wsl: command not found"

**Symptoms:**
- `wsl --status` shows error in PowerShell

**Fix:**
1. Windows version too old (need Windows 10 version 2004+ or Windows 11)
2. WSL feature not enabled:
   ```powershell
   # Run as Administrator
   dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
   dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
   # Restart computer
   wsl --set-default-version 2
   wsl --install -d Ubuntu-24.04
   ```

---

### Issue 3: Scripts fail with "permission denied"

**Symptoms:**
- `./shared/provision/proxmox.sh: Permission denied`

**Fix:**
```bash
# In WSL terminal, navigate to project directory:
cd ~/linus-deployment-specialist

# Make scripts executable:
chmod +x shared/provision/*.sh
chmod +x shared/bootstrap/*.sh
chmod +x shared/configure/*.sh

# Verify:
ls -l shared/provision/proxmox.sh
# Should show: -rwxr-xr-x (x = executable)
```

---

### Issue 4: "No such file or directory" errors

**Symptoms:**
- Scripts can't find files that exist in Windows

**Fix:**
- File is in Windows filesystem (`C:\Users\...`)
- Must clone repository in WSL filesystem:
  ```bash
  # WRONG - In Windows filesystem:
  cd /mnt/c/Users/YourName/Projects
  git clone ...

  # CORRECT - In WSL filesystem:
  cd ~
  git clone https://github.com/o3willard-AI/linus-deployment-specialist.git
  cd linus-deployment-specialist
  ```

---

### Issue 5: Copilot suggests PowerShell commands

**Symptoms:**
- Copilot generates `Get-ChildItem`, `Set-Location`, etc.
- Commands don't work in bash

**Fix:**
1. Explicitly tell Copilot: "Use bash commands only"
2. Verify terminal shows bash prompt (`$` not `>`)
3. Ask Copilot: "Convert this to bash syntax"

---

### Issue 6: Line ending errors (`\r` command not found)

**Symptoms:**
- Error: `$'\r': command not found`
- Scripts have Windows line endings (CRLF)

**Fix:**
```bash
# Convert line endings from CRLF to LF:
sudo apt-get install dos2unix
find shared -name "*.sh" -exec dos2unix {} \;

# Or configure Git to handle line endings:
git config --global core.autocrlf input
git config --global core.eol lf

# Re-clone repository:
cd ~
rm -rf linus-deployment-specialist
git clone https://github.com/o3willard-AI/linus-deployment-specialist.git
```

---

### Still Having Issues?

1. **Restart VS Code** - Configuration changes sometimes need restart
2. **Check WSL status**: `wsl --status` in PowerShell
3. **Check VS Code settings**: Search for "terminal.integrated.defaultProfile.windows"
4. **Test in standalone WSL**: Open "Ubuntu" app and try commands there
5. **File an issue**: https://github.com/o3willard-AI/linus-deployment-specialist/issues

</details>

---

## 📚 Usage Examples

### Proxmox Provider

```bash
# Set environment variables
export PROXMOX_HOST=192.168.101.155
export PROXMOX_USER=root@pam
export PROXMOX_TOKEN_ID=linus-token
export PROXMOX_TOKEN_SECRET=your-secret

# Provision VM
./shared/provision/proxmox.sh

# With custom specs
VM_NAME=dev-server-001 \
VM_CPU=4 \
VM_RAM=8192 \
VM_DISK=50 \
  ./shared/provision/proxmox.sh
```

### AWS EC2 Provider

```bash
# Set environment variables
export AWS_REGION=us-west-2
export AWS_KEY_NAME=my-keypair

# Provision instance (auto-selects instance type and AMI)
./shared/provision/aws.sh

# With specific instance type
VM_CPU=4 \
VM_RAM=16384 \
  ./shared/provision/aws.sh
# Result: Selects t3.xlarge automatically
```

### QEMU/libvirt Provider

```bash
# Set environment variables
export QEMU_HOST=192.168.101.59
export QEMU_USER=sblanken
export QEMU_SUDO_PASS=your-password

# Provision VM
./shared/provision/qemu.sh

# With custom specs
VM_NAME=test-vm-001 \
VM_CPU=2 \
VM_RAM=2048 \
VM_DISK=20 \
  ./shared/provision/qemu.sh
```

### Bootstrap Ubuntu VM

```bash
# SSH to the new VM
ssh ubuntu@<vm-ip>

# Run bootstrap script (on the VM)
curl -sSL https://raw.githubusercontent.com/yourusername/linusstr/master/shared/bootstrap/ubuntu.sh | bash

# Install development tools
curl -sSL https://raw.githubusercontent.com/yourusername/linusstr/master/shared/configure/dev-tools.sh | bash
```

---

## 📁 Project Structure

```
linusstr/
├── shared/
│   ├── provision/          # VM creation scripts
│   │   ├── proxmox.sh      # Proxmox VE provider (408 lines)
│   │   ├── aws.sh          # AWS EC2 provider (405 lines)
│   │   └── qemu.sh         # QEMU/libvirt provider (400 lines)
│   │
│   ├── bootstrap/          # OS setup
│   │   └── ubuntu.sh       # Ubuntu 24.04 bootstrap (330 lines)
│   │
│   ├── configure/          # Development environment
│   │   ├── dev-tools.sh    # Python, Node.js, Docker (366 lines)
│   │   └── base-packages.sh # Build tools (245 lines)
│   │
│   └── lib/                # Shared libraries
│       ├── logging.sh      # Logging functions
│       ├── validation.sh   # Input validation
│       ├── mcp-helpers.sh  # MCP integration
│       ├── noninteractive.sh # Level 2 automation
│       └── tmux-helper.sh  # Level 3 automation
│
├── skill/                  # Claude Code skill documentation
│   └── SKILL.md
│
└── conductor/              # Gemini Conductor documentation
    ├── product.md
    ├── tech-stack.md
    └── workflow.md
```

---

## 🔧 Configuration

### Environment Variables

All providers support these common variables:

```bash
VM_NAME=linus-vm-001    # Instance name (default: linus-vm-<timestamp>)
VM_CPU=2                # CPU cores
VM_RAM=4096             # RAM in MB
VM_DISK=20              # Disk size in GB
```

### Provider-Specific Variables

**Proxmox:**
- `PROXMOX_HOST` - Proxmox host IP (required)
- `PROXMOX_USER` - API user (required, e.g., root@pam)
- `PROXMOX_TOKEN_ID` - API token ID (required)
- `PROXMOX_TOKEN_SECRET` - API token secret (required)
- `PROXMOX_NODE` - Proxmox node name (default: pve)
- `PROXMOX_STORAGE` - Storage name (default: local-lvm)
- `PROXMOX_TEMPLATE_ID` - Template VM ID (default: 9000)

**AWS:**
- `AWS_REGION` - AWS region (required)
- `AWS_KEY_NAME` - EC2 key pair name (required)
- `AWS_INSTANCE_TYPE` - Instance type (optional, auto-selected)
- `AWS_AMI_ID` - AMI ID (optional, auto-detects Ubuntu 24.04)
- `AWS_SUBNET_ID` - VPC subnet (optional, uses default VPC)
- `AWS_SECURITY_GROUP` - Security group (optional, creates linus-default-sg)

**QEMU:**
- `QEMU_HOST` - QEMU host IP (required)
- `QEMU_USER` - SSH username (required)
- `QEMU_SUDO_PASS` - Sudo password (required)
- `QEMU_POOL` - Storage pool (default: default)
- `QEMU_NETWORK` - Network name (default: default)

---

## 🏗️ Architecture

### Three-Level Automation Strategy

**Level 1: Non-Interactive Design (95% of cases) ⭐ Preferred**
- Scripts use `-y`, `-f`, `-q` flags
- No user prompts
- Environment variables for configuration

**Level 2: Smart Wrappers (4% of cases)**
- Cross-distribution compatibility
- Automatic detection and adaptation
- Functions in `noninteractive.sh`

**Level 3: TMUX Sessions (1% of cases)**
- Complex interactive workflows
- Remote session management
- Functions in `tmux-helper.sh`

### Output Format

All provisioning scripts output structured results:

```bash
LINUS_RESULT:SUCCESS
LINUS_VM_NAME:dev-server-001
LINUS_VM_IP:192.168.1.50
LINUS_VM_USER:ubuntu
LINUS_VM_CPU:4
LINUS_VM_RAM:8192
LINUS_VM_DISK:50
```

---

## 🐛 Known Issues & Bugs Fixed

### Proxmox Provider
- ✅ **Fixed (5 bugs):** apt-get logic, curl arguments, pkg_install errors
- ⚠️ **v1.1 Known Issue:** AlmaLinux/Rocky cloud templates have cloud-init networking issues
  - qemu-guest-agent not starting properly in cloud images
  - Network configuration not applied via DHCP
  - **Workaround needed:** Manual template configuration or alternative cloud images
  - **Status:** Under investigation for v1.1.1

### AWS Provider
- ✅ **Fixed (2 bugs):** Logging output, SSH key handling

### QEMU Provider
- ✅ **Fixed (2 bugs):** SSH key mismatch, timeout configuration
- ⚠️ **Note:** Cloud-init takes ~6-7 minutes (longer than other providers)

---

## 🤝 Contributing

This is currently a personal project. If you'd like to contribute:

1. Fork the repository
2. Create a feature branch
3. Test thoroughly on all three providers
4. Submit a pull request

---

## 📝 License

MIT License - See [LICENSE](LICENSE) file for details

---

## 🙏 Acknowledgments

- Built with [Claude Code](https://claude.com/claude-code)
- Uses [ssh-mcp](https://www.npmjs.com/package/ssh-mcp) for MCP integration
- Tested on Proxmox VE 8.x, AWS EC2, and QEMU/KVM

---

## 📊 Project Status

**Version:** 1.1.0
**Status:** Production Ready ✅ (Ubuntu), Experimental (AlmaLinux/Rocky)

| Component | Status |
|-----------|--------|
| Proxmox VE Provider | ✅ Fully tested |
| AWS EC2 Provider | ✅ Fully tested |
| QEMU/libvirt Provider | ✅ Fully tested |
| Ubuntu 24.04 Bootstrap | ✅ Production ready |
| AlmaLinux/Rocky Linux | ⚠️ Code complete, template issues (v1.1) |
| Web UI | ⏳ Planned for v1.2 |

---

**Made with ❤️ for the AI agent development community**

🤖 Generated with [Claude Code](https://claude.com/claude-code)
