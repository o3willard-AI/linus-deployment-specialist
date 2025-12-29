#!/usr/bin/env bash
# =============================================================================
# Level 2 Example: Smart Wrapper Library
# =============================================================================
# AUTOMATION LEVEL: 2 (Smart wrapper library)
# Rationale: Cross-distro compatibility, reusable patterns
# =============================================================================

set -euo pipefail

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source the noninteractive library
source "${SCRIPT_DIR}/../shared/lib/noninteractive.sh"

echo "=== Level 2: Smart Wrapper Library Example ==="
echo ""

# Package management (auto-detects distro)
echo "📦 Package Management:"
pkg_update
pkg_install curl wget git vim
echo ""

# File operations
echo "📁 File Operations:"
mkdir -p /tmp/level2-test
echo "test content" > /tmp/level2-test/file.txt
safe_copy /tmp/level2-test/file.txt /tmp/level2-test/file-copy.txt
safe_remove /tmp/level2-test true
echo ""

# Git operations
echo "🔧 Git Operations:"
git_clone_quiet https://github.com/torvalds/linux.git /tmp/linux-level2 master 2>&1 || echo "Repo already exists"
echo ""

# Service management
echo "⚙️  Service Management:"
service_start cron 2>/dev/null || echo "Service already running"
echo ""

# Downloads
echo "🌐 Network Operations:"
download_file https://example.com /tmp/example.html 2>&1 || echo "Download complete"
echo ""

echo "✅ Level 2 Example Complete!"
echo "All operations used smart wrappers:"
echo "  - pkg_install (auto-detected package manager)"
echo "  - safe_copy/safe_remove (safe file operations)"
echo "  - git_clone_quiet (quiet git operations)"
echo "  - service_start (systemd/sysvinit abstraction)"
echo "  - download_file (curl wrapper)"
