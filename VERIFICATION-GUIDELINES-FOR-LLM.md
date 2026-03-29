# Verification Guidelines for Current LLM

## Purpose

This document provides verification criteria for the current LLM (you) to ensure that a local coding model has successfully implemented the QA testing enhancements described in `QA-TESTING-ENHANCEMENTS-IMPLEMENTATION-GUIDE.md`.

**Verification Philosophy:** Trust but verify. Check both functionality and adherence to project standards.

---

## Verification Checklist Template

For each implemented feature, verify:

### ✅ Functional Requirements
- [ ] Script executes without errors
- [ ] Exit codes follow documented scheme (0=success)
- [ ] Output includes required `LINUS_*` markers
- [ ] Handles edge cases and errors gracefully

### ✅ Code Quality  
- [ ] Follows existing project patterns and style
- [ ] Sources shared libraries (logging.sh, validation.sh)
- [ ] Uses `set -euo pipefail` and `IFS=$'\n\t'`
- [ ] Has proper function documentation
- [ ] Includes usage examples in comments

### ✅ Integration
- [ ] Works with all three providers (Proxmox, AWS, QEMU)
- [ ] Compatible with existing bootstrap/configure scripts
- [ ] Added to appropriate documentation
- [ ] Included in test suite where applicable

### ✅ Testing
- [ ] Has corresponding test file
- [ ] Tests pass successfully
- [ ] Handles both success and failure cases

---

## Task-Specific Verification Criteria

### Task 1: Artifact Deployment Script (`shared/deploy/artifact.sh`)

**Commands to run:**
```bash
# 1. Check script exists and is executable
test -f shared/deploy/artifact.sh && echo "✅ Script exists"
test -x shared/deploy/artifact.sh && echo "✅ Script executable"

# 2. Check script structure
head -20 shared/deploy/artifact.sh | grep -q "LINUS_RESULT" && echo "✅ Output markers present"

# 3. Test with dry-run mode (if implemented)
export TARGET_IP="127.0.0.1"
export TARGET_USER="test"
export SOURCE_PATH="/tmp/test-file"
touch /tmp/test-file
./shared/deploy/artifact.sh --dry-run 2>&1 | grep -q "LINUS_RESULT" && echo "✅ Dry-run works"

# 4. Check error handling
unset TARGET_IP
./shared/deploy/artifact.sh 2>&1 | grep -q "LINUS_RESULT:FAILURE" && echo "✅ Error handling works"
```

**Manual checks:**
- [ ] Supports both `scp` and `rsync` with fallback
- [ ] Has progress reporting for large files
- [ ] Includes retry logic for network issues
- [ ] Preserves file permissions

### Task 2: Test Execution Script (`shared/test/runner.sh`)

**Commands to run:**
```bash
# 1. Basic validation
test -f shared/test/runner.sh && echo "✅ Script exists"

# 2. Test timeout handling (should exit within 5 seconds)
timeout 5 ./shared/test/runner.sh --test-command="sleep 10" 2>&1 | grep -q "timeout" && echo "✅ Timeout works"

# 3. Check JUnit output support
./shared/test/runner.sh --help 2>&1 | grep -q "junit" && echo "✅ JUnit support mentioned"
```

**Manual checks:**
- [ ] Captures both stdout and stderr
- [ ] Generates JUnit XML when requested
- [ ] Properly propagates test exit codes
- [ ] Includes test duration measurement

### Task 3: VM Teardown Script (`shared/provision/destroy.sh`)

**Commands to run:**
```bash
# 1. Verify unified interface
grep -q "PROVIDER=" shared/provision/destroy.sh && echo "✅ Provider parameter exists"

# 2. Check safety features
grep -q "confirmation" shared/provision/destroy.sh && echo "✅ Has confirmation logic"
grep -q "force" shared/provision/destroy.sh && echo "✅ Has force flag"

# 3. Verify provider implementations
grep -q "qm destroy" shared/provision/destroy.sh && echo "✅ Proxmox support"
grep -q "aws ec2 terminate" shared/provision/destroy.sh && echo "✅ AWS support"
grep -q "virsh destroy" shared/provision/destroy.sh && echo "✅ QEMU support"
```

**Manual checks:**
- [ ] Graceful shutdown before force destroy
- [ ] Resource cleanup verification
- [ ] Proper error messages for missing VMs

### Task 4: Workflow Orchestrator (`workflows/qa-testing.sh`)

**Commands to run:**
```bash
# 1. Check workflow exists
test -f workflows/qa-testing.sh && echo "✅ Workflow exists"

# 2. Test help output
./workflows/qa-testing.sh --help 2>&1 | grep -q "Usage:" && echo "✅ Help works"

# 3. Verify stage-based execution
grep -q "Stage" workflows/qa-testing.sh && echo "✅ Stage-based design"

# 4. Check configuration file support
grep -q "config" workflows/qa-testing.sh && echo "✅ Config file support"
```

**Manual checks:**
- [ ] Supports both CLI flags and config files
- [ ] Has rollback on stage failure
- [ ] Produces comprehensive final report
- [ ] Cleanup option works correctly

### Task 5: Multi-VM Provisioning (`shared/provision/multi-vm.sh`)

**Verification:**
```bash
# Check VM count parameter
grep -q "VM_COUNT" shared/provision/multi-vm.sh && echo "✅ VM count parameter"

# Check network configuration
grep -q "NETWORK_CONFIG" shared/provision/multi-vm.sh && echo "✅ Network config"

# Verify output format includes multiple VMs
grep -q "LINUS_VM_.*_IP" shared/provision/multi-vm.sh && echo "✅ Multi-VM output format"
```

**Manual checks:**
- [ ] Creates sequential hostnames
- [ ] Configures private networking between VMs
- [ ] Cleanup destroys all VMs

### Task 6: Snapshot System (`shared/snapshot/`)

**Verification:**
```bash
# Check all snapshot scripts exist
test -f shared/snapshot/save-snapshot.sh && echo "✅ Save script"
test -f shared/snapshot/restore-snapshot.sh && echo "✅ Restore script"
test -f shared/snapshot/list-snapshots.sh && echo "✅ List script"

# Verify provider support
grep -l "qm snapshot" shared/snapshot/*.sh && echo "✅ Proxmox snapshot"
```

### Task 7: Network Configuration (`shared/network/`)

**Verification:**
```bash
# Check network scripts
ls shared/network/*.sh 2>/dev/null && echo "✅ Network scripts exist"

# Verify port forwarding
grep -r "port.*forward" shared/network/ && echo "✅ Port forwarding"
```

### Task 8: Result Dashboard (`scripts/generate-report.sh`)

**Verification:**
```bash
# Test report generation
./scripts/generate-report.sh --test 2>&1 | grep -q "HTML" && echo "✅ HTML output"

# Check historical data support
grep -q "historical" scripts/generate-report.sh && echo "✅ Historical comparison"
```

---

## Cross-Cutting Verification

### Documentation Updates

**Check these files were updated:**
```bash
# AGENT-GUIDE.md
grep -q "artifact deployment" AGENT-GUIDE.md && echo "✅ AGENT-GUIDE updated"
grep -q "test execution" AGENT-GUIDE.md && echo "✅ Test workflow documented"

# SKILL.md  
grep -q "deploy.*artifact" skill/SKILL.md && echo "✅ Skill updated"

# README.md
grep -q "QA testing" README.md && echo "✅ README mentions QA testing"

# CONFIGURATION.md
grep -q "workflow" CONFIGURATION.md && echo "✅ Configuration docs updated"
```

### Test Suite Integration

**Verify tests exist and pass:**
```bash
# Run smoke tests (should include new scripts)
./tests/smoke/test-all-scripts.sh 2>&1 | tail -5 | grep -q "PASS" && echo "✅ Smoke tests pass"

# Check for new integration tests
find tests/integration -name "*artifact*" -o -name "*test-runner*" | head -2 && echo "✅ Integration tests exist"

# Run specific new tests
for test in tests/integration/test-*.sh; do
    echo "Running $test..."
    bash "$test" 2>&1 | tail -1 | grep -q "PASS\|SUCCESS" && echo "✅ $test passes"
done
```

### Code Quality Standards

**Run automated checks:**
```bash
# Syntax check all new scripts
for script in shared/deploy/*.sh shared/test/*.sh workflows/*.sh; do
    bash -n "$script" && echo "✅ $script syntax OK"
done

# Check for bash version compatibility
grep -r "bash --version" shared/deploy/ shared/test/ workflows/ && echo "✅ Bash version checks"

# Verify no hardcoded credentials
grep -r "password\|secret\|key" shared/deploy/ shared/test/ workflows/ | grep -v "SSH_KEY\|comment" && echo "⚠ Check for secrets"
```

### Agent Compatibility

**Verify parseable output:**
```bash
# Test each script's output format
for script in shared/deploy/artifact.sh shared/test/runner.sh shared/provision/destroy.sh; do
    echo "Testing $script..."
    # Mock environment and run
    export TARGET_IP="test"
    export TARGET_USER="test"
    timeout 2 bash "$script" --help 2>&1 | head -5 | grep -q "LINUS\|Usage" && echo "✅ $script has proper output"
done
```

---

## Verification Workflow

### Step 1: Initial Scan
1. **Directory structure:** Check all expected directories exist
2. **File existence:** All required scripts are present
3. **Permissions:** Scripts are executable (755)

### Step 2: Code Review
1. **Pattern adherence:** Matches existing project style
2. **Error handling:** Comprehensive try/catch/retry
3. **Documentation:** In-script comments and usage examples
4. **Provider support:** Works with Proxmox, AWS, QEMU

### Step 3: Functional Testing
1. **Dry-run tests:** Execute with `--dry-run` or `--help`
2. **Error case tests:** Trigger missing parameter errors
3. **Integration tests:** Run provided test suites
4. **End-to-end:** If environment permits, full workflow test

### Step 4: Integration Verification
1. **Documentation:** Check updates to guides
2. **Skill/Conductor:** Updated for AI agent usage
3. **Test suite:** New tests added and passing
4. **Dependencies:** No breaking changes to existing features

### Step 5: Final Validation
1. **Agent workflow test:** Simulate agent using new features
2. **Output parsing:** Ensure `LINUS_*` markers work
3. **Performance:** Scripts complete in reasonable time
4. **Resource cleanup:** No leftover files or processes

---

## Acceptance Criteria Summary

The implementation is acceptable when:

### ✅ Must Have (Blocking)
1. All high-priority tasks (1-4) implemented and functional
2. Scripts follow project patterns and coding standards
3. Comprehensive error handling and useful error messages
4. Proper `LINUS_*` output markers for agent parsing
5. Documentation updated (AGENT-GUIDE.md, SKILL.md)
6. Integration tests exist and pass

### ✅ Should Have (Important)
1. Medium-priority tasks (5-7) at least partially implemented
2. Works with all three providers where applicable
3. Reasonable performance (no infinite loops, proper timeouts)
4. Clean code structure with separation of concerns
5. Added to test suite (`run-all-tests.sh` includes them)

### ✅ Nice to Have (Optional)
1. Low-priority tasks implemented
2. Advanced features like HTML reports
3. CI/CD integration examples
4. Performance benchmarking

---

## Common Failure Modes to Watch For

### ❌ Code Quality Issues
- Missing error handling (`set -e` but no trap for cleanup)
- Hardcoded paths or assumptions
- Inconsistent logging (mix of `echo` and `log_info`)
- No usage documentation in script header

### ❌ Integration Issues
- Breaking existing functionality
- Missing provider support (only implements for one provider)
- Not sourcing shared libraries
- Conflicts with existing environment variables

### ❌ Testing Issues
- No tests for new features
- Tests don't actually verify functionality
- Tests require full infrastructure (should have mock mode)

### ❌ Documentation Issues
- Usage examples don't match actual parameters
- Missing from AGENT-GUIDE.md
- Skill/Conductor not updated for AI agents

---

## Verification Command Cheat Sheet

```bash
# Quick verification of all new scripts
find shared/deploy/ shared/test/ workflows/ -name "*.sh" -exec bash -n {} \; && echo "✅ All scripts syntax OK"

# Check for required output markers
grep -r "LINUS_RESULT:" shared/deploy/ shared/test/ workflows/ && echo "✅ Output markers present"

# Test dry-run/help for all scripts
for script in $(find shared/deploy/ shared/test/ workflows/ -name "*.sh"); do
    timeout 3 bash "$script" --help 2>&1 | head -2 && echo "✅ $script help works"
done

# Run integration tests
cd tests && ./run-all-tests.sh --integration-only 2>&1 | tail -10
```

---

## Final Sign-off Checklist

Before considering the implementation complete:

- [ ] All high-priority tasks implemented
- [ ] All scripts pass syntax check (`bash -n`)
- [ ] Integration tests pass
- [ ] Documentation updated
- [ ] Skill/Conductor files updated
- [ ] No breaking changes to existing features
- [ ] Output format compatible with agent parsing
- [ ] Code follows project patterns
- [ ] Added to appropriate test suites
- [ ] Verification commands in this document pass

---

**Verification completed by:** [LLM Name/Date]  
**Implementation status:** ✅ ACCEPTED / ❌ NEEDS REVISION  
**Notes:** [Any observations or issues found]