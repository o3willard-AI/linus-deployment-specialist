# Linus Deployment Specialist - Tech Stack

## Core Technologies

| Component | Choice | Version | Rationale |
|-----------|--------|---------|-----------|
| MCP SSH Server | @essential-mcp/server-enhanced-ssh | latest | TMUX sessions, file transfer, persistent connections |
| Scripting | Bash (POSIX) | N/A | Universal, no dependencies, works everywhere |
| Local UI | HTML + vanilla JS | N/A | Zero build step, maximum simplicity |
| Version Control | Git | 2.x | Standard, available everywhere |

## VM Providers

| Provider | API/Tool | Authentication | Notes |
|----------|----------|----------------|-------|
| Proxmox | REST API via curl | Token or user/pass | Primary enterprise target |
| AWS | AWS CLI | IAM credentials | Cloud provider option |
| QEMU | virsh/libvirt | Local socket | Local development option |

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
@essential-mcp/server-enhanced-ssh
```

### Installation
```bash
npm install -g @essential-mcp/server-enhanced-ssh
```

### Configuration Location
```
~/.mcp/ssh/config/
```

### Default Port
```
6480
```

### Key Features Used
- Persistent TMUX sessions
- Multi-window support
- Smart session recovery
- File upload/download

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

## File Structure Convention

```
shared/
├── provision/          # VM creation (one per provider)
│   └── {provider}.sh
├── bootstrap/          # OS setup (one per OS)
│   └── {os}.sh
├── configure/          # Common configs (reusable)
│   └── {purpose}.sh
└── lib/                # Shared utilities
    └── {utility}.sh
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
QEMU_URI=qemu:///system      # Optional
QEMU_POOL=default            # Optional
QEMU_NETWORK=default         # Optional
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
