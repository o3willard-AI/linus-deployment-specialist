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
    "shared/bootstrap/ubuntu.sh"
    "shared/configure/dev-tools.sh"
    "shared/configure/base-packages.sh"
    "shared/lib/logging.sh"
    "shared/lib/validation.sh"
    "shared/lib/mcp-helpers.sh"
    "shared/lib/noninteractive.sh"
    "shared/lib/tmux-helper.sh"
    "examples/level1-example.sh"
    "examples/level2-example.sh"
    "examples/level3-example.sh"
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
        ((passed++))
    else
        echo -e "${RED}❌${NC} $script - SYNTAX ERROR"
        bash -n "$script" 2>&1 | sed 's/^/    /'
        ((failed++))
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
