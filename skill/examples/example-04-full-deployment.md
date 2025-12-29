# Example 04: Full Deployment Workflow

## User Request
"Create a fully configured Ubuntu development VM with Python, Node.js, and Docker"

---

## Agent Response

I'll create a complete development environment for you with all the requested tools. This will take approximately 10-12 minutes.

---

## Step 1: Provision VM on Proxmox

**Action:** Execute proxmox.sh to create the base VM

**Agent Process:**
1. Read `/home/sblanken/working/linusstr/shared/provision/proxmox.sh`
2. Upload script to Proxmox host via MCP ssh-mcp
3. Execute with environment variables:
   ```bash
   VM_CPU=4
   VM_RAM=8192
   VM_DISK=40
   ```

**Output:**
```
[INFO] 2025-12-29 01:00:00 - Step 1: Validating environment
[SUCCESS] 2025-12-29 01:00:02 - Environment validation passed
[INFO] 2025-12-29 01:00:02 - Step 2: Allocating VM ID
[SUCCESS] 2025-12-29 01:00:02 - Allocated VM ID: 114
[INFO] 2025-12-29 01:00:03 - Step 3: Cloning template VM 9000
[SUCCESS] 2025-12-29 01:00:18 - VM 114 created from template
[INFO] 2025-12-29 01:00:18 - Step 4: Configuring VM resources
[SUCCESS] 2025-12-29 01:00:21 - VM configured: 4 CPU, 8192MB RAM, 40GB disk
[INFO] 2025-12-29 01:00:21 - Step 5: Starting VM
[SUCCESS] 2025-12-29 01:00:23 - VM started
[INFO] 2025-12-29 01:00:23 - Step 6: Waiting for network configuration
[SUCCESS] 2025-12-29 01:00:38 - VM IP obtained: 192.168.101.114
[INFO] 2025-12-29 01:00:38 - Step 7: Verifying SSH accessibility
[SUCCESS] 2025-12-29 01:00:48 - SSH is ready at ubuntu@192.168.101.114

LINUS_RESULT:SUCCESS
LINUS_VM_ID:114
LINUS_VM_IP:192.168.101.114
LINUS_VM_USER:ubuntu
LINUS_VM_NAME:linus-vm-114
```

**Duration:** 1 minute 48 seconds

**Agent Communicates to User:**
```
✅ VM Provisioned Successfully!
- VM ID: 114
- IP: 192.168.101.114
- SSH: ssh ubuntu@192.168.101.114

Moving to Step 2: Bootstrap Ubuntu...
```

---

## Step 2: Bootstrap Ubuntu

**Action:** Install essential packages and configure OS

**Agent Process:**
1. Read bootstrap script and required libraries:
   - `/home/sblanken/working/linusstr/shared/bootstrap/ubuntu.sh`
   - `/home/sblanken/working/linusstr/shared/lib/logging.sh`
   - `/home/sblanken/working/linusstr/shared/lib/validation.sh`

2. Upload scripts to VM via SCP (through MCP):
   ```bash
   scp ubuntu.sh logging.sh validation.sh ubuntu@192.168.101.114:/tmp/
   ```

3. Execute bootstrap script:
   ```bash
   ssh ubuntu@192.168.101.114 "cd /tmp && sudo bash ubuntu.sh"
   ```

**Output:**
```
[INFO] 2025-12-29 01:02:00 - Step 1: Validating environment
[INFO] 2025-12-29 01:02:00 - Detected: Ubuntu 24.04 LTS
[SUCCESS] 2025-12-29 01:02:01 - Environment validation passed
[INFO] 2025-12-29 01:02:01 - Step 2: Updating package cache
[SUCCESS] 2025-12-29 01:02:15 - Package cache updated
[INFO] 2025-12-29 01:02:15 - Step 3: Upgrading existing packages
[SUCCESS] 2025-12-29 01:02:48 - Packages upgraded
[INFO] 2025-12-29 01:02:48 - Step 4: Installing essential packages
[INFO] 2025-12-29 01:02:48 - Installing: curl wget git vim nano tmux screen htop ncdu tree
[SUCCESS] 2025-12-29 01:03:25 - Essential packages installed
[INFO] 2025-12-29 01:03:25 - Step 6: Configuring timezone
[SUCCESS] 2025-12-29 01:03:26 - Timezone configured: UTC
[INFO] 2025-12-29 01:03:26 - Step 7: Configuring locale
[SUCCESS] 2025-12-29 01:03:28 - Locale configured: en_US.UTF-8
[INFO] 2025-12-29 01:03:28 - Step 8: Cleaning up
[SUCCESS] 2025-12-29 01:03:35 - Cleanup complete
[INFO] 2025-12-29 01:03:35 - Step 9: Verifying installations
[SUCCESS] 2025-12-29 01:03:36 - All packages verified

LINUS_RESULT:SUCCESS
LINUS_PACKAGES_INSTALLED:curl,wget,git,vim,tmux,htop,ncdu,tree,nano,screen
LINUS_PACKAGE_COUNT:10
LINUS_TIMEZONE:UTC
LINUS_LOCALE:en_US.UTF-8
```

**Duration:** 1 minute 36 seconds

**Agent Communicates to User:**
```
✅ Ubuntu Bootstrapped!
- Essential packages: curl, wget, git, vim, tmux, htop, tree
- Timezone: UTC
- Locale: en_US.UTF-8

Moving to Step 3: Install Development Tools...
```

---

## Step 3: Install Development Tools

**Action:** Install Python, Node.js, and Docker

**Agent Process:**
1. Read dev-tools script and dependencies:
   - `/home/sblanken/working/linusstr/shared/configure/dev-tools.sh`
   - `/home/sblanken/working/linusstr/shared/lib/noninteractive.sh`

2. Upload to VM:
   ```bash
   scp dev-tools.sh noninteractive.sh ubuntu@192.168.101.114:/tmp/
   ```

3. Execute:
   ```bash
   ssh ubuntu@192.168.101.114 "cd /tmp && sudo bash dev-tools.sh"
   ```

**Output:**
```
[INFO] 2025-12-29 01:04:00 - Step 1: Validating environment
[INFO] 2025-12-29 01:04:00 - Detected: Ubuntu 24.04 LTS
[SUCCESS] 2025-12-29 01:04:01 - Environment validation passed

[INFO] 2025-12-29 01:04:01 - Step 2: Installing Python 3
[SUCCESS] 2025-12-29 01:04:15 - Python installed: 3.12.0

[INFO] 2025-12-29 01:04:15 - Step 3: Installing Node.js 22
[INFO] 2025-12-29 01:04:15 - Adding NodeSource repository...
[SUCCESS] 2025-12-29 01:04:58 - Node.js installed: v22.11.0
[INFO] 2025-12-29 01:04:58 - npm installed: 10.9.0

[INFO] 2025-12-29 01:04:58 - Step 4: Installing Docker
[INFO] 2025-12-29 01:04:58 - Installing Docker prerequisites...
[INFO] 2025-12-29 01:05:12 - Adding Docker GPG key...
[INFO] 2025-12-29 01:05:15 - Adding Docker repository...
[INFO] 2025-12-29 01:05:18 - Installing Docker packages...
[INFO] 2025-12-29 01:08:45 - Starting Docker service...
[INFO] 2025-12-29 01:08:48 - Adding user ubuntu to docker group...
[SUCCESS] 2025-12-29 01:08:49 - Docker installed: 24.0.7
[INFO] 2025-12-29 01:08:49 - Docker Compose plugin installed: v2.24.0

[INFO] 2025-12-29 01:08:49 - Step 5: Verifying installations
[SUCCESS] 2025-12-29 01:08:50 - All tools verified

LINUS_RESULT:SUCCESS
LINUS_PYTHON_VERSION:3.12.0
LINUS_NODE_VERSION:v22.11.0
LINUS_DOCKER_VERSION:24.0.7
LINUS_DOCKER_USER:ubuntu
LINUS_TOOLS_INSTALLED:python=3.12.0,node=v22.11.0,docker=24.0.7
```

**Duration:** 4 minutes 50 seconds

**Agent Communicates to User:**
```
✅ Development Tools Installed!
- Python 3.12.0 (with pip and venv)
- Node.js v22.11.0 (with npm 10.9.0)
- Docker 24.0.7 (with Compose v2.24.0)
- User 'ubuntu' added to docker group

Moving to Step 4: Install Base Packages...
```

---

## Step 4: Install Base Packages

**Action:** Install build tools and utilities

**Agent Process:**
1. Read script:
   - `/home/sblanken/working/linusstr/shared/configure/base-packages.sh`

2. Upload to VM:
   ```bash
   scp base-packages.sh ubuntu@192.168.101.114:/tmp/
   ```

3. Execute:
   ```bash
   ssh ubuntu@192.168.101.114 "cd /tmp && sudo bash base-packages.sh"
   ```

**Output:**
```
[INFO] 2025-12-29 01:09:30 - Step 1: Validating environment
[SUCCESS] 2025-12-29 01:09:31 - Environment validation passed

[INFO] 2025-12-29 01:09:31 - Step 2: Installing build tools
[INFO] 2025-12-29 01:09:31 - Installing: build-essential make cmake gcc g++ gdb
[SUCCESS] 2025-12-29 01:09:58 - Build tools installed

[INFO] 2025-12-29 01:09:58 - Step 3: Installing SSL/crypto packages
[SUCCESS] 2025-12-29 01:10:05 - SSL packages installed

[INFO] 2025-12-29 01:10:05 - Step 4: Installing network tools
[SUCCESS] 2025-12-29 01:10:18 - Network tools installed

[INFO] 2025-12-29 01:10:18 - Step 5: Installing utility packages
[SUCCESS] 2025-12-29 01:10:28 - Utility packages installed

[INFO] 2025-12-29 01:10:28 - Step 6: Verifying installations
[SUCCESS] 2025-12-29 01:10:29 - All tools verified

LINUS_RESULT:SUCCESS
LINUS_BUILD_TOOLS:true
LINUS_NETWORK_TOOLS:true
LINUS_PACKAGE_COUNT:23
```

**Duration:** 59 seconds

**Agent Communicates to User:**
```
✅ Base Packages Installed!
- Build tools (gcc, g++, make, cmake, gdb)
- Network tools (nmap, dnsutils, netcat)
- Utilities (jq, unzip, rsync)

Moving to Step 5: Final Verification...
```

---

## Step 5: Final Verification

**Action:** Verify all installations and system health

**Agent Process:**
Execute verification commands via SSH:

```bash
# Python check
ssh ubuntu@192.168.101.114 "python3 --version"
# Output: Python 3.12.0

# Node.js check
ssh ubuntu@192.168.101.114 "node --version"
# Output: v22.11.0

# npm check
ssh ubuntu@192.168.101.114 "npm --version"
# Output: 10.9.0

# Docker check
ssh ubuntu@192.168.101.114 "docker --version"
# Output: Docker version 24.0.7, build 24.0.7-0ubuntu4

# Docker Compose check
ssh ubuntu@192.168.101.114 "docker compose version"
# Output: Docker Compose version v2.24.0

# GCC check
ssh ubuntu@192.168.101.114 "gcc --version | head -1"
# Output: gcc (Ubuntu 11.4.0-1ubuntu1~22.04) 11.4.0

# Docker service check
ssh ubuntu@192.168.101.114 "systemctl is-active docker"
# Output: active

# Disk space check
ssh ubuntu@192.168.101.114 "df -h / | tail -1"
# Output: /dev/sda1  39G  8.2G   29G  23% /

# Memory check
ssh ubuntu@192.168.101.114 "free -h | grep Mem"
# Output: Mem:  7.8Gi  1.2Gi  5.8Gi  45Mi  812Mi  6.3Gi
```

**All Checks:** ✅ PASSED

**Duration:** 15 seconds

---

## Final Response to User

```
╔═══════════════════════════════════════════════════════╗
║                                                       ║
║   ✅  FULL DEVELOPMENT ENVIRONMENT READY!  ✅        ║
║                                                       ║
╚═══════════════════════════════════════════════════════╝

VM Details:
-----------
- VM ID: 114
- IP Address: 192.168.101.114
- SSH Access: ssh ubuntu@192.168.101.114
- Resources: 4 CPU, 8 GB RAM, 40 GB Disk
- Provider: Proxmox (node: moxy)

Installed Software:
-------------------
✅ Operating System: Ubuntu 24.04 LTS
✅ Python: 3.12.0 (with pip, venv)
✅ Node.js: v22.11.0 (with npm 10.9.0)
✅ Docker: 24.0.7 (with Compose v2.24.0)
✅ Build Tools: GCC 11.4.0, Make, CMake, GDB
✅ Essential Tools: curl, wget, git, vim, tmux, htop
✅ Network Tools: nmap, dnsutils, netcat, traceroute
✅ Utilities: jq, unzip, rsync, tree

System Status:
--------------
- Docker Service: Running ✅
- Disk Usage: 23% (29 GB available)
- Memory: 7.8 GB total, 6.3 GB available
- All verification checks: PASSED ✅

Total Deployment Time:
----------------------
- Provision VM: 1m 48s
- Bootstrap Ubuntu: 1m 36s
- Install Dev Tools: 4m 50s
- Install Base Packages: 59s
- Final Verification: 15s
-------------------------
  TOTAL: 9m 28s

Next Steps:
-----------
You can now SSH into your VM and start developing:

  ssh ubuntu@192.168.101.114

Example commands to try:
  python3 --version
  node --version
  docker run hello-world
  git clone <your-repo>

The VM is fully configured and ready for development!
```

---

## Key Takeaways

1. **Automation Levels Used:**
   - Provision: Level 1 (non-interactive design)
   - Bootstrap: Level 1 (non-interactive design)
   - Dev Tools: Level 2 (smart wrappers with noninteractive.sh)
   - Base Packages: Level 1 (non-interactive design)

2. **Total Time:** ~10 minutes (within target)

3. **No Manual Intervention:** Fully automated from start to finish

4. **Structured Output:** All scripts output `LINUS_RESULT:SUCCESS` for parsing

5. **Error Handling:** Each step verified before proceeding to next

6. **Idempotent:** All scripts can be re-run safely if needed

7. **MCP Compatible:** All operations work through ssh-mcp (no TTY required)

---

## Troubleshooting This Workflow

### If Provisioning Fails
- Check Proxmox host is accessible
- Verify template VM 9000 exists
- Check storage pool has space

### If Bootstrap Hangs
- Increase MCP timeout to 180000ms (3 minutes)
- Check VM has internet access for apt downloads
- Verify SSH connectivity

### If Docker Install Fails
- Most common: Network timeout downloading packages
- Solution: Retry dev-tools.sh (idempotent)
- Check Docker repository is accessible

### If Verification Fails
- Wait 30s and retry (services may still be starting)
- Check systemctl status for failed services
- Review /var/log/syslog on VM for errors

---

## Variations

### Minimal Setup (Skip Docker)
```bash
INSTALL_DOCKER=false bash dev-tools.sh
```

### Skip Build Tools
```bash
INSTALL_BUILD_TOOLS=false bash base-packages.sh
```

### Custom Timezone
```bash
TIMEZONE=America/New_York bash ubuntu.sh
```

### Faster Bootstrap (Skip Upgrade)
```bash
SKIP_UPGRADE=true bash ubuntu.sh
```
