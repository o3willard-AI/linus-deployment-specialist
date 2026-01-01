# Linus Deployment Specialist - Product Context

## What We're Building

An infrastructure automation tool that enables AI agents to provision ephemeral Linux environments for development and QA testing of other AI agents.

## Problem Statement

AI agent developers waste significant time manually provisioning test environments. Each test cycle requires creating VMs, installing packages, configuring SSH, and tearing down - all manual, repetitive work that slows iteration.

## Solution

A tool where AI agents (Claude or Gemini) can:
1. Accept natural language environment requirements
2. Translate to infrastructure-as-code
3. Execute provisioning via MCP SSH server
4. Return ready-to-use credentials
5. Support ephemeral lifecycle (create → use → delete)

## Target Users

- AI agent developers testing their agents
- QA engineers needing disposable test environments  
- DevOps teams prototyping infrastructure

## Core Features

### MVP (v1.0) - Current Status

1. **VM Provisioning** ✅ **IMPLEMENTED**
   - ✅ Create VMs on Proxmox VE (full lifecycle)
   - ✅ AWS EC2 (full instance provisioning with auto-AMI detection)
   - ✅ QEMU/libvirt (cloud-init based provisioning)
   - ✅ Configure CPU, RAM, storage
   - ✅ Assign network/IP (QEMU agent + fallback nmap)

2. **OS Bootstrapping** ✅ **IMPLEMENTED**
   - ✅ Ubuntu 24.04 LTS (via cloud-init template)
   - ✅ ubuntu.sh - Essential packages, timezone, locale (330 lines, ~2 min)
   - ⏳ AlmaLinux 9.x (planned)
   - ⏳ Rocky Linux 9.x (planned)
   - ⏳ AWS Linux 2023 (planned)

3. **Basic Configuration** ✅ **IMPLEMENTED**
   - ✅ Essential packages (curl, wget, git, vim, tmux, htop, tree)
   - ✅ Development tools (dev-tools.sh: Python 3.12, Node.js 22, Docker CE)
   - ✅ Build tools (base-packages.sh: gcc, make, cmake, network utils)
   - ✅ SSH access setup (working via cloud-init)

4. **MCP Integration** ✅ **IMPLEMENTED**
   - ✅ Remote execution via ssh-mcp v1.4.0 (exec, sudo-exec tools)
   - ✅ Hybrid automation strategy (Level 1: non-interactive, Level 2: smart wrappers, Level 3: TMUX)
   - ⚠️ File transfer via base64 encoding (no native upload in ssh-mcp)

5. **Dual-Agent Support** ✅ **IMPLEMENTED**
   - ✅ Claude Skill package (SKILL.md with examples)
   - ✅ Gemini Conductor context (product.md, tech-stack.md, workflow.md)
   - ✅ Shared source-of-truth scripts (proxmox.sh, libraries)

## Non-Goals (v1.0)

- Production security hardening
- Long-running environment management
- Monitoring or alerting
- Multi-tenant isolation
- Windows support
- Automated teardown scheduling

## Success Criteria

| Metric | Target |
|--------|--------|
| Provision + Bootstrap Time | < 5 minutes |
| Success Rate | > 95% |
| Agent Compatibility | Works with Claude AND Gemini |
| Script Portability | Same scripts for all OS types |

## User Stories

### Story 1: Quick Dev Environment
> As an AI developer, I want to say "Create an Ubuntu VM with Python and Docker" and get working SSH credentials within 5 minutes.

### Story 2: Multi-Environment Testing
> As a QA engineer, I want to test my agent on different Linux distros by creating multiple VMs with identical configurations.

### Story 3: Clean Slate Testing
> As a developer, I want disposable environments so each test starts fresh without artifacts from previous runs.

## Constraints

- **Simplicity over Security**: These are dev/QA environments, not production
- **Reliability over Features**: Basic functionality that works every time
- **Agent-Autonomy**: Minimize human intervention after initial setup

## Risks

| Risk | Mitigation |
|------|------------|
| MCP server instability | Pin to specific version |
| Provider API changes | Abstract behind provider scripts |
| Context window overflow | Strict context protocol |

## Timeline (Updated)

**Completed Phases:**
- ✅ Phase 0: Foundation (completed 2025-12-27)
- ✅ Phase 1: MCP SSH Setup with ssh-mcp (completed 2025-12-28)
- ✅ Phase 2: Proxmox Provisioning + Automation Strategy (completed 2025-12-29)
- ✅ Phase 3: Agent Integration (completed 2025-12-29)
- ✅ Phase 4: AWS EC2 Provider (completed 2025-12-30)
- ✅ Phase 5: QEMU/libvirt Provider (completed 2025-12-31)

**Current Phase:**
- 🔄 Phase 6: Documentation & v1.0 Release (in progress)

**Progress: 31/48 milestones (64.6%)**

**Key Architectural Decisions:**
1. Using ssh-mcp v1.4.0 instead of @essential-mcp/server-enhanced-ssh (simpler, correct architecture)
2. Implemented hybrid three-level automation strategy to solve interactive prompt problem
3. Full deployment testing revealed 5 critical bugs in Proxmox - all fixed, Ubuntu + Proxmox validated production-ready
4. AWS EC2 provider implemented with auto-instance-type selection and AMI detection (2 bugs fixed)
5. QEMU/libvirt provider implemented with cloud-init support (2 critical bugs fixed during testing)
