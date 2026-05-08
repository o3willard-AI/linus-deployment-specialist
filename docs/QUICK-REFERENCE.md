# New Features Quick Reference

## 1. Snapshot Before Bootstrap

```bash
# Set environment
export PROVIDER="proxmox"
export VM_IDENTIFIER="113"
export VM_IP="192.168.101.113"

# Run bootstrap with automatic snapshot protection
./shared/snapshot/bootstrap-with-snapshot.sh ../shared/bootstrap/ubuntu.sh

# If bootstrap fails, restore info saved to:
cat /tmp/linus-snapshots/restore-info.txt

# Restore from snapshot
export PROVIDER="proxmox"
export VM_IDENTIFIER="113"
export SNAPSHOT_NAME="bootstrap-baseline-20260508-123456-default"
./shared/snapshot/restore-snapshot.sh
```

## 2. Cleanup Verification

```bash
# Verify VM cleanup after tests
export PROVIDER="proxmox"
export VM_IDENTIFIER="113"
./shared/snapshot/verify-cleanup.sh

# Exit code 0 = cleanup verified
# Exit code 1 = resources still exist
```

## 3. Resource Monitoring

```bash
# Monitor for 300 seconds
./shared/snapshot/monitor-resource.sh

# Custom settings
./shared/snapshot/monitor-resource.sh --timeout 600 --interval 15

# Real-time output:
# 2026-05-08T12:34:56Z | CPU:  45% | MEM:  62% | DISK_IO:   12345678 bytes

# Auto-detects when bootstrap completes (no activity for 30s)
```

## Complete Workflow

```bash
#!/usr/bin/env bash

# 1. Provision
./shared/provision/proxmox.sh

# 2. Bootstrap with snapshot
export PROVIDER="proxmox"
export VM_IDENTIFIER="113"
./shared/snapshot/bootstrap-with-snapshot.sh ../shared/bootstrap/ubuntu.sh

# 3. Run tests
./tests/e2e/test-full-workflow.sh

# 4. Verify cleanup
export VM_IDENTIFIER="113"
./shared/snapshot/verify-cleanup.sh

# 5. Destroy
./shared/provision/destroy.sh

# 6. Final verification
./shared/snapshot/verify-cleanup.sh
```

## Key Files

| File | Purpose |
|------|---------|
| `shared/snapshot/bootstrap-with-snapshot.sh` | Snapshot before bootstrap |
| `shared/snapshot/verify-cleanup.sh` | Verify VM cleanup |
| `shared/snapshot/monitor-resource.sh` | Resource monitoring |
| `docs/NEW-FEATURES.md` | Full documentation |
| `docs/QUICK-REFERENCE.md` | This file |

## Exit Codes

| Code | bootstrap-with-snapshot.sh | verify-cleanup.sh | monitor-resource.sh |
|------|---------------------------|-------------------|---------------------|
| 0 | Success | Verified complete | Monitoring complete |
| 1 | General error | Resources exist | Timeout |
| 2 | Snapshot creation failed | Invalid config | Invalid config |
| 3 | Bootstrap failed | - | Monitoring error |
| 4 | Restore failed | - | - |
