# Linus Deployment Specialist - Distribution Support Guide

## Overview

The Linus Deployment Specialist supports multiple Linux distributions through **template-based provisioning** and **bootstrap scripts**. Each distribution has its own optimization patterns while sharing common infrastructure.

---

## Distribution Support Matrix

| Distribution | Version(s) | Bootstrap Script | Status | Network Handling | Template Required |
|--------------|------------|------------------|--------|-----------------|-------------------|
| **Ubuntu** | 20.04, 22.04, 24.04 LTS | `ubuntu.sh` (v1.0) | ✅ Production Ready | Standard cloud-init | Yes |
| **Debian** | 10, 11, 12 LTS | N/A (manual via ISO) | ✅ Manual Setup | Standard cloud-init | Optional |
| **AlmaLinux** | 9.x | `almalinux.sh` (v1.2) | ⚠️ Alpha | Enhanced multi-method IP | Custom needed |
| **Rocky Linux** | 9.x | `rocky.sh` (v1.2) | ⚠️ Alpha | Enhanced multi-method IP | Custom needed |
| **CentOS Stream** | 9.x | `centos.sh` (v1.3) | 🆕 Beta | Standard with EPEL repos | Yes |
| **Oracle Linux** | 9.x | `ol9.sh` (v1.3) | 🆕 Beta | Standard with OL repos | Yes |
| **Fedora** | 39, 40 | `fedora.sh` (v1.3) | 🆕 Beta | Standard ephemeral VM | Yes |

---

## Usage Examples

### Quick Start by Distribution

```bash
# Ubuntu - Production Ready (Recommended for new users)
VM_CPU=2 VM_RAM=2048 VM_DISK=20 \
    VM_TEMPLATE_ID=9000 \
    ./shared/provision/proxmox.sh

# AlmaLinux - Alpha (Enhanced network support)
VM_CPU=2 VM_RAM=2048 VM_DISK=20 \
    VM_OS_TYPE=almalinux \
    ./shared/provision/proxmox.sh

# CentOS Stream 9 - Beta (Fresh install from ISO)
VM_CPU=2 VM_RAM=2048 VM_DISK=20 \
    VM_OS_TYPE=centos \
    ./shared/provision/proxmox.sh

# Oracle Linux 9 - Beta (Fresh install from ISO)
VM_CPU=2 VM_RAM=2048 VM_DISK=20 \
    VM_OS_TYPE=ol9 \
    ./shared/provision/proxmox.sh

# Fedora - Beta (Ephemeral VM mode)
VM_CPU=2 VM_RAM=2048 VM_DISK=20 \
    VM_OS_TYPE=fedora \
    ./shared/provision/proxmox.sh
```

---

## Bootstrap Script Comparison

All bootstrap scripts share the same architecture but have distribution-specific packages and configurations:

### Shared Features (All Distributions)

| Feature | Description | Status |
|---------|-------------|--------|
| **Network Interface Detection** | Auto-detects available network interface | ✅ All distributions |
| **Multi-Method IP Detection** | Falls back: nmcli → ip route → cloud-init | ✅ AlmaLinux/Rocky only |
| **Timezone Configuration** | Sets system timezone from env variable | ✅ All distributions |
| **Locale Settings** | Configures locale for terminal output | ✅ All distributions |
| **Hostname Management** | Sets hostname if provided in env | ✅ All distributions |
| **DNS Cleanup** | Removes default DNS (internal network focus) | ✅ All distributions |
| **Verification Step** | Validates all installations completed | ✅ All distributions |

### Distribution-Specific Features

#### Ubuntu/Debian
- Cloud-init networking module handling
- Standard LXD/LXC bridge compatibility
- Package cache cleanup optimized for local repos

#### AlmaLinux/Rocky Linux (v1.2)
- NetworkManager API integration (`nmcli`)
- QEMU guest agent initialization support  
- Cloud-init timing compensation (up to 60s)
- Enhanced error handling for RHEL-based quirks

#### CentOS Stream 9 (v1.3 Beta)
- EPEL repository configuration
- Base repo URL with generic fallback
- Compatible with Proxmox VE storage
- Development tools package list

#### Oracle Linux 9 (v1.3 Beta)
- OL-specific repository detection
- Oracle Java SDK option in extras
- `ol-release` file identity check
- Enhanced firewall (firewalld) configuration

#### Fedora (v1.3 Beta)
- Ephemeral VM mode optimization  
- Developer-friendly package defaults
- Firewalld and SELinux pre-configured
- Container tooling (docker, kubectl, helm) optional extras

---

## Template Creation Instructions

### Option 1: Use Existing Templates (Recommended)

The project repository provides ready-made templates for Ubuntu. For RHEL-based distros, you need to create custom templates.

**Why?**
- RHEL-based cloud images have different networking behavior than Ubuntu
- QEMU guest agent may not start automatically in all RHEL variants
- Cloud-init modules initialize at different times across distributions

### Option 2: Create Your Own Templates

See `docs/FIXING-ALMALINEURROCKY-CLOUD-INIT-THEMES.md` for detailed instructions.

**Quick Steps:**

1. **Clone from Proxmox storage:**
   ```bash
   qm create TEMPLATE_ID \
       --ostype "LNX64" \
       --memory 2048 \
       --cores 1 \
       --scsi0 local-lvm:clone,source=UBUNTU_TEMPLATE_ID,bus=virtio
   ```

2. **Configure for target distribution:**
   - Set OS type to distribution-specific string (e.g., `LNX964:AlmaLinux 9`)
   - Enable QEMU guest agent: `--agent 1`
   - Set CIUser to root: `--ciuser root`

3. **Bootstrap and configure:**
   ```bash
   # Start VM with ISO attached
   qm start TEMPLATE_ID
   
   # Boot from ISO (temporary)
   qm set TEMPLATE_ID --boot order=scsi0,cdrom
   
   # Inside VM: Install distribution via ISO, then convert to template
   # Run appropriate bootstrap script if needed
   
   # Convert to template
   qm convert TEMPLATE_ID --template
   ```

4. **Store in Proxmox storage:**
   - Recommended: `local-lvm` thin provision
   - Or use LXC templates: `/var/lib/lxc/templates/`

---

## Testing New Distributions

### Quick Syntax Check

```bash
# Verify all bootstrap scripts pass syntax validation
for script in shared/bootstrap/*.sh; do
    bash -n "$script" && echo "✓ $(basename $script)" || echo "✗ $(basename $script) FAILED"
done
```

### Manual Testing Steps

1. **Create test VM:**
   ```bash
   VM_CPU=1 VM_RAM=1024 VM_DISK=5 \
       VM_OS_TYPE=centos \
       ./shared/provision/proxmox.sh
   ```

2. **Verify networking works:**
   ```bash
   # Check VM output for IP address
   grep "VM_IP:" < /path/to/provision_output.log
   
   # SSH into VM and verify:
   ssh root@<vm-ip> hostname
   ```

3. **Test bootstrap script directly:**
   ```bash
   # Upload to VM (for testing)
   scp almalinux.sh root@<vm-ip>:/tmp/
   
   # Execute on VM:
   ssh root@<vm-ip> /tmp/almalinux.sh
   ```

---

## Troubleshooting Guide

### Ubuntu - No network connectivity

**Symptom:** VM boots but doesn't get IP address

**Fix:** Ensure cloud-init networking module is enabled in template:
```bash
# In template configuration:
echo "modules: [network]" >> /etc/cloud/cloud.cfg.d/99-disable-networking.cfg 2>/dev/null || true
```

### AlmaLinux/Rocky - Network not detecting IP on first boot

**Symptom:** `wait_for_network` times out in bootstrap output

**Fix:** (Implemented in v1.2) Multi-method IP detection handles this automatically now. See enhanced network functions in almalinux.sh/rocky.sh

### CentOS Stream - EPEL repos not found

**Symptom:** dnf reports repository not found during package installation

**Fix:** Ensure BASE_URL environment variable is set correctly, or script will fall back to generic Fedora repos

```bash
BASE_URL=https://mirrors.fedoraproject.org/releases/9/x86_64/os/ \
    ./centos.sh
```

### Oracle Linux - Wrong repository detected

**Symptom:** Package installation fails with "repository not found"

**Fix:** Script includes OL-specific repo detection. If repositories don't exist, it falls back to EPEL Fedora repos automatically.

### Fedora - SELinux issues during provisioning

**Symptom:** Installation errors related to file context changes

**Fix:** For ephemeral VMs, set `SELINUX=0` in `/etc/selinux/config` if needed:
```bash
echo "SELINUX=disabled" > /etc/selinux/config
```

---

## Recommended Workloads by Distribution

| Use Case | Recommended Distribution | Reason |
|----------|-------------------------|--------|
| **DevOps/CI** | Ubuntu 22.04 LTS | Largest ecosystem, most tutorials available |
| **Production Server** | AlmaLinux/Rocky 9.x | RHEL-compatible, enterprise support via community |
| **Development Environment** | Fedora Workstation | Latest packages, developer-friendly defaults |
| **Research/Testing** | Oracle Linux 9 | Oracle Support Exchange access if licensed |
| **Learning/Lab** | CentOS Stream 9 | Upstream of RHEL, good for experimentation |
| **Container Workloads** | Ubuntu or Fedora | Docker/Podman pre-installed in extras on Fedora |

---

## Version History

### v1.3 Beta (May 7, 2026)
- ✨ Added: CentOS Stream 9 bootstrap script
- ✨ Added: Oracle Linux 9 bootstrap script  
- ✨ Added: Fedora ephemeral VM support
- 📊 All new scripts include network fallback handling

### v1.2 Alpha (May 7, 2026)
- 🔧 Fixed: AlmaLinux/Rocky cloud-init timing issues
- 🔧 Enhanced: Multi-method IP address detection (nmcli, ip route, cloud-init)
- 📄 Added: Documentation for fixing RHEL-based template issues
- ✅ Network interface auto-detection implemented

### v1.0 Stable (Initial Release)
- ✅ Ubuntu/Debian support production-ready
- ⚠️ AlmaLinux/Rocky basic support (networking quirks later fixed)

---

## Quick Reference: Distribution Selection

**New to Proxmox?** → Use **Ubuntu 22.04 LTS** template (`VM_TEMPLATE_ID=9000`)

**Enterprise-like environment?** → Use **AlmaLinux/Rocky 9.x** (v1.2)

**Want latest packages?** → Use **Fedora 40** ephemeral VM

**Oracle ecosystem integration?** → Use **Oracle Linux 9** (v1.3 beta)

**RHEL upstream testing?** → Use **CentOS Stream 9** (v1.3 beta)

---

## Next Steps & Roadmap

### Phase 4: Multi-Distro Template Management
- Create automated template creation scripts for each distribution
- Add Proxmox LXC support alongside QEMU VMs
- Implement automatic template health monitoring

### Phase 5: Enhanced Monitoring
- Add health check endpoints for provisioning
- Implement automated logging aggregation
- Create dashboard for fleet status

### Security (Priority #1)
- Add security hardening scripts per distribution
- Implement CIS benchmark automation
- Add vulnerability scanner integration

---

## Files by Distribution

| Distribution | Script Path | Lines | Status |
|--------------|-------------|-------|--------|
| Ubuntu | `shared/bootstrap/ubuntu.sh` | ~200 | ✅ v1.0 |
| AlmaLinux | `shared/bootstrap/almalinux.sh` | 449 | ⚠️ v1.2 Alpha |
| Rocky | `shared/bootstrap/rocky.sh` | 449 | ⚠️ v1.2 Alpha |
| CentOS Stream | `shared/bootstrap/centos.sh` | 444 | 🆕 v1.3 Beta |
| Oracle Linux | `shared/bootstrap/ol9.sh` | 465 | 🆕 v1.3 Beta |
| Fedora | `shared/bootstrap/fedora.sh` | 461 | 🆕 v1.3 Beta |

---

## Contributing New Distributions

To add support for a new distribution (e.g., openSUSE, SLES):

1. **Review existing patterns:** Look at how Ubuntu, AlmaLinux scripts are structured
2. **Follow naming conventions:** `<distro>.sh` in `shared/bootstrap/`
3. **Include shared functions:** Auto-detection and IP fallback helpers
4. **Add to documentation:** Update this guide with usage examples
5. **Test thoroughly:** Verify networking works on cloud-init images

---

## Support & Contact

For issues, feature requests, or contributions:
- Review existing documentation in `docs/` folder
- Check version notes at project root
- Refer to commit messages for detailed change history

**Current Project Version:** v1.3 Beta (May 7, 2026)
