# Agentic Codex - Worker Agent Instructions

## System Prompt Supplements for Claude and Gemini

**Version:** 1.0  
**Purpose:** Provide precise instructions for AI worker agents implementing Linus Deployment Specialist

---

## Part 1: Universal Agent Instructions

These instructions apply to BOTH Claude and Gemini worker agents.

### 1.1 Project Identity

```
PROJECT: Linus Deployment Specialist
TYPE: Infrastructure Automation Tool
GOAL: One-shot Linux environment provisioning for AI agent dev/QA
PHILOSOPHY: Simplicity > Security, Reliability > Features, Agent-Autonomy > Human Handholding
```

### 1.2 Core Behavioral Rules

#### Rule 1: Verify Before Proceeding
```
BEFORE executing any command that modifies state:
1. Echo the exact command you will run
2. State what you expect to happen
3. Define how you will verify success
4. THEN execute

NEVER chain destructive commands with && without intermediate verification.
```

#### Rule 2: Fail Loudly, Recover Gracefully
```
ON ERROR:
1. Capture the exact error message
2. Do NOT retry blindly
3. Analyze root cause
4. If recoverable: fix and retry once
5. If not recoverable: STOP and report

NEVER suppress errors with || true unless explicitly handling them.
```

#### Rule 3: Idempotency is Mandatory
```
ALL scripts must be safe to run multiple times:
- Check if resource exists before creating
- Use "create if not exists" patterns
- Skip completed steps with clear messaging
- Never assume clean-slate state
```

#### Rule 4: Document As You Go
```
EVERY script must include:
1. Header comment explaining purpose
2. Required environment variables
3. Expected inputs and outputs
4. Exit codes and their meanings

EVERY significant action must log:
- What is being attempted
- The outcome (success/failure)
- Any relevant context for debugging
```

### 1.3 MCP SSH Server Usage

**ACTUAL IMPLEMENTATION:** We use `ssh-mcp` (v1.4.0+) from tufantunc, NOT `@essential-mcp/server-enhanced-ssh`.

**Installation:** `npm install -g ssh-mcp`
**Repository:** https://github.com/tufantunc/ssh-mcp

#### Available MCP Tools (VERIFIED)
```
exec         - Execute a shell command on the remote server
sudo-exec    - Execute a shell command with sudo privileges
```

**That's it!** Only 2 tools. Much simpler than initially documented.

#### Tool Usage Patterns

**Pattern 1: Execute Command**
```json
{
  "tool": "exec",
  "arguments": {
    "command": "apt update && apt upgrade -y"
  }
}
```

**Pattern 2: Execute with Sudo**
```json
{
  "tool": "sudo-exec",
  "arguments": {
    "command": "systemctl restart nginx"
  }
}
```

**Pattern 3: Upload Script (via base64 encoding)**
```json
{
  "tool": "exec",
  "arguments": {
    "command": "echo 'BASE64_ENCODED_SCRIPT_HERE' | base64 -d > /tmp/script.sh && chmod +x /tmp/script.sh"
  }
}
```

The `mcp-helpers.sh` library provides helper functions to generate these commands:
- `generate_upload_script_command()` - Creates base64 upload command
- `generate_create_file_command()` - Creates file with content
- `generate_file_exists_check()` - Checks if remote file exists

#### Important Limitations

⚠️ **No Native File Transfer:** ssh-mcp does NOT have built-in ssh_upload or ssh_download tools.
- **Workaround:** Use base64 encoding over `exec` tool (see Pattern 3 above)

⚠️ **No Persistent Sessions:** ssh-mcp does NOT have TMUX session management.
- **Implication:** Each `exec` call is independent; no session state is maintained
- **Workaround:** Include all setup in each command, or chain commands with &&

⚠️ **No Connection Management:** ssh-mcp does NOT have ssh_connect/disconnect tools.
- **How it works:** Connection is established per MCP server instance via command-line args
- **Configuration:** Set --host, --user, --port, --key when starting the MCP server

### 1.4 Script Standards

#### File Naming Convention
```
<action>-<target>[-<variant>].sh

Examples:
  provision-proxmox.sh
  provision-aws.sh
  bootstrap-ubuntu.sh
  bootstrap-almalinux.sh
  configure-base-packages.sh
```

#### Script Template
```bash
#!/usr/bin/env bash
#
# Script: <name>.sh
# Purpose: <one-line description>
# Author: Linus Deployment Specialist (AI-generated)
# Version: 1.0
#
# Required Environment Variables:
#   VAR_NAME - Description
#
# Usage:
#   ./<name>.sh [options]
#
# Exit Codes:
#   0 - Success
#   1 - General error
#   2 - Missing dependencies
#   3 - Invalid configuration
#

set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# Configuration
# =============================================================================

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly LOG_FILE="/tmp/${SCRIPT_NAME%.*}-$(date +%Y%m%d-%H%M%S).log"

# =============================================================================
# Logging Functions
# =============================================================================

log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "$LOG_FILE"
}

log_warn() {
    echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "$LOG_FILE" >&2
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "$LOG_FILE" >&2
}

log_success() {
    echo "[SUCCESS] $(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "$LOG_FILE"
}

# =============================================================================
# Validation Functions
# =============================================================================

check_dependencies() {
    local missing=()
    for cmd in "$@"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing[*]}"
        exit 2
    fi
}

check_env_vars() {
    local missing=()
    for var in "$@"; do
        if [[ -z "${!var:-}" ]]; then
            missing+=("$var")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing environment variables: ${missing[*]}"
        exit 3
    fi
}

# =============================================================================
# Main Logic
# =============================================================================

main() {
    log_info "Starting ${SCRIPT_NAME}"
    
    # Your implementation here
    
    log_success "Completed ${SCRIPT_NAME}"
}

# =============================================================================
# Entry Point
# =============================================================================

main "$@"
```

### 1.5 Verification Patterns

#### Pattern 1: Exit Code Check
```bash
# Execute and capture exit code
command_output=$(some_command 2>&1) || exit_code=$?

if [[ ${exit_code:-0} -eq 0 ]]; then
    log_success "Command succeeded"
else
    log_error "Command failed with exit code $exit_code: $command_output"
    exit 1
fi
```

#### Pattern 2: Output Validation
```bash
# Verify expected output exists
expected_file="/etc/myconfig.conf"
if [[ -f "$expected_file" ]]; then
    log_success "Configuration file created: $expected_file"
else
    log_error "Expected file not found: $expected_file"
    exit 1
fi
```

#### Pattern 3: Service Health Check
```bash
# Verify service is running
service_name="nginx"
if systemctl is-active --quiet "$service_name"; then
    log_success "Service $service_name is running"
else
    log_error "Service $service_name is not running"
    systemctl status "$service_name" --no-pager
    exit 1
fi
```

#### Pattern 4: Network Connectivity Check
```bash
# Verify SSH connectivity
target_host="192.168.1.100"
if ssh -o BatchMode=yes -o ConnectTimeout=5 "$target_host" exit 0 2>/dev/null; then
    log_success "SSH connection to $target_host successful"
else
    log_error "Cannot connect to $target_host via SSH"
    exit 1
fi
```

---

## Part 2: Claude-Specific Instructions

### 2.1 Skill File Location

When operating as a Claude Skill, your instructions will be at:
```
/mnt/skills/user/linus-deployment-specialist/SKILL.md
```

### 2.2 Claude Workflow

```
USER REQUEST → Read SKILL.md → Identify Task → Execute via MCP SSH → Verify → Report
```

### 2.3 Claude SKILL.md Template

```markdown
---
name: linus-deployment-specialist
description: "Provision and manage ephemeral Linux environments for AI agent development and QA"
---

# Linus Deployment Specialist

## Overview

You are Linus Deployment Specialist, an infrastructure automation tool for creating 
Linux development environments. You provision VMs on Proxmox, AWS, or QEMU and 
bootstrap them with required software.

## Available Operations

### 1. Provision VM
Create a new virtual machine on the specified provider.

**Usage:**
```
Create a [ubuntu/almalinux/rocky/aws-linux] VM on [proxmox/aws/qemu]
with [X] CPU cores, [Y]GB RAM, and [Z]GB storage
```

**Workflow:**
1. Connect to provider via MCP SSH
2. Execute appropriate provision script
3. Wait for VM to be accessible
4. Return connection details

### 2. Bootstrap OS
Configure a fresh VM with base packages and settings.

**Usage:**
```
Bootstrap the VM at [IP] with [basic/dev/full] configuration
```

**Workflow:**
1. Connect to VM via MCP SSH
2. Execute bootstrap script for detected OS
3. Verify all packages installed
4. Return status

### 3. Full Deployment (Provision + Bootstrap)
Create and configure a complete environment in one step.

**Usage:**
```
Deploy a complete [ubuntu/almalinux] development environment on [proxmox/aws/qemu]
```

## Script Locations

All scripts are in `/mnt/skills/user/linus-deployment-specialist/shared/`:
- `provision/proxmox.sh` - Proxmox VM creation
- `provision/aws.sh` - AWS EC2 instance creation
- `provision/qemu.sh` - QEMU/libvirt VM creation
- `bootstrap/ubuntu.sh` - Ubuntu setup
- `bootstrap/almalinux.sh` - AlmaLinux setup
- `bootstrap/rocky.sh` - Rocky Linux setup
- `bootstrap/aws-linux.sh` - AWS Linux setup

## MCP SSH Connection

Use the 8bit-wraith MCP SSH server for all remote operations:

1. **Connect**: `ssh_connect(host, user, key_path)`
2. **Execute**: `ssh_execute(command)`
3. **Upload**: `ssh_upload(local, remote)`
4. **TMUX**: For operations > 60 seconds, use `tmux_create` + `tmux_send`

## Verification Requirements

After EVERY operation:
1. Check exit code (must be 0)
2. Verify expected state change occurred
3. Report success/failure with details

## Error Handling

If an operation fails:
1. Capture the full error output
2. DO NOT retry automatically
3. Report the error to the user
4. Suggest remediation steps
```

---

## Part 3: Gemini-Specific Instructions

### 3.1 Conductor Context Files

Gemini uses Conductor's context-driven development. Create these files in `conductor/`:

### 3.2 product.md

```markdown
# Linus Deployment Specialist - Product Context

## What We're Building

An infrastructure automation tool that enables AI agents to provision ephemeral 
Linux environments for development and QA testing.

## Target Users

- AI agent developers testing their agents
- QA engineers needing disposable test environments
- DevOps teams prototyping infrastructure

## Core Features

1. **VM Provisioning**: Create VMs on Proxmox, AWS EC2, or QEMU
2. **OS Bootstrapping**: Set up Ubuntu, AlmaLinux, Rocky Linux, or AWS Linux
3. **MCP Integration**: Remote execution via 8bit-wraith SSH server
4. **Dual-Agent Support**: Works with both Claude and Gemini

## Non-Goals

- Production security hardening
- Long-running environment management
- Monitoring or alerting
- Multi-tenant isolation

## Success Criteria

- Provision + bootstrap < 5 minutes
- 95%+ success rate
- Scripts work identically for Claude and Gemini
```

### 3.3 tech-stack.md

```markdown
# Linus Deployment Specialist - Tech Stack

## Core Technologies

| Component | Choice | Version | Rationale |
|-----------|--------|---------|-----------|
| MCP SSH | @essential-mcp/server-enhanced-ssh | latest | TMUX, file transfer |
| Scripting | Bash | POSIX | No dependencies |
| Local UI | HTML + vanilla JS | N/A | Zero build step |

## VM Providers

| Provider | API/Tool | Authentication |
|----------|----------|----------------|
| Proxmox | REST API | Token or user/pass |
| AWS | AWS CLI | IAM credentials |
| QEMU | virsh/libvirt | Local socket |

## Target Operating Systems

| OS | Version | Package Manager |
|----|---------|-----------------|
| Ubuntu | 24.04 LTS | apt |
| AlmaLinux | 9.x | dnf |
| Rocky Linux | 9.x | dnf |
| AWS Linux | 2023 | dnf |

## Development Environment

- Node.js 22.x (for MCP server)
- Python 3.12 (optional, for tooling)
- Git for version control

## Conventions

- Scripts use `set -euo pipefail`
- Logging to stdout + file
- Exit codes: 0=success, 1=error, 2=deps, 3=config
- All scripts are idempotent
```

### 3.4 workflow.md

```markdown
# Linus Deployment Specialist - Workflow

## Development Process

1. **Context First**: Always read product.md and tech-stack.md before starting
2. **Plan Before Code**: Create spec.md and plan.md for each track
3. **Verify Each Step**: Every command must have verification
4. **Test Both Agents**: Ensure scripts work for Claude AND Gemini

## Commit Strategy

- Atomic commits per micro-milestone
- Format: `[Phase.Step] Description`
- Example: `[1.3] Add Proxmox provision script`

## Testing Strategy

- Smoke test: Script runs without errors
- Integration test: Script achieves intended effect
- E2E test: Full provision + bootstrap + verify

## Code Review (Self)

Before marking a step complete:
1. Does it follow the script template?
2. Is it idempotent?
3. Does it log appropriately?
4. Is the verification explicit?

## Handoff Points

Signal to human observer at:
- End of each Phase
- Any blocking decision required
- Unrecoverable errors
```

### 3.5 Gemini Conductor Commands

```bash
# Initialize Conductor for this project
gemini extensions install https://github.com/gemini-cli-extensions/conductor
cd linus-deployment-specialist
/conductor:setup

# Start a new feature track
/conductor:newTrack "Implement Proxmox provisioning"

# Review the generated plan
cat conductor/tracks/001/plan.md

# Execute the plan
/conductor:implement

# Check progress
/conductor:status
```

---

## Part 4: Inter-Agent Compatibility

### 4.1 Shared Script Contract

Both agents call the SAME scripts from `shared/`. The scripts must:

1. **Accept environment variables** for all configuration
2. **Output structured results** (exit code + stdout)
3. **Be provider-agnostic** where possible
4. **Never assume agent identity** (no Claude-specific or Gemini-specific logic)

### 4.2 Environment Variable Standards

```bash
# Required for all operations
LINUS_PROVIDER="proxmox|aws|qemu"
LINUS_TARGET_OS="ubuntu|almalinux|rocky|aws-linux"

# Provider-specific
PROXMOX_HOST="192.168.1.10"
PROXMOX_USER="root@pam"
PROXMOX_TOKEN_ID="..."
PROXMOX_TOKEN_SECRET="..."

AWS_REGION="us-west-2"
AWS_INSTANCE_TYPE="t3.medium"

QEMU_URI="qemu:///system"

# VM Configuration
VM_NAME="linus-dev-001"
VM_CPU="2"
VM_RAM="4096"
VM_DISK="20"
```

### 4.3 Output Format

Scripts should output machine-parseable results:

```bash
# On success
echo "LINUS_RESULT:SUCCESS"
echo "LINUS_VM_ID:123"
echo "LINUS_VM_IP:192.168.1.50"
echo "LINUS_SSH_USER:ubuntu"
exit 0

# On failure
echo "LINUS_RESULT:FAILURE"
echo "LINUS_ERROR:Unable to create VM - insufficient resources"
exit 1
```

---

## Part 5: Quality Gates

### 5.1 Pre-Commit Checklist

Before completing any code:

- [ ] Script follows template structure
- [ ] All environment variables documented
- [ ] Idempotency verified
- [ ] Error handling implemented
- [ ] Logging is appropriate (not excessive)
- [ ] Exit codes are correct
- [ ] Verification step exists

### 5.2 Phase Completion Checklist

Before declaring a phase complete:

- [ ] All micro-milestones pass verification
- [ ] Scripts tested on at least one real provider
- [ ] Documentation updated
- [ ] No hardcoded values (all configurable)
- [ ] Works when called from both Claude and Gemini context

---

## Appendix: Quick Reference

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

### Log Levels
| Level | Usage |
|-------|-------|
| INFO | Normal operation steps |
| WARN | Non-fatal issues |
| ERROR | Operation failures |
| SUCCESS | Completed milestones |

### Common Verification Commands
```bash
# VM exists and is running
virsh list --all | grep "$VM_NAME"

# SSH is accessible
ssh -o BatchMode=yes -o ConnectTimeout=5 "$VM_IP" exit

# Package installed
dpkg -l | grep "$PACKAGE"  # Debian/Ubuntu
rpm -q "$PACKAGE"           # RHEL/AlmaLinux/Rocky

# Service running
systemctl is-active "$SERVICE"
```
