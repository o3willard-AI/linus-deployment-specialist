#!/usr/bin/env bash
# Kiosk Challenge Runner — sends the Kiosk Admin Panel spec to a running
# llama.cpp server on a Vast GPU instance and captures the output.
#
# Usage: bash send-kiosk-challenge.sh <ip> <port> [output_dir]
# Example: bash send-kiosk-challenge.sh ssh4.vast.ai 17667 /tmp/kiosk-test

set -euo pipefail

IP="${1:?Usage: $0 <ip> <port> [output_dir]}"
PORT="${2:?Usage: $0 <ip> <port> [output_dir]}"
OUTDIR="${3:-/tmp/kiosk-test-$(date +%Y%m%d-%H%M%S)}"

SPEC_FILE="$(dirname "$0")/challenge-prompt.txt"
ENDPOINT="http://${IP}:${PORT}/v1/completions"

mkdir -p "$OUTDIR"

echo "=== Kiosk Challenge Runner ==="
echo "Target: $ENDPOINT"
echo "Output: $OUTDIR"
echo ""

# ---- Health check ----
echo -n "Checking server health... "
if curl -sf --max-time 10 "$ENDPOINT" -d '{"prompt":"test"}' > /dev/null 2>&1; then
    echo "OK"
else
    echo "FAILED"
    echo "Server not reachable at $ENDPOINT"
    exit 1
fi

# ---- Send the challenge ----
echo "Sending Kiosk Admin Panel challenge..."
echo "Spec size: $(wc -c < "$SPEC_FILE") chars"

START_TIME=$(date +%s)

# llama.cpp /v1/completions: use "prompt" not "messages"
RESPONSE=$(curl -s --max-time 1800 "$ENDPOINT" \
    -H "Content-Type: application/json" \
    -d @"$SPEC_FILE" 2>&1) || {
    echo "Curl failed or timed out after 30 min"
    echo "$RESPONSE"
    exit 1
}

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

# ---- Save raw response ----
echo "$RESPONSE" > "$OUTDIR/raw-response.json"

# ---- Extract content ----
CONTENT=$(echo "$RESPONSE" | python3 -c "
import json, sys
d = json.load(sys.stdin)
c = d.get('choices', [{}])[0].get('text', '')
print(c)
" 2>/dev/null) || CONTENT=""

echo "$CONTENT" > "$OUTDIR/model-output.txt"

# ---- Metrics ----
CONTENT_CHARS=$(wc -c < "$OUTDIR/model-output.txt")
CONTENT_LINES=$(wc -l < "$OUTDIR/model-output.txt")
FILE_COUNT=$(grep -c '^```' "$OUTDIR/model-output.txt" 2>/dev/null || echo 0)
FILE_COUNT=$((FILE_COUNT / 2))  # opening + closing fences per file

echo ""
echo "=== Results ==="
echo "Wall time:    ${ELAPSED}s"
echo "Content:      ${CONTENT_CHARS} chars, ${CONTENT_LINES} lines"
echo "Files output: ~${FILE_COUNT}"
echo "Saved to:     $OUTDIR"

# ---- Quick anti-pattern scan ----
AP_COUNT=0
if grep -q 'render_template_string' "$OUTDIR/model-output.txt" 2>/dev/null; then
    echo "⚠️  ANTI-PATTERN: render_template_string found"
    ((AP_COUNT++)) || true
fi
APP_FLASK_COUNT=$(grep -c 'app\s*=\s*Flask' "$OUTDIR/model-output.txt" 2>/dev/null || echo 0)
if [[ $APP_FLASK_COUNT -gt 1 ]]; then
    echo "⚠️  ANTI-PATTERN: app = Flask defined ${APP_FLASK_COUNT} times (should be 1)"
    ((AP_COUNT++)) || true
fi

echo "Anti-patterns: $AP_COUNT"

# ---- Save manifest ----
cat > "$OUTDIR/manifest.json" << EOF
{
  "model": "OBLITERATUS/Qwen3.6-27B-OBLITERATED",
  "quant": "Q4_K_M",
  "context": 32768,
  "endpoint": "$ENDPOINT",
  "wall_time_s": $ELAPSED,
  "content_chars": $CONTENT_CHARS,
  "content_lines": $CONTENT_LINES,
  "file_count": $FILE_COUNT,
  "anti_patterns": $AP_COUNT,
  "timestamp": "$(date -Iseconds)"
}
EOF

echo "Manifest: $OUTDIR/manifest.json"
echo "Done."
