# Linus Deployment Specialist - New Features Documentation

## Overview

This document describes the three major improvements made to the Linus Deployment Specialist:

1. **Snapshot Before Bootstrap** - Automatic snapshot creation for easy rollback
2. **Cleanup Verification** - Ensures VMs are fully destroyed after tests
3. **Resource Monitoring** - Tracks CPU, memory, and disk usage during bootstrap

---

## 1. Snapshot Before Bootstrap

### Purpose
Automatically create a snapshot before running bootstrap operations, enabling easy rollback if the bootstrap fails.

### New Scripts

#### `shared/snapshot/bootstrap-with-snapshot.sh`

A wrapper script that:
1. Creates a snapshot before bootstrap
2. Stores metadata about the snapshot operation
3. Offers automatic restore if bootstrap fails
4. Provides clean separation between provisioning and bootstrap phases

#### Usage

```bash
# Basic usage
./shared/snapshot/bootstrap-with-snapshot.sh ../shared/bootstrap/ubuntu.sh

# With custom timeout and options
BOOTSTRAP_TYPE=dev ./shared/snapshot/bootstrap-with-snapshot.sh ../shared/bootstrap/almalinux.sh TIMEZONE=America/New_York

# Capture the bootstrap output
OUTPUT=$(./shared/snapshot/bootstrap-with-snapshot.sh ../shared/bootstrap/ubuntu.sh 2>&1)
```

#### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `PROVIDER` | VM provider (proxmox\|aws\|qemu) | Required |
| `VM_IDENTIFIER` | VM ID or name | Required |
| `VM_IP` | VM IP address | Optional |
| `VM_NAME` | VM name | Optional |
| `BOOTSTRAP_TYPE` | Type of bootstrap (dev, prod, test) | `default` |
| `LINUS_SNAPSHOT_DIR` | Snapshot metadata directory | `/tmp/linus-snapshots` |
| `MAX_SNAPSHOT_AGE_DAYS` | Auto-cleanup old snapshots | `7` |

#### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error |
| 2 | Snapshot creation failed |
| 3 | Bootstrap failed (snapshot available for restore) |
| 4 | Restore failed |

#### Example Workflow

```bash
# Set up environment
export PROVIDER="proxmox"
export VM_IDENTIFIER="113"
export VM_IP="192.168.101.113"

# Run bootstrap with snapshot protection
if ! ./shared/snapshot/bootstrap-with-snapshot.sh ../shared/bootstrap/ubuntu.sh; then
    echo "Bootstrap failed, but snapshot is available!"
    cat /tmp/linus-snapshots/restore-info.txt
fi
```

#### Metadata Structure

Snapshot metadata is saved to `/tmp/linus-snapshots/{snapshot-name}.meta.json`:

```json
{
  "snapshot_name": "bootstrap-baseline-20260508-123456-default",
  "provider": "proxmox",
  "vm_identifier": "113",
  "vm_ip": "192.168.101.113",
  "operation_type": "bootstrap_baseline",
  "bootstrap_type": "default",
  "created_at": "2026-05-08T12:34:56Z",
  "bootstrap_script": "../shared/bootstrap/ubuntu.sh",
  "bootstrap_args": "SKIP_UPGRADE=false",
  "status": "created",
  "restore_available": true
}
```

---

## 2. Cleanup Verification

### Purpose
Verify that VM cleanup is complete after test execution, ensuring no orphaned resources remain.

### New Scripts

#### `shared/snapshot/verify-cleanup.sh`

A verification script that:
1. Checks VM is destroyed on the provider
2. Verifies no orphaned resources remain
3. Provides detailed cleanup status report
4. Can detect leftover snapshots, volumes, or AMIs

#### Usage

```bash
# Proxmox verification
export PROVIDER="proxmox"
export VM_IDENTIFIER="113"
./shared/snapshot/verify-cleanup.sh

# AWS verification
export PROVIDER="aws"
export VM_IDENTIFIER="i-0abc123def456"
./shared/snapshot/verify-cleanup.sh

# QEMU verification
export PROVIDER="qemu"
export VM_NAME="test-vm-001"
./shared/snapshot/verify-cleanup.sh
```

#### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `PROVIDER` | VM provider (proxmox\|aws\|qemu) | Required |
| `VM_IDENTIFIER` | VM ID that should be destroyed | Required |
| `VM_NAME` | Alternative identifier | Optional |
| `MAX_ORPHANED_SNAPSHOTS` | Maximum allowed orphaned snapshots | `5` |

#### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Cleanup verified complete |
| 1 | Verification failed (resources still exist) |
| 2 | Invalid configuration |

#### Provider-Specific Checks

### Proxmox
- ✅ VM destroyed check
- ✅ Snapshot check
- ⚠️ Disk cleanup note (manual)
- ⚠️ Network resources (normal state)

### AWS
- ✅ Instance terminated check
- ✅ EBS volume check
- ✅ AMI/snapshot check
- ✅ Elastic IP check
- ✅ Security group check

### QEMU
- ✅ VM destroyed check
- ✅ Snapshot check
- ⚠️ Disk image cleanup note (manual)
- ⚠️ Network resources check

#### Example Test Integration

```bash
# In your test script
cleanup() {
    echo "Cleaning up..."
    ./shared/provision/destroy.sh
    
    # Verify cleanup was successful
    export PROVIDER="proxmox"
    export VM_IDENTIFIER="113"
    
    if ./shared/snapshot/verify-cleanup.sh; then
        echo "✓ Cleanup verified successful"
    else
        echo "✗ Cleanup verification failed"
        exit 1
    fi
}

# Run cleanup on exit
trap cleanup EXIT
```

---

## 3. Resource Monitoring

### Purpose
Monitor CPU, memory, and disk usage during bootstrap operations to detect bottlenecks and determine when bootstrap is complete.

### New Scripts

#### `shared/snapshot/monitor-resource.sh`

A monitoring script that:
1. Monitors resource usage at configurable intervals
2. Detects when bootstrap operations are complete
3. Provides visibility into bootstrap performance
4. Can detect performance bottlenecks

#### Usage

```bash
# Monitor for 300 seconds with 10-second intervals
./shared/snapshot/monitor-resource.sh --timeout 300 --interval 10

# Quick monitoring
./shared/snapshot -t 60 -i 5

# Custom log directory
./shared/snapshot --log-dir /var/log/linus-monitor
```

#### Command Line Options

| Option | Description | Default |
|--------|-------------|---------|
| `--timeout, -t SECONDS` | Maximum monitoring duration | `300` |
| `--interval, -i SECONDS` | Sampling interval | `10` |
| `--log-dir, -l PATH` | Log directory | `/tmp/linus-monitor` |

#### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `MONITOR_TIMEOUT` | Monitoring duration | `300` |
| `MONITOR_INTERVAL` | Sampling interval | `10` |
| `LOG_DIR` | Log directory | `/tmp/linus-monitor` |

#### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Monitoring complete (bootstrap finished) |
| 1 | Timeout reached (bootstrap still running) |
| 2 | Invalid configuration |
| 3 | Monitoring error |

#### Monitoring Output

Real-time output format:
```
2026-05-08T12:34:56Z | CPU:  45% | MEM:  62% | DISK_IO:   12345678 bytes | Activity: NORMAL
```

CSV logs saved to `${LOG_DIR}/monitor-YYYYMMDD-HHMMSS.csv`:
```csv
timestamp,cpu_percent,memory_percent,disk_io_bytes,activity
2026-05-08T12:34:56Z,45,62,12345678,0
2026-05-08T12:35:06Z,78,65,23456789,1
```

#### Example Integration

```bash
# Run bootstrap and monitor resources
./shared/snapshot/monitor-resource.sh --timeout 300 &
MONITOR_PID=$!

# In another terminal or background
./shared/bootstrap/ubuntu.sh

# Wait for bootstrap to complete (monitor auto-detects)
wait $MONITOR_PID

# Or timeout after 300 seconds
wait $MONITOR_PID || true
```

#### Bootstrap Completion Detection

The monitor auto-detects bootstrap completion when:
- CPU usage is consistently below 50% for 3 intervals (30 seconds)
- Memory usage is consistently below 70% for 3 intervals (30 seconds)
- No significant disk I/O activity for 3 intervals

---

## Combined Workflow Example

### Complete Test Flow with All Features

```bash
#!/usr/bin/env bash
# =============================================================================
# Complete test flow with snapshot, verification, and monitoring
# =============================================================================

set -e

# Step 1: Provision VM
echo "=== Step 1: Provisioning VM ==="
./shared/provision/proxmox.sh

# Capture VM info
VM_ID=$(echo "$OUTPUT" | grep "VM_ID:" | cut -d: -f2)
VM_IP=$(echo "$OUTPUT" | grep "VM_IP:" | cut -d: -f2)

# Step 2: Bootstrap with snapshot protection
echo "=== Step 2: Bootstrap with snapshot protection ==="
export PROVIDER="proxmox"
export VM_IDENTIFIER="${VM_ID}"
export VM_IP="${VM_IP}"

if ! ./shared/snapshot/bootstrap-with-snapshot.sh ../shared/bootstrap/ubuntu.sh; then
    echo "Bootstrap failed, restoring from snapshot..."
    source /tmp/linus-snapshots/restore-info.txt
    ./shared/snapshot/restore-snapshot.sh
    exit 1
fi

# Step 3: Run tests
echo "=== Step 3: Running tests ==="
./tests/e2e/test-full-workflow.sh

# Step 4: Verify cleanup
echo "=== Step 4: Verifying cleanup ==="
if ! ./shared/snapshot/verify-cleanup.sh; then
    echo "Cleanup verification failed, manual cleanup required"
    # Log the issue for later review
fi

# Step 5: Destroy VM
echo "=== Step 5: Destroying VM ==="
./shared/provision/destroy.sh

# Step 6: Final cleanup verification
echo "=== Step 6: Final cleanup verification ==="
./shared/snapshot/verify-cleanup.sh

echo "=== Test flow completed successfully ==="
```

---

## Migration Guide

### From Old Workflow to New Workflow

#### Before (No Snapshot Protection)
```bash
# Old workflow
./shared/provision/proxmox.sh
./shared/bootstrap/ubuntu.sh
./tests/e2e/test-full-workflow.sh
./shared/provision/destroy.sh
```

#### After (With Snapshot Protection)
```bash
# New workflow
export PROVIDER="proxmox"
export VM_IDENTIFIER="113"
export VM_IP="192.168.101.113"

./shared/provision/proxmox.sh
./shared/snapshot/bootstrap-with-snapshot.sh ../shared/bootstrap/ubuntu.sh
./tests/e2e/test-full-workflow.sh
./shared/provision/destroy.sh
./shared/snapshot/verify-cleanup.sh
```

---

## Troubleshooting

### Snapshot Issues

**Problem**: Snapshot creation fails

**Solution**:
1. Check `PROVIDER` and `VM_IDENTIFIER` are set
2. Verify the snapshot script is executable: `chmod +x shared/snapshot/save-snapshot.sh`
3. Check disk space on the provider

**Problem**: Cannot restore from snapshot

**Solution**:
1. Check metadata file exists: `ls /tmp/linus-snapshots/*.meta.json`
2. Verify the snapshot still exists on the provider
3. Check `FORCE_RESTORE=true` if VM is running

### Cleanup Verification Issues

**Problem**: VM still exists after destroy

**Solution**:
1. Check provider-specific destroy script logs
2. Manually verify: `qm list` (Proxmox), `aws ec2 describe-instances` (AWS), `virsh list` (QEMU)
3. Force destroy: `qm destroy <VM_ID>` (Proxmox)

**Problem**: Orphaned resources detected

**Solution**:
1. Review the detailed report from `verify-cleanup.sh`
2. Manually clean up identified resources
3. Consider adding auto-cleanup to your test workflow

### Monitoring Issues

**Problem**: Monitor doesn't detect bootstrap completion

**Solution**:
1. Increase timeout: `./shared/snapshot/monitor-resource.sh --timeout 600`
2. Check log files: `ls -la /tmp/linus-monitor/monitor-*.csv`
3. Review peak resource usage to identify bottlenecks

**Problem**: Resource usage always high

**Solution**:
1. Check for runaway processes: `top` or `htop`
2. Review bootstrap script for long-running operations
3. Consider increasing monitoring interval

---

## Future Enhancements

### Planned Improvements

1. **Snapshot Comparison**: Compare snapshots to detect changes
2. **Automated Cleanup**: Auto-remove orphaned resources
3. **Performance Alerts**: Alert on high resource usage
4. **Bootstrap Optimization**: Suggest optimizations based on monitoring
5. **GUI Dashboard**: Visual resource monitoring UI

### Contributing

To contribute improvements to these features:
1. Fork the repository
2. Create a new branch for your feature
3. Add tests for new functionality
4. Update documentation
5. Submit a pull request

---

## Version History

### v1.4.0-alpha (May 8, 2026)
- ✨ Added `bootstrap-with-snapshot.sh` for snapshot protection
- ✨ Added `verify-cleanup.sh` for cleanup verification
- ✨ Added `monitor-resource.sh` for resource monitoring
- 📝 Added comprehensive documentation

---

## Support

For issues or questions:
1. Check this documentation first
2. Review the script help: `./script-name.sh --help`
3. Check the smoke tests pass: `./tests/smoke/test-all-scripts.sh`
4. File an issue on the GitHub repository
