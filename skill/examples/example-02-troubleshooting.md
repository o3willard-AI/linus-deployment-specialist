# Example 02: Troubleshooting Common Issues

## Scenario 1: Command Timeout

### User Report
"The VM provisioning failed with a timeout error"

### Error Output
```
Error: Command timed out after 60000ms
Command: /root/linus-deployment/shared/provision/proxmox.sh
Exit Code: 124
```

### Agent Diagnosis

**Root Cause:** The VM cloning step takes longer than 60 seconds (default timeout)

**Solution:**

1. **Increase MCP timeout in configuration**

   Update `~/.config/Claude/claude_desktop_config.json`:
   ```json
   {
     "mcpServers": {
       "linus-ssh": {
         "command": "ssh-mcp",
         "args": [
           "--host=192.168.101.155",
           "--user=root",
           "--key=/home/user/.ssh/id_rsa",
           "--timeout=180000",  ← Increase to 3 minutes
           "--maxChars=none"
         ]
       }
     }
   }
   ```

2. **Restart Claude Code** to apply config changes

3. **Retry provisioning**

**Prevention:** For operations known to take >1 minute, use Level 3 automation (TMUX) which allows monitoring long-running operations without timeout constraints.

---

## Scenario 2: Permission Denied

### User Report
"Getting permission denied when trying to clone the VM"

### Error Output
```
[ERROR] 2025-12-29 00:20:00 - Failed to clone template
Error: Permission denied (publickey)
```

### Agent Diagnosis

**Root Cause:** SSH key authentication is not configured correctly

**Solution:**

1. **Verify SSH key exists on Proxmox host**
   ```bash
   ssh root@192.168.101.155 "ls -la /root/.ssh/id_rsa.pub"
   ```

2. **If missing, generate SSH key on Proxmox**
   ```bash
   ssh root@192.168.101.155 "ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N ''"
   ```

3. **Verify MCP config uses correct key**
   The `--key` parameter in MCP config should point to the LOCAL machine's private key that matches the public key on Proxmox

4. **Alternative: Use password authentication temporarily**
   ```json
   {
     "args": [
       "--host=192.168.101.155",
       "--user=root",
       "--password=YOUR_PASSWORD"  ← Use with caution
     ]
   }
   ```

---

## Scenario 3: Template VM Not Found

### User Report
"VM provisioning failed - template not found"

### Error Output
```
[ERROR] 2025-12-29 00:25:00 - Template VM 9000 not found
[ERROR] 2025-12-29 00:25:00 - Environment validation passed
```

### Agent Diagnosis

**Root Cause:** Template VM ID 9000 does not exist on Proxmox node

**Solution:**

1. **Check available templates on Proxmox**
   ```bash
   ssh root@192.168.101.155 "qm list | grep template"
   ```

2. **If template exists with different ID:**
   ```bash
   # Use correct template ID
   export VM_TEMPLATE_ID=8000  # Replace with actual ID
   /root/linus-deployment/shared/provision/proxmox.sh
   ```

3. **If no template exists, create one:**
   - Download Ubuntu cloud image
   - Create VM from image
   - Convert to template
   - Configure cloud-init

   See Proxmox documentation: https://pve.proxmox.com/wiki/Cloud-Init_Support

---

## Scenario 4: Network Timeout

### User Report
"VM created but can't get IP address"

### Error Output
```
[INFO] 2025-12-29 00:30:00 - Waiting for network... (120s/120s)
[ERROR] 2025-12-29 00:30:00 - Timeout waiting for network configuration
```

### Agent Diagnosis

**Root Cause:** QEMU guest agent not running or network not configured

**Solutions:**

**Option 1: Check QEMU agent status**
```bash
ssh root@192.168.101.155 "qm agent 113 ping"
```

If agent not responding:
- Ensure qemu-guest-agent is installed in template
- Template must have cloud-init configured

**Option 2: Manual network scan fallback**

The script has fallback logic using nmap:
```bash
# The script automatically tries nmap scan after 30s
# Check if nmap is installed on Proxmox
ssh root@192.168.101.155 "command -v nmap"
```

**Option 3: Get IP manually**
```bash
# Check VM console for IP
ssh root@192.168.101.155 "qm terminal 113"

# Or check DHCP leases
ssh root@192.168.101.155 "cat /var/lib/dhcp/dhcpd.leases | grep 113"
```

---

## Scenario 5: Command Too Long Error

### User Report
"Getting 'command truncated' error"

### Error Output
```
Error: Command exceeds maxChars limit (1000)
Transmitted: 1024 characters
```

### Agent Diagnosis

**Root Cause:** MCP maxChars limit truncates the provisioning script

**Solution:**

Update MCP config to allow unlimited command length:
```json
{
  "args": [
    "--host=192.168.101.155",
    "--user=root",
    "--key=/home/user/.ssh/id_rsa",
    "--timeout=180000",
    "--maxChars=none"  ← Set to "none" for unlimited
  ]
}
```

**Restart Claude Code** to apply changes

---

## Best Practices for Debugging

1. **Check MCP tool response first** - Contains most debugging info
2. **Verify environment variables** - Ensure all required vars are set
3. **Test script syntax locally** - Use `bash -n script.sh` before execution
4. **Enable debug logging** - Set `LINUS_DEBUG=1` for verbose output
5. **Verify connectivity** - Test SSH connection manually before automation
6. **Read full logs** - Don't truncate error messages, read everything
7. **Check Proxmox logs** - `/var/log/pve/` contains useful diagnostics

---

## Recovery Strategies

### If VM Creation Fails Midway

The `proxmox.sh` script has automatic cleanup on error:
```bash
# Cleanup function runs on EXIT with non-zero code
cleanup_on_error() {
    if [[ $exit_code -ne 0 && -n "${ALLOCATED_VM_ID:-}" ]]; then
        qm stop "${ALLOCATED_VM_ID}"
        qm destroy "${ALLOCATED_VM_ID}"
    fi
}
```

**Manual cleanup if needed:**
```bash
# List all VMs
ssh root@192.168.101.155 "qm list"

# Destroy failed VM
ssh root@192.168.101.155 "qm stop 113 && qm destroy 113"
```

### If Script Hangs

1. **Check TMUX session** (if using Level 3):
   ```bash
   ssh root@192.168.101.155 "tmux list-sessions"
   ssh root@192.168.101.155 "tmux attach -t session-name"
   ```

2. **Kill background process**:
   ```bash
   ssh root@192.168.101.155 "pkill -f proxmox.sh"
   ```

3. **Check for interactive prompts** (should never happen with Level 1 automation):
   ```bash
   ssh root@192.168.101.155 "ps aux | grep proxmox.sh"
   ```
