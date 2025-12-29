# Example 01: Simple VM Provisioning

## User Request
"Create an Ubuntu VM on Proxmox with 4 CPU cores and 8GB RAM"

---

## Agent Response

I'll provision an Ubuntu VM on Proxmox with 4 CPU cores and 8GB RAM.

**Step 1: Validate parameters**
- Provider: proxmox ✓
- OS: ubuntu ✓
- CPU: 4 cores ✓
- RAM: 8192 MB ✓
- Disk: 20 GB (default) ✓

**Step 2: Read and prepare provisioning script**

*[Agent reads /home/sblanken/working/linusstr/shared/provision/proxmox.sh]*

**Step 3: Execute provisioning on Proxmox host**

*[Agent uses MCP ssh-mcp exec tool to run the provisioning script]*

```bash
# Environment variables set:
export PROXMOX_NODE=moxy
export PROXMOX_STORAGE=local-lvm
export PROXMOX_BRIDGE=vmbr0
export VM_TEMPLATE_ID=9000
export VM_CPU=4
export VM_RAM=8192
export VM_DISK=20

# Execute provisioning script
/root/linus-deployment/shared/provision/proxmox.sh
```

**Output:**
```
[INFO] 2025-12-29 00:15:00 - Step 1: Validating environment
[INFO] 2025-12-29 00:15:01 - Checking Proxmox node status...
[INFO] 2025-12-29 00:15:01 - Node online (uptime: 1234567s)
[SUCCESS] 2025-12-29 00:15:02 - Environment validation passed

[INFO] 2025-12-29 00:15:02 - Step 2: Allocating VM ID
[SUCCESS] 2025-12-29 00:15:02 - Allocated VM ID: 113

[INFO] 2025-12-29 00:15:03 - Step 3: Cloning template VM 9000
[SUCCESS] 2025-12-29 00:15:15 - VM 113 created from template

[INFO] 2025-12-29 00:15:15 - Step 4: Configuring VM resources
[INFO] 2025-12-29 00:15:15 - Setting CPU: 4 cores, RAM: 8192 MB...
[INFO] 2025-12-29 00:15:16 - Resizing disk to 20G...
[SUCCESS] 2025-12-29 00:15:18 - VM configured: 4 CPU, 8192MB RAM, 20GB disk

[INFO] 2025-12-29 00:15:18 - Step 5: Starting VM
[SUCCESS] 2025-12-29 00:15:20 - VM started

[INFO] 2025-12-29 00:15:20 - Step 6: Waiting for network configuration
[INFO] 2025-12-29 00:15:25 - Waiting for network... (5s/120s)
[SUCCESS] 2025-12-29 00:15:35 - VM IP obtained: 192.168.101.113

[INFO] 2025-12-29 00:15:35 - Step 7: Verifying SSH accessibility
[INFO] 2025-12-29 00:15:40 - Waiting for SSH... (5s/60s)
[SUCCESS] 2025-12-29 00:15:45 - SSH is ready at ubuntu@192.168.101.113

[INFO] 2025-12-29 00:15:45 - Step 8: Generating output
LINUS_RESULT:SUCCESS
LINUS_VM_ID:113
LINUS_VM_IP:192.168.101.113
LINUS_VM_USER:ubuntu
LINUS_VM_NAME:linus-vm-113
LINUS_VM_CPU:4
LINUS_VM_RAM:8192
LINUS_VM_DISK:20
LINUS_VM_NODE:moxy

[SUCCESS] 2025-12-29 00:15:45 - VM provisioning completed successfully
```

**Step 4: Parse results and report to user**

---

## Final Response to User

✅ **VM Provisioning Complete!**

**VM Details:**
- **VM ID:** 113
- **IP Address:** 192.168.101.113
- **Provider:** Proxmox (node: moxy)
- **Resources:** 4 CPU cores, 8192 MB RAM, 20 GB disk
- **OS:** Ubuntu 24.04 LTS

**Connect via SSH:**
```bash
ssh ubuntu@192.168.101.113
```

**Verification:** All checks passed
- ✓ Template cloned successfully
- ✓ Resources configured
- ✓ VM started and running
- ✓ Network configured (IP obtained via QEMU agent)
- ✓ SSH accessible and ready

The VM is ready for use!

---

## Key Takeaways

1. **Level 1 Automation:** The `proxmox.sh` script uses non-interactive design (no prompts)
2. **Structured Output:** All results are parseable via `LINUS_RESULT:` lines
3. **Full Lifecycle:** Script handles everything from clone to SSH verification
4. **Environment-Driven:** Configuration via environment variables (no hardcoded values)
5. **Robust Error Handling:** Each step validates before proceeding
