#!/usr/bin/env bash
# Kiosk Challenge Runner — sends the Kiosk Admin Panel spec to a running
# llama.cpp server on a Vast GPU instance and captures the output.
#
# Usage: API_KEY=mykey bash send-kiosk-challenge.sh <ip> <port> [output_dir]
# Example: API_KEY=linus-inference bash send-kiosk-challenge.sh ssh4.vast.ai 17667 /tmp/kiosk-test
#
# Resiliency improvements:
#   - API_KEY env var support (required for auth-protected servers)
#   - Pre-flight quality canary (small prompt → check output sanity)
#   - Unbuffered Python for real-time progress visibility

set -euo pipefail

IP="${1:?Usage: $0 <ip> <port> [output_dir]}"
PORT="${2:?Usage: $0 <ip> <port> [output_dir]}"
OUTDIR="${3:-/tmp/kiosk-test-$(date +%Y%m%d-%H%M%S)}"
API_KEY="${API_KEY:-}"

SPEC_FILE="$(dirname "$0")/challenge-prompt.txt"
ENDPOINT="http://${IP}:${PORT}/v1/completions"

mkdir -p "$OUTDIR"

# Divert stdout to both terminal and a log file for background visibility
exec > >(tee "$OUTDIR/run.log") 2>&1

echo "=== Kiosk Challenge Runner ==="
echo "Target: $ENDPOINT"
echo "Output: $OUTDIR"
echo ""

# ---- Auth header ----
AUTH_HEADER=""
if [[ -n "$API_KEY" ]]; then
    AUTH_HEADER="-H \"Authorization: Bearer $API_KEY\""
    echo "Auth: Bearer *** (set)"
else
    echo "Auth: none (API_KEY not set)"
fi
echo ""

# ---- Pre-flight: Quality canary ----
# Sends a small prompt first to verify the model produces sane output
# before committing to a 30-minute challenge on a broken model.
echo "=== Quality Canary ==="
echo "Testing model with small prompt (200 tokens max)..."
CANARY_RESPONSE=$(eval curl -s --max-time 120 "$ENDPOINT" \
    $AUTH_HEADER \
    -H "Content-Type: application/json" \
    -d '{"prompt":"Write a Python function that reverses a string. Output ONLY code, no explanation.","max_tokens":200,"temperature":0.3}' 2>&1) || {
    echo "FAILED: Canary request failed"
    echo "$CANARY_RESPONSE"
    exit 1
}

CANARY_TEXT=$(echo "$CANARY_RESPONSE" | python3 -c "
import json, sys
d = json.load(sys.stdin)
c = d.get('choices', [{}])[0].get('text', '')
print(c)
" 2>/dev/null) || CANARY_TEXT=""

CANARY_CHARS=$(echo -n "$CANARY_TEXT" | wc -c)

# Heuristic: garbage output = lots of newlines or repeated single chars
NEWLINE_RATIO=$(echo "$CANARY_TEXT" | tr -cd '\n' | wc -c)
if [[ $CANARY_CHARS -gt 0 ]]; then
    NEWLINE_PCT=$((NEWLINE_RATIO * 100 / CANARY_CHARS))
else
    NEWLINE_PCT=0
fi

# Check for repeated-character garbage (e.g., "ssssssss")
REPEAT_SCORE=$(echo "$CANARY_TEXT" | python3 -c "
import sys
text = sys.stdin.read()
if len(text) < 10:
    print(0)
else:
    from collections import Counter
    c = Counter(text)
    # If any single char is >50% of output, likely garbage
    top_pct = max(c.values()) / len(text) * 100 if text else 0
    print(int(top_pct))
" 2>/dev/null) || REPEAT_SCORE=0

echo "Canary: ${CANARY_CHARS} chars, ${NEWLINE_PCT}% newlines, ${REPEAT_SCORE}% repeated char"
CANARY_FIRST=$(echo "$CANARY_TEXT" | head -c 200)
echo "Preview: ${CANARY_FIRST}"

if [[ $NEWLINE_PCT -gt 40 ]]; then
    echo "⚠️  CANARY FAILED: >40% newlines — model output likely garbage"
    echo "   Skipping full challenge. Try a larger model or different quant."
    echo "FAILED:garbage" > "$OUTDIR/manifest.json"
    exit 1
fi

if [[ $REPEAT_SCORE -gt 50 ]]; then
    echo "⚠️  CANARY FAILED: single character repeated >50% — model output is garbage"
    echo "   Skipping full challenge."
    echo "FAILED:repeated_char" > "$OUTDIR/manifest.json"
    exit 1
fi

echo "Canary PASSED ✓"
echo ""

# ---- Send the challenge ----
echo "Sending Kiosk Admin Panel challenge..."
echo "Spec size: $(wc -c < "$SPEC_FILE") chars"

START_TIME=$(date +%s)

RESPONSE=$(eval curl -s --max-time 1800 "$ENDPOINT" \
    $AUTH_HEADER \
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
  "canary_chars": $CANARY_CHARS,
  "canary_newline_pct": $NEWLINE_PCT,
  "canary_repeat_pct": $REPEAT_SCORE,
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
