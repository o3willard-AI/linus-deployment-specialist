#!/usr/bin/env bash
# =============================================================================
# Level 3 Example: TMUX Session Management
# =============================================================================
# AUTOMATION LEVEL: 3 (TMUX session management)
# Rationale: Long-running operation demonstration, session persistence
# =============================================================================

set -euo pipefail

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source the TMUX helper library
source "${SCRIPT_DIR}/../shared/lib/tmux-helper.sh"

echo "=== Level 3: TMUX Session Management Example ==="
echo ""

SESSION_NAME="level3-demo"

# Clean up any existing session
tmux_kill_session "$SESSION_NAME" 2>/dev/null || true

echo "🚀 Creating TMUX Session: $SESSION_NAME"

# Create a TMUX session running a long command
tmux_create_session "$SESSION_NAME" "bash -c 'for i in {1..10}; do echo \"Processing step \$i/10...\"; sleep 1; done; echo \"LINUS_RESULT:SUCCESS\"'"

echo ""
echo "📊 Monitoring session output..."
sleep 2

# Capture initial output
echo "--- Session Output (first 5 lines) ---"
tmux_capture_pane "$SESSION_NAME" 0 5
echo "--------------------------------------"
echo ""

# Monitor for completion pattern
echo "⏳ Waiting for completion pattern..."
if tmux_monitor_output "$SESSION_NAME" "LINUS_RESULT:SUCCESS" "LINUS_RESULT:FAILURE" 30; then
    echo ""
    echo "--- Final Session Output ---"
    tmux_capture_pane "$SESSION_NAME" 0 20
    echo "----------------------------"
    echo ""
    echo "✅ Operation completed successfully!"
else
    echo ""
    echo "❌ Operation failed or timed out"
fi

# Clean up
echo ""
echo "🧹 Cleaning up TMUX session..."
tmux_kill_session "$SESSION_NAME"

echo ""
echo "✅ Level 3 Example Complete!"
echo "Demonstrated TMUX capabilities:"
echo "  - tmux_create_session (persistent session)"
echo "  - tmux_capture_pane (get output)"
echo "  - tmux_monitor_output (wait for pattern)"
echo "  - tmux_kill_session (cleanup)"
echo ""
echo "This level is useful for:"
echo "  • Long-running operations (> 5 minutes)"
echo "  • Operations that might disconnect"
echo "  • Truly interactive third-party tools"
