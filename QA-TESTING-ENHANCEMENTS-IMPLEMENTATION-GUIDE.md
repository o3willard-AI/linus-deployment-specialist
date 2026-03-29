# QA Testing Enhancements - Implementation Guide for Local Coding Models

## Overview

This document provides detailed implementation instructions for enhancing Linus Deployment Specialist to better support AI agent QA testing workflows. Each task is broken down into explicit steps, file locations, and coding patterns that match the existing project structure.

**Target Audience:** Local coding models (smaller LLMs) implementing these features.

**Project Philosophy:** Simplicity > Security, Reliability > Features, Speed > Perfection

---

## Project Structure Reference

```
linus-deployment-specialist/
├── shared/
│   ├── lib/                    # Shared libraries (source these)
│   │   ├── logging.sh
│   │   ├── validation.sh
│   │   ├── noninteractive.sh
│   │   ├── tmux-helper.sh
│   │   └── mcp-helpers.sh
│   ├── provision/              # VM creation scripts
│   │   ├── proxmox.sh
│   │   ├── aws.sh
│   │   └── qemu.sh
│   ├── bootstrap/              # OS setup scripts
│   │   ├── ubuntu.sh
│   │   ├── almalinux.sh
│   │   └── rocky.sh
│   └── configure/              # Tool installation scripts
│       ├── dev-tools.sh
│       └── base-packages.sh
├── workflows/                  # NEW: High-level workflows
├── scripts/                    # Utility scripts
├── tests/                      # Test suites
└── examples/                   # Example usage
```

## Core Implementation Patterns

### 1. Script Template Pattern
All scripts should follow this template:

```bash
#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist - [SCRIPT PURPOSE]
# =============================================================================
# Purpose: [One-line description]
# Author: Linus Deployment Specialist (AI-generated)
# Version: 1.0
# Automation Level: [1, 2, or 3]
#
# Required Environment Variables:
#   VAR_NAME    - Description (default: value)
#
# Optional Environment Variables:
#   VAR_NAME    - Description (default: value)
#
# Usage:
#   ./script.sh [args]
#
# Exit Codes:
#   0 - Success
#   1 - General error
#   2 - Missing dependencies
#   [other] - See specific script
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source libraries (adjust path as needed)
source "${SCRIPT_DIR}/../lib/logging.sh"
source "${SCRIPT_DIR}/../lib/validation.sh"

# Configuration from environment with defaults
readonly VAR_NAME="${VAR_NAME:-default_value}"

# -----------------------------------------------------------------------------
# Functions
# -----------------------------------------------------------------------------

# Function naming: verb_noun (e.g., deploy_artifact, run_tests)
function my_function() {
    log_info "Starting my_function..."
    
    # Implementation here
    
    if [[ $? -eq 0 ]]; then
        log_info "my_function completed successfully"
        return 0
    else
        log_error "my_function failed"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Main Execution
# -----------------------------------------------------------------------------

main() {
    log_info "Starting $SCRIPT_NAME"
    
    # Validate prerequisites
    validate_ssh_available || return 2
    validate_command curl || return 2
    
    # Core logic
    my_function || return 1
    
    # Output success marker (required for agent parsing)
    echo "LINUS_RESULT:SUCCESS"
    echo "LINUS_SCRIPT:$SCRIPT_NAME"
    echo "LINUS_TIMESTAMP:$(date +%s)"
    
    log_info "$SCRIPT_NAME completed successfully"
    return 0
}

# Execute main only if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
```

### 2. Output Format Requirements
- **Success**: Must output `LINUS_RESULT:SUCCESS`
- **Failure**: Must output `LINUS_RESULT:FAILURE` with `LINUS_ERROR:description`
- **Key data**: Use `LINUS_` prefix for parseable outputs (e.g., `LINUS_VM_IP:192.168.1.10`)
- **Exit codes**: 0=success, non-zero=failure (match documented codes)

### 3. Error Handling Pattern
```bash
function safe_operation() {
    local attempt=1
    local max_attempts=3
    
    while [[ $attempt -le $max_attempts ]]; do
        if operation; then
            return 0
        fi
        log_warn "Attempt $attempt failed, retrying..."
        sleep 2
        ((attempt++))
    done
    log_error "Operation failed after $max_attempts attempts"
    return 1
}
```

---

## Task 1: Artifact Deployment Script (`deploy-artifact.sh`)

**Purpose:** Transfer application binaries, test files, or configuration to provisioned VMs.

**Location:** `shared/deploy/artifact.sh` (create `shared/deploy/` directory)

**Dependencies:**
- SSH access to target VM
- `scp` or `rsync` available locally
- Source files exist locally

**Implementation Steps:**

1. **Create directory structure:**
   ```bash
   mkdir -p shared/deploy
   ```

2. **Create `shared/deploy/artifact.sh` with:**
   - Required parameters: `TARGET_IP`, `TARGET_USER`, `SOURCE_PATH`
   - Optional: `TARGET_PATH` (default: `/home/$TARGET_USER/`)
   - Support both `scp` (fallback) and `rsync` (preferred)
   - Progress reporting with file counts and sizes
   - Checksum verification option

3. **Key features to implement:**
   - Recursive directory copying
   - Permission preservation
   - Large file handling (>100MB) with progress bar
   - Retry logic for network issues
   - Dry-run mode

4. **Example usage pattern:**
   ```bash
   # From agent after provisioning VM
   export TARGET_IP="192.168.1.10"
   export TARGET_USER="ubuntu"
   export SOURCE_PATH="./build/myapp.tar.gz"
   ./shared/deploy/artifact.sh
   ```

5. **Output requirements:**
   - `LINUS_ARTIFACT_COUNT:X` (number of files transferred)
   - `LINUS_ARTIFACT_SIZE:X` (total bytes)
   - `LINUS_ARTIFACT_TARGET:/path/on/vm`

**Testing:**
- Create test file: `tests/integration/test-deploy-artifact.sh`
- Test with local SSH loopback if possible
- Verify files appear on target with correct permissions

---

## Task 2: Test Execution Script (`run-tests.sh`)

**Purpose:** Execute test suites on remote VMs and capture results.

**Location:** `shared/test/runner.sh` (create `shared/test/` directory)

**Dependencies:**
- SSH access to target VM
- Test framework installed on VM (specify in docs)
- Artifacts deployed (if testing application)

**Implementation Steps:**

1. **Create `shared/test/runner.sh`:**
   - Required: `TARGET_IP`, `TARGET_USER`, `TEST_COMMAND`
   - Optional: `TEST_TIMEOUT` (default: 300s), `TEST_OUTPUT_DIR`
   - Support common test frameworks: pytest, jest, mocha, unittest

2. **Key features:**
   - Timeout handling with SIGTERM then SIGKILL
   - JUnit XML output capture (standard for CI)
   - Console log capture with timestamps
   - Exit code propagation
   - Test duration measurement

3. **Remote execution pattern:**
   ```bash
   # Use heredoc for complex commands
   ssh "$TARGET_USER@$TARGET_IP" << 'REMOTE_EOF'
   set -e
   cd /home/ubuntu/myapp
   python -m pytest tests/ --junitxml=test-results.xml
   REMOTE_EOF
   ```

4. **Result collection:**
   - Auto-scp of `test-results.xml` and logs
   - Parse XML for summary statistics
   - Output in parseable format

5. **Output requirements:**
   - `LINUS_TEST_RESULT:PASS|FAIL`
   - `LINUS_TEST_PASSED:X`
   - `LINUS_TEST_FAILED:X`
   - `LINUS_TEST_DURATION:X`
   - `LINUS_TEST_OUTPUT:/local/path/to/results`

**Testing:**
- Create mock test that passes/fails
- Test timeout handling
- Verify XML output parsing

---

## Task 3: VM Teardown Script (`destroy-vm.sh`)

**Purpose:** Explicit VM destruction (not just error cleanup).

**Location:** `shared/provision/destroy.sh` (in existing provision directory)

**Dependencies:**
- Provider credentials configured
- VM exists and is identifiable

**Implementation Steps:**

1. **Create `shared/provision/destroy.sh`:**
   - Unified interface for all providers
   - Required: `PROVIDER` (proxmox|aws|qemu), `VM_IDENTIFIER`
   - Optional: `FORCE` flag for running VMs

2. **Provider-specific implementations:**
   - Proxmox: `qm destroy $VM_ID`
   - AWS: `aws ec2 terminate-instances --instance-ids $INSTANCE_ID`
   - QEMU: `virsh destroy $VM_NAME && virsh undefine $VM_NAME`

3. **Safety features:**
   - Confirmation prompt (can be skipped with `-y` flag)
   - Pre-destroy snapshot option
   - Resource cleanup verification
   - Graceful shutdown attempt before force destroy

4. **Output requirements:**
   - `LINUS_DESTROY_RESULT:SUCCESS`
   - `LINUS_DESTROY_PROVIDER:X`
   - `LINUS_DESTROY_TIME:X`

**Testing:**
- Integration with each provider
- Test force vs graceful destruction
- Verify resource cleanup

---

## Task 4: Workflow Orchestrator (`orchestrate.sh`)

**Purpose:** Single command for full QA workflow: provision → deploy → test → destroy → report.

**Location:** `workflows/qa-testing.sh` (create `workflows/` directory)

**Dependencies:** All previous scripts (deploy, test, destroy)

**Implementation Steps:**

1. **Create `workflows/qa-testing.sh`:**
   - Command-line interface with flags
   - Configuration via environment or config file
   - Stage-by-stage execution with rollback on failure

2. **Stage implementation:**
   ```bash
   # Stage 1: Provision
   source shared/provision/$PROVIDER.sh
   VM_IP=$?
   
   # Stage 2: Bootstrap (wait for SSH)
   wait_for_ssh "$VM_IP"
   
   # Stage 3: Deploy artifacts
   export TARGET_IP="$VM_IP"
   ./shared/deploy/artifact.sh
   
   # Stage 4: Run tests
   ./shared/test/runner.sh
   
   # Stage 5: Collect results
   collect_results
   
   # Stage 6: Destroy (if CLEANUP=true)
   if [[ "$CLEANUP" == "true" ]]; then
       ./shared/provision/destroy.sh
   fi
   ```

3. **Configuration file support:**
   ```yaml
   # qa-config.yaml
   provider: proxmox
   vm_spec:
     cpu: 2
     ram: 4096
     disk: 40
   artifacts:
     - source: ./build/app.tar.gz
       target: /home/ubuntu/
   test_command: "cd /home/ubuntu && ./run-tests.sh"
   cleanup: true
   ```

4. **Output requirements:**
   - Stage-wise success/failure
   - Total duration
   - Test summary
   - Artifact location for results

**Testing:**
- End-to-end with mock artifacts
- Partial rollback testing
- Configuration file parsing

---

## Task 5: Multi-VM Provisioning

**Purpose:** Create N identical VMs for distributed system testing.

**Location:** `shared/provision/multi-vm.sh`

**Implementation Steps:**

1. **Create `shared/provision/multi-vm.sh`:**
   - Parameters: `VM_COUNT`, `BASE_NAME`, `NETWORK_CONFIG`
   - Sequential or parallel creation
   - Private networking between VMs

2. **Networking features:**
   - Create virtual network segment
   - Configure hostnames: `$BASE_NAME-1`, `$BASE_NAME-2`, etc.
   - Generate hosts file for intra-VM communication
   - Optional VPN setup for cross-provider

3. **Output format:**
   ```bash
   LINUS_VM_COUNT:3
   LINUS_VM_1_IP:192.168.1.10
   LINUS_VM_1_NAME:test-cluster-1
   LINUS_VM_2_IP:192.168.1.11
   # etc.
   ```

4. **Cleanup coordination:**
   - Destroy all VMs in reverse order
   - Network cleanup

---

## Task 6: Snapshot System

**Purpose:** Save/restore VM state for test isolation.

**Location:** `shared/snapshot/` directory

**Implementation:**

1. **`save-snapshot.sh`:**
   - Stop VM (if running)
   - Create provider snapshot
   - Store metadata (timestamp, description)

2. **`restore-snapshot.sh`:**
   - Revert to snapshot
   - Start VM

3. **`list-snapshots.sh`:**
   - Show available snapshots
   - Creation times, sizes

**Provider-specific notes:**
- Proxmox: `qm snapshot`
- QEMU: `virsh snapshot-create`
- AWS: AMI creation (more expensive)

---

## Task 7: Network Configuration

**Purpose:** Customize VM networking for service testing.

**Location:** `shared/network/` directory

**Features:**
1. **Port forwarding:** Map host ports to VM ports
2. **Firewall rules:** Open/close specific ports
3. **DNS configuration:** Custom resolv.conf
4. **VLAN support:** Isolated network segments

**Implementation:** Provider-specific APIs for network modification.

---

## Task 8: Result Dashboard

**Purpose:** Aggregate and visualize test results across multiple runs.

**Location:** `scripts/generate-report.sh`

**Features:**
1. **HTML report generation** with charts
2. **Historical comparison** across test runs
3. **Performance trends** (duration, resource usage)
4. **Failure analysis** (common failures, flaky tests)

**Output:** Static HTML file that can be served or archived.

---

## Implementation Priority Order

1. **High (Core QA workflow):**
   - Task 1: Artifact deployment
   - Task 2: Test execution  
   - Task 3: VM teardown
   - Task 4: Workflow orchestrator

2. **Medium (Enhanced testing):**
   - Task 5: Multi-VM provisioning
   - Task 6: Snapshot system
   - Task 7: Network configuration

3. **Low (Advanced features):**
   - Task 8: Result dashboard
   - CI/CD integration examples
   - Performance benchmarking
   - Distributed test coordination

---

## Testing Strategy for New Features

For each new script, create:

1. **Unit tests:** Test functions in isolation
2. **Integration tests:** Test with mock VMs
3. **E2E tests:** Full workflow with real provider (optional)

**Test location:** `tests/integration/test-<feature>.sh`

**Test pattern:**
```bash
#!/usr/bin/env bash
set -e

# Source the script being tested
source shared/deploy/artifact.sh

# Mock dependencies
function ssh() { echo "mock ssh: $@"; }
function scp() { echo "mock scp: $@"; }

# Test cases
test_deploy_single_file() {
    # Test logic
    assert "condition" "test description"
}
```

---

## Integration with Existing Codebase

### Adding to Documentation

Update these files after implementation:
1. **AGENT-GUIDE.md** - Add new workflow section
2. **SKILL.md** - Add new operations to skill definition
3. **README.md** - Update features list
4. **CONFIGURATION.md** - Add configuration options

### Adding to Test Suite

1. Update `tests/run-all-tests.sh` to include new tests
2. Add smoke test validation for new scripts
3. Update verification scripts if needed

### Version Management

1. Update `VERSION` file or inline version comments
2. Consider semver: minor version for new features
3. Update `.context/state.json` with new milestones

---

## Common Pitfalls to Avoid

1. **Hardcoded paths:** Use `SCRIPT_DIR` and environment variables
2. **Missing error handling:** Every external command should check `$?`
3. **Infinite loops:** Add timeouts to all wait operations
4. **Resource leaks:** Ensure cleanup on script exit
5. **Provider assumptions:** Support all three providers equally
6. **Output format violations:** Always emit `LINUS_RESULT:SUCCESS|FAILURE`

---

## Example Complete Workflow

Here's what the final agent workflow should look like:

```bash
# 1. Configure
export PROVIDER=proxmox
export VM_CPU=4
export VM_RAM=8192

# 2. Run full QA workflow
./workflows/qa-testing.sh \
  --provider=$PROVIDER \
  --artifact=./build/myapp.tar.gz \
  --test-command="cd /home/ubuntu && python -m pytest" \
  --cleanup

# 3. Check results
if grep -q "LINUS_TEST_RESULT:PASS" output.log; then
    echo "✅ Tests passed!"
else
    echo "❌ Tests failed"
    cat output.log | grep "LINUS_TEST_FAILED"
fi
```

---

## Success Criteria

A successful implementation will enable AI agents to:

1. Provision a VM with one command
2. Deploy their application artifacts automatically  
3. Execute test suites remotely
4. Capture and analyze results
5. Clean up resources reliably
6. Repeat the process with different configurations

All while maintaining the project's core principles of simplicity, reliability, and speed.

---

*Last updated: $(date)*  
*For questions, refer to existing scripts as reference implementations.*