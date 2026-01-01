# Linus Deployment Specialist

> **Provision ephemeral Linux environments for AI agent development and QA testing**

An infrastructure automation tool that enables AI agents to create, configure, and manage disposable Linux VMs across multiple providers (Proxmox, AWS EC2, QEMU/libvirt).

[![Version](https://img.shields.io/badge/version-1.0.0-blue.svg)](https://github.com/yourusername/linusstr)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Providers](https://img.shields.io/badge/providers-3-success.svg)](README.md#supported-providers)

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

### Prerequisites

- **Local Machine:**
  - Node.js 24.12+ (for MCP server)
  - sshpass (for QEMU provider)

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

1. **Clone the repository:**
   ```bash
   git clone https://github.com/yourusername/linusstr.git
   cd linusstr
   ```

2. **Install MCP SSH server:**
   ```bash
   npm install -g ssh-mcp
   ```

3. **Configure Claude Code** (if using Claude):
   ```bash
   # Add to ~/.config/claude-code/mcp.json
   {
     "mcpServers": {
       "ssh": {
         "command": "ssh-mcp"
       }
     }
   }
   ```

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

**Version:** 1.0.0
**Status:** Production Ready ✅

| Component | Status |
|-----------|--------|
| Proxmox VE Provider | ✅ Fully tested |
| AWS EC2 Provider | ✅ Fully tested |
| QEMU/libvirt Provider | ✅ Fully tested |
| Ubuntu 24.04 Bootstrap | ✅ Production ready |
| AlmaLinux/Rocky Linux | ⏳ Planned for v1.1 |
| Web UI | ⏳ Planned for v1.1 |

---

**Made with ❤️ for the AI agent development community**

🤖 Generated with [Claude Code](https://claude.com/claude-code)
