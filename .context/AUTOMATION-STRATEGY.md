# Linus Deployment Specialist - Automation Strategy

**Version:** 1.0
**Created:** 2025-12-28
**Purpose:** Handle interactive prompts in non-interactive SSH automation

---

## Problem Statement

Simple SSH MCP servers (like `ssh-mcp`) cannot handle interactive prompts because there's no TTY for user input. Commands that ask questions will hang indefinitely:

```bash
# These will HANG with simple SSH:
apt install package          # "Do you want to continue? [Y/n]"
rm -i file                   # "remove file? (y/n)"
ssh-keygen                   # "Enter passphrase:"
```

---

## Solution: Three-Level Hybrid Approach

We use a **layered strategy** where you choose the right tool for the complexity of the task:

```
Level 1: Non-Interactive Design ──> 95% of use cases ✅ PREFERRED
         ↓ (if insufficient)
Level 2: Smart Wrapper Library ──> Complex multi-tool workflows
         ↓ (if insufficient)
Level 3: TMUX Session Management ──> Long-running, truly interactive tasks
```

---

## Level 1: Non-Interactive Script Design ⭐ RECOMMENDED

**Philosophy**: Design scripts to NEVER prompt for input

### Guidelines:

1. **Always use non-interactive flags**:
   ```bash
   #!/usr/bin/env bash
   set -euo pipefail

   # Set non-interactive environment
   export DEBIAN_FRONTEND=noninteractive

   # Use -y flag for confirmations
   apt-get install -y package

   # Use -f for force operations
   rm -f file

   # Use -q for quiet mode
   git clone --quiet repo
   ```

2. **Provide defaults via environment variables**:
   ```bash
   readonly CONFIRM="${CONFIRM:-yes}"
   readonly OVERWRITE="${OVERWRITE:-false}"
   readonly TIMEOUT="${TIMEOUT:-300}"
   ```

3. **Document non-interactive requirements**:
   ```bash
   #!/usr/bin/env bash
   # =============================================================================
   # CRITICAL: This script MUST run non-interactively
   # All operations use automatic defaults (see environment variables above)
   # =============================================================================
   ```

### Common Non-Interactive Flags:

| Tool | Interactive | Non-Interactive |
|------|------------|-----------------|
| **apt** | `apt install pkg` | `apt install -y pkg` |
| **yum/dnf** | `yum install pkg` | `yum install -y pkg` |
| **rm** | `rm -i file` | `rm -f file` |
| **cp** | `cp -i src dst` | `cp -f src dst` |
| **git clone** | `git clone repo` | `git clone --quiet repo` |
| **systemctl** | `systemctl restart srv` | `systemctl restart --quiet srv` |

### When to Use:
- ✅ **ALL** production automation scripts
- ✅ VM provisioning (our current use case)
- ✅ Deployment pipelines
- ✅ Scheduled tasks

### Pros:
- ✅ Simple, predictable, testable
- ✅ No dependencies
- ✅ Fast execution
- ✅ Easy to debug

### Cons:
- ⚠️ Requires knowing the right flags
- ⚠️ Some tools don't have non-interactive options

---

## Level 2: Smart Wrapper Library

**Philosophy**: Centralize non-interactive logic in reusable functions

### Library: `shared/lib/noninteractive.sh`

#### Usage:

```bash
#!/usr/bin/env bash
source "${SCRIPT_DIR}/../lib/noninteractive.sh"

# Package management (auto-detects distro)
pkg_install nginx postgresql
pkg_update
pkg_upgrade
pkg_remove apache2

# File operations
safe_remove /tmp/oldfile
safe_copy /src/file /dest/file overwrite

# Git operations
git_clone_quiet https://github.com/user/repo /opt/repo
git_pull_quiet /opt/repo

# Service management
service_start nginx
service_enable postgresql
service_restart nginx

# Downloads
download_file https://example.com/file.tar.gz /tmp/file.tar.gz

# Generic runner (auto-adds flags)
run_noninteractive apt install nginx
```

### Available Functions:

#### Package Management:
- `pkg_install <packages...>` - Install packages (any distro)
- `pkg_update` - Update package lists
- `pkg_upgrade` - Upgrade all packages
- `pkg_remove <packages...>` - Remove packages

#### File Operations:
- `safe_remove <path> [force]` - Remove files/directories
- `safe_copy <source> <dest> [overwrite]` - Copy files

#### Git:
- `git_clone_quiet <url> [dir] [branch]` - Clone repository quietly
- `git_pull_quiet [dir]` - Pull updates quietly

#### Services:
- `service_start <name>` - Start service (systemd/sysvinit)
- `service_stop <name>` - Stop service
- `service_enable <name>` - Enable service at boot
- `service_restart <name>` - Restart service

#### Users:
- `user_create <username> [home] [shell]` - Create user
- `user_add_to_group <username> <group>` - Add user to group

#### Network:
- `download_file <url> [output]` - Download file with curl

#### Generic:
- `run_noninteractive <command>` - Run command with auto-flags

### When to Use:
- ✅ Multiple scripts with common patterns
- ✅ Cross-distro compatibility needed
- ✅ Centralizing best practices

### Pros:
- ✅ Reusable across all scripts
- ✅ Handles distro differences automatically
- ✅ Tested, reliable wrappers
- ✅ Still works with simple SSH

### Cons:
- ⚠️ Another library dependency
- ⚠️ Limited to covered commands

---

## Level 3: TMUX Session Management 🚀

**Philosophy**: For complex operations that truly need persistence or interaction

### Library: `shared/lib/tmux-helper.sh`

#### Usage:

```bash
#!/usr/bin/env bash
source "${SCRIPT_DIR}/../lib/tmux-helper.sh"

# Create TMUX session with command
tmux_create_session "provision-vm-113" "/opt/provision.sh"

# Monitor for completion
tmux_monitor_output "provision-vm-113" "LINUS_RESULT:SUCCESS" "LINUS_RESULT:FAILURE" 600

# Capture output
tmux_capture_pane "provision-vm-113" 0 100

# Send interactive input if needed
tmux_send_keys "provision-vm-113" "yes"

# Clean up
tmux_kill_session "provision-vm-113"
```

#### Remote TMUX (for operations on remote hosts):

```bash
# Create TMUX session on Proxmox host
tmux_remote_create "root@192.168.101.155" "provision-vm" "./provision.sh"

# Monitor remote session
tmux_remote_capture "root@192.168.101.155" "provision-vm" 50

# Send input to remote session
tmux_remote_send_keys "root@192.168.101.155" "provision-vm" "yes"

# Kill remote session
tmux_remote_kill "root@192.168.101.155" "provision-vm"
```

### Available Functions:

#### Session Management:
- `tmux_create_session <name> [command] [dir]` - Create detached session
- `tmux_list_sessions` - List all sessions
- `tmux_session_exists <name>` - Check if session exists
- `tmux_kill_session <name>` - Kill session

#### Window Management:
- `tmux_create_window <session> <name> [command]` - Create window
- `tmux_list_windows <session>` - List windows

#### Interaction:
- `tmux_send_keys <session> <keys> [window]` - Send input to session
- `tmux_capture_pane <session> [window] [lines]` - Capture output
- `tmux_capture_last_line <session> [window]` - Get last line

#### Workflows:
- `tmux_run_script <session> <script> [dir]` - Run script in TMUX
- `tmux_wait_for_completion <session> [timeout]` - Wait for session end
- `tmux_monitor_output <session> <success> <error> [timeout]` - Monitor for patterns

#### Remote Operations:
- `tmux_remote_create <host> <session> [command]` - Create remote session
- `tmux_remote_send_keys <host> <session> <keys>` - Send remote input
- `tmux_remote_capture <host> <session> [lines]` - Capture remote output
- `tmux_remote_kill <host> <session>` - Kill remote session

### When to Use:
- ⚠️ **ONLY** when Level 1 & 2 are insufficient
- ✅ Long-running operations (> 5 minutes)
- ✅ Operations that might disconnect
- ✅ Truly interactive third-party tools
- ✅ Multi-step workflows needing state

### Pros:
- ✅ Session persistence (survives disconnects)
- ✅ Can send input mid-execution
- ✅ Monitor long-running tasks
- ✅ Works with any tool

### Cons:
- ⚠️ Requires TMUX installed on target
- ⚠️ More complex to implement
- ⚠️ Need to manage lifecycle
- ⚠️ Overkill for simple operations

---

## Decision Tree: Which Level to Use?

```
┌─────────────────────────────────────┐
│ Can you add -y/-f flags to command? │
└─────────┬───────────────────────────┘
          │
    YES ──┼──> Level 1: Use flags directly ✅ DONE
          │
    NO────┘
          │
┌─────────┴───────────────────────────────────────┐
│ Is it a common operation (apt, git, service)?   │
└─────────┬───────────────────────────────────────┘
          │
    YES ──┼──> Level 2: Use noninteractive.sh wrapper ✅ DONE
          │
    NO────┘
          │
┌─────────┴────────────────────────────────────────┐
│ Is it long-running or needs mid-stream input?    │
└─────────┬────────────────────────────────────────┘
          │
    YES ──┼──> Level 3: Use tmux-helper.sh 🚀
          │
    NO────┘
          │
┌─────────┴────────────────────────────┐
│ Consider redesigning the workflow    │
│ to use Level 1 or 2                  │
└───────────────────────────────────────┘
```

---

## Best Practices

### 1. **Start Simple, Escalate as Needed**
   - Always try Level 1 first
   - Only use Level 2 for repeated patterns
   - Reserve Level 3 for genuinely complex cases

### 2. **Document Your Choice**
   ```bash
   #!/usr/bin/env bash
   # AUTOMATION LEVEL: 1 (Non-interactive design)
   # Rationale: Simple package installation, no complex workflows
   ```

### 3. **Test Each Level**
   - Level 1: Run script directly via SSH
   - Level 2: Test wrapper functions individually
   - Level 3: Verify TMUX sessions cleanup properly

### 4. **Error Handling at Each Level**
   ```bash
   # Level 1: Use set -e
   set -euo pipefail

   # Level 2: Wrappers return status codes
   if ! pkg_install nginx; then
       log_error "Installation failed"
       exit 1
   fi

   # Level 3: Monitor for success/failure patterns
   if ! tmux_monitor_output "session" "SUCCESS" "FAILURE"; then
       tmux_kill_session "session"
       exit 1
   fi
   ```

---

## Examples

### Example 1: Simple Package Installation (Level 1)

```bash
#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y nginx postgresql
systemctl enable --quiet nginx
```

### Example 2: Cross-Distro Deployment (Level 2)

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/../lib/noninteractive.sh"

pkg_update
pkg_install nginx postgresql redis
service_enable nginx
service_start nginx
```

### Example 3: Long-Running Build (Level 3)

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/../lib/tmux-helper.sh"

# Start build in TMUX session
tmux_create_session "app-build" "/opt/build.sh"

# Monitor for completion (30 min timeout)
if tmux_monitor_output "app-build" "BUILD SUCCESS" "BUILD FAILED" 1800; then
    log_success "Build completed"
    tmux_capture_pane "app-build" > /var/log/build.log
else
    log_error "Build failed or timed out"
    tmux_capture_pane "app-build" > /var/log/build-error.log
fi

tmux_kill_session "app-build"
```

---

## Current Implementation Status

| Component | Status | Notes |
|-----------|--------|-------|
| **Level 1 Documentation** | ✅ Complete | In use in proxmox.sh |
| **Level 2 Library** | ✅ Complete | `shared/lib/noninteractive.sh` |
| **Level 3 Library** | ✅ Complete | `shared/lib/tmux-helper.sh` |
| **proxmox.sh** | ✅ Uses Level 1 | No changes needed |
| **Testing** | ⏳ Pending | Create test scripts |
| **Documentation** | ✅ Complete | This document |

---

## Migration Guide

### For Existing Scripts:

1. **Audit current scripts** - Check for potential interactive prompts
2. **Add Level 1 patterns** - Add `-y`, `-f`, `-q` flags
3. **Consider Level 2** - If multiple scripts share patterns
4. **Reserve Level 3** - Only for truly complex needs

### For New Scripts:

1. **Start with Level 1** - Design non-interactive from the start
2. **Use Level 2 wrappers** - For standard operations
3. **Document assumptions** - What flags are used and why

---

**Remember**: Keep it simple! 95% of automation should use **Level 1** only. 🎯
