# Linus Deployment Specialist - Testing Suite

Comprehensive automated testing for all provisioning and bootstrap scripts.

## Test Levels

### 1. Smoke Tests (Fast, No Requirements)
**Purpose:** Syntax validation of all shell scripts
**Duration:** < 5 seconds
**Requirements:** None (just bash)

```bash
./tests/smoke/test-all-scripts.sh
```

**What it tests:**
- Validates syntax of all `.sh` files using `bash -n`
- Catches syntax errors before deployment
- No VM or infrastructure required

**Scripts tested:**
- `shared/provision/proxmox.sh`
- `shared/bootstrap/ubuntu.sh`
- `shared/configure/dev-tools.sh`
- `shared/configure/base-packages.sh`
- All library files (`shared/lib/*.sh`)
- All example files (`examples/*.sh`)

---

### 2. Integration Tests (Requires Live VM)
**Purpose:** Test individual scripts on real infrastructure
**Duration:** 2-7 minutes per test
**Requirements:** Live Ubuntu VM with SSH access

#### Test 2.1: Bootstrap Ubuntu
```bash
export TEST_VM_IP=192.168.101.113
export TEST_VM_USER=ubuntu
./tests/integration/test-bootstrap-ubuntu.sh
```

**What it tests:**
- SSH connectivity to VM
- Uploads and executes `ubuntu.sh`
- Verifies package installations (curl, wget, git, vim, tmux, htop)
- Tests idempotency (can run multiple times)

**Expected duration:** ~2 minutes

#### Test 2.2: Dev Tools Installation
```bash
export TEST_VM_IP=192.168.101.113
export TEST_VM_USER=ubuntu
./tests/integration/test-dev-tools.sh
```

**What it tests:**
- Uploads libraries and `dev-tools.sh`
- Installs Python 3, Node.js 22, Docker
- Verifies all tools with version checks
- Confirms Docker service is running

**Expected duration:** ~5-7 minutes (Docker install takes time)

---

### 3. E2E Tests (Requires Proxmox)
**Purpose:** Test complete workflow from provision to fully configured VM
**Duration:** 8-10 minutes
**Requirements:** Proxmox host with SSH access, template VM configured

```bash
export PROXMOX_HOST=192.168.101.155
export PROXMOX_USER=root
./tests/e2e/test-full-workflow.sh
```

**What it tests:**
1. Provisions new VM on Proxmox (2 CPU, 2GB RAM, 20GB disk)
2. Bootstraps Ubuntu with essential packages
3. Installs development tools (Python, Node.js, Docker)
4. Installs base packages (build tools, utilities)
5. Verifies all installations (7 tools)
6. Performs system health check
7. Automatically cleans up test VM

**Expected duration:** ~8-10 minutes

**Cleanup:** Automatically destroys test VM on success or failure

---

## Running All Tests

### Quick Start
```bash
# Run all tests (smoke + integration + E2E)
./tests/run-all-tests.sh
```

### Run Specific Test Levels
```bash
# Only smoke tests (fast, no VM required)
./tests/run-all-tests.sh --smoke-only

# Only integration tests (requires VM)
./tests/run-all-tests.sh --integration-only

# Only E2E tests (requires Proxmox)
./tests/run-all-tests.sh --e2e-only
```

### Help
```bash
./tests/run-all-tests.sh --help
```

---

## Environment Variables

### Integration Tests
```bash
export TEST_VM_IP=192.168.101.113      # IP of test VM
export TEST_VM_USER=ubuntu             # SSH user (default: ubuntu)
export TEST_VM_SSH_KEY=$HOME/.ssh/id_rsa  # SSH private key path
```

### E2E Tests
```bash
export PROXMOX_HOST=192.168.101.155    # Proxmox host IP
export PROXMOX_USER=root               # Proxmox SSH user (default: root)
export PROXMOX_SSH_KEY=$HOME/.ssh/id_rsa  # SSH private key path
```

---

## Test Reports

Test results are automatically saved to:
```
tests/test-report-YYYYMMDD-HHMMSS.txt
```

Example report:
```
Linus Deployment Specialist - Test Report
==========================================
Date: 2025-12-29 01:30:45
Duration: 487s

Results:
- Passed:  5
- Failed:  0
- Skipped: 0

Configuration:
- Smoke Tests: true
- Integration Tests: true
- E2E Tests: true
```

---

## Test Structure

```
tests/
├── smoke/
│   └── test-all-scripts.sh          # Syntax validation
├── integration/
│   ├── test-bootstrap-ubuntu.sh     # Ubuntu bootstrap test
│   └── test-dev-tools.sh            # Dev tools installation test
├── e2e/
│   └── test-full-workflow.sh        # Full provision + bootstrap test
├── run-all-tests.sh                 # Main test runner
└── README.md                        # This file
```

---

## Prerequisites

### For Smoke Tests
- Bash 4.x+
- No other requirements

### For Integration Tests
- Live Ubuntu 24.04 LTS VM
- SSH access with key-based authentication
- VM should be freshly provisioned (or reset after each test)
- Sudo access for the test user

### For E2E Tests
- Proxmox VE host with SSH access
- Template VM configured (ID: 9000 by default)
- Sufficient resources to create test VM (2 CPU, 2GB RAM, 20GB disk)
- Network connectivity from test machine to Proxmox
- `pvesh`, `qm` commands available on Proxmox host

---

## CI/CD Integration

### GitHub Actions Example
```yaml
name: Test Suite

on: [push, pull_request]

jobs:
  smoke-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Run smoke tests
        run: ./tests/run-all-tests.sh --smoke-only

  integration-tests:
    runs-on: ubuntu-latest
    needs: smoke-tests
    steps:
      - uses: actions/checkout@v3
      - name: Set up test VM
        run: # Provision test VM
      - name: Run integration tests
        env:
          TEST_VM_IP: ${{ secrets.TEST_VM_IP }}
        run: ./tests/run-all-tests.sh --integration-only
```

---

## Troubleshooting

### Smoke Tests Fail
**Problem:** Syntax errors in scripts
**Solution:** Fix syntax errors reported by `bash -n`

### Integration Tests Can't Connect to VM
**Problem:** SSH connectivity issues
**Solution:**
1. Verify VM is running: `ping $TEST_VM_IP`
2. Verify SSH key: `ssh -i $TEST_VM_SSH_KEY ubuntu@$TEST_VM_IP`
3. Check firewall rules on VM
4. Ensure SSH service is running: `systemctl status sshd`

### Dev Tools Test Takes Too Long
**Problem:** Docker installation is slow
**Solution:**
- Normal - Docker install takes 3-5 minutes
- Use faster mirrors if needed
- Pre-install Docker on test VM to skip this step

### E2E Test Fails During Provisioning
**Problem:** Proxmox provisioning fails
**Solution:**
1. Verify Proxmox SSH access: `ssh root@$PROXMOX_HOST`
2. Check template VM exists: `qm status 9000`
3. Verify storage pool: `pvesm status`
4. Check available VM IDs: `qm list`

### E2E Test VM Not Cleaned Up
**Problem:** Test VM remains after failure
**Solution:**
```bash
# Manually destroy test VM
ssh root@$PROXMOX_HOST "qm stop <VM_ID> && qm destroy <VM_ID>"
```

---

## Best Practices

1. **Run smoke tests before committing**
   ```bash
   ./tests/smoke/test-all-scripts.sh && git commit
   ```

2. **Use dedicated test VM** - Don't run integration tests on production VMs

3. **Reset test VM between runs** - Ensures clean state for each test

4. **Monitor E2E tests** - They create and destroy VMs automatically

5. **Review test reports** - Check for patterns in failures

6. **Update tests when scripts change** - Keep tests in sync with implementation

---

## Adding New Tests

### Smoke Test
1. Add script path to `tests/smoke/test-all-scripts.sh`
2. Script will be automatically syntax-checked

### Integration Test
1. Create new file in `tests/integration/`
2. Follow existing test structure (steps, colors, verification)
3. Add to `tests/run-all-tests.sh` if needed

### E2E Test
1. Create new file in `tests/e2e/`
2. Include cleanup trap for VM destruction
3. Add comprehensive verification steps

---

## Performance Benchmarks

| Test Type | Duration | Requirements |
|-----------|----------|--------------|
| Smoke Tests | 5s | None |
| Integration: Bootstrap | 2 min | Live VM |
| Integration: Dev Tools | 5-7 min | Live VM |
| E2E: Full Workflow | 8-10 min | Proxmox |
| **Full Suite** | **15-20 min** | **All** |

---

## Exit Codes

All test scripts use consistent exit codes:

| Code | Meaning |
|------|---------|
| 0 | All tests passed |
| 1 | One or more tests failed |
| 2 | Missing dependencies |
| 3 | Invalid configuration |

---

## Support

For issues with the testing suite:
1. Check this README for troubleshooting steps
2. Review test output for specific error messages
3. Verify environment variables are set correctly
4. Ensure all prerequisites are met

For questions about specific tests, see inline comments in test scripts.
