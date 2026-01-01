# Linus Deployment Specialist - Agent Usage Guide

> **This document is optimized for AI agent consumption. All instructions are explicit, verifiable, and executable without human intervention.**

---

## Document Purpose

This guide enables coding and QA agents to autonomously:
1. Install all prerequisites
2. Configure providers
3. Provision VMs
4. Bootstrap operating systems
5. Verify successful deployment

**Target Consumers:** AI coding agents (Claude Code, Gemini, Copilot, etc.) with tool execution capabilities

---

## Quick Navigation

- [Installation](#installation-autonomous-agent-workflow) - Complete setup from scratch
- [Provider Configuration](#provider-configuration) - Configure Proxmox, AWS, or QEMU
- [VM Provisioning](#vm-provisioning-workflows) - Create VMs with exact commands
- [Verification](#verification-procedures) - Confirm successful operations
- [Troubleshooting](#troubleshooting-decision-trees) - Error resolution

---

## Installation (Autonomous Agent Workflow)

### Prerequisites Check

**Execute these verification commands. Proceed only if ALL return success (exit code 0):**

```bash
# Check Node.js version (required: 24.12+)
node --version | grep -qE 'v2[4-9]|v[3-9][0-9]' && echo "✓ Node.js OK" || echo "✗ Node.js REQUIRED: Install Node.js 24.12+"

# Check Git
git --version && echo "✓ Git OK" || echo "✗ Git REQUIRED"

# Check Bash version (required: 4.0+)
bash --version | head -1 | grep -qE 'version [4-9]' && echo "✓ Bash OK" || echo "✗ Bash 4+ REQUIRED"

# Check SSH client
ssh -V 2>&1 && echo "✓ SSH OK" || echo "✗ SSH REQUIRED"
```

**Decision Point:**
- ALL checks passed → Continue to [Step 1](#step-1-clone-repository)
- ANY check failed → Install missing dependencies before proceeding

### Step 1: Clone Repository

```bash
# Execute exactly as shown
git clone https://github.com/yourusername/linusstr.git
cd linusstr

# Verify clone success
test -f shared/provision/proxmox.sh && echo "✓ Repository cloned successfully" || echo "✗ Clone failed"
```

### Step 2: Install MCP SSH Server

```bash
# Install ssh-mcp globally
npm install -g ssh-mcp

# Verify installation
ssh-mcp --version && echo "✓ ssh-mcp installed" || echo "✗ Installation failed"

# Alternative verification
npm list -g ssh-mcp | grep ssh-mcp && echo "✓ Verified in npm global" || echo "✗ Not found in global packages"
```

### Step 3: Install Provider-Specific Tools

**Choose based on intended provider(s):**

#### For Proxmox Provider:
```bash
# No additional tools required
# Proxmox uses SSH + pvesh (pre-installed on Proxmox host)
echo "✓ Proxmox: No local dependencies"
```

#### For AWS Provider:
```bash
# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo "Installing AWS CLI..."

    # Linux installation
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip awscliv2.zip
    sudo ./aws/install
    rm -rf aws awscliv2.zip
fi

# Verify AWS CLI
aws --version && echo "✓ AWS CLI installed" || echo "✗ AWS CLI installation failed"
```

#### For QEMU Provider:
```bash
# Install sshpass (required for password-based SSH)
if ! command -v sshpass &> /dev/null; then
    # Detect OS and install
    if command -v apt-get &> /dev/null; then
        sudo apt-get update && sudo apt-get install -y sshpass
    elif command -v yum &> /dev/null; then
        sudo yum install -y sshpass
    elif command -v brew &> /dev/null; then
        brew install sshpass
    fi
fi

# Verify sshpass
sshpass -V && echo "✓ sshpass installed" || echo "✗ sshpass installation failed"
```

### Step 4: Validate Script Permissions

```bash
# Make all scripts executable
chmod +x shared/provision/*.sh
chmod +x shared/bootstrap/*.sh
chmod +x shared/configure/*.sh
chmod +x shared/lib/*.sh

# Verify permissions
ls -l shared/provision/*.sh | grep -q 'x' && echo "✓ Scripts are executable" || echo "✗ Permission error"
```

### Step 5: Syntax Validation

```bash
# Validate all Bash scripts for syntax errors
for script in shared/provision/*.sh shared/bootstrap/*.sh shared/configure/*.sh shared/lib/*.sh; do
    bash -n "$script" || echo "✗ Syntax error in $script"
done

echo "✓ All scripts validated"
```

**Installation Complete** - Proceed to [Provider Configuration](#provider-configuration)

---

## Provider Configuration

### Configuration Decision Tree

```
START: Which provider will you use?
│
├─→ Proxmox VE → [Configure Proxmox](#proxmox-configuration)
├─→ AWS EC2 → [Configure AWS](#aws-configuration)
└─→ QEMU/libvirt → [Configure QEMU](#qemu-configuration)
```

### Proxmox Configuration

**Required Information:**
- Proxmox host IP address
- API user (typically `root@pam`)
- API token ID
- API token secret
- Node name (default: `pve`)
- Storage name (default: `local-lvm`)
- Cloud-init template ID (default: `9000`)

**Setup Procedure:**

```bash
# Set environment variables (replace with actual values)
export PROXMOX_HOST="192.168.101.155"
export PROXMOX_USER="root@pam"
export PROXMOX_TOKEN_ID="linus-token"
export PROXMOX_TOKEN_SECRET="your-actual-secret-here"
export PROXMOX_NODE="pve"
export PROXMOX_STORAGE="local-lvm"
export PROXMOX_TEMPLATE_ID="9000"

# Persist to shell profile (choose one)
cat >> ~/.bashrc << 'EOF'
export PROXMOX_HOST="192.168.101.155"
export PROXMOX_USER="root@pam"
export PROXMOX_TOKEN_ID="linus-token"
export PROXMOX_TOKEN_SECRET="your-actual-secret-here"
export PROXMOX_NODE="pve"
export PROXMOX_STORAGE="local-lvm"
export PROXMOX_TEMPLATE_ID="9000"
EOF

source ~/.bashrc
```

**Verification:**

```bash
# Test Proxmox API connectivity
curl -k -H "Authorization: PVEAPIToken=${PROXMOX_USER}!${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
  "https://${PROXMOX_HOST}:8006/api2/json/version" | grep -q "version" && \
  echo "✓ Proxmox API accessible" || echo "✗ Proxmox API connection failed"
```

### AWS Configuration

**Required Information:**
- AWS region (e.g., `us-west-2`)
- AWS access key ID
- AWS secret access key
- EC2 key pair name (must exist in the region)

**Setup Procedure:**

```bash
# Configure AWS CLI
aws configure set aws_access_key_id YOUR_ACCESS_KEY_ID
aws configure set aws_secret_access_key YOUR_SECRET_ACCESS_KEY
aws configure set region us-west-2
aws configure set output json

# Set Linus-specific environment variables
export AWS_REGION="us-west-2"
export AWS_KEY_NAME="your-keypair-name"

# Persist to shell profile
cat >> ~/.bashrc << 'EOF'
export AWS_REGION="us-west-2"
export AWS_KEY_NAME="your-keypair-name"
EOF

source ~/.bashrc
```

**Verification:**

```bash
# Test AWS connectivity
aws sts get-caller-identity && echo "✓ AWS credentials valid" || echo "✗ AWS authentication failed"

# Verify key pair exists
aws ec2 describe-key-pairs --key-names "${AWS_KEY_NAME}" --region "${AWS_REGION}" && \
  echo "✓ Key pair exists" || echo "✗ Key pair not found"
```

### QEMU Configuration

**Required Information:**
- QEMU host IP address
- SSH username on QEMU host
- Sudo password for SSH user
- Storage pool name (default: `default`)
- Network name (default: `default`)

**Setup Procedure:**

```bash
# Set environment variables
export QEMU_HOST="192.168.101.59"
export QEMU_USER="username"
export QEMU_SUDO_PASS="password"
export QEMU_POOL="default"
export QEMU_NETWORK="default"

# Persist to shell profile
cat >> ~/.bashrc << 'EOF'
export QEMU_HOST="192.168.101.59"
export QEMU_USER="username"
export QEMU_SUDO_PASS="password"
export QEMU_POOL="default"
export QEMU_NETWORK="default"
EOF

source ~/.bashrc
```

**Verification:**

```bash
# Test SSH connectivity to QEMU host
sshpass -p "${QEMU_SUDO_PASS}" ssh -o StrictHostKeyChecking=no "${QEMU_USER}@${QEMU_HOST}" "echo '${QEMU_SUDO_PASS}' | sudo -S virsh version" && \
  echo "✓ QEMU host accessible, libvirt operational" || echo "✗ QEMU connection failed"

# Verify SSH key exists on QEMU host (required for cloud-init)
sshpass -p "${QEMU_SUDO_PASS}" ssh -o StrictHostKeyChecking=no "${QEMU_USER}@${QEMU_HOST}" "test -f ~/.ssh/id_rsa.pub" && \
  echo "✓ SSH key exists on QEMU host" || echo "✗ Generate SSH key on QEMU host: ssh-keygen -t rsa -b 4096 -N ''"
```

---

## VM Provisioning Workflows

### Workflow Selection

```
DECISION: What operation do you need?
│
├─→ Create new VM → [Provision VM](#provision-new-vm)
├─→ Bootstrap existing VM → [Bootstrap OS](#bootstrap-operating-system)
└─→ Install dev tools → [Configure Development Environment](#configure-development-environment)
```

### Provision New VM

**Required Inputs:**
- Provider (proxmox|aws|qemu)
- VM Name (optional, auto-generated if omitted)
- CPU cores (integer, e.g., 2)
- RAM in MB (integer, e.g., 4096)
- Disk size in GB (integer, e.g., 20)

**Execution Templates:**

#### Proxmox Provisioning

```bash
# Minimal (uses defaults: 2 CPU, 2GB RAM, 20GB disk)
./shared/provision/proxmox.sh

# Custom specifications
VM_NAME="dev-server-001" \
VM_CPU=4 \
VM_RAM=8192 \
VM_DISK=50 \
  ./shared/provision/proxmox.sh

# Capture output
OUTPUT=$(./shared/provision/proxmox.sh 2>&1)

# Parse results
VM_IP=$(echo "$OUTPUT" | grep "LINUS_VM_IP:" | cut -d: -f2)
VM_USER=$(echo "$OUTPUT" | grep "LINUS_VM_USER:" | cut -d: -f2)

# Verify success
echo "$OUTPUT" | grep -q "LINUS_RESULT:SUCCESS" && \
  echo "✓ VM provisioned: ssh ${VM_USER}@${VM_IP}" || \
  echo "✗ Provisioning failed"
```

#### AWS Provisioning

```bash
# Minimal (auto-selects instance type based on CPU/RAM)
./shared/provision/aws.sh

# Custom specifications
VM_NAME="test-instance-001" \
VM_CPU=2 \
VM_RAM=4096 \
VM_DISK=30 \
  ./shared/provision/aws.sh

# With specific instance type
AWS_INSTANCE_TYPE="t3.medium" \
VM_NAME="prod-app-001" \
  ./shared/provision/aws.sh

# Capture and parse output
OUTPUT=$(./shared/provision/aws.sh 2>&1)
INSTANCE_ID=$(echo "$OUTPUT" | grep "LINUS_INSTANCE_ID:" | cut -d: -f2)
INSTANCE_IP=$(echo "$OUTPUT" | grep "LINUS_INSTANCE_IP:" | cut -d: -f2)

# Verify success
echo "$OUTPUT" | grep -q "LINUS_RESULT:SUCCESS" && \
  echo "✓ EC2 instance provisioned: $INSTANCE_ID ($INSTANCE_IP)" || \
  echo "✗ Provisioning failed"
```

#### QEMU Provisioning

```bash
# Minimal
./shared/provision/qemu.sh

# Custom specifications
VM_NAME="qemu-test-001" \
VM_CPU=2 \
VM_RAM=2048 \
VM_DISK=20 \
  ./shared/provision/qemu.sh

# Capture and parse output
OUTPUT=$(./shared/provision/qemu.sh 2>&1)
VM_IP=$(echo "$OUTPUT" | grep "LINUS_VM_IP:" | cut -d: -f2 | tr -d ' ')
VM_NAME=$(echo "$OUTPUT" | grep "LINUS_VM_NAME:" | cut -d: -f2 | tr -d ' ')

# Verify success
echo "$OUTPUT" | grep -q "LINUS_RESULT:SUCCESS" && \
  echo "✓ QEMU VM provisioned: $VM_NAME ($VM_IP)" || \
  echo "✗ Provisioning failed"

# Note: SSH access is via QEMU host
# ssh ${QEMU_USER}@${QEMU_HOST} "ssh ubuntu@${VM_IP} 'command'"
```

**Expected Timing:**
- Proxmox: 2-3 minutes
- AWS: 1-2 minutes
- QEMU: 6-7 minutes (cloud-init is slower)

### Bootstrap Operating System

**Purpose:** Install essential packages and configure base OS

**Prerequisites:**
- VM must be provisioned and SSH-accessible
- Know VM IP address and SSH user (typically `ubuntu`)

**Execution:**

```bash
# Direct execution on VM
ssh ubuntu@<VM_IP> << 'REMOTE_SCRIPT'
# Download and execute bootstrap
curl -fsSL https://raw.githubusercontent.com/yourusername/linusstr/master/shared/bootstrap/ubuntu.sh | bash

# Verify completion
test $? -eq 0 && echo "✓ Bootstrap complete" || echo "✗ Bootstrap failed"
REMOTE_SCRIPT

# Alternative: Copy script and execute
scp shared/bootstrap/ubuntu.sh ubuntu@<VM_IP>:/tmp/
ssh ubuntu@<VM_IP> "bash /tmp/ubuntu.sh"

# With custom options
ssh ubuntu@<VM_IP> << 'REMOTE_SCRIPT'
export TIMEZONE="America/New_York"
export INSTALL_EXTRAS="true"
curl -fsSL https://raw.githubusercontent.com/yourusername/linusstr/master/shared/bootstrap/ubuntu.sh | bash
REMOTE_SCRIPT
```

**Expected Duration:** ~2 minutes

**Verification:**

```bash
# Verify essential tools installed
ssh ubuntu@<VM_IP> "command -v git && command -v curl && command -v vim" && \
  echo "✓ Essential tools verified" || echo "✗ Bootstrap incomplete"
```

### Configure Development Environment

**Purpose:** Install Python, Node.js, Docker

**Prerequisites:**
- OS bootstrap completed
- VM has internet access

**Execution:**

```bash
# Install development tools
ssh ubuntu@<VM_IP> << 'REMOTE_SCRIPT'
curl -fsSL https://raw.githubusercontent.com/yourusername/linusstr/master/shared/configure/dev-tools.sh | bash

# Verify installation
python3 --version && node --version && docker --version && \
  echo "✓ Dev tools installed" || echo "✗ Installation failed"
REMOTE_SCRIPT
```

**Expected Duration:** ~5-7 minutes

**Verification:**

```bash
# Comprehensive verification
ssh ubuntu@<VM_IP> << 'REMOTE_SCRIPT'
python3 --version | grep -q "3.12" && echo "✓ Python 3.12"
node --version | grep -q "v22" && echo "✓ Node.js 22"
docker --version | grep -q "Docker" && echo "✓ Docker installed"
docker ps &>/dev/null && echo "✓ Docker service running"
REMOTE_SCRIPT
```

---

## Verification Procedures

### Post-Provisioning Verification Checklist

**Execute after VM provisioning:**

```bash
# 1. Check provisioning output for success marker
echo "$OUTPUT" | grep -q "LINUS_RESULT:SUCCESS" || exit 1

# 2. Extract VM details
VM_IP=$(echo "$OUTPUT" | grep "LINUS_VM_IP:" | cut -d: -f2 | tr -d ' ')
VM_USER=$(echo "$OUTPUT" | grep "LINUS_VM_USER:" | cut -d: -f2 | tr -d ' ')
VM_NAME=$(echo "$OUTPUT" | grep "LINUS_VM_NAME:" | cut -d: -f2 | tr -d ' ')

# 3. Verify VM details are non-empty
test -n "$VM_IP" && test -n "$VM_USER" || exit 1

# 4. Test SSH connectivity (provider-specific)
case "$PROVIDER" in
  proxmox|aws)
    ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "${VM_USER}@${VM_IP}" "echo SSH OK" && \
      echo "✓ SSH accessible" || echo "✗ SSH failed"
    ;;
  qemu)
    sshpass -p "${QEMU_SUDO_PASS}" ssh -o StrictHostKeyChecking=no "${QEMU_USER}@${QEMU_HOST}" \
      "ssh -o ConnectTimeout=10 ubuntu@${VM_IP} 'echo SSH OK'" && \
      echo "✓ SSH accessible via QEMU host" || echo "✗ SSH failed"
    ;;
esac

# 5. Verify OS version
ssh "${VM_USER}@${VM_IP}" "cat /etc/lsb-release" | grep -q "24.04" && \
  echo "✓ Ubuntu 24.04 confirmed" || echo "✗ OS verification failed"

# 6. Check system resources
ssh "${VM_USER}@${VM_IP}" << 'REMOTE_SCRIPT'
CPU_COUNT=$(nproc)
MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
echo "✓ Resources: ${CPU_COUNT} CPU, ${MEM_MB}MB RAM"
REMOTE_SCRIPT
```

---

## Troubleshooting Decision Trees

### Provisioning Failures

```
ERROR: Provisioning script exits with non-zero code
│
├─→ Check 1: Environment variables set?
│   ├─→ No: Review [Provider Configuration](#provider-configuration)
│   └─→ Yes: Continue to Check 2
│
├─→ Check 2: Provider credentials valid?
│   ├─→ No: Re-run verification steps for your provider
│   └─→ Yes: Continue to Check 3
│
├─→ Check 3: Examine script output
│   ├─→ Contains "LINUS_RESULT:SUCCESS": False positive, check SSH access
│   ├─→ Contains specific error: Search error message below
│   └─→ No clear error: Enable debug mode (set -x in script)
```

### Common Errors and Resolutions

#### Error: "SSH public key not found on QEMU host"

**Resolution:**
```bash
# Generate SSH key on QEMU host
sshpass -p "${QEMU_SUDO_PASS}" ssh "${QEMU_USER}@${QEMU_HOST}" \
  "ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ''"

# Verify key exists
sshpass -p "${QEMU_SUDO_PASS}" ssh "${QEMU_USER}@${QEMU_HOST}" \
  "cat ~/.ssh/id_rsa.pub"
```

#### Error: "AWS credentials not configured"

**Resolution:**
```bash
# Reconfigure AWS CLI
aws configure

# Or set via environment variables
export AWS_ACCESS_KEY_ID="your-key-id"
export AWS_SECRET_ACCESS_KEY="your-secret-key"
export AWS_DEFAULT_REGION="us-west-2"
```

#### Error: "Proxmox API connection failed"

**Resolution:**
```bash
# Test API manually
curl -k -H "Authorization: PVEAPIToken=${PROXMOX_USER}!${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
  "https://${PROXMOX_HOST}:8006/api2/json/version"

# If fails: Verify token is valid in Proxmox web UI
# Datacenter → Permissions → API Tokens
```

#### Error: "Timeout waiting for IP address"

**Cause:** VM networking not configured or DHCP slow

**Resolution:**
```bash
# For QEMU: Verify default network exists
sshpass -p "${QEMU_SUDO_PASS}" ssh "${QEMU_USER}@${QEMU_HOST}" \
  "echo '${QEMU_SUDO_PASS}' | sudo -S virsh net-list --all"

# If network doesn't exist, create it
sshpass -p "${QEMU_SUDO_PASS}" ssh "${QEMU_USER}@${QEMU_HOST}" \
  "echo '${QEMU_SUDO_PASS}' | sudo -S virsh net-start default"

# For Proxmox: Check VM is on correct network bridge
```

#### Error: "SSH timeout after 300s" (QEMU only)

**Cause:** Cloud-init taking longer than expected

**Resolution:**
```bash
# This is expected behavior for QEMU
# Wait additional 2-3 minutes and test SSH manually
sshpass -p "${QEMU_SUDO_PASS}" ssh "${QEMU_USER}@${QEMU_HOST}" \
  "ssh ubuntu@<VM_IP> 'echo SSH ready'"

# If still fails, check cloud-init logs via console
sshpass -p "${QEMU_SUDO_PASS}" ssh "${QEMU_USER}@${QEMU_HOST}" \
  "echo '${QEMU_SUDO_PASS}' | sudo -S virsh console <VM_NAME>"
# Press Ctrl+] to exit console
```

---

## Complete End-to-End Example

**Scenario:** Agent receives instruction: "Create a Ubuntu VM with Python and Docker"

**Autonomous Execution:**

```bash
#!/bin/bash
set -euo pipefail

# Step 1: Determine provider (assume Proxmox configured)
PROVIDER="proxmox"

# Step 2: Provision VM
echo "Provisioning VM..."
OUTPUT=$(VM_NAME="auto-dev-$(date +%s)" VM_CPU=2 VM_RAM=4096 VM_DISK=20 ./shared/provision/proxmox.sh 2>&1)

# Step 3: Verify provisioning
if ! echo "$OUTPUT" | grep -q "LINUS_RESULT:SUCCESS"; then
    echo "ERROR: Provisioning failed"
    echo "$OUTPUT"
    exit 1
fi

# Step 4: Extract VM details
VM_IP=$(echo "$OUTPUT" | grep "LINUS_VM_IP:" | cut -d: -f2 | tr -d ' ')
VM_USER=$(echo "$OUTPUT" | grep "LINUS_VM_USER:" | cut -d: -f2 | tr -d ' ')

echo "✓ VM provisioned: ${VM_USER}@${VM_IP}"

# Step 5: Wait for SSH (belt-and-suspenders)
sleep 10

# Step 6: Bootstrap OS
echo "Bootstrapping OS..."
ssh -o StrictHostKeyChecking=no "${VM_USER}@${VM_IP}" << 'REMOTE_SCRIPT'
curl -fsSL https://raw.githubusercontent.com/yourusername/linusstr/master/shared/bootstrap/ubuntu.sh | bash
REMOTE_SCRIPT

# Step 7: Install dev tools
echo "Installing development tools..."
ssh "${VM_USER}@${VM_IP}" << 'REMOTE_SCRIPT'
curl -fsSL https://raw.githubusercontent.com/yourusername/linusstr/master/shared/configure/dev-tools.sh | bash
REMOTE_SCRIPT

# Step 8: Verify installation
echo "Verifying installation..."
ssh "${VM_USER}@${VM_IP}" << 'REMOTE_SCRIPT'
python3 --version
docker --version
echo "✓ All tools installed successfully"
REMOTE_SCRIPT

# Step 9: Report results
echo "========================================="
echo "VM Ready for Use"
echo "========================================="
echo "SSH: ssh ${VM_USER}@${VM_IP}"
echo "Python: $(ssh ${VM_USER}@${VM_IP} 'python3 --version')"
echo "Docker: $(ssh ${VM_USER}@${VM_IP} 'docker --version')"
echo "========================================="
```

**Expected Output:**

```
Provisioning VM...
✓ VM provisioned: ubuntu@192.168.1.50
Bootstrapping OS...
Installing development tools...
Verifying installation...
Python 3.12.3
Docker version 29.1.3, build 4433759
✓ All tools installed successfully
=========================================
VM Ready for Use
=========================================
SSH: ssh ubuntu@192.168.1.50
Python: Python 3.12.3
Docker: Docker version 29.1.3, build 4433759
=========================================
```

---

## Agent Capabilities Summary

After successful installation and configuration, AI agents can autonomously:

✅ **Provision VMs** on Proxmox, AWS, or QEMU with custom specifications
✅ **Bootstrap Ubuntu 24.04** with essential packages in ~2 minutes
✅ **Install development tools** (Python 3.12, Node.js 22, Docker CE) in ~5-7 minutes
✅ **Verify successful deployment** through structured output parsing
✅ **Handle errors** using decision trees and troubleshooting procedures
✅ **Execute complete workflows** from provisioning to ready-for-use state

**No human intervention required** when:
- Provider credentials are pre-configured
- Network connectivity exists
- Required tools (Node.js, Git, SSH) are installed

---

## Additional Resources

- **Script Source Code:** All scripts in `shared/` directory with inline documentation
- **SKILL.md:** Claude Code-specific integration guide
- **conductor/:** Gemini Conductor context files
- **state.json:** Project progress and milestones

---

**Document Version:** 1.0.0
**Last Updated:** 2025-12-31
**Target Agents:** Claude Code, Gemini, GitHub Copilot, Cursor, Codeium, any coding agent with Bash execution capability
