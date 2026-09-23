# Must-Fix Backlog — Proxmox VM Provisioning Pipeline

**Created:** 2026-05-30
**Branch:** `main` (o3willard-AI/linus-deployment-specialist)
**Status:** Priorities set — Tier 1 items being implemented now

---

## P0 — Broken (pipeline fails or silently degrades)

### 1. No structured output contract
- **File:** `shared/provision/proxmox.sh:785-801` (output_result)
- **Symptom:** `output_result()` calls `linus_success` but the format isn't parseable by downstream consumers. `bootstrap-vm.sh` expects `VM_IP` and `VM_USER` as env vars passed manually.
- **Root cause:** No `LINUS_RESULT:SUCCESS` block with standardized key-value pairs. The script succeeded but the handoff to bootstrap is manual.
- **Impact:** Human error in env var passing. Multi-VM orchestrator can't parse results automatically. No cost/time tracking.
- **Fix:** Standardize `output_result()` to emit `LINUS_RESULT:SUCCESS` + `LINUS_*` key-value pairs matching Vast contract. Create driver script that parses and hands off.

### 2. No auto-destroy on failure (ERR trap exists but is fragile)
- **File:** `shared/provision/proxmox.sh:810-823` (cleanup_on_error)
- **Symptom:** `cleanup_on_error()` exists and is trapped, but doesn't log what it destroyed. No `LINUS_KEEP_VM` bypass for debugging.
- **Root cause:** The trap was added reactively after orphaned VM discovery. Missing: bypass flag, logging, verification that destroy succeeded.
- **Impact:** Orphaned VMs exhaust the 113-199 ID range. Pitfall #13 documents this but the trap can be improved.
- **Fix:** Add `LINUS_KEEP_VM=true` bypass flag. Log destroyed VM ID. Verify destroy via API call after DELETE.

### 3. VM_SSH_USER defaults to empty in some code paths
- **File:** `shared/provision/proxmox.sh:715` (verify_ssh_ready)
- **Symptom:** `verify_ssh_ready()` uses `${VM_SSH_USER:-ubuntu}` (correct), but other functions reference `VM_SSH_USER` directly. `output_result()` uses a local variable correctly.
- **Root cause:** `VM_SSH_USER` is set by OS type switch (line 211-224) but some edge cases (unknown OS type → "cloud-user") may not match actual template. Pitfall #19 documents this.
- **Impact:** SSH verification fails because it tries to connect as wrong user.
- **Fix:** Audit all `VM_SSH_USER` references. Add template discovery that reads the template's default user from its config.

---

## P1 — Brittle (works but fragile, costs time on failure)

### 4. No driver script coupling provision + bootstrap
- **Files:** `shared/provision/proxmox.sh` → manual output → `shared/bootstrap/bootstrap-vm.sh`
- **Symptom:** After `proxmox.sh` succeeds, user must manually copy `VM_IP`, `VM_USER` and export them before running `bootstrap-vm.sh`.
- **Root cause:** Same as Vast P1.3 — two independent scripts with no programmatic handoff.
- **Impact:** Human error. Multi-VM provisioning breaks because `multi-vm.sh` calls `proxmox.sh` but doesn't auto-bootstrap.
- **Fix:** Create `shared/provision/proxmox-provision-and-bootstrap.sh` that runs `proxmox.sh`, parses output, and calls `bootstrap-vm.sh`.

### 5. No cost/time tracking
- **Files:** All provisioning scripts
- **Symptom:** Can't answer "how long does an Ubuntu 24.04 clone take vs AlmaLinux 9.7?" or "is template 9000 faster to provision than 9001?"
- **Root cause:** No timing instrumentation. No resource accounting.
- **Impact:** Can't optimize template selection. Can't detect performance regression. Can't forecast capacity.
- **Fix:** Track `wall_time_s` in `LINUS_COST`. For Proxmox, also track `LINUS_RESOURCE:cpu_cores,ram_mb,disk_gb`.

### 6. No template fallback chain
- **File:** `shared/provision/proxmox.sh:98` (VM_TEMPLATE_ID hardcoded)
- **Symptom:** If `VM_TEMPLATE_ID=9000` is missing, locked, or corrupt, the script fails with "Template VM 9000 not found" and exits. No automatic pivot.
- **Root cause:** Hardcoded single template ID. No fallback.
- **Impact:** Provisioning fails when template is renumbered, deleted, or moved. Template discovery exists in `validate_environment()` but only checks the one hardcoded ID.
- **Fix:** `VM_TEMPLATE_FALLBACKS=9000,9001,9002,9101`. Clone loop that iterates through fallbacks.

### 7. Template check uses individual status endpoint (breaks with --fail)
- **File:** `shared/provision/proxmox.sh:271-275` (validate_environment)
- **Symptom:** Template existence check calls `GET /nodes/{node}/qemu/{template_id}/status/current` — returns 404 for missing template, but without `--fail`, curl exits 0 and the check passes.
- **Root cause:** `_pvesh get` doesn't use `--fail`. The `|| { log_error ... }` is dead code for GET requests.
- **Impact:** Script proceeds with a missing template, clone fails later with confusing error.
- **Fix:** Use `_pvesh get /nodes/${PROXMOX_NODE}/qemu` to list all VMs, check if template ID is in the list. Single API call, no 404 problem.

---

## P2 — Optimization (not broken, but sharp edges)

### 8. No AlmaLinux template support in default config
- **File:** `shared/provision/proxmox.sh:98-99` (VM_TEMPLATE_ID, VM_OS_TYPE)
- **Symptom:** Ubuntu 24.04 has 120-180s first-boot cloud-init delay. AlmaLinux 9.7 boots in ~10s. But default config hardcodes Ubuntu template.
- **Root cause:** No AlmaLinux template exists on moxy currently. But the boot-time advantage is significant (10s vs 120s).
- **Impact:** Every Ubuntu 24.04 provisioning burns 2-3 minutes of unnecessary wait time.
- **Fix:** Create AlmaLinux 9.7 template on moxy. Add `VM_OS_TYPE=almalinux` support with proper SSH user, package manager (dnf), and Python 3.12 via EPEL.

### 9. No fatal pattern detection in bootstrap apt operations
- **File:** `shared/bootstrap/bootstrap-vm.sh:35-66` (apt_retry)
- **Symptom:** `apt_retry()` retries up to 10× on lock errors, but also retries on non-lock failures (DNS dead, disk full, bad sources). Each retry takes 3+ seconds.
- **Root cause:** The non-lock error path at line 59-62 detects non-lock errors but still returns the exit code — the caller (`install_package`) doesn't distinguish fatal from transient.
- **Impact:** DNS failure retries 10× over 165 seconds before surfacing the real error. Disk full retries 8× over 144 seconds.
- **Fix:** Add fatal pattern matching in `apt_retry()`: `Temporary failure resolving`, `No space left on device`, `404 Not Found`, `Hash Sum mismatch`, `dpkg was interrupted`. Fail fast on these.

### 10. Bootstrap SSH connections lack keepalive
- **File:** `shared/bootstrap/bootstrap-vm.sh:31` (ssh_args)
- **Symptom:** Long-running operations (`apt-get install`, `git clone`) can die on network hiccups. Proxmox bridges occasionally drop idle TCP connections.
- **Root cause:** No `ServerAliveInterval` in SSH args. Same bug that killed 4/5 Vast download attempts.
- **Impact:** Bootstrap fails mid-operation with cryptic SSH errors. Retry logic helps but wastes time.
- **Fix:** Add `-o ServerAliveInterval=30 -o ServerAliveCountMax=3` to `ssh_args`.

### 11. Bootstrap has no structured output
- **File:** `shared/bootstrap/bootstrap-vm.sh:226-227` (end of main)
- **Symptom:** Prints `LINUS_RESULT:SUCCESS` on success but no structured key-value pairs. `LINUS_PKG_*:installed` lines are printed but not in a unified format.
- **Root cause:** Bootstrap was written before the LINUS_RESULT contract was established.
- **Impact:** Driver script can't programmatically determine what was installed or cloned.
- **Fix:** Emit `LINUS_RESULT:SUCCESS` + `LINUS_BOOTSTRAP_PACKAGES:golang-go,git,make` + `LINUS_BOOTSTRAP_REPOS:owner/repo` in a structured block.

### 12. No VM capability verification after bootstrap
- **File:** Missing — no function exists
- **Symptom:** Bootstrap says "SUCCESS" but the VM might be incapable of the intended workload: wrong CPU type (kvm64 → numpy crash), disk full, DNS dead, no Python.
- **Root cause:** Bootstrap verifies SSH and DNS, but not workload capability.
- **Impact:** Discover VM is broken AFTER deploying workload. Pitfall #25 (kvm64 CPU → numpy crash) is entirely undetected.
- **Fix:** Add `verify_vm_capability()` function: check CPU has AVX2/SSE4.2, >2 GB free disk, DNS works, Python available.
