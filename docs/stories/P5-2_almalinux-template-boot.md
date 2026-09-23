# Story P5-2: AlmaLinux Template Boot Support

**Priority:** P2 (Ubuntu 24.04 burns 2-3 min per provision; AlmaLinux boots in ~10s)
**Estimate:** 0.5 day
**Phase:** Phase 5 — Proxmox MUSTFIX Completion
**Depends on:** P5-1 (kvm64 CPU fix ensures AVX2 works for ML on any template)

---

## User Story

As a **Proxmox provisioner (`proxmox.sh`)**
I want **AlmaLinux 9.7 cloud-init template support with proper OS detection, SSH user mapping, network config, and dnf-based bootstrapping**
So that **VM provisioning takes ~10s instead of 120-180s, and RHEL-based workloads are supported natively**

---

## Acceptance Criteria

### AC1: Template Availability

- [ ] VM 9001 `alma-cloud-template` is confirmed working on node moxy (already exists — verify accessibility)
- [ ] `discover_templates()` returns at least one template with `ostype=almalinux`
- [ ] `select_template()` with `VM_OS_TYPE=almalinux` correctly selects VM 9001
- [ ] Fallback chain: if no almalinux template exists, `select_template()` falls through to Ubuntu → any template

### AC2: SSH User Detection

- [ ] OS type detection in proxmox.sh (lines 215-231) maps `almalinux` → `VM_SSH_USER=almalinux`
- [ ] `rocky` → `VM_SSH_USER=rocky` (already exists ✅)
- [ ] `SELECTED_TEMPLATE_OSTYPE` from template discovery overrides `VM_OS_TYPE` for SSH user (already implemented ✅)
- [ ] Unknown OS types fall back to `cloud-user` (already implemented ✅)

### AC3: Network Configuration Compatibility

- [ ] `configure_network_for_os_type()` almalinux case (lines 459-499) already exists ✅
- [ ] Verify it works: test with `VM_OS_TYPE=almalinux`, confirm VM gets correct static IP
- [ ] Cloud-init ISO regenerated correctly for AlmaLinux (same cloudinit endpoint, works for all distros)
- [ ] No DNS parameter in ipconfig0 (pitfall #17 guardrail already present ✅)

### AC4: Bootstrap Script Routing

- [ ] `proxmox-provision-and-bootstrap.sh` routes to OS-specific bootstrap:
  - `ubuntu` / `debian` → `shared/bootstrap/bootstrap-vm.sh` (apt)
  - `almalinux` / `rocky` → `shared/bootstrap/almalinux.sh` (dnf)
  - Unknown → `bootstrap-vm.sh` with warning
- [ ] Driver parses `PARSED_VM_OS_TYPE` from LINUS_RESULT output
- [ ] Bootstrap script existence checked before dispatch; falls back to generic with warning if missing
- [ ] `almalinux.sh` already exists at `shared/bootstrap/almalinux.sh` — verify it's functional

### AC5: E2E Validation

- [ ] Provision AlmaLinux VM: `VM_OS_TYPE=almalinux VM_TEMPLATE_ID=9001`
- [ ] Template 9001 selected, SSH user = `almalinux`
- [ ] VM boots in <30s (vs 120-180s for Ubuntu 24.04)
- [ ] `verify_vm_capability()` passes: AVX2 ✅, disk ✅, DNS ✅, Python ✅
- [ ] Bootstrap with `BOOTSTRAP_PACKAGES="python3.12 python3.12-pip" BOOTSTRAP_REPOS="o3willard-AI/hermes-agent"`
- [ ] dnf install succeeds, EPEL enabled for python3.12
- [ ] VM destroyed cleanly

---

## Technical Notes

**AlmaLinux cloud-init user:** AlmaLinux 9 GenericCloud images use `almalinux` as the default user (not `cloud-user` or `root`). This is configured in `/etc/cloud/cloud.cfg`. The proxmox.sh OS type switch already maps `almalinux` → `VM_SSH_USER=almalinux`.

**Python 3.12 on AlmaLinux 9:** AlmaLinux 9 ships Python 3.9 by default. Python 3.12 is available via EPEL:
```bash
dnf install -y epel-release
dnf install -y python3.12 python3.12-pip python3.12-devel
```

**Boot time comparison:**
| OS | First boot cloud-init | Second boot | Notes |
|----|----------------------|-------------|-------|
| Ubuntu 24.04 | 120-180s | ~20s | package_upgrade + unattended-upgrades |
| AlmaLinux 9.7 | ~10s | ~5s | no unattended-upgrades trigger |

**Existing almalinux.sh bootstrap:** The script at `shared/bootstrap/almalinux.sh` already handles:
- dnf-based package installation
- DNS configuration
- EPEL repository setup
- Python installation
- Git repo cloning

The driver script just needs to route to it when OS type is almalinux or rocky.

**Template already exists:** VM 9001 `alma-cloud-template` was discovered during the May 30 E2E test:
```
VM 9001: alma-cloud-template (template)
```
No creation step needed — just verification.

---

## Definition of Done

- [ ] All 5 AC sections with all checkboxes passing
- [ ] `bash -n shared/provision/proxmox.sh` clean
- [ ] `bash -n shared/provision/proxmox-provision-and-bootstrap.sh` clean
- [ ] E2E Ubuntu test still passes (no regression)
- [ ] E2E AlmaLinux test: provisions, boots in <30s, capability VERIFIED
- [ ] VMs destroyed cleanly after tests
- [ ] Committed with message: `feat: AlmaLinux template boot support + bootstrap routing (MUSTFIX #8)`
