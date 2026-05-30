# Tier 3: Multi-Provider Unification Strategy

**Created:** 2026-05-30
**Updated:** 2026-05-30 — revised after Vast + Proxmox E2E testing (5 bugs found, 5 lessons learned)
**Status:** Fully specced. Dependencies from Tiers 1-2 complete. Ready to implement.

---

## 3.1 Unified Provider Interface

### Current State (After Tiers 1-2)

| Aspect | Vast (`vast.sh`) | Proxmox (`proxmox.sh`) | Gap |
|--------|------------------|------------------------|-----|
| Output format | `LINUS_RESULT:SUCCESS` + `LINUS_*` key-value pairs | `LINUS_RESULT:SUCCESS` + `LINUS_*` key-value pairs | **Unified ✅** |
| Input contract | `VAST_GPU_NAME`, `VAST_MODEL_REPO`, `VAST_MODEL_FILE` | `PROXMOX_HOST`, `VM_TEMPLATE_ID` | Namespaced ✅ |
| Lifecycle steps | provision → bootstrap → verify → output | provision → configure → start → wait → verify → output | Near-identical |
| Error handling | ERR trap auto-destroy + `LINUS_KEEP_INSTANCE` | ERR trap auto-destroy + `LINUS_KEEP_VM` | Identical pattern |
| Driver script | `vast-provision-and-bootstrap.sh` | `proxmox-provision-and-bootstrap.sh` | **Both exist ✅** |
| Quality gates | 4-tier (char + 5-gram + LLM + fallback) | 4-tier (char + 5-gram + LLM + capability) | Equivalent depth |
| Cost tracking | `LINUS_COST:total_usd` | `LINUS_COST:wall_time_s` + `LINUS_RESOURCE` | Different currencies |
| ND touch points | 4 (offer-select, build-watch, quality-judge, run-strategist) | 3 (template-select, bootstrap-judge, proxmox-strategist) | Provider-specific modes |
| Bootstrap | SSH-based, remote execution | SSH-based, auto-detect apt/dnf | Same pattern ✅ |

The gap between providers has narrowed from 7 differences to essentially 1: **cost currency** (dollars vs wall time + resources). The lifecycle, output contract, error handling, driver pattern, and quality gates are now structurally identical.

### Target State: Unified Provider Contract

Every provider script implements the same interface:

#### 3.1.1 Standardized Input (env vars)

```
PROVIDER=<name>           # proxmox | vast | aws | gcp | qemu
PROVIDER_CONFIG_*         # provider-specific, always namespaced
LINUS_KEEP_INSTANCE=true  # universal kill switch for debugging
LINUS_LOG_FILE=/tmp/...   # shared log destination
```

Provider-specific vars use a `PROVIDER_` prefix convention:
- Vast: `VAST_GPU_NAME`, `VAST_MODEL_REPO` (already namespaced ✅)
- Proxmox: `PROXMOX_HOST`, `VM_TEMPLATE_ID` (already namespaced ✅)

#### 3.1.2 Standardized Output (LINUS_RESULT block)

```
LINUS_RESULT:SUCCESS|FAILURE
LINUS_INSTANCE_ID:<provider-specific identifier>
LINUS_ACCESS_HOST:<IP or hostname>
LINUS_ACCESS_PORT:<SSH or API port>
LINUS_ACCESS_USER:<ssh user>
LINUS_INSTANCE_TYPE:<GPU model | VM template>
LINUS_COST:total_usd=X.XX,wall_time_s=Y
LINUS_RESOURCE:cpu_cores=N,ram_mb=N,disk_gb=N,host_free_ram_mb=N,host_free_disk_gb=N
LINUS_WARNINGS:<comma-separated warning tags>
LINUS_CAPABILITY:VERIFIED|DEGRADED|FAILED
```

The `LINUS_` prefix is the contract. Any consumer (driver script, multi-vm orchestrator, test harness, cron job) knows to look for `LINUS_RESULT:SUCCESS` and parse `LINUS_*` key-value pairs.

**New: `LINUS_WARNINGS`** — aggregates all non-fatal warnings from the provisioning run. Discovered during E2E testing: the AlmaLinux network config logged 3 non-fatal warnings that masked a ciuser mismatch. Without aggregation, these warnings are invisible to downstream consumers and the LLM quality judge. Format: comma-separated tags (`qemu_agent_failed,net0_bridge_failed,dhcp_failed`).

#### 3.1.3 Standardized Lifecycle

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
10. output_result()           → LINUS_RESULT block with LINUS_WARNINGS
11. trap cleanup_on_failure   → Auto-destroy on non-zero exit
```

#### 3.1.4 Standardized Exit Codes

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

#### 3.1.5 SSH Command Construction Standard (E2E Lesson 1)

**Every script that constructs SSH commands MUST use bash arrays, never string concatenation.** This was the most expensive bug found during E2E testing — `bootstrap-vm.sh` built SSH as a space-delimited string, then quoted it as `"$ssh"`, causing bash to treat the entire string as a single filename.

```
# CORRECT — arrays survive word-splitting and quoting
ssh_args=(-i "$key" -o StrictHostKeyChecking=no -o ServerAliveInterval=30)
ssh "${ssh_args[@]}" user@host "command"

# WRONG — string + quoting is fragile
ssh="ssh -i $key -o StrictHostKeyChecking=no user@host"
"$ssh" "command"     # "ssh -i /path ... user@host": No such file or directory
$ssh "command"        # works but loses argument grouping under IFS changes
```

This standard applies to: all bootstrap scripts, all provision scripts, all driver scripts, and any future provider scripts. The Vast scripts already follow this pattern (`ssh_args+=(-i "$key")`); Proxmox bootstrap had the string-based bug and was fixed.

#### 3.1.6 Warning Aggregation Standard (E2E Lesson 4)

**Non-fatal warnings MUST be collected and surfaced in the LINUS_RESULT block.** During E2E testing, the AlmaLinux network config logged 3 non-fatal warnings (`qemu_agent_failed`, `net0_bridge_failed`, `dhcp_failed`) and continued silently. The ciuser mismatch was only caught because SSH auth failed visibly. If SSH had coincidentally worked, we'd have a VM with silently wrong config.

Implementation pattern:
```bash
# Global warning accumulator
LINUS_WARNINGS=()

# In any function with non-fatal failures:
if ! some_operation; then
    log_warn "some_operation failed (non-fatal)"
    LINUS_WARNINGS+=("some_operation_failed")
fi

# In output_result():
linus_success \
    "WARNINGS:${LINUS_WARNINGS[*]:-none}" \
    ...
```

Warnings feed into the LLM quality judge (TP3): if warnings are present, the judge receives them as context for its VERIFIED/DEGRADED assessment.

#### 3.1.7 Variable Scoping Standard (E2E Lesson 5)

**Driver scripts MUST NOT use `readonly` for variables they re-export to subprocesses.** The driver declares defaults, then passes them as inline env vars to the provision script. If the driver declared `readonly PROXMOX_HOST=...`, bash refuses the re-export. This almost derailed the first E2E test.

```
# Driver scripts (dispatchers):
PROXMOX_HOST="${PROXMOX_HOST:-192.168.101.155}"    # mutable — may re-export

# Provision scripts (finalized config):
readonly PROXMOX_HOST="${PROXMOX_HOST:?required}"   # readonly — config is final
```

### Benefits

1. **Driver scripts become provider-agnostic.** `multi-vm.sh` dispatches to `proxmox.sh` or `vast.sh` and parses the same output format. No per-provider special cases.

2. **Quality gates are shared.** The `quality-gate.sh` library becomes provider-agnostic — it checks text output, not Vast-specific artifacts. `verify_capability()` calls the same 5-gram + LLM judge regardless of whether the instance is a GPU or a VM.

3. **Non-deterministic touch points plug in uniformly.** `llm-eval.py` has 7 modes (4 Vast, 3 Proxmox). The same 2B model that picks Vast offers also picks Proxmox templates.

4. **Cost model unifies.** Vast reports `total_usd` (rental cost); Proxmox reports `wall_time_s` and `resource_usage`. A unified `LINUS_COST` line carries both.

5. **Warnings survive to downstream consumers.** The `LINUS_WARNINGS` line ensures non-fatal failures are never silent — the LLM judge, test harness, and human operator all see them.

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

Split into three layers:

**Layer 1: `shared/lib/quality-gate.sh` — Provider-Agnostic**
- `_linus_run_quality_gates(text)` — char-level + 5-gram + whitespace checks
- `_linus_llm_quality_judge(text, context)` — LLM semantic evaluation
- `_linus_check_disk_space(ssh_cmd, path, required_gb)` — disk validation
- `_linus_parse_content_range(headers)` — HTTP Content-Range parsing
- `_linus_check_fatal_patterns(log, patterns)` — generic fatal pattern matching
- `_linus_aggregate_warnings()` — collects and formats LINUS_WARNINGS

**Layer 2a: `shared/lib/quality-gate-vast.sh` — Vast-Specific**
- `_linus_get_model_size_bytes()` — Vast-only
- `_linus_check_fatal_build_errors()` — Vast-only
- `_linus_llm_build_watch()` — Vast-only

**Layer 2b: `shared/lib/quality-gate-proxmox.sh` — Proxmox-Specific**
- `_linus_check_vm_capability(ssh_cmd)` — Proxmox-only (CPU, disk, DNS, Python)
- `_linus_check_apt_fatal_patterns(stderr)` — Proxmox-only (DNS errors, disk full, bad sources)

The provider scripts source Layer 1 + their specific Layer 2. `llm-eval.py` already handles provider-agnostic + provider-specific modes.

### Bootstrap Abstraction Pattern (E2E Lesson 2)

**OS-specific bootstrap scripts that run LOCALLY are the wrong abstraction.** During E2E testing, `almalinux.sh` ran on the control host (checking `/etc/os-release` locally) instead of on the provisioned VM via SSH. The fix: a SINGLE bootstrap script that SSHs into the target and auto-detects the environment.

```
# Pattern for every provider:
# 1. SSH into the provisioned instance
# 2. Detect: package manager (apt/dnf), OS, available tools
# 3. Install packages using detected manager
# 4. Clone repos
# 5. Report results as LINUS_BOOTSTRAP_* lines

# bootstrap-vm.sh already implements this for Proxmox:
# - SSH into VM
# - Detect dnf vs apt-get
# - Install + clone
```

The OS-specific scripts (`almalinux.sh`, `rocky.sh`, `ubuntu.sh`) remain as standalone utilities for manual use, but the pipeline always routes through the SSH-based bootstrap.

---

## 3.3 Cost Model for Proxmox (Resource Accounting)

### Why This Matters

Vast bills per hour. Proxmox doesn't — but it has a harder constraint: **finite resources.** The Proxmox host has:

| Resource | Capacity (moxy, measured) | Per-VM Consumption |
|----------|--------------------------|---------------------|
| CPU cores | 16 | 2-4 |
| RAM | ~62 GB (32 GB free) | 2-4 GB |
| Disk (local-lvm) | 1,754 GB (1,269 GB free) | 20-40 GB |
| VM IDs | 113-250 (138 available) | 1 per VM |
| IP addresses | 192.168.101.113-250 (138 available) | 1 per VM |

A Vast GPU burns money. An orphaned Proxmox VM burns **capacity** — and when capacity is exhausted, all future provisioning fails.

### Implemented: Resource Tracking in LINUS_RESULT

`discover_host_capacity()` is live and tested. Every provision outputs:
```
LINUS_RESOURCE:cpu_cores=2,ram_mb=2048,disk_gb=20,host_free_ram_mb=30311,host_free_disk_gb=1264
```

Capacity guards in `allocate_vm_id()` warn on low RAM and refuse on insufficient disk (exit 7).

### Target: multi-vm.sh Capacity Awareness

```python
# Pseudocode in multi-vm orchestrator:
remaining_ram = total_ram - sum(r['ram_mb'] for r in active_resources)
if remaining_ram < (VM_COUNT * VM_RAM):
    abort("Not enough RAM: {remaining_ram}MB free, need {VM_COUNT * VM_RAM}MB")
```

### Integration with Non-Deterministic Touch Points

The 2B model at PP-TP4 (Provisioning Strategist) sees resource capacity in its decision prompt:

```
Provisioning failed after 3 attempts with template 9000.
Host moxy capacity: 4 CPU free of 16, 12GB RAM free of 32GB, 80GB disk free.
3 VMs currently running (IDs 113, 115, 118).

Next action?
  RETRY:template_9001_on_moxy      (fits: 2GB/12GB RAM)
  RETRY:template_9001_on_pve2      (pve2: 48GB free)
  ABORT:no_viable_path             (would fit on moxy)
```

The model can now make capacity-aware decisions: "moxy has 12 GB free and we need 2 GB — that works. No need to switch nodes."

---

## 3.4 Template Config Discovery (E2E Lesson 3)

**Template configuration should be READ from the existing template, not GUESSED from OS defaults.** During E2E testing, the AlmaLinux network config overrode `ciuser=root`, but the template had `ciuser=almalinux`. SSH keys were injected for root, but SSH connected as almalinux — resulting in `Permission denied (publickey)`.

The fix: `select_template()` already reads the template's detected OS type from `discover_templates()`. The next step for Tier 3 is to read the FULL template config before modifying it:

```bash
read_template_config() {
    local template_id="$1"
    _pvesh get "/nodes/${PROXMOX_NODE}/qemu/${template_id}/config" | jq '.data'
}

# Before provisioning:
template_config=$(read_template_config "$SELECTED_TEMPLATE_ID")
existing_ciuser=$(echo "$template_config" | jq -r '.ciuser // ""')
existing_ostype=$(echo "$template_config" | jq -r '.ostype // ""')

# Use existing values; only set what's missing
[[ -n "$existing_ciuser" ]] && VM_SSH_USER="$existing_ciuser"
```

This pattern applies to Vast too: read the instance's reported state before making assumptions.

---

## Implementation Sequence

Item 3 (resource tracking) and item 6 (Proxmox touch points) from the original sequence are already done. The revised sequence:

### Phase 1: Standards + Warnings (1-2 sessions)

1. **Standardize SSH command construction.** Audit all scripts for `ssh="ssh ..."` string patterns. Replace with arrays. This is a mechanical change with high blast radius — one mistake = "No such file or directory."

2. **Implement warning aggregation.** Add `LINUS_WARNINGS` array + accumulator + output to both `proxmox.sh` and `vast.sh`. Feed warnings into TP3 quality judge.

3. **Encode variable scoping standard.** Remove `readonly` from driver scripts. Add to contributor guide.

### Phase 2: Library Split (1 session)

4. **Split quality-gate.sh.** Extract provider-agnostic Layer 1 to `shared/lib/quality-gate.sh`. Move Vast specifics to `shared/lib/quality-gate-vast.sh`. Create `shared/lib/quality-gate-proxmox.sh`. Both provision scripts update their source lines.

### Phase 3: Unification (1-2 sessions)

5. **Unify driver scripts.** `linus-provision.sh` as a single entry point that dispatches to `proxmox.sh` / `vast.sh` based on `PROVIDER` env var. Parses identical `LINUS_RESULT` blocks.

6. **Update multi-vm.sh.** Parse `LINUS_RESOURCE`, track cumulative consumption across VMs, abort when near host limits. Use capacity data from `discover_host_capacity()`.

### Phase 4: Discovery (1 session)

7. **Template config discovery.** Read existing ciuser/ostype/cpu from template before modifying. Apply to Proxmox; pattern applies to any future provider.

---

## Dependencies — All Met

Tier 3 assumes (all confirmed complete from E2E testing):

| Dependency | Source | Status |
|-----------|--------|--------|
| Proxmox structured output (`LINUS_RESULT`) | T1.1 | ✅ Live — 11 key-value pairs in output |
| Proxmox ERR trap auto-destroy | T1.2 | ✅ Live — `LINUS_KEEP_VM` bypass + verification |
| Proxmox template discovery | T2.4 | ✅ Live — 3 templates discovered per run |
| Proxmox capability verification | T2.2 | ✅ Live — AVX2/disk/DNS/Python checks |
| Proxmox ND touch points | T2.5 | ✅ Live — 3 modes in llm-eval.py |
| Proxmox resource tracking | T2/P5-1 | ✅ Live — `LINUS_RESOURCE` with host data |
| Proxmox driver script | T2 | ✅ Live — `proxmox-provision-and-bootstrap.sh` |
| Vast structured output | P1.3 | ✅ Live — `vast-provision-and-bootstrap.sh` |
| Vast ND touch points | May 30 | ✅ Live — 4 modes in llm-eval.py |
