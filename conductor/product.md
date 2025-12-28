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

### MVP (v1.0)

1. **VM Provisioning**
   - Create VMs on Proxmox, AWS EC2, or QEMU
   - Configure CPU, RAM, storage
   - Assign network/IP

2. **OS Bootstrapping**
   - Ubuntu 24.04 LTS
   - AlmaLinux 9.x
   - Rocky Linux 9.x
   - AWS Linux 2023

3. **Basic Configuration**
   - Essential packages
   - Development tools (Python, Node, Docker)
   - SSH access setup

4. **MCP Integration**
   - Remote execution via 8bit-wraith SSH server
   - Persistent TMUX sessions
   - File transfer support

5. **Dual-Agent Support**
   - Claude Skill package
   - Gemini Conductor context
   - Shared source-of-truth scripts

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

## Timeline

- Phase 0: Foundation (~30 min)
- Phase 1: MCP SSH Setup (~1 hour)
- Phase 2: Provisioning Scripts (~2 hours)
- Phase 3: Agent Integration (~1.5 hours)
- Phase 4: Local Dev UI (~1 hour)
- Phase 5: Documentation (~1 hour)

**Total: ~7 hours across 5-8 sessions**
