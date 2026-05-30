# Story P5-1: Proxmox Resource Tracking + kvm64 CPU Fix

**Priority:** P1 (resource exhaustion blocks multi-VM provisioning; kvm64 breaks ML workloads)
**Estimate:** 0.5 day
**Phase:** Phase 5 — Proxmox MUSTFIX Completion
**Depends on:** P4-1 (validate_environment exists)

---

## User Story

As a **multi-VM orchestrator (`multi-vm.sh`)**
I want **proxmox.sh to output resource consumption per VM and the host's remaining capacity**
So that **I can refuse to provision when the host is near its RAM/disk limits, and I can ensure VMs have AVX2 for ML workloads**

---

## Acceptance Criteria

### AC1: Host Capacity Discovery

- [ ] Function `discover_host_capacity()` in `shared/provision/proxmox.sh` (after `detect_network_config`)
- [ ] Queries `/nodes/{node}/status` to get `memory.free` and `cpuinfo.cpus`
- [ ] Queries `/nodes/{node}/storage/{storage}/status` to get `total - used` disk bytes
- [ ] Sets `PROXMOX_FREE_RAM_MB` (integer MB), `PROXMOX_FREE_DISK_GB` (integer GB), `PROXMOX_TOTAL_CPUS`
- [ ] Non-fatal: returns 1 on API error, logs warning, skips capacity tracking
- [ ] Log line: `Host capacity: 34883MB RAM free, 412GB disk free, 32 CPUs`

### AC2: Capacity Guard in VM ID Allocation

- [ ] In `allocate_vm_id()`, after `ALLOCATED_VM_IP` is set, add guard:
- [ ] If `PROXMOX_FREE_RAM_MB` is set and `VM_RAM > (PROXMOX_FREE_RAM_MB - 1024)`, log warning about low RAM
- [ ] If `PROXMOX_FREE_DISK_GB` is set and `VM_DISK > PROXMOX_FREE_DISK_GB`, log error and return 7
- [ ] Return code 7 = resource exhausted (new exit code, add to header comment)
- [ ] Guards are skipped if capacity discovery failed (no false positives on API errors)

### AC3: LINUS_RESOURCE Output Line

- [ ] `output_result()` emits `LINUS_RESOURCE` line:
  ```
  LINUS_RESOURCE:cpu_cores=2,ram_mb=2048,disk_gb=20,host_free_ram_mb=34883,host_free_disk_gb=412
  ```
- [ ] Host values show 0 if capacity discovery failed (graceful degradation)
- [ ] Line appears in main() output, parsed by driver script

### AC4: kvm64 CPU Fix

- [ ] In `configure_vm()`, before CPU/RAM config PUT:
  ```bash
  _pvesh put .../config --data-raw '{"cpu":"host"}'
  ```
- [ ] Non-fatal: logs warning on failure, VM gets kvm64 default
- [ ] Comment references pitfall #25 (kvm64 lacks AVX2/SSE4.2)
- [ ] E2E test: `verify_vm_capability()` shows `CPU supports AVX2/SSE4.2 ✅`

### AC5: main() Integration

- [ ] `discover_host_capacity` called after `detect_network_config` (line ~835 in main)
- [ ] Calls with `|| true` — non-fatal, pipeline continues without capacity tracking on failure
- [ ] `bash -n shared/provision/proxmox.sh` clean

---

## Technical Notes

**Storage API endpoint:** The storage status endpoint is `/nodes/{node}/storage/{storage}/status` (not `/storage/{storage}` which is cluster-level). The node-level endpoint returns per-node storage stats with `total`, `used`, `avail` in bytes.

**jq math avoidance:** Use `awk` for byte → GB conversion. `jq '(.total - .used) / 1073741824'` works but rounds to integer. `awk "BEGIN {print int(...)}"` is more explicit.

**RAM in bytes:** Proxmox reports memory in bytes. Divide by 1048576 (1024²) for MB. The `memory.free` field is what's actually available — not `memory.total - memory.used` (which ignores cache/buffers).

**cpu=host compatibility:** Setting `cpu: host` does NOT pin the VM to the current physical host. Migration between hosts with compatible CPU features (same generation) still works. This is Proxmox's default behavior for `cpu: host`.

---

## Definition of Done

- [ ] All 5 AC sections with all checkboxes passing
- [ ] `bash -n shared/provision/proxmox.sh` clean
- [ ] E2E test: Ubuntu VM provisions, capability shows AVX2 ✅, output contains LINUS_RESOURCE
- [ ] E2E test: VM destroyed cleanly, no orphaned resources
- [ ] Committed with message: `feat: Proxmox resource tracking + kvm64 CPU fix (MUSTFIX #5, #25)`
