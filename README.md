# Linus Deployment Specialist

> One-shot Linux environment provisioning for AI agent development and QA

[![Status](https://img.shields.io/badge/status-in_development-yellow)]()
[![License](https://img.shields.io/badge/license-MIT-blue)]()

## What is This?

**Linus Deployment Specialist** is an infrastructure automation tool that enables AI agents (Claude and Gemini) to provision ephemeral Linux environments for testing and development. 

Instead of manually creating VMs, you can simply tell your AI assistant:

> "Create an Ubuntu 24.04 VM with Python, Node.js, and Docker on Proxmox"

And get back a ready-to-use SSH connection.

## Features

- **Multi-Provider Support**: Proxmox, AWS EC2, QEMU/libvirt
- **Multi-OS Support**: Ubuntu, AlmaLinux, Rocky Linux, AWS Linux
- **Dual-Agent Compatible**: Works with both Claude (via Skills) and Gemini CLI (via Conductor)
- **MCP Integration**: Uses 8bit-wraith's enhanced SSH server for persistent sessions
- **Ephemeral by Design**: Create, use, delete - no long-term maintenance

## Quick Start

### Prerequisites

- Node.js 18+
- SSH access to your VM provider (Proxmox/AWS/QEMU host)
- Provider credentials configured

### Installation

```bash
# Clone the repository
git clone https://github.com/YOUR_USERNAME/linus-deployment-specialist.git
cd linus-deployment-specialist

# Install MCP SSH server
npm install -g @essential-mcp/server-enhanced-ssh

# Run setup
./mcp-config/ssh-server-setup.sh
```

### For Claude Users

1. Copy `skill/` directory to your Claude Skills location
2. Configure MCP server in Claude's settings using `mcp-config/claude-mcp.json`
3. Ask Claude: "Create a Ubuntu VM on Proxmox"

### For Gemini Users

1. Install Conductor extension: `gemini extensions install https://github.com/gemini-cli-extensions/conductor`
2. Initialize project: `cd linus-deployment-specialist && /conductor:setup`
3. Add MCP server: `gemini mcp add linus-ssh -- mcp-ssh-server`
4. Start working: `/conductor:newTrack "Create Ubuntu VM"`

## Project Structure

```
linus-deployment-specialist/
├── skill/                 # Claude Skill package
├── conductor/             # Gemini Conductor context
├── shared/                # Cross-agent scripts (source of truth)
│   ├── provision/         # VM creation scripts
│   ├── bootstrap/         # OS setup scripts
│   ├── configure/         # Configuration scripts
│   └── lib/               # Shared utilities
├── mcp-config/            # MCP server configuration
├── web-ui/                # Local development UI
├── tests/                 # Test suites
└── docs/                  # Documentation
```

## Supported Platforms

| Provider | Status | Authentication |
|----------|--------|----------------|
| Proxmox | ✅ Supported | API Token |
| AWS EC2 | ✅ Supported | IAM/CLI |
| QEMU/libvirt | ✅ Supported | Local socket |

| Operating System | Version | Status |
|------------------|---------|--------|
| Ubuntu | 24.04 LTS | ✅ Supported |
| AlmaLinux | 9.x | ✅ Supported |
| Rocky Linux | 9.x | ✅ Supported |
| AWS Linux | 2023 | ✅ Supported |

## Documentation

- [Quick Start Guide](docs/QUICKSTART.md)
- [GitHub Setup Instructions](docs/GITHUB-SETUP.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)

## For Developers

This project was built using a "Self-Assembling" methodology where AI agents perform implementation under human strategic guidance. The implementation is documented in:

- `01-MASTER-PRD.md` - Product requirements and architecture
- `02-AGENTIC-CODEX.md` - Instructions for AI worker agents
- `03-CONTEXT-PROTOCOL.md` - Multi-session context management
- `04-MICRO-PHASE-ROADMAP.md` - Atomic implementation steps

## Contributing

Contributions welcome! Please read the implementation documents to understand the project philosophy.

## License

MIT License - See [LICENSE](LICENSE) for details.

## Acknowledgments

- [8bit-wraith](https://github.com/8bit-wraith/mcp) for the enhanced MCP SSH server
- [Gemini CLI Conductor](https://github.com/gemini-cli-extensions/conductor) for context-driven development
- Anthropic and Google for Claude and Gemini

---

*Built with 🤖 by AI agents, supervised by humans*
