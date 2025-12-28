# Proxmox Provisioning - Detailed Implementation Plan

**Version:** 1.0
**Created:** 2025-12-28
**Status:** Planning Phase
**Target:** Create reliable, testable Proxmox VM provisioning

---

## Executive Summary

This plan breaks down Proxmox VM provisioning into **testable micro-steps**, each with clear inputs, outputs, and verification criteria. The implementation prioritizes **reliability and consistency** over speed.

### Success Criteria

1. ✅ Script creates VMs on Proxmox reliably (>95% success rate)
2. ✅ All steps are verifiable and idempotent
3. ✅ Clear error messages with remediation steps
4. ✅ Works identically when called by Claude or Gemini
5. ✅ Full unit test coverage for each component

### Key Constraints

- **MCP Limitations:** Only `exec` and `sudo-exec` tools available
- **No File Upload:** Must transfer scripts via base64 encoding
- **No Session State:** Each MCP exec is independent
- **Proxmox Only:** Focus on single provider initially

---

## Prerequisites Checklist

### Required Information from User

- [ ] **Proxmox Host Details**
  - Hostname or IP address
  - SSH port (default: 22)
  - SSH user (typically: root)
  - SSH key path or password

- [ ] **Proxmox API Details**
  - API token ID (or will use user/password)
  - API token secret
  - Node name (e.g., "pve", "proxmox01")

- [ ] **Network Configuration**
  - Bridge name (e.g., "vmbr0")
  - VLAN tag (if any)
  - DHCP or static IP?
  - Gateway IP
  - DNS servers

- [ ] **VM Defaults**
  - Starting VM ID (e.g., 100)
  - Default storage pool (e.g., "local-lvm")
  - Default VM template/ISO location

### Required Tools on Proxmox Host

- [ ] `pvesh` - Proxmox VE API shell
- [ ] `qm` - QEMU/KVM VM manager
- [ ] `curl` - For API calls
- [ ] `jq` - For JSON parsing (will install if missing)

---

## Architecture Overview

### Component Breakdown

```
┌─────────────────────────────────────────────────────────────┐
│  USER REQUEST                                                │
│  "Create Ubuntu 24.04 VM: 4 CPU, 8GB RAM, 50GB disk"       │
└────────────────┬────────────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────────────┐
│  CLAUDE/GEMINI (via MCP)                                    │
│  - Validates parameters                                      │
│  - Calls provision-proxmox.sh                               │
└────────────────┬────────────────────────────────────────────┘
                 │
                 ▼ MCP exec tool (base64 upload)
┌─────────────────────────────────────────────────────────────┐
│  PROXMOX HOST                                               │
│  /tmp/linus-provision-proxmox.sh                            │
└────────────────┬────────────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────────────┐
│  SCRIPT EXECUTION FLOW                                      │
│  1. Validate environment                                     │
│  2. Check Proxmox node status                               │
│  3. Allocate VM ID                                          │
│  4. Create VM configuration                                 │
│  5. Download/attach OS image                                │
│  6. Start VM                                                │
│  7. Wait for network (get IP via DHCP or cloud-init)       │
│  8. Verify SSH accessibility                                │
│  9. Output LINUS_RESULT:SUCCESS with VM details             │
└────────────────┬────────────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────────────┐
│  OUTPUT                                                      │
│  LINUS_RESULT:SUCCESS                                       │
│  LINUS_VM_ID:100                                            │
│  LINUS_VM_IP:192.168.1.50                                   │
│  LINUS_VM_USER:ubuntu                                       │
└─────────────────────────────────────────────────────────────┘
```

---

## Implementation Phases

### Phase 1: MCP Configuration & Connection Testing

**Objective:** Establish and verify MCP connection to Proxmox host

#### Step 1.1: Create MCP Configuration File

**File:** `mcp-config/proxmox-mcp-config.json`

**Inputs:**
- Proxmox hostname/IP
- SSH user
- SSH key path or password
- Port (default: 22)

**Actions:**
1. Use `generate_mcp_config_claude()` from mcp-helpers.sh
2. Create config file with Proxmox connection details
3. Set timeout to 120000ms (2 minutes for long operations)
4. Set maxChars to "none" (scripts can be long)

**Output:**
```json
{
  "mcpServers": {
    "proxmox": {
      "command": "ssh-mcp",
      "args": [
        "--host=PROXMOX_HOST",
        "--port=22",
        "--user=root",
        "--key=/path/to/key",
        "--timeout=120000",
        "--maxChars=none"
      ]
    }
  }
}
```

**Verification:**
```bash
# Validate JSON syntax
python3 -c "import json; json.load(open('mcp-config/proxmox-mcp-config.json'))"
echo "Exit code: $?"  # Must be 0
```

**Success Criteria:** Valid JSON file created

---

#### Step 1.2: Test MCP Connection

**Objective:** Verify we can execute commands on Proxmox via MCP

**Test Commands:**
1. `hostname` - Should return Proxmox hostname
2. `pveversion` - Should return Proxmox version
3. `qm list` - Should list existing VMs (or empty)

**How to Test:**
- If using Claude Code: Configure MCP and test via Claude
- If testing manually: Use `ssh-mcp` CLI directly

**Expected Output:**
```
# Command 1: hostname
proxmox01

# Command 2: pveversion
pve-manager/8.1.3/...

# Command 3: qm list
VMID  NAME   STATUS     MEM(MB)    BOOTDISK(GB)
```

**Verification:**
- All 3 commands return successfully
- No connection errors
- No timeout errors

**Success Criteria:** Can execute basic commands on Proxmox host

---

#### Step 1.3: Install Dependencies on Proxmox

**Objective:** Ensure required tools are available

**Dependencies:**
- `jq` - JSON parsing
- `curl` - HTTP requests (usually pre-installed)
- `cloud-init` - For cloud-init images (if using)

**Actions:**
```bash
# Via MCP exec tool
apt update && apt install -y jq cloud-init
```

**Verification:**
```bash
command -v jq && echo "jq: OK" || echo "jq: MISSING"
command -v curl && echo "curl: OK" || echo "curl: MISSING"
```

**Success Criteria:** All dependencies installed and available

---

### Phase 2: Script Development & Testing

#### Step 2.1: Create Script Skeleton

**File:** `shared/provision/proxmox.sh`

**Template Structure:**
```bash
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Source libraries
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../lib/logging.sh"
source "${SCRIPT_DIR}/../lib/validation.sh"

# Configuration from environment
readonly VM_NAME="${VM_NAME:-}"
readonly VM_CPU="${VM_CPU:-2}"
readonly VM_RAM="${VM_RAM:-2048}"
readonly VM_DISK="${VM_DISK:-20}"
readonly VM_OS="${VM_OS:-ubuntu}"
readonly PROXMOX_NODE="${PROXMOX_NODE:-pve}"
readonly PROXMOX_STORAGE="${PROXMOX_STORAGE:-local-lvm}"
readonly PROXMOX_BRIDGE="${PROXMOX_BRIDGE:-vmbr0}"

# Main function sections
main() {
    log_header "Linus Proxmox VM Provisioning"

    validate_environment
    allocate_vm_id
    download_os_image
    create_vm
    configure_vm
    start_vm
    wait_for_network
    verify_ssh_ready
    output_result

    log_success "VM provisioned successfully"
}

main "$@"
```

**Success Criteria:** Script has proper structure, sources libraries, uses strict mode

---

#### Step 2.2: Implement Environment Validation

**Function:** `validate_environment()`

**Validations:**
1. Check Proxmox node is online: `pvesh get /nodes/${PROXMOX_NODE}/status`
2. Check storage exists: `pvesh get /storage/${PROXMOX_STORAGE}`
3. Check network bridge exists: `ip link show ${PROXMOX_BRIDGE}`
4. Validate VM parameters using validation.sh functions

**Implementation:**
```bash
validate_environment() {
    log_step "1" "Validating environment"

    # Check required tools
    check_dependencies pvesh qm curl jq || exit 2

    # Check required env vars
    check_env_vars PROXMOX_NODE PROXMOX_STORAGE PROXMOX_BRIDGE || exit 3

    # Validate VM spec
    validate_vm_spec "proxmox" "$VM_OS" "$VM_CPU" "$VM_RAM" "$VM_DISK" || exit 1

    # Check Proxmox node status
    local node_status=$(pvesh get /nodes/${PROXMOX_NODE}/status --output-format json | jq -r '.status')
    if [[ "$node_status" != "online" ]]; then
        log_error "Proxmox node ${PROXMOX_NODE} is not online (status: ${node_status})"
        exit 4
    fi

    log_success "Environment validation passed"
}
```

**Unit Test:**
```bash
# Test with valid environment
export PROXMOX_NODE="pve"
export PROXMOX_STORAGE="local-lvm"
export PROXMOX_BRIDGE="vmbr0"
export VM_OS="ubuntu"
export VM_CPU="2"
export VM_RAM="2048"
export VM_DISK="20"

source shared/provision/proxmox.sh
validate_environment
echo "Test result: $?"  # Should be 0
```

**Success Criteria:**
- Returns 0 for valid environment
- Returns non-zero with clear error for invalid environment
- Logs all validation steps

---

#### Step 2.3: Implement VM ID Allocation

**Function:** `allocate_vm_id()`

**Strategy:** Find next available VM ID starting from 100

**Implementation:**
```bash
allocate_vm_id() {
    log_step "2" "Allocating VM ID"

    # Start from VM ID 100 (Proxmox convention)
    local vm_id=100

    # Find next available ID
    while qm status "$vm_id" &>/dev/null; do
        ((vm_id++))
        if [[ $vm_id -gt 999 ]]; then
            log_error "No available VM IDs (checked 100-999)"
            exit 5
        fi
    done

    # Export for other functions
    export ALLOCATED_VM_ID="$vm_id"

    log_success "Allocated VM ID: $vm_id"
}
```

**Unit Test:**
```bash
# Mock qm command for testing
qm() {
    if [[ "$1" == "status" && "$2" -lt 105 ]]; then
        return 0  # VMs 100-104 exist
    else
        return 1  # VM doesn't exist
    fi
}

allocate_vm_id
echo "Allocated ID: $ALLOCATED_VM_ID"  # Should be 105
```

**Success Criteria:**
- Finds next available ID
- Exports ALLOCATED_VM_ID variable
- Fails gracefully if no IDs available

---

#### Step 2.4: Implement OS Image Download

**Function:** `download_os_image()`

**Strategy:** Use cloud-init images for each OS

**Ubuntu 24.04 Cloud Image:**
- URL: `https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img`
- Download to: `/var/lib/vz/template/iso/`
- Verify checksum

**Implementation:**
```bash
download_os_image() {
    log_step "3" "Downloading OS image"

    local image_dir="/var/lib/vz/template/iso"
    local image_name=""
    local image_url=""

    case "$VM_OS" in
        ubuntu)
            image_name="ubuntu-24.04-cloudimg-amd64.img"
            image_url="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
            ;;
        *)
            log_error "Unsupported OS: $VM_OS"
            exit 1
            ;;
    esac

    local image_path="${image_dir}/${image_name}"

    # Check if already downloaded
    if [[ -f "$image_path" ]]; then
        log_info "Image already exists: $image_path"
        export OS_IMAGE_PATH="$image_path"
        return 0
    fi

    # Download image
    log_info "Downloading $image_url..."
    curl -L -o "$image_path" "$image_url" || {
        log_error "Failed to download image"
        exit 1
    }

    export OS_IMAGE_PATH="$image_path"
    log_success "Image downloaded: $image_path"
}
```

**Unit Test:**
```bash
# Test with existing image (idempotency)
touch /var/lib/vz/template/iso/ubuntu-24.04-cloudimg-amd64.img
VM_OS="ubuntu"
download_os_image
echo "Image path: $OS_IMAGE_PATH"
```

**Success Criteria:**
- Downloads image if not present
- Skips download if already present (idempotent)
- Exports OS_IMAGE_PATH variable

---

#### Step 2.5: Implement VM Creation

**Function:** `create_vm()`

**Strategy:** Use `qm create` with appropriate settings

**Implementation:**
```bash
create_vm() {
    log_step "4" "Creating VM"

    local vm_id="$ALLOCATED_VM_ID"
    local vm_name="${VM_NAME:-linus-vm-${vm_id}}"

    # Create VM with basic config
    qm create "$vm_id" \
        --name "$vm_name" \
        --memory "$VM_RAM" \
        --cores "$VM_CPU" \
        --net0 "virtio,bridge=${PROXMOX_BRIDGE}" \
        --serial0 socket \
        --vga serial0 \
        --agent enabled=1 || {
        log_error "Failed to create VM"
        exit 5
    }

    # Import cloud image as disk
    qm importdisk "$vm_id" "$OS_IMAGE_PATH" "$PROXMOX_STORAGE" || {
        log_error "Failed to import disk"
        qm destroy "$vm_id"
        exit 5
    }

    # Attach disk to VM
    qm set "$vm_id" \
        --scsihw virtio-scsi-pci \
        --scsi0 "${PROXMOX_STORAGE}:vm-${vm_id}-disk-0" || {
        log_error "Failed to attach disk"
        qm destroy "$vm_id"
        exit 5
    }

    # Set boot order
    qm set "$vm_id" --boot order=scsi0 || {
        log_error "Failed to set boot order"
        qm destroy "$vm_id"
        exit 5
    }

    # Resize disk to requested size
    qm resize "$vm_id" scsi0 "${VM_DISK}G" || {
        log_error "Failed to resize disk"
        qm destroy "$vm_id"
        exit 5
    }

    log_success "VM created: ID=$vm_id, Name=$vm_name"
}
```

**Unit Test:**
```bash
# Dry-run test (check command syntax)
bash -n shared/provision/proxmox.sh
echo "Syntax check: $?"
```

**Success Criteria:**
- VM created with correct specs
- Disk imported and attached
- Boot order configured
- Rollback (destroy VM) on any failure

---

#### Step 2.6: Implement Cloud-Init Configuration

**Function:** `configure_vm()`

**Strategy:** Configure cloud-init for SSH access and networking

**Implementation:**
```bash
configure_vm() {
    log_step "5" "Configuring cloud-init"

    local vm_id="$ALLOCATED_VM_ID"

    # Add cloud-init drive
    qm set "$vm_id" --ide2 "${PROXMOX_STORAGE}:cloudinit" || {
        log_error "Failed to add cloud-init drive"
        exit 5
    }

    # Configure cloud-init
    qm set "$vm_id" \
        --ciuser "ubuntu" \
        --cipassword "$(openssl rand -base64 12)" \
        --ipconfig0 "ip=dhcp" \
        --nameserver "8.8.8.8" || {
        log_error "Failed to configure cloud-init"
        exit 5
    }

    # Add SSH key if available
    if [[ -n "${SSH_PUBLIC_KEY:-}" ]]; then
        qm set "$vm_id" --sshkeys "$SSH_PUBLIC_KEY"
    elif [[ -f ~/.ssh/id_rsa.pub ]]; then
        qm set "$vm_id" --sshkeys "$(cat ~/.ssh/id_rsa.pub)"
    fi

    log_success "Cloud-init configured"
}
```

**Success Criteria:**
- Cloud-init drive added
- Default user configured
- Network set to DHCP
- SSH keys added

---

#### Step 2.7: Implement VM Start & Network Wait

**Function:** `start_vm()` and `wait_for_network()`

**Implementation:**
```bash
start_vm() {
    log_step "6" "Starting VM"

    local vm_id="$ALLOCATED_VM_ID"

    qm start "$vm_id" || {
        log_error "Failed to start VM"
        exit 5
    }

    log_success "VM started"
}

wait_for_network() {
    log_step "7" "Waiting for network configuration"

    local vm_id="$ALLOCATED_VM_ID"
    local max_wait=120  # 2 minutes
    local elapsed=0
    local vm_ip=""

    while [[ $elapsed -lt $max_wait ]]; do
        # Try to get IP from QEMU agent
        vm_ip=$(qm agent "$vm_id" network-get-interfaces 2>/dev/null | \
                jq -r '.[] | select(.name == "eth0" or .name == "ens18") | .["ip-addresses"][]? | select(.["ip-address-type"] == "ipv4") | .["ip-address"]' | \
                grep -v "127.0.0.1" | head -1)

        if [[ -n "$vm_ip" ]]; then
            export VM_IP="$vm_ip"
            log_success "VM IP obtained: $vm_ip"
            return 0
        fi

        sleep 5
        ((elapsed+=5))
        log_info "Waiting for network... (${elapsed}s/${max_wait}s)"
    done

    log_error "Timeout waiting for network configuration"
    exit 6
}
```

**Success Criteria:**
- VM starts successfully
- IP address obtained within timeout
- Exports VM_IP variable

---

#### Step 2.8: Implement SSH Verification

**Function:** `verify_ssh_ready()`

**Implementation:**
```bash
verify_ssh_ready() {
    log_step "8" "Verifying SSH accessibility"

    local vm_ip="$VM_IP"
    local ssh_user="${VM_SSH_USER:-ubuntu}"
    local max_wait=60
    local elapsed=0

    while [[ $elapsed -lt $max_wait ]]; do
        if ssh -o BatchMode=yes \
               -o ConnectTimeout=5 \
               -o StrictHostKeyChecking=no \
               "${ssh_user}@${vm_ip}" \
               "exit 0" 2>/dev/null; then
            log_success "SSH is ready"
            export VM_SSH_USER="$ssh_user"
            return 0
        fi

        sleep 5
        ((elapsed+=5))
        log_info "Waiting for SSH... (${elapsed}s/${max_wait}s)"
    done

    log_error "SSH not accessible after ${max_wait}s"
    exit 6
}
```

**Success Criteria:**
- SSH connection successful within timeout
- Exports VM_SSH_USER variable

---

#### Step 2.9: Implement Structured Output

**Function:** `output_result()`

**Implementation:**
```bash
output_result() {
    log_step "9" "Generating output"

    # Structured output for parsing
    linus_success \
        "VM_ID:${ALLOCATED_VM_ID}" \
        "VM_IP:${VM_IP}" \
        "VM_USER:${VM_SSH_USER}" \
        "VM_NAME:${VM_NAME:-linus-vm-${ALLOCATED_VM_ID}}" \
        "VM_OS:${VM_OS}" \
        "VM_CPU:${VM_CPU}" \
        "VM_RAM:${VM_RAM}" \
        "VM_DISK:${VM_DISK}"
}
```

**Expected Output:**
```
LINUS_RESULT:SUCCESS
LINUS_VM_ID:100
LINUS_VM_IP:192.168.1.50
LINUS_VM_USER:ubuntu
LINUS_VM_NAME:linus-vm-100
LINUS_VM_OS:ubuntu
LINUS_VM_CPU:2
LINUS_VM_RAM:2048
LINUS_VM_DISK:20
```

**Success Criteria:**
- All required fields present
- Parseable format
- Uses linus_success() function

---

### Phase 3: Integration & Testing

#### Step 3.1: Local Syntax Testing

**Test:** Verify bash syntax without execution

```bash
bash -n shared/provision/proxmox.sh
```

**Success Criteria:** Exit code 0, no syntax errors

---

#### Step 3.2: Mock Environment Testing

**Test:** Run with mock commands to verify logic

```bash
# Create mock environment
export PROXMOX_NODE="pve-test"
export PROXMOX_STORAGE="test-storage"
export PROXMOX_BRIDGE="vmbr0"
export VM_OS="ubuntu"
export VM_CPU="2"
export VM_RAM="2048"
export VM_DISK="20"

# Mock critical commands
pvesh() { echo "{ \"status\": \"online\" }"; }
qm() { return 0; }
curl() { return 0; }

# Run validation only
source shared/provision/proxmox.sh
validate_environment
```

**Success Criteria:** Validation passes with mocked environment

---

#### Step 3.3: Upload Script to Proxmox via MCP

**Test:** Transfer script using base64 encoding

```bash
# Generate upload command
source shared/lib/mcp-helpers.sh
upload_cmd=$(generate_upload_script_command \
    "shared/provision/proxmox.sh" \
    "/tmp/linus-provision-proxmox.sh")

# Execute via MCP exec tool
# (This would be done by Claude/Gemini via MCP)
```

**Verification:**
```bash
# Via MCP exec: verify script exists
test -f /tmp/linus-provision-proxmox.sh && echo "EXISTS"
```

**Success Criteria:** Script uploaded and executable on Proxmox host

---

#### Step 3.4: Dry-Run Test on Proxmox

**Test:** Run script with dry-run flag (if implemented)

```bash
# Via MCP exec
/tmp/linus-provision-proxmox.sh --dry-run
```

**Expected:** Validation passes, shows what would be done, exits before VM creation

**Success Criteria:** Dry-run completes without errors

---

#### Step 3.5: Full Integration Test

**Test:** Create actual VM on Proxmox

**Setup:**
1. Set all required environment variables
2. Upload script via MCP
3. Execute script via MCP
4. Monitor output
5. Verify VM created and accessible

**Execution:**
```bash
# Via MCP exec
export PROXMOX_NODE="pve"
export PROXMOX_STORAGE="local-lvm"
export PROXMOX_BRIDGE="vmbr0"
export VM_OS="ubuntu"
export VM_CPU="2"
export VM_RAM="2048"
export VM_DISK="20"
export VM_NAME="test-linus-001"

/tmp/linus-provision-proxmox.sh
```

**Verification Steps:**
1. Check exit code = 0
2. Parse output for LINUS_RESULT:SUCCESS
3. Extract VM_ID from output
4. Verify VM exists: `qm status <VM_ID>`
5. Verify VM is running: `qm status <VM_ID> | grep running`
6. Test SSH: `ssh ubuntu@<VM_IP> "uname -a"`

**Success Criteria:** VM created, running, and SSH accessible

---

#### Step 3.6: Idempotency Test

**Test:** Run script twice with same parameters

**Expected:** Second run should detect existing VM and either:
- Option A: Fail gracefully with "VM already exists"
- Option B: Skip creation, return existing VM details

**Decision:** Option A (fail gracefully) - user should be explicit about reusing VMs

**Success Criteria:** Second run fails gracefully with clear message

---

#### Step 3.7: Error Recovery Test

**Test:** Verify cleanup on failure

**Scenarios:**
1. Kill script during VM creation
2. Simulate network timeout
3. Provide invalid storage name

**Expected:** Partial VMs should be cleaned up (qm destroy)

**Success Criteria:** No orphaned VMs left behind on failure

---

#### Step 3.8: Cleanup Test

**Test:** Delete created VMs

```bash
# Via MCP exec
qm stop <VM_ID>
qm destroy <VM_ID>
```

**Verification:**
```bash
qm list | grep <VM_ID>
# Should return empty
```

**Success Criteria:** VMs cleanly removed

---

## Testing Strategy Summary

### Unit Tests (Per Function)

| Function | Test Type | Expected Result |
|----------|-----------|-----------------|
| validate_environment() | Valid input | Returns 0 |
| validate_environment() | Invalid node | Returns 4, error logged |
| allocate_vm_id() | IDs 100-104 taken | Returns 105 |
| allocate_vm_id() | All IDs taken | Returns 5 (error) |
| download_os_image() | Image exists | Skips download |
| download_os_image() | Image missing | Downloads image |
| create_vm() | Valid params | VM created |
| configure_vm() | With SSH key | Key added to cloud-init |
| start_vm() | Valid VM ID | VM starts |
| wait_for_network() | Gets IP in 30s | Returns IP |
| wait_for_network() | Timeout | Returns 6 (error) |
| verify_ssh_ready() | SSH available | Returns 0 |
| output_result() | All vars set | Structured output |

### Integration Tests

| Test | Description | Success Criteria |
|------|-------------|------------------|
| Syntax Check | bash -n script | Exit 0 |
| Upload Test | Transfer via MCP | File exists on Proxmox |
| Dry Run | Validate only | No VMs created |
| Full Provision | End-to-end | VM running, SSH works |
| Idempotency | Run twice | Second fails gracefully |
| Cleanup | Delete VM | No orphans |

### Acceptance Test

**Scenario:** User requests Ubuntu VM

1. User: "Create Ubuntu 24.04 VM with 4 CPU, 8GB RAM, 50GB disk"
2. Claude validates parameters
3. Claude uploads script to Proxmox via MCP
4. Claude executes script via MCP
5. Script provisions VM
6. Claude reports: "✅ VM created! SSH: ssh ubuntu@192.168.1.50"
7. User can SSH to VM
8. User runs `lscpu`, `free -h`, `df -h` - all match specs

**Success:** User has working VM matching requested specs

---

## Risk Mitigation

### Risk 1: Proxmox API Changes

**Mitigation:**
- Pin Proxmox version requirements in documentation
- Use stable CLI commands (qm, pvesh) not internal APIs
- Add version detection and warning

### Risk 2: Network Configuration Varies

**Mitigation:**
- Support both DHCP and static IP
- Make bridge name configurable
- Document network setup requirements

### Risk 3: Cloud-Init Issues

**Mitigation:**
- Add fallback to manual configuration
- Provide clear error messages
- Document cloud-init requirements

### Risk 4: MCP Timeouts on Slow Operations

**Mitigation:**
- Set timeout to 120s (2 minutes)
- Break long operations into steps with progress updates
- Use maxChars=none to avoid truncation

### Risk 5: Partial VM Creation on Failure

**Mitigation:**
- Implement cleanup on error (qm destroy)
- Use atomic operations where possible
- Log VM ID immediately for manual cleanup

---

## Next Steps After Plan Approval

1. **Get User Input** on prerequisites (Proxmox credentials, network config)
2. **Implement Phase 1** (MCP configuration)
3. **Implement Phase 2** (Script development) in order of steps
4. **Execute Phase 3** (Testing) after each component
5. **Iterate** based on test results
6. **Document** any deviations from plan

---

## Questions for User

Before implementation, please provide:

1. **Proxmox Host Details:**
   - Hostname/IP: _______
   - SSH Port: _______ (default: 22)
   - SSH User: _______ (default: root)
   - SSH Key Path: _______

2. **Proxmox Configuration:**
   - Node Name: _______ (default: pve)
   - Storage Pool: _______ (default: local-lvm)
   - Network Bridge: _______ (default: vmbr0)

3. **Preferences:**
   - Starting VM ID range: _______ (default: 100-999)
   - Default OS: _______ (ubuntu/almalinux/rocky)
   - Auto-cleanup failed VMs? (yes/no)

---

**Plan Status:** Ready for Review
**Next Action:** User approval + prerequisite information
**Estimated Implementation Time:** 3-4 hours with testing
