# Fixing AlmaLinux/Rocky Cloud-Init Template Issues

## Overview

This document describes how to resolve networking issues when using AlmaLinux 9.x or Rocky Linux 9.x as cloud-init templates for ephemeral VM provisioning.

## Problem Summary

**Symptom:** When provisioning AlmaLinux or Rocky Linux VMs, the network may not configure properly on first boot:
- `qemu-guest-agent` fails to start automatically in cloud images
- DHCP/network configuration doesn't get applied within expected timeout
- VM boots but doesn't receive IP address within 120s

**Root Cause:** RHEL-based distros have different cloud-init behavior compared to Ubuntu/Debian, particularly around:
1. Network interface detection timing
2. QEMU guest agent initialization
3. Cloud-init networking module configuration

## Solutions Implemented

### 1. Proxmox Provisioning Script Updates ✅

**File:** `shared/provision/proxmox.sh`

**Changes Added:**
- New function `configure_network_for_os_type()` that applies OS-specific network settings after VM clone
- For AlmaLinux/Rocky, sets:
  - VM OS type to "Linux" for QEMU agent compatibility
  - Enables QEMU guest agent (`--agent 1`)
  - Explicitly configures network bridge
  - Sets CIUser to root for proper cloud-init context
  - Enables DHCP on network interface

**Configuration Added:**
```bash
configure_network_for_os_type() {
    case "$os_type" in
        almalinux|rocky)
            qm set "$vm_id" --agent 1 --net0 bridged="${PROXMOX_BRIDGE}"
            qm set "$vm_id" --ciuser root
            qm set "$vm_id" --net0 ipv4=dhcp
            ;;
    esac
}
```

### 2. Bootstrap Script Enhancements ✅

**Files:** `shared/bootstrap/almalinux.sh`, `shared/bootstrap/rocky.sh`

**New Functions Added:**

#### `detect_network_interface()`
- Automatically detects available network interface
- Falls back to `ens3` default if detection fails

#### `get_vm_ip_address()`
- Uses **multiple methods** for IP detection (handles cloud-init timing):
  1. **nmcli** - NetworkManager API (most reliable for RHEL-based)
  2. **ip route** - Get default gateway's IP
  3. **cloud-init config** - Read from `/var/lib/cloud/instance/networking/`

#### `wait_for_network_ready()`
- Waits up to 60 seconds (configurable via `BOOTSTAP_WAIT_TIME`)
- Retries every 5 seconds
- Provides better feedback during boot

### 3. Environment Variables for Troubleshooting

New optional environment variables added:

| Variable | Default | Purpose |
|----------|---------|---------|
| `NETWORK_INTERFACE` | `ens3` | Custom network interface name |
| `BOOTSTAP_WAIT_TIME` | `60` | Seconds to wait for network |

## Template Creation Best Practices

### Option A: Using Ubuntu Template as Base (Recommended)

Since Ubuntu templates work reliably, you can create RHEL-based templates by cloning and converting:

```bash
# Create AlmaLinux/Rocky cloud-init templates from scratch
# Requires Proxmox VE 8.x with PVE-Packages or pve-container-tools

# 1. Download official cloud-init ISO
proxmox-terminal-create-vm --vmid "TEMPLATE_ID" \
    --ostype "LNX964:AlmaLinux 9 | AlmaLinux 9 (x86_64)" \
    --memory 2048 --cores 1

# 2. Upload cloud-init ISO to storage
qm set TEMPLATE_ID --scsi0 local:iso/cloud-init.iso --scsi1 virtio0p10,media=disk,size=32G

# 3. Boot and configure
qm start TEMPLATE_ID
qm set TEMPLATE_ID --boot order=scsi0

# 4. Inside VM, install AlmaLinux/Rocky via ISO
# Then run cloud-init setup manually to create proper template

# 5. Configure networking explicitly:
#    - Install qemu-guest-agent
#    - Configure network scripts for DHCP
#    - Verify cloud-init completed successfully

# 6. Convert to template
qm convert TEMPLATE_ID --template
```

### Option B: Using Proxmox Cloud-Init Template Maker

For creating from scratch with proper cloud-init config:

```bash
# Create new VM with cloud-init settings
qm create NEW_VM_ID \
    --ostype "LNX964" \
    --memory 2048 \
    --cores 1 \
    --scsi0 local-lvm:clone,source=UBUNTU_TEMPLATE_ID,bus=virtio \
    --net0 virtio,bridge=vmbr0,model=virtio,connect=on,network=default

# Set OS info specifically for RHEL-based distros
qm set NEW_VM_ID --ostype "LNX964:AlmaLinux 9 | AlmaLinux 9 (x86_64)"

# Enable QEMU guest agent
qm set NEW_VM_ID --agent1 --agent-xpra0

# Configure cloud-init user
qm set NEW_VM_ID --ciuser root

# Start VM and install AlmaLinux/Rocky via ISO
qm start NEW_VM_ID

# Install OS, configure cloud-init networking, then convert to template
```

## Testing the Fixes

### Verify Bootstrap Scripts Syntax

```bash
# Check all modified scripts pass syntax validation
for script in shared/bootstrap/{almalinux,rocky}.sh; do
    bash -n "$script" && echo "✓ $script" || echo "✗ $script FAILED"
done
```

Expected output:
```
✓ shared/bootstrap/almalinux.sh
✓ shared/bootstrap/rocky.sh
```

### Test Network Detection Functions Manually

On a running AlmaLinux/Rocky VM, test the new functions:

```bash
# Source the bootstrap script (for testing only)
source /opt/linus/shared/bootstrap/almalinux.sh 2>/dev/null || \
    source ./almalinux.sh

# Test network interface detection
detect_network_interface

# Test IP address detection  
get_vm_ip_address

# If these work, networking is functional
```

### End-to-End Test for AlmaLinux/Rocky

```bash
# Create a test VM with AlmaLinux template
VM_CPU=2 VM_RAM=2048 VM_DISK=20 \
    VM_OS_TYPE=almalinux \
    ./shared/provision/proxmox.sh

# Expected behavior:
# 1. VM clones from template (or creates new)
# 2. Network is configured for AlmaLinux
# 3. VM starts and boots
# 4. Bootstrap script runs with enhanced network handling
# 5. IP address detected via nmcli or ip route fallback
# 6. SSH becomes accessible

# Verify VM obtained IP (check output)
grep "VM_IP:" < output.log
```

## Troubleshooting Guide

### Issue: VM still doesn't get IP after boot

**Symptom:** `wait_for_network` times out in bootstrap script

**Possible Causes:**
1. Cloud-init not installed/initialized
2. NetworkManager service not starting
3. Virtual network bridge misconfigured on host

**Fixes to try:**

1. **Install cloud-init:**
   ```bash
   dnf install -y cloud-init
   systemctl enable --now cloud-init-network.target
   ```

2. **Enable NetworkManager:**
   ```bash
   dnf install -y NetworkManager
   systemctl enable --now NetworkManager
   ```

3. **Check network interface:**
   ```bash
   ip a show ens3  # Should show UP state
   nmcli device status
   ```

4. **Verify cloud-init completed:**
   ```bash
   cat /var/log/cloud-init-output.log | tail -50
   ls /var/lib/cloud/instance/networking/nw-config/
   ```

### Issue: qemu-guest-agent not running

**Symptom:** Network discovery via QEMU agent fails

**Fix:**
```bash
# Install and configure guest agent
dnf install -y qemu-guest-agent

# Configure to start on boot
systemctl enable --now qemu-guest-agent

# Verify running
systemctl status qemu-guest-agent

# Restart VM after configuration
qm reboot $VM_ID
```

### Issue: Wrong network interface detected

**Symptom:** `detect_network_interface` returns empty or wrong interface

**Fix:**
```bash
# Specify custom interface explicitly
NETWORK_INTERFACE=eth0 ./almalinux.sh

# Or check available interfaces first
ip link show
```

## Configuration Examples

### Quick Test with AlmaLinux Template

```bash
# Create minimal AlmaLinux test VM
VM_CPU=1 VM_RAM=1024 VM_DISK=10 \
    VM_OS_TYPE=almalinux \
    PROXMOX_NODE=proxmox-host \
    ./shared/provision/proxmox.sh

# Expected: VM created with network configured, boots to AlmaLinux, gets IP
```

### Test Rocky Linux

```bash
VM_CPU=2 VM_RAM=2048 VM_DISK=20 \
    VM_OS_TYPE=rocky \
    BOOTSTAP_WAIT_TIME=120 \
    ./shared/provision/proxmox.sh
```

## Rollback Procedure

If issues persist after applying fixes:

### Option 1: Disable RHEL-specific network config

Edit `shared/provision/proxmox.sh`, comment out:
```bash
# For almalinux|rocky cases in configure_network_for_os_type()
if ! qm set "$vm_id" --osinfo "Linux" || true
```

### Option 2: Use Ubuntu templates exclusively

Keep using `VM_TEMPLATE_ID=9000` (Ubuntu) only and document that RHEL-based distros require custom template creation.

## Related Files

- `shared/provision/proxmox.sh` - Provisioning script with network config
- `shared/bootstrap/almalinux.sh` - AlmaLinux bootstrap with enhanced networking
- `shared/bootstrap/rocky.sh` - Rocky Linux bootstrap with enhanced networking  
- `docs/FIXING-ALMALINEURROCKY-CLOUD-INIT-THEMES.md` - This document

## Version History

| Version | Date | Change |
|---------|------|--------|
| 1.0 | Initial | AlmaLinux/Rocky support added (templates broken) |
| 1.2 | Current | Enhanced networking, multi-method IP detection |

## Contributing Fixes

If you discover another network configuration quirk:

1. Test on actual Proxmox host with both providers (if applicable)
2. Add new detection method to `get_vm_ip_address()` function
3. Document the fix in this file's troubleshooting section
4. Update version number and date above

## Next Steps (v1.1.1+)

Priority improvements for future releases:

- [ ] Add AWS-specific template creation scripts for AlmaLinux/Rocky
- [ ] Add QEMU/libvirt custom network bridge configuration for RHEL-based distros  
- [ ] Create official Proxmox templates in project repo's storage
- [ ] Add automated template creation script (`scripts/create-alma-template.sh`)
- [ ] Update AGENT-GUIDE.md with RHEL-based distro usage examples
