# Tier 3: Multi-Provider Unification Strategy

**Created:** 2026-05-30
**Status:** Documented, not implemented — awaiting more learning from Vast + Proxmox e2e testing
**Context:** After proving the 4 non-deterministic touch points + resilience patterns on Vast.ai (May 29-30), and applying Tiers 1-2 to Proxmox, the next strategic level is a unified provisioning framework where all providers conform to the same contracts.

---

## 3.1 Unified Provider Interface

### Current State

Two providers, two different interfaces:

| Aspect | Vast (`vast.sh`) | Proxmox (`proxmox.sh`) |
|--------|------------------|------------------------|
| Output format | `LINUS_RESULT:SUCCESS` + `LINUS_*` key-value pairs | `linus_success` with ad-hoc keys |
| Input contract | `VAST_GPU_NAME`, `VAST_MODEL_REPO`, `VAST_MODEL_FILE` | `PROXMOX_HOST`, `VM_TEMPLATE_ID` |
| Lifecycle steps | provision → bootstrap → verify → output | provision → configure → start → wait → verify → output |
| Error handling | ERR trap auto-destroy | ERR trap auto-destroy (added T1.2) |
| Driver script | `vast-provision-and-bootstrap.sh` | To be created (T2) |
| Quality gates | 4-tier (char + 5-gram + LLM + fallback) | Capability check only (added T2.2) |
| Cost tracking | `LINUS_COST:total_usd` | `LINUS_COST:wall_time_s` (no monetary cost for local VMs) |

### Target State: Unified Provider Contract

Every provider script (`proxmox.sh`, `vast.sh`, future `aws.sh`, `gcp.sh`, `qemu.sh`) implements the same interface:

#### 1. Standardized Input (env vars)

```
PROVIDER=<name>           # proxmox | vast | aws | gcp | qemu
PROVIDER_CONFIG_*         # provider-specific, always namespaced
LINUS_KEEP_INSTANCE=true  # universal kill switch for debugging
LINUS_LOG_FILE=/tmp/...   # shared log destination
```

Provider-specific vars use a `PROVIDER_` prefix convention:
- Vast: `VAST_GPU_NAME`, `VAST_MODEL_REPO` (keep existing names, they're already namespaced)
- Proxmox: `PROXMOX_HOST`, `VM_TEMPLATE_ID` (already namespaced)

#### 2. Standardized Output (LINUS_RESULT block)

```
LINUS_RESULT:SUCCESS|FAILURE
LINUS_INSTANCE_ID:<provider-specific identifier>
LINUS_ACCESS_HOST:<IP or hostname>
LINUS_ACCESS_PORT:<SSH or API port>
LINUS_ACCESS_USER:<ssh user>
LINUS_INSTANCE_TYPE:<GPU model | VM template>
LINUS_COST:total_usd=X.XX,wall_time_s=Y
LINUS_CAPABILITY:VERIFIED|DEGRADED|FAILED
```

The `LINUS_` prefix is the contract. Any consumer (driver script, multi-vm orchestrator, test harness, cron job) knows to look for `LINUS_RESULT:SUCCESS` and parse `LINUS_*` key-value pairs.

#### 3. Standardized Lifecycle

```
1. validate_environment()    → Return 0 or exit code
2. discover_resources()      → Survey available offers/templates/hosts
3. select_resource()         → Pick best one (TP1 — non-deterministic)
4. allocate_id()             → Get ID (VM ID, contract ID, instance ID)
5. create_instance()         → Provision (clone, create, launch)
6. configure_instance()      → Network, SSH, CPU, disk
7. start_instance()          → Power on
8. wait_for_ready()          → Poll until responsive (TP2 — build/fatal watch)
9. verify_capability()       → Quality gate (TP3 — semantic judge)
10. output_result()           → LINUS_RESULT block
11. trap cleanup_on_failure   → Auto-destroy on non-zero exit
```

#### 4. Standardized Exit Codes

```
0  — Success
1  — General error
2  — Missing dependencies
3  — Invalid configuration
4  — Provider/node offline
5  — Instance creation failed
6  — Network/SSH timeout
7  — Resource exhausted (no offers, no IDs, no disk)
8  — Quality gate failure (instance works but is degraded)
```

### Benefits

1. **Driver scripts become provider-agnostic.** `multi-vm.sh` dispatches to `proxmox.sh` or `vast.sh` and parses the same output format. No per-provider special cases.

2. **Quality gates are shared.** The `quality-gate.sh` library becomes provider-agnostic — it checks text output, not Vast-specific artifacts. `verify_capability()` calls the same 5-gram + LLM judge regardless of whether the instance is a GPU or a VM.

3. **Non-deterministic touch points plug in uniformly.** `llm-eval.py` adds `proxmox-template-select`, `proxmox-bootstrap-judge`, and `proxmox-strategist` modes. The same 2B model that picks Vast offers also picks Proxmox templates.

4. **Cost model unifies.** Vast reports `total_usd` (rental cost); Proxmox reports `wall_time_s` and `resource_usage` (CPU cores, RAM GB, disk GB consumed). A unified `LINUS_COST` line carries both monetary and resource costs.

5. **Testing harness is shared.** `send-kiosk-challenge.sh` works against any provider — it takes a `LINUS_ACCESS_HOST` and `LINUS_ACCESS_PORT`, not a Vast-specific proxy port.

---

## 3.2 Shared Quality Gate Library — Provider-Agnostic

### Current State

`shared/lib/quality-gate.sh` is Vast-specific:
- `_linus_get_model_size_bytes()` — Vast-only (HuggingFace Content-Range)
- `_linus_check_disk_space()` — generic but only used by Vast
- `_linus_run_quality_gates()` — char-level + 5-gram (provider-agnostic, but called in Vast context)
- `_linus_llm_quality_judge()` — provider-agnostic
- `_linus_check_fatal_build_errors()` — Vast-only (onstart.log patterns)
- `_linus_llm_build_watch()` — Vast-only

### Target State

Split into two layers:

**Layer 1: `shared/lib/quality-gate.sh` — Provider-Agnostic**
- `_linus_run_quality_gates(text)` — char-level + 5-gram + whitespace checks
- `_linus_llm_quality_judge(text, context)` — LLM semantic evaluation
- `_linus_check_disk_space(ssh_cmd, path, required_gb)` — disk validation
- `_linus_parse_content_range(headers)` — HTTP Content-Range parsing
- `_linus_check_fatal_patterns(log, patterns)` — generic fatal pattern matching

**Layer 2: `shared/lib/quality-gate-vast.sh` — Vast-Specific**
- `_linus_get_model_size_bytes()` — Vast-only
- `_linus_check_fatal_build_errors()` — Vast-only
- `_linus_llm_build_watch()` — Vast-only

**Layer 2: `shared/lib/quality-gate-proxmox.sh` — Proxmox-Specific**
- `_linus_check_vm_capability(ssh_cmd)` — Proxmox-only (CPU, disk, DNS, Python)
- `_linus_check_apt_fatal_patterns(stderr)` — Proxmox-only (DNS errors, disk full, bad sources)

The provider scripts source Layer 1 + their specific Layer 2. `llm-eval.py` already handles this (provider-agnostic modes + provider-specific modes).

---

## 3.3 Cost Model for Proxmox (Resource Accounting)

### Why This Matters

Vast bills per hour. Proxmox doesn't — but it has a harder constraint: **finite resources.** The Proxmox host has:

| Resource | Capacity (moxy example) | Per-VM Consumption |
|----------|------------------------|---------------------|
| CPU cores | 32 | 2-4 |
| RAM | 64 GB | 2-4 GB |
| Disk (local-lvm) | 500 GB | 20-40 GB |
| VM IDs | 113-250 (138 available) | 1 per VM |
| IP addresses | 192.168.101.113-250 (138 available) | 1 per VM |

A Vast GPU burns money. An orphaned Proxmox VM burns **capacity** — and when capacity is exhausted, all future provisioning fails.

### Target: Resource Tracking in LINUS_RESULT

```bash
LINUS_COST:wall_time_s=547,total_usd=0.00
LINUS_RESOURCE:cpu_cores=2,ram_mb=2048,disk_gb=20,vm_ids_used=1,ips_used=1
```

The `LINUS_RESOURCE` line lets multi-VM orchestrators answer: "Can I provision 5 more 2 GB VMs?"

```python
# Pseudocode in multi-vm orchestrator:
remaining_ram = total_ram - sum(r['ram_mb'] for r in active_resources)
if remaining_ram < (VM_COUNT * VM_RAM):
    abort("Not enough RAM: {remaining_ram}MB free, need {VM_COUNT * VM_RAM}MB")
```

### Target: Proxmox Host Capacity Discovery

Before provisioning, query the node's actual free resources:

```bash
discover_host_capacity() {
    local node_status
    node_status=$(_pvesh get /nodes/${PROXMOX_NODE}/status | jq '.data')
    
    local total_ram_mb=$(echo "$node_status" | jq -r '.memory.total // 0')
    local free_ram_mb=$(echo "$node_status" | jq -r '.memory.free // 0')
    local cpu_count=$(echo "$node_status" | jq -r '.cpuinfo.cpus // 0')
    
    # Storage
    local storage_info
    storage_info=$(_pvesh get /nodes/${PROXMOX_NODE}/storage | jq '.data[] | select(.storage == "'${PROXMOX_STORAGE}'")')
    local total_disk_gb=$(echo "$storage_info" | jq -r '.total // 0' | awk '{print int($1/1073741824)}')
    local used_disk_gb=$(echo "$storage_info" | jq -r '.used // 0' | awk '{print int($1/1073741824)}')
    
    PROXMOX_FREE_RAM_MB=$free_ram_mb
    PROXMOX_FREE_DISK_GB=$((total_disk_gb - used_disk_gb))
    PROXMOX_TOTAL_CPUS=$cpu_count
}
```

This feeds into `allocate_vm_id()` — if the host is near capacity, the allocation fails early rather than creating a VM that can't run.

### Integration with Non-Deterministic Touch Points

The 2B model at PP-TP4 (Provisioning Strategist) sees resource capacity in its decision prompt:

```
Provisioning failed after 3 attempts with template 9000.
Host moxy capacity: 4 CPU free of 32, 12GB RAM free of 64GB, 80GB disk free of 500GB.
3 VMs currently running (IDs 113, 115, 118).

Next action?
  RETRY:template_9001_on_moxy      (fits: 2GB/12GB RAM)
  RETRY:template_9001_on_pve2      (pve2: 48GB free)
  ABORT:no_viable_path             (would fit on moxy)
```

The model can now make capacity-aware decisions: "moxy has 12 GB free and we need 2 GB — that works. No need to switch nodes."

---

## Implementation Sequence (Future)

When ready to implement Tier 3:

1. **Unify output format first.** Update `proxmox.sh` and `vast.sh` to emit identical `LINUS_RESULT` blocks. This is the foundation.

2. **Split quality-gate.sh.** Extract provider-agnostic functions to `shared/lib/quality-gate.sh`. Move Vast-specific functions to `shared/lib/quality-gate-vast.sh`. Create `shared/lib/quality-gate-proxmox.sh`.

3. **Add resource tracking to Proxmox.** `discover_host_capacity()` + `LINUS_RESOURCE` output line.

4. **Update multi-vm.sh.** Parse `LINUS_RESOURCE`, track cumulative consumption, abort when near limits.

5. **Unify driver scripts.** `linus-provision.sh` as a single entry point that dispatches to `proxmox.sh` / `vast.sh` / `aws.sh` based on `PROVIDER` env var.

6. **Extend llm-eval.py.** Add `proxmox-template-select`, `proxmox-bootstrap-judge`, `proxmox-strategist` modes (already specced in T2.5).

---

## Dependencies on Tier 1-2 Completion

Tier 3 assumes:
- Proxmox has structured output (`LINUS_RESULT`) — T1.1
- Proxmox has ERR trap auto-destroy — T1.2
- Proxmox has template discovery — T2.4
- Proxmox has capability verification — T2.2
- Proxmox has non-deterministic touch points — T2.5

All of these are being implemented now. Tier 3 builds on them.
