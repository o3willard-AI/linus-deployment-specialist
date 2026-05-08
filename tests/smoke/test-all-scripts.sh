#!/usr/bin/env bash
# =============================================================================
# Smoke Tests: Syntax Validation
# =============================================================================
# Purpose: Validate all shell scripts have correct syntax
# Duration: < 5 seconds
# Requirements: None (just bash)
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Navigate to project root
cd "$(dirname "$0")/../.."

echo "=== Smoke Tests: Syntax Validation ==="
echo ""

# All scripts to test
scripts=(
"shared/provision/proxmox.sh"
    "shared/provision/aws.sh"
    "shared/provision/qemu.sh"
    "shared/provision/destroy.sh"
    "shared/provision/multi-vm.sh"
    "shared/bootstrap/ubuntu.sh"
    "shared/configure/dev-tools.sh"
    "shared/configure/base-packages.sh"
    "shared/deploy/artifact.sh"
    "shared/test/runner.sh"
    "shared/snapshot/save-snapshot.sh"
    "shared/snapshot/restore-snapshot.sh"
    "shared/snapshot/list-snapshots.sh"
    "shared/network/configure.sh"
    "shared/lib/logging.sh"
    "shared/lib/validation.sh"
    "shared/lib/mcp-helpers.sh"
    "shared/lib/noninteractive.sh"
    "shared/lib/tmux-helper.sh"
    "workflows/qa-testing.sh"
    "scripts/generate-report.sh"
    "examples/level1-example.sh"
    "examples/level2-example.sh"
    "examples/level3-example.sh"
    "examples/pre-bootstrap-snapshot-example.sh"
    "examples/cleanup-verification-example.sh"
    "examples/resource-monitoring-example.sh"
    "shared/snapshot/bootstrap-with-snapshot.sh"
    "shared/snapshot/verify-cleanup.sh"
    "shared/snapshot/monitor-resource.sh"

)

failed=0
passed=0

for script in "${scripts[@]}"; do
    if [[ ! -f "$script" ]]; then
        echo -e "${YELLOW}⚠${NC}  $script - FILE NOT FOUND"
        continue
    fi

    if bash -n "$script" 2>/dev/null; then
        echo -e "${GREEN}✅${NC} $script"
        passed=$((passed + 1))
    else
        echo -e "${RED}❌${NC} $script - SYNTAX ERROR"
        bash -n "$script" 2>&1 | sed 's/^/    /'
        failed=$((failed + 1))
    fi
done

echo ""
echo "Results: ${passed} passed, ${failed} failed"

if [[ $failed -eq 0 ]]; then
    echo -e "${GREEN}✅ All smoke tests passed${NC}"
    exit 0
else
    echo -e "${RED}❌ $failed script(s) failed smoke test${NC}"
    exit 1
fi
