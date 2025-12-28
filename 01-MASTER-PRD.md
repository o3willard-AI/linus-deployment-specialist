# Linus Deployment Specialist - Master PRD

## Product Requirements Document v1.0

**Project Codename:** Linus Deployment Specialist  
**Document Version:** 1.0  
**Created:** 2025-12-26  
**Status:** Ready for Implementation

---

## Executive Summary

**Linus Deployment Specialist** is a specialized infrastructure automation tool designed to provision and manage ephemeral Linux environments for the development and QA testing of AI agents. It enables "one-shot" environment creation through a hybrid architecture that supports both Claude (via Skills) and Gemini CLI (via Conductor).

### Core Value Proposition

> "Describe what you need, get a working Linux environment in minutes."

AI agent developers can request environments like:
- *"Create an Ubuntu 24.04 VM with Python 3.12, Node 22, and Docker for testing my chatbot agent"*
- *"Spin up three AlmaLinux instances on Proxmox for distributed testing"*
- *"Give me a QEMU VM with AWS Linux 2023 to test my deployment scripts"*

---

## Product Vision

### Problem Statement

AI agent developers waste significant time manually provisioning test environments. Each test cycle requires:
1. Creating VMs (via GUI or complex CLI)
2. Installing base packages
3. Configuring SSH access
4. Setting up development tools
5. Tearing down when complete

This friction slows iteration and discourages comprehensive testing.

### Solution

An automated system where AI agents (Claude or Gemini) can:
1. Accept natural language environment requirements
2. Translate to infrastructure-as-code
3. Execute provisioning via MCP SSH server
4. Return ready-to-use credentials
5. Support ephemeral lifecycle (create → use → delete)

---

## Stakeholders

| Role | Description | Primary Concern |
|------|-------------|-----------------|
| **Human Observer** | Project owner/supervisor | Progress tracking, decision points |
| **Claude Worker Agent** | AI executing via Claude Code/Skills | Clear instructions, verifiable outputs |
| **Gemini Worker Agent** | AI executing via Gemini CLI/Conductor | Context files, structured workflow |
| **End User** | Developer using the final tool | Simplicity, reliability |

---

## Technical Architecture

### Hybrid Architecture (Option C)

```
linus-deployment-specialist/
├── skill/                      # Claude Skill Package
│   ├── SKILL.md               # Claude's instruction file
│   └── examples/              # Usage examples for Claude
│
├── conductor/                  # Gemini Conductor Context
│   ├── product.md             # Product context
│   ├── tech-stack.md          # Technology decisions
│   ├── workflow.md            # Development workflow
│   └── tracks/                # Feature tracks
│
├── shared/                     # Cross-Agent Scripts (Source of Truth)
│   ├── provision/             # VM creation scripts
│   │   ├── proxmox.sh
│   │   ├── aws.sh
│   │   └── qemu.sh
│   ├── bootstrap/             # OS setup scripts
│   │   ├── ubuntu.sh
│   │   ├── almalinux.sh
│   │   ├── rocky.sh
│   │   └── aws-linux.sh
│   ├── configure/             # Common configuration
│   │   ├── base-packages.sh
│   │   ├── dev-tools.sh
│   │   └── ssh-hardening.sh
│   └── lib/                   # Shared utilities
│       ├── logging.sh
│       ├── validation.sh
│       └── mcp-helpers.sh
│
├── mcp-config/                 # MCP Server Configuration
│   ├── claude-mcp.json        # Claude MCP config
│   ├── gemini-mcp.json        # Gemini MCP config
│   └── ssh-server-setup.sh    # 8bit-wraith MCP SSH setup
│
├── web-ui/                     # Local Development UI (Phase 3)
│   ├── index.html
│   ├── api/
│   └── static/
│
├── tests/                      # Verification Scripts
│   ├── smoke/
│   ├── integration/
│   └── e2e/
│
└── docs/                       # Documentation
    ├── QUICKSTART.md
    ├── GITHUB-SETUP.md
    └── TROUBLESHOOTING.md
```

### Technology Stack

| Component | Technology | Rationale |
|-----------|------------|-----------|
| **MCP SSH Server** | `@essential-mcp/server-enhanced-ssh` | TMUX sessions, file transfer, persistent connections |
| **VM Providers** | Proxmox API, AWS CLI, QEMU/libvirt | Multi-cloud flexibility |
| **Target OS** | Ubuntu 24.04, AlmaLinux 9, Rocky 9, AWS Linux 2023 | Enterprise + cloud native coverage |
| **Scripting** | Bash (POSIX-compatible) | Universal, no dependencies |
| **Local UI** | HTML + vanilla JS | Zero build step, maximum simplicity |

---

## Feature Scope

### In Scope (MVP)

| Feature | Description | Priority |
|---------|-------------|----------|
| **VM Provisioning** | Create VMs on Proxmox, AWS EC2, QEMU | P0 |
| **OS Bootstrapping** | Install base OS, configure networking | P0 |
| **MCP SSH Integration** | Connect via 8bit-wraith enhanced SSH | P0 |
| **Basic Configuration** | Users, packages, SSH keys | P1 |
| **Claude Skill Package** | SKILL.md + supporting scripts | P0 |
| **Gemini Conductor Context** | product.md, tech-stack.md, workflow.md | P0 |
| **Local Web UI** | Trigger deployments during development | P2 |
| **GitHub Publishing** | Open source release instructions | P1 |

### Out of Scope (v1.0)

| Feature | Reason |
|---------|--------|
| Monitoring/Health Checks | Adds complexity, ephemeral environments don't need it |
| Automated Teardown | Manual deletion is sufficient for dev/QA |
| Enterprise Security | Priority is simplicity for agent development |
| Multi-tenant | Single-user tool for now |
| Windows Support | Linux-only per requirements |

---

## Definition of Done (DoD)

### Phase-Level DoD

Each phase is complete when:

1. **All micro-milestones verified** - Every step has passing verification
2. **Cross-agent tested** - Works with both Claude AND Gemini
3. **Documentation updated** - Relevant docs reflect current state
4. **Human checkpoint passed** - Observer confirms phase completion

### Project-Level DoD

The project is complete when:

1. ✅ MCP SSH server deploys and connects successfully
2. ✅ VMs can be created on all three providers (Proxmox, AWS, QEMU)
3. ✅ All four OS types bootstrap correctly
4. ✅ Claude Skill package works in Claude Code
5. ✅ Gemini Conductor context works in Gemini CLI
6. ✅ Local web UI triggers deployments
7. ✅ GitHub repository is published with documentation
8. ✅ End-to-end test passes: "Create Ubuntu VM on Proxmox" → working SSH session

---

## Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| **Provisioning Time** | < 5 minutes | Time from request to SSH-ready |
| **Success Rate** | > 95% | Successful provisions / total attempts |
| **Agent Compatibility** | 100% | Same scripts work for Claude AND Gemini |
| **Script Portability** | 100% | Scripts run on all target OS types |

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| MCP SSH server instability | Medium | High | Pin to specific version, document workarounds |
| Provider API changes | Low | Medium | Abstract behind provider scripts |
| Context window overflow | Medium | Medium | Strict context management protocol |
| Agent interpretation drift | High | Medium | Explicit verification at each step |

---

## Human Decision Points

The following require human input before proceeding:

| Decision Point | Phase | Question |
|----------------|-------|----------|
| **Provider Credentials** | 1 | Provide API keys/URLs for Proxmox, AWS, or QEMU |
| **Network Configuration** | 1 | Confirm SSH port, allowed IPs |
| **Resource Limits** | 2 | Max CPU, RAM, storage per VM |
| **GitHub Repository** | 4 | Confirm repo name, org, visibility |

---

## Glossary

| Term | Definition |
|------|------------|
| **MCP** | Model Context Protocol - Standardized way for AI to interact with external tools |
| **Skill** | Claude's mechanism for loading specialized instructions |
| **Conductor** | Gemini CLI extension for context-driven development |
| **Track** | Gemini Conductor's unit of work (feature or bug fix) |
| **Ephemeral** | Short-lived, disposable (environments created and deleted per session) |
| **Bootstrap** | Initial OS setup after VM creation |
| **Provision** | Creating the VM infrastructure itself |

---

## Appendix: Reference Links

- [8bit-wraith MCP Repository](https://github.com/8bit-wraith/mcp)
- [Gemini CLI Conductor](https://github.com/gemini-cli-extensions/conductor)
- [Proxmox API Documentation](https://pve.proxmox.com/wiki/Proxmox_VE_API)
- [AWS CLI EC2 Reference](https://docs.aws.amazon.com/cli/latest/reference/ec2/)
- [libvirt/QEMU Documentation](https://libvirt.org/docs.html)

---

**Document Owner:** Human Observer  
**Last Updated:** 2025-12-26  
**Next Review:** After Phase 1 completion
