#!/usr/bin/env bash
# Kiosk Challenge Runner (Chat API) — sends the Kiosk Admin Panel spec
# to a running llama.cpp server and captures output.
#
# Usage: API_KEY=mykey bash send-kiosk-challenge.sh <ip> <port> [output_dir]
# Example: API_KEY=linus-inference bash send-kiosk-challenge.sh ssh4.vast.ai 17667

set -euo pipefail

IP="${1:?Usage: $0 <ip> <port> [output_dir]}"
PORT="${2:?Usage: $0 <ip> <port> [output_dir]}"
OUTDIR="${3:-/tmp/kiosk-test-$(date +%Y%m%d-%H%M%S)}"
API_KEY="${API_KEY:-}"

SPEC_FILE="$(dirname "$0")/challenge-prompt-chat.json"
ENDPOINT="http://${IP}:${PORT}/v1/chat/completions"

mkdir -p "$OUTDIR"
exec > >(tee "$OUTDIR/run.log") 2>&1

echo "=== Kiosk Challenge Runner (Chat API) ==="
echo "Target: $ENDPOINT"
echo "Output: $OUTDIR"
echo ""

# ---- Auth ----
if [[ -n "$API_KEY" ]]; then
    echo "Auth: Bearer *** (set)"
else
    echo "Auth: none (API_KEY not set)"
fi
echo ""

# ---- Pre-flight: Quality canary (chat format) ----
echo "=== Quality Canary ==="
echo "Testing model with small prompt (50 tokens max)..."
CANARY_RESPONSE=$(curl -s --max-time 60 "$ENDPOINT" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{
        "messages": [
            {"role": "system", "content": "Respond with ONLY the answer. No explanation."},
            {"role": "user", "content": "What is 2+2?"}
        ],
        "max_tokens": 50,
        "temperature": 0.0
    }' 2>&1) || {
    echo "FAILED: Canary request failed"
    echo "$CANARY_RESPONSE"
    exit 1
}

CANARY_CONTENT=$(echo "$CANARY_RESPONSE" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d['choices'][0]['message']['content'])
" 2>/dev/null) || CANARY_CONTENT=""

CANARY_CHARS=$(echo -n "$CANARY_CONTENT" | wc -c)

# Quality: slash ratio
SLASH_COUNT=$(echo "$CANARY_CONTENT" | tr -cd '/' | wc -c)
if [[ $CANARY_CHARS -gt 0 ]]; then
    SLASH_PCT=$((SLASH_COUNT * 100 / CANARY_CHARS))
else
    SLASH_PCT=0
fi

# Quality: char dominance
REPEAT_PCT=$(echo "$CANARY_CONTENT" | python3 -c "
import sys
from collections import Counter
text = sys.stdin.read()
if len(text) < 5: print(0)
else:
    c = Counter(text)
    print(int(max(c.values()) / len(text) * 100))
" 2>/dev/null) || REPEAT_PCT=0

echo "Canary: ${CANARY_CHARS} chars, ${SLASH_PCT}% slashes, ${REPEAT_PCT}% repeated"
echo "Preview: ${CANARY_CONTENT:0:200}"

if [[ $SLASH_PCT -gt 50 ]]; then
    echo "CANARY FAILED: >50% slash characters — model output is garbage"
    exit 1
fi
if [[ $REPEAT_PCT -gt 50 ]]; then
    echo "CANARY FAILED: single character >50% — model output is garbage"
    exit 1
fi
echo "Canary PASSED"
echo ""

# ---- Send the challenge ----
echo "Sending Kiosk Admin Panel challenge (chat format)..."
echo "Spec size: $(wc -c < "$SPEC_FILE") chars"
echo ""

START_TIME=$(date +%s)

RESPONSE=$(curl -s --max-time 1800 "$ENDPOINT" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d @"$SPEC_FILE" 2>&1) || {
    echo "Curl failed or timed out"
    exit 1
}

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo "$RESPONSE" > "$OUTDIR/raw-response.json"

# ---- Extract content ----
CONTENT=$(echo "$RESPONSE" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d['choices'][0]['message']['content'])
" 2>/dev/null) || CONTENT=""

USAGE=$(echo "$RESPONSE" | python3 -c "
import json, sys
d = json.load(sys.stdin)
u = d.get('usage', {})
print(f\"{u.get('completion_tokens',0)}/{u.get('prompt_tokens',0)}/{u.get('total_tokens',0)}\")
" 2>/dev/null) || USAGE="?/?/?"

echo "$CONTENT" > "$OUTDIR/model-output.txt"

CONTENT_CHARS=$(wc -c < "$OUTDIR/model-output.txt")
FILE_COUNT=$(grep -c '^```' "$OUTDIR/model-output.txt" 2>/dev/null || echo 0)
FILE_COUNT=$((FILE_COUNT / 2))

echo ""
echo "=== Results ==="
echo "Wall time:  ${ELAPSED}s"
echo "Tokens:     ${USAGE}"
echo "Content:    ${CONTENT_CHARS} chars"
echo "Files:      ~${FILE_COUNT}"

# ---- Semantic quality: n-gram repetition ----
REPEAT_SCORE=$(python3 -c "
import sys
text = open('$OUTDIR/model-output.txt').read()
# Check for 5-gram repetition (catches degeneration loops)
from collections import Counter
if len(text) < 30:
    print(0)
else:
    # Extract 5-grams (word-level)
    words = text.split()
    if len(words) < 10:
        print(0)
    else:
        grams = [' '.join(words[i:i+5]) for i in range(len(words)-4)]
        c = Counter(grams)
        top_count = c.most_common(1)[0][1]
        # If any 5-gram appears more than 10 times, it's repeating
        print(top_count)
" 2>/dev/null) || REPEAT_SCORE=0

echo "Max 5-gram repeat: ${REPEAT_SCORE} (degeneration if >10)"

# ---- Anti-pattern scan ----
AP_COUNT=0
if grep -q 'render_template_string' "$OUTDIR/model-output.txt" 2>/dev/null; then
    echo "ANTI-PATTERN: render_template_string found"
    ((AP_COUNT++)) || true
fi
APP_FLASK_COUNT=$(grep -c 'app\s*=\s*Flask' "$OUTDIR/model-output.txt" 2>/dev/null || echo 0)
if [[ $APP_FLASK_COUNT -gt 1 ]]; then
    echo "ANTI-PATTERN: app = Flask defined ${APP_FLASK_COUNT} times"
    ((AP_COUNT++)) || true
fi
echo "Anti-patterns: $AP_COUNT"

# ---- Save manifest ----
cat > "$OUTDIR/manifest.json" << EOF
{
  "canary_chars": $CANARY_CHARS,
  "canary_slash_pct": $SLASH_PCT,
  "canary_repeat_pct": $REPEAT_PCT,
  "endpoint": "$ENDPOINT",
  "wall_time_s": $ELAPSED,
  "content_chars": $CONTENT_CHARS,
  "file_count": $FILE_COUNT,
  "max_5gram_repeat": $REPEAT_SCORE,
  "anti_patterns": $AP_COUNT,
  "tokens": "$USAGE",
  "timestamp": "$(date -Iseconds)"
}
EOF

echo ""
echo "Manifest: $OUTDIR/manifest.json"
echo "Done."
