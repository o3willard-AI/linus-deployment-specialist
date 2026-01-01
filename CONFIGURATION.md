# Linus Deployment Specialist - Configuration Guide for AI Agents

**Audience:** AI coding and QA agents performing autonomous configuration

**Purpose:** Explicit, verifiable configuration procedures for all supported providers

---

## Table of Contents

- [Environment Variables Reference](#environment-variables-reference)
- [Proxmox VE Configuration](#proxmox-ve-configuration)
- [AWS EC2 Configuration](#aws-ec2-configuration)
- [QEMU/libvirt Configuration](#qemulibvirt-configuration)
- [Verification Procedures](#verification-procedures)
- [Troubleshooting Configuration Issues](#troubleshooting-configuration-issues)

---

## Environment Variables Reference

### Common VM Specification Variables

All providers support these optional variables:

```bash
VM_NAME=linus-vm-001    # Instance name (default: linus-vm-<timestamp>)
VM_CPU=2                # CPU cores (default: 2)
VM_RAM=4096             # RAM in MB (default: 4096)
VM_DISK=20              # Disk size in GB (default: 20)
```

### Provider-Specific Variables

| Variable | Provider | Required | Default | Description |
|----------|----------|----------|---------|-------------|
| `PROXMOX_HOST` | Proxmox | ✅ Yes | - | Proxmox host IP/hostname |
| `PROXMOX_USER` | Proxmox | ✅ Yes | - | API user (e.g., root@pam) |
| `PROXMOX_TOKEN_ID` | Proxmox | ✅ Yes | - | API token ID |
| `PROXMOX_TOKEN_SECRET` | Proxmox | ✅ Yes | - | API token secret |
| `PROXMOX_NODE` | Proxmox | No | pve | Proxmox node name |
| `PROXMOX_STORAGE` | Proxmox | No | local-lvm | Storage name |
| `PROXMOX_TEMPLATE_ID` | Proxmox | No | 9000 | Cloud-init template VM ID |
| `AWS_REGION` | AWS | ✅ Yes | - | AWS region (e.g., us-west-2) |
| `AWS_KEY_NAME` | AWS | ✅ Yes | - | EC2 key pair name |
| `AWS_INSTANCE_TYPE` | AWS | No | auto | Instance type (auto-selected from CPU/RAM) |
| `AWS_AMI_ID` | AWS | No | auto | AMI ID (auto-detects Ubuntu 24.04) |
| `AWS_SUBNET_ID` | AWS | No | default VPC | VPC subnet ID |
| `AWS_SECURITY_GROUP` | AWS | No | linus-default-sg | Security group ID |
| `QEMU_HOST` | QEMU | ✅ Yes | - | QEMU host IP/hostname |
| `QEMU_USER` | QEMU | ✅ Yes | - | SSH username for QEMU host |
| `QEMU_SUDO_PASS` | QEMU | ✅ Yes | - | Sudo password for QEMU host |
| `QEMU_POOL` | QEMU | No | default | libvirt storage pool name |
| `QEMU_NETWORK` | QEMU | No | default | libvirt network name |

---

## Proxmox VE Configuration

### Prerequisites

**On Proxmox Host:**
- Proxmox VE 8.x installed and running
- Cloud-init template VM created (ID 9000 by default)
- API token created for authentication
- Network bridge configured (vmbr0 or similar)

**On Local Machine:**
- SSH access to Proxmox host (for verification)
- curl installed

### Step 1: Create API Token

**Execute on Proxmox host (via SSH or web UI):**

```bash
# Via SSH to Proxmox host
ssh root@<proxmox-host>

# Create API token
pveum user token add root@pam linus-token --privsep=0

# Output will show:
# ┌──────────────┬──────────────────────────────────────┐
# │ key          │ value                                │
# ╞══════════════╪══════════════════════════════════════╡
# │ full-tokenid │ root@pam!linus-token                 │
# ├──────────────┼──────────────────────────────────────┤
# │ info         │ {"privsep":"0"}                      │
# ├──────────────┼──────────────────────────────────────┤
# │ value        │ xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx │
# └──────────────┴──────────────────────────────────────┘

# SAVE the "value" field - this is PROXMOX_TOKEN_SECRET
```

**Expected Output:** UUID-format secret (e.g., `a1b2c3d4-e5f6-7890-abcd-ef1234567890`)

**Verification:**
```bash
# List tokens to confirm creation
pveum user token list root@pam

# Expected: Shows "linus-token" in the list
```

**Exit Code:** 0 = success, non-zero = failure

### Step 2: Create Cloud-Init Template (if not exists)

**Execute on Proxmox host:**

```bash
# Download Ubuntu 24.04 cloud image
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img \
  -O /var/lib/vz/template/iso/ubuntu-24.04-cloudimg-amd64.img

# Create VM 9000
qm create 9000 --name ubuntu-cloud-template --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0

# Import disk
qm importdisk 9000 /var/lib/vz/template/iso/ubuntu-24.04-cloudimg-amd64.img local-lvm

# Configure VM
qm set 9000 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-9000-disk-0
qm set 9000 --ide2 local-lvm:cloudinit
qm set 9000 --boot c --bootdisk scsi0
qm set 9000 --serial0 socket --vga serial0
qm set 9000 --agent enabled=1

# Convert to template
qm template 9000
```

**Verification:**
```bash
qm list | grep 9000

# Expected output (note "ubuntu-cloud-template"):
# 9000 ubuntu-cloud-template       0       2048       0.00               0
```

**Exit Code:** 0 = success

### Step 3: Set Environment Variables

```bash
export PROXMOX_HOST=192.168.101.155
export PROXMOX_USER=root@pam
export PROXMOX_TOKEN_ID=linus-token
export PROXMOX_TOKEN_SECRET=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
export PROXMOX_NODE=pve                    # Optional, default: pve
export PROXMOX_STORAGE=local-lvm           # Optional, default: local-lvm
export PROXMOX_TEMPLATE_ID=9000            # Optional, default: 9000
```

### Step 4: Verify Configuration

```bash
# Test API connectivity
curl -k -H "Authorization: PVEAPIToken=${PROXMOX_USER}!${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
  "https://${PROXMOX_HOST}:8006/api2/json/version"

# Expected output: JSON with Proxmox version information
# {"data":{"version":"8.x.x","release":"..."}}
```

**Exit Code:** 0 = success, non-zero = authentication failed

**Decision Point:**
- Exit code 0 AND JSON returned → Configuration complete, proceed to provisioning
- Exit code non-zero OR no JSON → Review credentials and retry

---

## AWS EC2 Configuration

### Prerequisites

**On Local Machine:**
- AWS CLI installed (version 2.x)
- jq installed (for JSON parsing)

**On AWS Account:**
- IAM user with EC2 permissions
- EC2 key pair created
- Default VPC available (or custom VPC configured)

### Step 1: Install AWS CLI

**For Linux:**
```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
```

**Verification:**
```bash
aws --version

# Expected: aws-cli/2.x.x Python/3.x.x ...
```

**Exit Code:** 0 = installed

### Step 2: Configure AWS Credentials

**Option A: Using aws configure (interactive)**
```bash
aws configure

# Enter when prompted:
# AWS Access Key ID: AKIA...
# AWS Secret Access Key: ...
# Default region name: us-west-2
# Default output format: json
```

**Option B: Manual configuration**
```bash
# Create credentials file
mkdir -p ~/.aws
cat > ~/.aws/credentials <<'EOF'
[default]
aws_access_key_id = AKIA...
aws_secret_access_key = ...
EOF

# Create config file
cat > ~/.aws/config <<'EOF'
[default]
region = us-west-2
output = json
EOF
```

**Verification:**
```bash
aws sts get-caller-identity

# Expected output:
# {
#     "UserId": "AIDA...",
#     "Account": "123456789012",
#     "Arn": "arn:aws:iam::123456789012:user/..."
# }
```

**Exit Code:** 0 = credentials valid, 254/255 = invalid credentials

### Step 3: Create EC2 Key Pair

```bash
# Create key pair
aws ec2 create-key-pair --key-name linus-key --query 'KeyMaterial' --output text > ~/.ssh/linus-key.pem

# Set permissions
chmod 400 ~/.ssh/linus-key.pem
```

**Verification:**
```bash
# List key pairs
aws ec2 describe-key-pairs --key-names linus-key

# Expected: JSON showing key pair details
```

**Exit Code:** 0 = key pair exists

### Step 4: Set Environment Variables

```bash
export AWS_REGION=us-west-2
export AWS_KEY_NAME=linus-key
export AWS_INSTANCE_TYPE=t3.medium         # Optional, auto-selected
export AWS_AMI_ID=ami-xxxxx                # Optional, auto-detects Ubuntu 24.04
export AWS_SUBNET_ID=subnet-xxxxx          # Optional, uses default VPC
export AWS_SECURITY_GROUP=sg-xxxxx         # Optional, creates linus-default-sg
```

### Step 5: Verify Configuration

```bash
# Test EC2 access
aws ec2 describe-instances --max-results 1

# Expected: JSON with instances list (may be empty)
```

**Exit Code:** 0 = configuration complete

**Decision Point:**
- Exit code 0 → Proceed to provisioning
- Exit code non-zero → Review credentials, check IAM permissions

---

## QEMU/libvirt Configuration

### Prerequisites

**On QEMU Host:**
- QEMU/KVM installed (libvirt 10.0+)
- virsh and virt-install commands available
- User has sudo privileges
- SSH key pair at ~/.ssh/id_rsa (for cloud-init)

**On Local Machine:**
- sshpass installed (for password-based SSH)
- SSH client

### Step 1: Verify QEMU Host Requirements

**Execute from local machine:**

```bash
# Test SSH access (using sshpass)
sshpass -p 'your-password' ssh -o StrictHostKeyChecking=no user@qemu-host 'echo SSH OK'

# Expected output: SSH OK
```

**Exit Code:** 0 = SSH access working

**Execute on QEMU host:**

```bash
# SSH to QEMU host
ssh user@qemu-host

# Check libvirt version
virsh version

# Expected output:
# Compiled against library: libvirt 10.0.0
# Using library: libvirt 10.0.0
# ...
```

**Verification:**
```bash
# Check libvirt is running
sudo systemctl status libvirtd

# Expected: active (running)
```

**Exit Code:** 0 = libvirt running

### Step 2: Setup SSH Key on QEMU Host

**Execute on QEMU host:**

```bash
# Generate SSH key if not exists
if [ ! -f ~/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa
fi

# Verify key exists
ls -la ~/.ssh/id_rsa*

# Expected:
# -rw------- 1 user user 3389 ... /home/user/.ssh/id_rsa
# -rw-r--r-- 1 user user  738 ... /home/user/.ssh/id_rsa.pub
```

**Exit Code:** 0 = SSH key exists

### Step 3: Setup libvirt Networks and Pools

**Execute on QEMU host:**

```bash
# Check default network exists
sudo virsh net-list --all

# If "default" network doesn't exist, create it:
sudo virsh net-define /usr/share/libvirt/networks/default.xml
sudo virsh net-start default
sudo virsh net-autostart default

# Check default storage pool exists
sudo virsh pool-list --all

# If "default" pool doesn't exist, create it:
sudo virsh pool-define-as default dir --target /var/lib/libvirt/images
sudo virsh pool-build default
sudo virsh pool-start default
sudo virsh pool-autostart default
```

**Verification:**
```bash
# Verify network is active
sudo virsh net-list

# Expected:
# Name      State    Autostart   Persistent
# --------------------------------------------
# default   active   yes         yes

# Verify pool is active
sudo virsh pool-list

# Expected:
# Name      State    Autostart
# -------------------------------
# default   active   yes
```

**Exit Code:** 0 = setup complete

### Step 4: Install Required Tools

**Execute on QEMU host:**

```bash
# Ubuntu/Debian
sudo apt-get update
sudo apt-get install -y genisoimage

# Verify installation
which genisoimage

# Expected: /usr/bin/genisoimage
```

**Exit Code:** 0 = tools installed

### Step 5: Set Environment Variables

**Execute on local machine:**

```bash
export QEMU_HOST=192.168.101.59
export QEMU_USER=sblanken
export QEMU_SUDO_PASS=your-password
export QEMU_POOL=default                   # Optional, default: default
export QEMU_NETWORK=default                # Optional, default: default
```

### Step 6: Verify Configuration

**Execute from local machine:**

```bash
# Test complete workflow
sshpass -p "$QEMU_SUDO_PASS" ssh -o StrictHostKeyChecking=no \
  ${QEMU_USER}@${QEMU_HOST} \
  'echo yes | sudo -S virsh pool-list'

# Expected: List of storage pools including "default"
```

**Exit Code:** 0 = configuration complete

**Decision Point:**
- Exit code 0 → Proceed to provisioning
- Exit code non-zero → Review SSH access, sudo password, or libvirt setup

---

## Verification Procedures

### Complete Configuration Verification Script

```bash
#!/bin/bash
# verify-config.sh - Verify provider configuration

set -euo pipefail

echo "========================================="
echo "Linus Configuration Verification"
echo "========================================="

# Function: Check environment variable
check_var() {
    local var_name=$1
    local required=$2

    if [ -z "${!var_name:-}" ]; then
        if [ "$required" = "true" ]; then
            echo "✗ $var_name not set (REQUIRED)"
            return 1
        else
            echo "⊘ $var_name not set (optional)"
            return 0
        fi
    else
        echo "✓ $var_name set"
        return 0
    fi
}

# Detect provider based on environment variables
PROVIDER=""
if [ -n "${PROXMOX_HOST:-}" ]; then
    PROVIDER="proxmox"
elif [ -n "${AWS_REGION:-}" ]; then
    PROVIDER="aws"
elif [ -n "${QEMU_HOST:-}" ]; then
    PROVIDER="qemu"
else
    echo "✗ No provider configured (set PROXMOX_HOST, AWS_REGION, or QEMU_HOST)"
    exit 1
fi

echo "Detected provider: $PROVIDER"
echo "-----------------------------------------"

# Provider-specific verification
if [ "$PROVIDER" = "proxmox" ]; then
    check_var PROXMOX_HOST true || exit 1
    check_var PROXMOX_USER true || exit 1
    check_var PROXMOX_TOKEN_ID true || exit 1
    check_var PROXMOX_TOKEN_SECRET true || exit 1
    check_var PROXMOX_NODE false
    check_var PROXMOX_STORAGE false

    # Test API connectivity
    echo "-----------------------------------------"
    echo "Testing Proxmox API connectivity..."
    if curl -k -s -f -H "Authorization: PVEAPIToken=${PROXMOX_USER}!${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
        "https://${PROXMOX_HOST}:8006/api2/json/version" > /dev/null; then
        echo "✓ Proxmox API connection successful"
    else
        echo "✗ Proxmox API connection failed"
        exit 1
    fi

elif [ "$PROVIDER" = "aws" ]; then
    check_var AWS_REGION true || exit 1
    check_var AWS_KEY_NAME true || exit 1
    check_var AWS_INSTANCE_TYPE false
    check_var AWS_AMI_ID false

    # Test AWS credentials
    echo "-----------------------------------------"
    echo "Testing AWS credentials..."
    if aws sts get-caller-identity > /dev/null 2>&1; then
        echo "✓ AWS credentials valid"
    else
        echo "✗ AWS credentials invalid or not configured"
        exit 1
    fi

    # Check key pair exists
    echo "Checking EC2 key pair..."
    if aws ec2 describe-key-pairs --key-names "$AWS_KEY_NAME" > /dev/null 2>&1; then
        echo "✓ EC2 key pair '$AWS_KEY_NAME' exists"
    else
        echo "✗ EC2 key pair '$AWS_KEY_NAME' not found"
        exit 1
    fi

elif [ "$PROVIDER" = "qemu" ]; then
    check_var QEMU_HOST true || exit 1
    check_var QEMU_USER true || exit 1
    check_var QEMU_SUDO_PASS true || exit 1
    check_var QEMU_POOL false
    check_var QEMU_NETWORK false

    # Test SSH access
    echo "-----------------------------------------"
    echo "Testing QEMU host SSH access..."
    if command -v sshpass > /dev/null; then
        if sshpass -p "$QEMU_SUDO_PASS" ssh -o StrictHostKeyChecking=no \
            ${QEMU_USER}@${QEMU_HOST} 'echo SSH OK' 2>/dev/null | grep -q "SSH OK"; then
            echo "✓ SSH access to QEMU host successful"
        else
            echo "✗ SSH access to QEMU host failed"
            exit 1
        fi
    else
        echo "✗ sshpass not installed (required for QEMU provider)"
        exit 1
    fi

    # Test libvirt access
    echo "Testing libvirt access..."
    if sshpass -p "$QEMU_SUDO_PASS" ssh -o StrictHostKeyChecking=no \
        ${QEMU_USER}@${QEMU_HOST} 'echo yes | sudo -S virsh version' 2>/dev/null | grep -q "libvirt"; then
        echo "✓ libvirt access successful"
    else
        echo "✗ libvirt access failed"
        exit 1
    fi
fi

echo "========================================="
echo "✓ ALL CONFIGURATION CHECKS PASSED"
echo "========================================="
echo "Provider '$PROVIDER' is ready for provisioning"
exit 0
```

**Usage:**
```bash
# Make executable
chmod +x verify-config.sh

# Run verification
./verify-config.sh

# Exit code: 0 = all checks passed, 1 = configuration incomplete
```

---

## Troubleshooting Configuration Issues

### Common Issues Decision Tree

```
ISSUE: Configuration verification fails
│
├─→ Provider: Proxmox
│   │
│   ├─→ ERROR: "API connection failed"
│   │   ├─→ Check 1: Can you ping PROXMOX_HOST?
│   │   │   └─→ No: Network connectivity issue, verify IP address
│   │   ├─→ Check 2: Is Proxmox web UI accessible on port 8006?
│   │   │   └─→ No: Proxmox service not running, check host
│   │   ├─→ Check 3: Is PROXMOX_TOKEN_SECRET correct?
│   │   │   └─→ Verify: Re-create API token, update secret
│   │   └─→ Check 4: Does API user have correct permissions?
│   │       └─→ Fix: pveum user modify <user> --append Administrator
│   │
│   └─→ ERROR: "Template not found"
│       └─→ Fix: Create cloud-init template (see Step 2 above)
│
├─→ Provider: AWS
│   │
│   ├─→ ERROR: "AWS credentials invalid"
│   │   ├─→ Check 1: Run 'aws configure list'
│   │   │   └─→ Shows 'not set': Run 'aws configure'
│   │   ├─→ Check 2: Are credentials in ~/.aws/credentials?
│   │   │   └─→ No: Create credentials file (see Step 2)
│   │   └─→ Check 3: Test with 'aws sts get-caller-identity'
│   │       └─→ Error: Credentials expired or invalid, regenerate
│   │
│   └─→ ERROR: "Key pair not found"
│       └─→ Fix: aws ec2 create-key-pair --key-name linus-key
│
└─→ Provider: QEMU
    │
    ├─→ ERROR: "SSH access failed"
    │   ├─→ Check 1: Is sshpass installed?
    │   │   └─→ No: sudo apt-get install -y sshpass
    │   ├─→ Check 2: Can you SSH manually?
    │   │   └─→ Test: ssh user@host
    │   └─→ Check 3: Is password correct?
    │       └─→ Verify: QEMU_SUDO_PASS environment variable
    │
    ├─→ ERROR: "libvirt access failed"
    │   ├─→ Check 1: Is libvirtd running?
    │   │   └─→ Test: sudo systemctl status libvirtd
    │   └─→ Check 2: Does user have libvirt permissions?
    │       └─→ Fix: sudo usermod -a -G libvirt $USER
    │
    └─→ ERROR: "SSH key not found on QEMU host"
        └─→ Fix: ssh user@host 'ssh-keygen -t rsa -b 4096 -N ""'
```

### Error Messages Reference

| Error Message | Provider | Cause | Resolution |
|---------------|----------|-------|------------|
| `curl: (7) Failed to connect` | Proxmox | Network unreachable | Verify PROXMOX_HOST is correct, check firewall |
| `401 Unauthorized` | Proxmox | Invalid credentials | Re-create API token, verify TOKEN_SECRET |
| `Unable to locate credentials` | AWS | AWS CLI not configured | Run `aws configure` with access keys |
| `InvalidKeyPair.NotFound` | AWS | Key pair doesn't exist | Create key pair: `aws ec2 create-key-pair` |
| `Permission denied (publickey)` | QEMU | SSH key issue | Generate key on QEMU host: `ssh-keygen` |
| `Failed to connect socket` | QEMU | libvirtd not running | Start service: `sudo systemctl start libvirtd` |
| `command not found: virsh` | QEMU | libvirt not installed | Install: `sudo apt-get install libvirt-clients` |

---

## Security Considerations

### Important Notes for Agents

**These are ephemeral development/QA environments. Security is intentionally simplified:**

1. **Credentials Storage:** Environment variables are used for simplicity. In production, use secret management systems.

2. **Network Access:** VMs may have permissive security groups/firewalls for development purposes.

3. **SSH Keys:** Keys are not rotated automatically. For long-term use, implement key rotation.

4. **API Tokens:** Proxmox tokens have full privileges. For production, create limited-privilege tokens.

5. **Sudo Access:** QEMU provider requires sudo password in environment variable. This is acceptable for trusted environments only.

**When to Implement Additional Security:**
- Production environments
- Multi-tenant systems
- Long-running infrastructure
- Compliance requirements (PCI-DSS, HIPAA, etc.)

**Not Implemented (by design):**
- Credential encryption at rest
- Automatic credential rotation
- Network segmentation
- Audit logging
- Multi-factor authentication

---

## Next Steps

After completing configuration for your provider:

1. **Run verification script** (above) to confirm all settings
2. **Proceed to AGENT-GUIDE.md** for VM provisioning workflows
3. **Test with minimal VM** (VM_CPU=1, VM_RAM=1024) first
4. **Scale up** to production specifications after successful test

**Exit Codes Summary:**
- 0 = Configuration complete and verified
- 1 = Configuration incomplete or invalid
- Non-zero from verification commands = Specific component failure

**Structured Output Verification:**
All provisioning scripts will output:
```
LINUS_RESULT:SUCCESS|FAILURE
LINUS_VM_NAME:<name>
LINUS_VM_IP:<ip>
LINUS_VM_USER:<user>
```

Parse this output to determine provisioning success and extract connection details.
