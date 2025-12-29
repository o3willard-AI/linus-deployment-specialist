# Phase 2 Enhancements Plan

**Created:** 2025-12-29
**Purpose:** Enhance core functionality with bootstrap scripts, testing, and additional providers

---

## Scope

### In Scope (v1.0 Completion)
1. ✅ **Bootstrap Scripts** - Make provisioned VMs actually useful
   - Ubuntu bootstrap (base packages)
   - Development tools installer (Python, Node.js, Docker)
   - Configuration scripts (SSH hardening, basic firewall)

2. ✅ **Automated Testing** - Ensure reliability
   - Smoke tests for all scripts
   - Integration tests for Proxmox provisioning
   - E2E test for full provision + bootstrap workflow

3. ⏳ **Documentation Updates** - Keep docs current
   - Update SKILL.md with bootstrap workflows
   - Add bootstrap examples
   - Update state.json

### Deferred (v1.1)
- ❌ AWS provider support (requires AWS account/credentials)
- ❌ QEMU provider support (requires local libvirt setup)
- ❌ AlmaLinux/Rocky bootstrap scripts (no immediate need)

---

## Implementation Order

### Priority 1: Bootstrap Scripts (Most Value)
**Rationale:** Proxmox provisioning works, but VMs are bare. Bootstrap makes them usable.

**Deliverables:**
1. `shared/bootstrap/ubuntu.sh` - OS-level bootstrap
   - Update package lists
   - Install essential packages (curl, wget, git, vim, tmux, htop)
   - Configure timezone, locale
   - Set up non-root user (if needed)
   - Output: `LINUS_RESULT:SUCCESS`

2. `shared/configure/dev-tools.sh` - Development environment
   - Install Python 3.12 + pip + venv
   - Install Node.js 22 LTS via NodeSource
   - Install Docker + docker-compose
   - Add user to docker group
   - Output: `LINUS_RESULT:SUCCESS`

3. `shared/configure/base-packages.sh` - Common utilities
   - build-essential, make, gcc, g++
   - openssl, ca-certificates
   - net-tools, iputils-ping, dnsutils
   - jq, unzip, zip

4. `shared/configure/ssh-hardening.sh` (Optional - Basic)
   - Disable password authentication (key-only)
   - Change SSH port (optional via env var)
   - Set up fail2ban (basic config)

**Success Criteria:**
- Bootstrap Ubuntu VM in < 3 minutes
- All packages install non-interactively (Level 1 automation)
- Scripts are idempotent (safe to run multiple times)
- Works with MCP ssh-mcp (no interactive prompts)

---

### Priority 2: Automated Testing (Quality Assurance)
**Rationale:** Need confidence that scripts work reliably.

**Deliverables:**
1. `tests/smoke/test-all-scripts.sh` - Syntax validation
   - Test all .sh files with `bash -n`
   - Check for common errors (missing shebangs, etc.)
   - Fast (< 5 seconds)

2. `tests/integration/test-proxmox-provision.sh` - Live test
   - Provision actual VM on Proxmox
   - Verify VM created with correct specs
   - Verify SSH accessibility
   - Clean up (destroy VM) after test
   - Duration: ~2 minutes

3. `tests/e2e/test-full-workflow.sh` - End-to-end
   - Provision VM
   - Bootstrap with ubuntu.sh
   - Install dev-tools.sh
   - Verify all tools installed (python3 --version, node --version, docker --version)
   - Clean up
   - Duration: ~5 minutes

4. `tests/run-all-tests.sh` - Test runner
   - Run smoke tests first
   - Run integration tests if smoke passes
   - Run E2E tests if integration passes
   - Generate test report

**Success Criteria:**
- All tests pass consistently
- Tests are automated (no manual intervention)
- Tests clean up after themselves
- Test output is parseable (for CI/CD later)

---

### Priority 3: Documentation Updates
**Rationale:** Keep agent integration current with new capabilities.

**Deliverables:**
1. Update `skill/SKILL.md`:
   - Add "Bootstrap VM" operation section
   - Add "Full Deployment" workflow examples
   - Update verification requirements

2. Create `skill/examples/example-04-full-deployment.md`:
   - Provision + Bootstrap + Dev Tools
   - Complete walkthrough with timing
   - Troubleshooting tips

3. Update `.context/state.json`:
   - Mark bootstrap scripts complete
   - Update milestone count
   - Update completion percentage

4. Update `conductor/product.md`:
   - Mark bootstrap as ✅ IMPLEMENTED
   - Update success criteria

---

## Detailed Script Specifications

### 1. shared/bootstrap/ubuntu.sh

**Purpose:** Initial OS-level setup for Ubuntu 24.04 LTS

**Environment Variables:**
```bash
TIMEZONE="${TIMEZONE:-UTC}"                    # System timezone
LOCALE="${LOCALE:-en_US.UTF-8}"               # System locale
INSTALL_EXTRAS="${INSTALL_EXTRAS:-false}"     # Install optional packages
```

**Operations:**
1. Update package cache (`apt-get update`)
2. Upgrade existing packages (`apt-get upgrade -y`)
3. Install essential packages:
   - curl, wget, git, vim, nano, tmux, screen
   - htop, ncdu, tree
   - build-essential (if INSTALL_EXTRAS=true)
4. Configure timezone (`timedatectl set-timezone`)
5. Configure locale (`locale-gen`, `update-locale`)
6. Clean up (`apt-get autoremove`, `apt-get clean`)

**Automation Level:** Level 1 (direct non-interactive flags)

**Exit Codes:**
- 0: Success
- 1: General error
- 2: Missing dependencies (apt-get not found)
- 6: Bootstrap failed

**Output:**
```
LINUS_RESULT:SUCCESS
LINUS_PACKAGES_INSTALLED:curl,wget,git,vim,tmux,htop
LINUS_TIMEZONE:UTC
LINUS_LOCALE:en_US.UTF-8
```

**Testing:**
```bash
# Smoke test
bash -n shared/bootstrap/ubuntu.sh

# Integration test (requires Ubuntu VM)
ssh ubuntu@192.168.101.113 "bash" < shared/bootstrap/ubuntu.sh

# Verify
ssh ubuntu@192.168.101.113 "curl --version && git --version && tmux -V"
```

---

### 2. shared/configure/dev-tools.sh

**Purpose:** Install development tools (Python, Node.js, Docker)

**Environment Variables:**
```bash
PYTHON_VERSION="${PYTHON_VERSION:-3.12}"
NODE_VERSION="${NODE_VERSION:-22}"
INSTALL_DOCKER="${INSTALL_DOCKER:-true}"
DOCKER_USER="${DOCKER_USER:-ubuntu}"
```

**Operations:**
1. Install Python:
   - `apt-get install -y python3 python3-pip python3-venv`
   - Verify: `python3 --version`

2. Install Node.js:
   - Add NodeSource repository
   - `apt-get install -y nodejs`
   - Verify: `node --version && npm --version`

3. Install Docker (if INSTALL_DOCKER=true):
   - Add Docker GPG key
   - Add Docker repository
   - `apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin`
   - Add user to docker group: `usermod -aG docker $DOCKER_USER`
   - Start and enable docker service
   - Verify: `docker --version`

**Automation Level:** Level 2 (use noninteractive.sh wrappers for cross-distro)

**Exit Codes:**
- 0: Success
- 1: General error
- 2: Missing dependencies
- 6: Installation failed

**Output:**
```
LINUS_RESULT:SUCCESS
LINUS_PYTHON_VERSION:3.12.0
LINUS_NODE_VERSION:22.11.0
LINUS_DOCKER_VERSION:24.0.7
LINUS_DOCKER_USER:ubuntu
```

---

### 3. shared/configure/base-packages.sh

**Purpose:** Install common build tools and utilities

**Environment Variables:**
```bash
INSTALL_BUILD_TOOLS="${INSTALL_BUILD_TOOLS:-true}"
INSTALL_NETWORK_TOOLS="${INSTALL_NETWORK_TOOLS:-true}"
```

**Operations:**
1. Build tools (if enabled):
   - build-essential, make, cmake
   - gcc, g++, gdb

2. SSL/Crypto:
   - openssl, ca-certificates
   - libssl-dev

3. Network tools (if enabled):
   - net-tools, iputils-ping, dnsutils
   - netcat, telnet, traceroute

4. Utilities:
   - jq, unzip, zip, tar
   - rsync, less, which

**Automation Level:** Level 1

**Output:**
```
LINUS_RESULT:SUCCESS
LINUS_BUILD_TOOLS:installed
LINUS_NETWORK_TOOLS:installed
```

---

## Testing Strategy

### Smoke Tests (Fast Validation)
```bash
#!/usr/bin/env bash
# tests/smoke/test-all-scripts.sh

set -e

echo "=== Smoke Tests: Syntax Validation ==="

scripts=(
    "shared/provision/proxmox.sh"
    "shared/bootstrap/ubuntu.sh"
    "shared/configure/dev-tools.sh"
    "shared/configure/base-packages.sh"
    "shared/lib/logging.sh"
    "shared/lib/validation.sh"
    "shared/lib/noninteractive.sh"
    "shared/lib/tmux-helper.sh"
)

failed=0
for script in "${scripts[@]}"; do
    if bash -n "$script" 2>/dev/null; then
        echo "✅ $script"
    else
        echo "❌ $script - SYNTAX ERROR"
        ((failed++))
    fi
done

if [[ $failed -eq 0 ]]; then
    echo "✅ All smoke tests passed"
    exit 0
else
    echo "❌ $failed script(s) failed smoke test"
    exit 1
fi
```

### Integration Tests (Real Operations)
```bash
#!/usr/bin/env bash
# tests/integration/test-bootstrap-ubuntu.sh

set -euo pipefail

echo "=== Integration Test: Ubuntu Bootstrap ==="

# Requires: Live Ubuntu VM
VM_IP="${TEST_VM_IP:-192.168.101.113}"
VM_USER="${TEST_VM_USER:-ubuntu}"

echo "Testing against: $VM_USER@$VM_IP"

# Upload bootstrap script
scp shared/bootstrap/ubuntu.sh "$VM_USER@$VM_IP:/tmp/"

# Execute bootstrap
ssh "$VM_USER@$VM_IP" "sudo bash /tmp/ubuntu.sh"

# Verify installations
echo "Verifying packages..."
ssh "$VM_USER@$VM_IP" "curl --version" || { echo "❌ curl not installed"; exit 1; }
ssh "$VM_USER@$VM_IP" "git --version" || { echo "❌ git not installed"; exit 1; }
ssh "$VM_USER@$VM_IP" "tmux -V" || { echo "❌ tmux not installed"; exit 1; }

echo "✅ Bootstrap integration test passed"
```

### E2E Tests (Full Workflow)
```bash
#!/usr/bin/env bash
# tests/e2e/test-full-workflow.sh

set -euo pipefail

echo "=== E2E Test: Full Provision + Bootstrap + Dev Tools ==="

# Step 1: Provision VM
echo "[1/5] Provisioning VM..."
export VM_CPU=2
export VM_RAM=2048
export VM_DISK=20
./shared/provision/proxmox.sh > /tmp/provision-output.txt

# Parse VM details
VM_ID=$(grep "LINUS_VM_ID:" /tmp/provision-output.txt | cut -d: -f2)
VM_IP=$(grep "LINUS_VM_IP:" /tmp/provision-output.txt | cut -d: -f2)
VM_USER=$(grep "LINUS_VM_USER:" /tmp/provision-output.txt | cut -d: -f2)

echo "✅ VM provisioned: $VM_USER@$VM_IP (ID: $VM_ID)"

# Step 2: Bootstrap Ubuntu
echo "[2/5] Bootstrapping Ubuntu..."
scp shared/bootstrap/ubuntu.sh "$VM_USER@$VM_IP:/tmp/"
ssh "$VM_USER@$VM_IP" "sudo bash /tmp/ubuntu.sh"
echo "✅ Bootstrap complete"

# Step 3: Install dev tools
echo "[3/5] Installing dev tools..."
scp shared/configure/dev-tools.sh "$VM_USER@$VM_IP:/tmp/"
ssh "$VM_USER@$VM_IP" "sudo bash /tmp/dev-tools.sh"
echo "✅ Dev tools installed"

# Step 4: Verify installations
echo "[4/5] Verifying installations..."
ssh "$VM_USER@$VM_IP" "python3 --version && node --version && docker --version"
echo "✅ All tools verified"

# Step 5: Cleanup
echo "[5/5] Cleaning up test VM..."
ssh root@192.168.101.155 "qm stop $VM_ID && qm destroy $VM_ID"
echo "✅ Cleanup complete"

echo ""
echo "🎉 E2E Test PASSED"
```

---

## Success Criteria

| Criterion | Target | Verification |
|-----------|--------|--------------|
| Bootstrap Time | < 3 minutes | Time ubuntu.sh execution |
| Dev Tools Install | < 5 minutes | Time dev-tools.sh execution |
| Script Reliability | 100% pass rate | Run 10 times, all succeed |
| Idempotency | Safe to re-run | Run bootstrap twice, no errors |
| MCP Compatibility | No hangs/prompts | Execute via MCP ssh-mcp |
| Test Coverage | All scripts tested | Smoke + integration + E2E |

---

## Timeline Estimate

| Task | Duration | Dependencies |
|------|----------|--------------|
| Ubuntu bootstrap script | 30 min | None |
| Dev tools script | 45 min | Ubuntu bootstrap |
| Base packages script | 20 min | None |
| Smoke tests | 20 min | All scripts written |
| Integration tests | 30 min | Live VM access |
| E2E tests | 45 min | All scripts + tests |
| Documentation updates | 30 min | All complete |
| Testing & validation | 30 min | All complete |

**Total: ~4 hours**

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Package repo timeouts | Bootstrap fails | Add retry logic, use mirrors |
| Docker install complexity | Script too fragile | Use official Docker install script |
| Non-idempotent operations | Re-run causes errors | Check before install (dpkg -l) |
| MCP timeout on long installs | Bootstrap incomplete | Use Level 3 (TMUX) for >2 min ops |

---

## Next Steps

1. ✅ Create this plan document
2. Create `shared/bootstrap/ubuntu.sh`
3. Test ubuntu.sh on live VM
4. Create `shared/configure/dev-tools.sh`
5. Test dev-tools.sh on live VM
6. Create automated test suite
7. Run full test suite
8. Update documentation
9. Commit all enhancements

**Ready to proceed with implementation!**
