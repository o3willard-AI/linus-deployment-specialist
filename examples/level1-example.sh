#!/usr/bin/env bash
# =============================================================================
# Level 1 Example: Non-Interactive Script Design
# =============================================================================
# AUTOMATION LEVEL: 1 (Non-interactive design)
# Rationale: Simple operations, no complex workflows
# =============================================================================

set -euo pipefail

# Non-interactive environment for apt
export DEBIAN_FRONTEND=noninteractive

echo "=== Level 1: Non-Interactive Design Example ==="
echo ""
echo "Installing packages non-interactively..."

# Update package lists (quiet mode)
apt-get update -qq

# Install packages with -y flag (no prompts)
apt-get install -y -qq curl wget git

# Remove files with -f flag (no confirmation)
rm -f /tmp/test-file 2>/dev/null || true

# Git clone quietly
git clone --quiet --depth 1 https://github.com/torvalds/linux.git /tmp/linux-test 2>/dev/null || true

# Service operations (quiet)
systemctl enable --quiet --now cron 2>/dev/null || true

echo ""
echo "✅ Level 1 Example Complete!"
echo "All operations used non-interactive flags:"
echo "  - apt-get install -y"
echo "  - rm -f"
echo "  - git clone --quiet"
echo "  - systemctl --quiet"
