# Linus Deployment Specialist - Tech Stack

## Core Technologies

| Component | Choice | Version | Rationale |
|-----------|--------|---------|-----------|
| MCP SSH Server | ssh-mcp | 1.4.0 | SSH client architecture (connects TO remotes), exec/sudo-exec tools |
| Automation Strategy | Hybrid 3-level | v1.0 | Level 1 (non-interactive), Level 2 (wrappers), Level 3 (TMUX) |
| Scripting | Bash (POSIX) | 4.x+ | Universal, no dependencies, works everywhere |
| Local UI | HTML + vanilla JS | N/A | Zero build step, maximum simplicity (deferred to v1.1) |
| Version Control | Git | 2.x | Standard, available everywhere |

## VM Providers

| Provider | API/Tool | Authentication | Status | Notes |
|----------|----------|----------------|--------|-------|
| Proxmox | qm/pvesh CLI | SSH key | ✅ Implemented | Primary on-prem (v1.0) |
| AWS | AWS CLI | IAM credentials/Key Pair | ✅ Implemented | Cloud option (v1.0) |
| QEMU | virsh/libvirt | SSH + sudo | ✅ Implemented | Local/homelab (v1.0) |

## Target Operating Systems

| OS | Version | Package Manager | Cloud-Init |
|----|---------|-----------------|------------|
| Ubuntu | 24.04 LTS | apt | Yes |
| AlmaLinux | 9.x | dnf | Yes |
| Rocky Linux | 9.x | dnf | Yes |
| AWS Linux | 2023 | dnf | Yes |

## Development Environment

### Required
- Node.js 22.x (LTS) - for MCP server
- Bash 4.x+ - for scripts
- Git 2.x - for version control
- SSH client - for connectivity testing

### Optional
- Python 3.12 - for tooling
- jq - for JSON processing
- curl - for API calls

## MCP Server Details

### Package
```
ssh-mcp
```

### Installation
```bash
npm install -g ssh-mcp
```

### Repository
https://github.com/tufantunc/ssh-mcp

### Configuration (Claude Code)
```json
{
  "mcpServers": {
    "linus-ssh": {
      "command": "ssh-mcp",
      "args": [
        "--host=192.168.101.155",
        "--port=22",
        "--user=root",
        "--key=/home/user/.ssh/id_rsa",
        "--timeout=180000",
        "--maxChars=none"
      ]
    }
  }
}
```

### Available Tools
- `exec` - Execute shell command on remote server
- `sudo-exec` - Execute command with sudo privileges

### Limitations
- No native file upload/download (use base64 encoding workaround)
- Commands timeout after configured timeout (default: 60s)
- Non-TTY session (cannot handle interactive prompts)

## Script Standards

### Shell Configuration
```bash
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
```

### Exit Codes
| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error |
| 2 | Missing dependencies |
| 3 | Invalid configuration |
| 4 | Provider unreachable |
| 5 | VM creation failed |
| 6 | Bootstrap failed |

### Logging Format
```
[LEVEL] YYYY-MM-DD HH:MM:SS - Message
```

### Output Format
```
LINUS_RESULT:SUCCESS|FAILURE
LINUS_KEY:VALUE
```

## Hybrid Automation Strategy

To handle non-TTY SSH operations (MCP limitation), we use a three-level approach:

### Level 1: Non-Interactive Design (95% of cases) ⭐
- Use `-y`, `-f`, `-q` flags on all commands
- Set `DEBIAN_FRONTEND=noninteractive` for apt
- Provide defaults via environment variables
- **Example:** `apt-get install -y curl` (not `apt-get install curl`)

### Level 2: Smart Wrapper Library
- **File:** `shared/lib/noninteractive.sh`
- **Functions:** `pkg_install`, `pkg_update`, `service_start`, `safe_copy`, etc.
- **Purpose:** Cross-distro compatibility, reusable patterns
- **Example:** `pkg_install nginx` works on Ubuntu, AlmaLinux, Rocky

### Level 3: TMUX Session Management
- **File:** `shared/lib/tmux-helper.sh`
- **Functions:** `tmux_create_session`, `tmux_monitor_output`, `tmux_remote_*`
- **Purpose:** Long-running operations (>5 min), session persistence
- **Example:** Kubernetes installation, large database imports

**Decision Tree:**
1. Can you add non-interactive flags? → Use Level 1
2. Is it a common operation? → Use Level 2 wrapper
3. Is it long-running or interactive? → Use Level 3 TMUX

**Documentation:** See `.context/AUTOMATION-STRATEGY.md`

## File Structure Convention

```
shared/
├── provision/          # VM creation (one per provider)
│   ├── proxmox.sh      ✅ Proxmox: clone, configure, start, verify (408 lines)
│   ├── aws.sh          ✅ AWS EC2: provision, configure, wait SSH (405 lines)
│   └── qemu.sh         ✅ QEMU/libvirt: cloud-init, virt-install (400 lines)
├── bootstrap/          # OS setup (one per OS)
│   └── ubuntu.sh       ✅ Ubuntu 24.04 essential packages + config (330 lines, ~2 min)
├── configure/          # Common configs (reusable)
│   ├── dev-tools.sh    ✅ Python 3.12, Node.js 22, Docker CE (366 lines, ~5-7 min)
│   └── base-packages.sh ✅ Build tools, network utils (245 lines, ~1 min)
└── lib/                # Shared utilities
    ├── logging.sh      ✅ Log functions (info, warn, error, success, debug)
    ├── validation.sh   ✅ Input validation (deps, env vars, IP, hostname)
    ├── mcp-helpers.sh  ✅ MCP integration (base64 upload, file ops)
    ├── noninteractive.sh ✅ Level 2 automation (smart wrappers, 395 lines)
    └── tmux-helper.sh  ✅ Level 3 automation (TMUX sessions, 374 lines)
```

## Environment Variables

### Naming Convention
```
LINUS_*           - General Linus settings
PROXMOX_*         - Proxmox provider settings
AWS_*             - AWS provider settings  
QEMU_*            - QEMU provider settings
VM_*              - VM specification settings
```

### Required Per Provider

**Proxmox:**
```bash
PROXMOX_HOST=192.168.1.10
PROXMOX_USER=root@pam
PROXMOX_TOKEN_ID=linus
PROXMOX_TOKEN_SECRET=uuid-format
PROXMOX_NODE=pve           # Optional, default: pve
PROXMOX_STORAGE=local-lvm  # Optional
```

**AWS:**
```bash
AWS_REGION=us-west-2
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=...
AWS_INSTANCE_TYPE=t3.medium  # Optional
AWS_KEY_NAME=my-key          # Required
AWS_SUBNET_ID=subnet-xxx     # Optional
AWS_SECURITY_GROUP=sg-xxx    # Optional
```

**QEMU:**
```bash
QEMU_HOST=192.168.101.59     # Required - QEMU host IP/hostname
QEMU_USER=username           # Required - SSH username for QEMU host
QEMU_SUDO_PASS=password      # Required - Sudo password for QEMU host
QEMU_POOL=default            # Optional - libvirt storage pool
QEMU_NETWORK=default         # Optional - libvirt network name
```

**VM Specification:**
```bash
VM_NAME=linus-dev-001
VM_CPU=2
VM_RAM=4096      # MB
VM_DISK=20       # GB
```

## Security Considerations

### What We DO
- Use SSH key authentication
- Validate all inputs
- Log operations for audit

### What We DON'T (by design)
- Harden SSH configurations
- Implement firewall rules
- Encrypt data at rest
- Rotate credentials automatically

**Rationale:** These are ephemeral dev/QA environments. Security adds complexity that doesn't benefit disposable infrastructure.

## Dependencies

### System Packages (on orchestrator)
```bash
# Required
nodejs npm git openssh-client curl

# Optional
jq python3 
```

### System Packages (on target VMs)
```bash
# Installed by bootstrap
curl wget git vim sudo openssh-server
```

## Testing Strategy

| Level | Tool | Location |
|-------|------|----------|
| Syntax | bash -n | Pre-commit |
| Smoke | Manual run | tests/smoke/ |
| Integration | Scripted | tests/integration/ |
| E2E | Full flow | tests/e2e/ |

## Versioning

- Semantic versioning (MAJOR.MINOR.PATCH)
- Git tags for releases
- Changelog maintained in CHANGELOG.md
