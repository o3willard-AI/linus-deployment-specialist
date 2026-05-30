# Proxmox MUSTFIX Completion — Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Close the 2 remaining MUSTFIX items + 1 E2E-discovered bug in the Proxmox provisioning pipeline.

**Architecture:** All changes land in `shared/provision/proxmox.sh` + `shared/bootstrap/bootstrap-vm.sh`. No new files required (AlmaLinux bootstrap already exists at `shared/bootstrap/almalinux.sh`).

**Tech Stack:** Bash, Proxmox REST API, curl, jq, python3.

**Pre-existing work (10/12 MUSTFIX items already done):** Structured output ✅, ERR trap ✅, VM_SSH_USER ✅, driver script ✅, wall_time tracking ✅, template fallback ✅, template discovery ✅, fatal patterns ✅, SSH keepalive ✅, capability verification ✅.

---

## Task 1: LINUS_RESOURCE Tracking (#5 completion)

**Objective:** Add resource accounting to proxmox.sh output so multi-vm.sh can make capacity-aware decisions.

**Files:**
- Modify: `shared/provision/proxmox.sh` (add function + output line + main integration)

### Step 1: Add `discover_host_capacity()` function

Insert after `detect_network_config()` (around line 333):

```bash
# -----------------------------------------------------------------------------
# Function: discover_host_capacity
# -----------------------------------------------------------------------------
# Queries Proxmox node status and storage to determine free resources.
# Sets: PROXMOX_FREE_RAM_MB, PROXMOX_FREE_DISK_GB, PROXMOX_TOTAL_CPUS
# Returns: 0 on success, non-zero on failure
# -----------------------------------------------------------------------------

discover_host_capacity() {
    log_step "1c" "Discovering host capacity"

    local node_status storage_info
    
    node_status=$(_pvesh get /nodes/${PROXMOX_NODE}/status 2>/dev/null) || {
        log_warn "Could not query node status — capacity tracking disabled"
        return 1
    }
    
    PROXMOX_FREE_RAM_MB=$(echo "$node_status" | jq -r '.data.memory.free // 0' | awk '{print int($1/1048576)}')
    PROXMOX_TOTAL_CPUS=$(echo "$node_status" | jq -r '.data.cpuinfo.cpus // 0')
    
    storage_info=$(_pvesh get "/nodes/${PROXMOX_NODE}/storage/${PROXMOX_STORAGE}/status" 2>/dev/null) || {
        log_warn "Could not query storage — disk tracking disabled"
        PROXMOX_FREE_DISK_GB=0
        return 1
    }
    
    local total_bytes used_bytes
    total_bytes=$(echo "$storage_info" | jq -r '.data.total // 0')
    used_bytes=$(echo "$storage_info" | jq -r '.data.used // 0')
    PROXMOX_FREE_DISK_GB=$(awk "BEGIN {print int(($total_bytes - $used_bytes) / 1073741824)}")
    
    log_info "Host capacity: ${PROXMOX_FREE_RAM_MB}MB RAM free, ${PROXMOX_FREE_DISK_GB}GB disk free, ${PROXMOX_TOTAL_CPUS} CPUs"
    return 0
}
```

### Step 2: Add resource guard to `allocate_vm_id()`

Add after `ALLOCATED_VM_IP` is set (around line 362):

```bash
# Capacity guard: refuse to provision if host is near limits
if [[ -n "${PROXMOX_FREE_RAM_MB:-}" && $VM_RAM -gt $((PROXMOX_FREE_RAM_MB - 1024)) ]]; then
    log_warn "Low host RAM: ${PROXMOX_FREE_RAM_MB}MB free, VM needs ${VM_RAM}MB (1GB headroom)"
fi
if [[ -n "${PROXMOX_FREE_DISK_GB:-}" && ${PROXMOX_FREE_DISK_GB:-0} -gt 0 && $VM_DISK -gt ${PROXMOX_FREE_DISK_GB:-0} ]]; then
    log_error "Insufficient host disk: ${PROXMOX_FREE_DISK_GB}GB free, VM needs ${VM_DISK}GB"
    return 7
fi
```

### Step 3: Add `LINUS_RESOURCE` to `output_result()`

Add to the `linus_success` block in `output_result()` (after the existing COST line):

```bash
        "COST:wall_time_s=${wall_time}" \
        "RESOURCE:cpu_cores=${VM_CPU},ram_mb=${VM_RAM},disk_gb=${VM_DISK},host_free_ram_mb=${PROXMOX_FREE_RAM_MB:-0},host_free_disk_gb=${PROXMOX_FREE_DISK_GB:-0}"
```

### Step 4: Wire into `main()`

Add after `detect_network_config`:

```bash
    discover_host_capacity || true  # Non-fatal: capacity warning only
```

### Step 5: Verify

Run: `bash -n shared/provision/proxmox.sh`

Run E2E test and verify output contains:
```
LINUS_RESOURCE:cpu_cores=2,ram_mb=2048,disk_gb=20,host_free_ram_mb=...,host_free_disk_gb=...
```

---

## Task 2: kvm64 CPU Fix (E2E-discovered bug)

**Objective:** Set `cpu: host` in VM config so the VM exposes AVX2/SSE4.2 for ML workloads.

**Files:**
- Modify: `shared/provision/proxmox.sh` (add to configure_vm)

### Step 1: Add `cpu: host` to `configure_vm()`

In `configure_vm()`, before the CPU/RAM config PUT (around line 540), add:

```bash
    # PITFALL 25: Default kvm64 CPU lacks AVX2/SSE4.2 — breaks numpy/pytorch.
    # Set cpu=host so the VM exposes the full host CPU feature set.
    log_info "Setting CPU type: host (AVX2/SSE4.2 enabled)..."
    if ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id}/config \
        --data-raw '{"cpu":"host"}' >/dev/null 2>&1; then
        log_warn "Failed to set cpu=host (non-fatal — VM will use kvm64 default)"
    fi
```

### Step 2: Verify

Run E2E test, check capability output shows:
```
CPU supports AVX2/SSE4.2 ✅
```

---

## Task 3: AlmaLinux Template Support (#8)

**Objective:** Create AlmaLinux 9.7 cloud-init template on moxy, integrate with proxmox.sh's OS detection, and ensure almalinux.sh bootstrap is callable from the driver.

**Files:**
- Create: (template on Proxmox host — API-driven)
- Modify: `shared/provision/proxmox.sh` (configure_network_for_os_type already handles almalinux ✅)
- Modify: `shared/provision/proxmox-provision-and-bootstrap.sh` (route to almalinux.sh for almalinux OS)

### Step 1: Download AlmaLinux 9.7 cloud image

```bash
# On Proxmox host (or via sshpass):
ssh root@192.168.101.155 "
cd /var/lib/vz/template/iso
wget -q https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2
"
```

Verify:
```bash
ssh root@192.168.101.155 "ls -lh /var/lib/vz/template/iso/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2"
```

### Step 2: Create VM and convert to template

```bash
# Via Proxmox API:
# 1. Create VM with cloud-init
# 2. Import disk
# 3. Configure cloud-init
# 4. Convert to template

# Or use the existing alma-cloud-template (VM 9001) which already exists on moxy
```

**Note:** VM 9001 `alma-cloud-template` already exists on moxy. The proxmox.sh template discovery already detects it:
```
VM 9001: alma-cloud-template (template)
```

### Step 3: Update driver to route to almalinux.sh

In `proxmox-provision-and-bootstrap.sh`, update `run_bootstrap()`:

```bash
    # Select bootstrap script based on OS type
    local os_type="${PARSED_VM_OS_TYPE:-${VM_OS_TYPE}}"
    local bootstrap_script="$BOOTSTRAP_SCRIPT"  # default: bootstrap-vm.sh
    
    case "$os_type" in
        almalinux|rocky)
            bootstrap_script="$SCRIPT_DIR/../bootstrap/${os_type}.sh"
            ;;
    esac
    
    if [[ ! -f "$bootstrap_script" ]]; then
        log_warn "Bootstrap script not found for $os_type: $bootstrap_script — using generic"
        bootstrap_script="$BOOTSTRAP_SCRIPT"
    fi
```

### Step 4: E2E test with AlmaLinux

```bash
VM_OS_TYPE=almalinux VM_TEMPLATE_ID=9001 \
  bash shared/provision/proxmox-provision-and-bootstrap.sh
```

Expected: template 9001 selected, VM boots in ~10s (vs 120s for Ubuntu), capability check passes.

---

## Implementation Order

```
Task 1 (resource tracking) → Task 2 (kvm64 CPU) → Task 3 (AlmaLinux)
```

Tasks 1 and 2 touch the same file but different functions — safe to batch. Task 3 has a dependency on Task 2 (we want AVX2 working before we validate AlmaLinux).<｜end▁of▁thinking｜>Task 1 and 2 are independent — implement in parallel. Task 3 goes last.

**All code here is copy-pasteable into the target files.**

---

## Verification

After all 3 tasks:

```bash
# Syntax
bash -n shared/provision/proxmox.sh
bash -n shared/provision/proxmox-provision-and-bootstrap.sh

# Ubuntu E2E (resource tracking + kvm64 fix)
VM_OS_TYPE=ubuntu VM_TEMPLATE_ID=9000 LINUS_KEEP_VM=true \
  bash shared/provision/proxmox-provision-and-bootstrap.sh
# Expected: AVX2 ✅, LINUS_RESOURCE in output, cpu_cores=2

# AlmaLinux E2E (template support)
VM_OS_TYPE=almalinux VM_TEMPLATE_ID=9001 LINUS_KEEP_VM=true \
  bash shared/provision/proxmox-provision-and-bootstrap.sh
# Expected: 10s boot, capability VERIFIED
```
