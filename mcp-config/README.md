# MCP Configuration for Proxmox

## Setup Instructions

### For Claude Code

1. Add this MCP server to your Claude Code configuration:
   ```bash
   # Copy the config file to Claude's MCP settings
   cat mcp-config/proxmox-mcp-config.json
   ```

2. Or manually add to your Claude settings:
   - Open Claude Code settings
   - Navigate to MCP Servers
   - Add new server with the configuration from `proxmox-mcp-config.json`

### For Gemini CLI

1. Add MCP server:
   ```bash
   gemini mcp add linus-ssh -- ssh-mcp \
     --host=192.168.101.155 \
     --port=22 \
     --user=root \
     --key=/home/sblanken/.ssh/linus_proxmox \
     --timeout=120000 \
     --maxChars=none
   ```

2. Verify:
   ```bash
   gemini mcp list
   ```

## Testing the Connection

Once configured, test with these commands via your AI assistant:

1. **Test basic connectivity:**
   - Request: "Use the linus-ssh MCP server to run: hostname"
   - Expected: "moxy"

2. **Test Proxmox commands:**
   - Request: "Use the linus-ssh MCP server to run: pveversion"
   - Expected: "pve-manager/8.2.2/..."

3. **Test VM listing:**
   - Request: "Use the linus-ssh MCP server to run: qm list"
   - Expected: List of VMs

## Connection Details

- **Host:** 192.168.101.155
- **Node:** moxy
- **SSH User:** root
- **SSH Key:** /home/sblanken/.ssh/linus_proxmox
- **Timeout:** 120 seconds (for long operations)
- **Max Command Length:** Unlimited

## Proxmox Environment

- **Version:** pve-manager/8.2.2 (kernel 6.8.4-2-pve)
- **Available VM IDs:** 113+ (100-112 in use)
- **Templates:** VM 9000 (ubuntu-24.04-lts-template)
- **Storage:** local-lvm (default)
- **Network:** vmbr0 (default)
