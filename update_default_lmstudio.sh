#!/bin/bash
# Update default lmstudio provider

set -e

MODELS_JSON="$HOME/.cache/opencode/models.json"

echo "Updating default lmstudio provider..."

# Backup
cp "$MODELS_JSON" "$MODELS_JSON.backup.$(date +%s)"

# Update lmstudio provider with correct models
jq '
  .lmstudio.api = "http://192.168.101.21:1234/v1" |
  .lmstudio.models = {
    "qwen/qwen3-coder-30b": .lmstudio.models["qwen/qwen3-coder-30b"],
    "qwen/qwen3.5-35b-a3b": (.lmstudio.models["qwen/qwen3-30b-a3b-2507"] | 
      .id = "qwen/qwen3.5-35b-a3b" |
      .name = "Qwen3.5 35B A3B"),
    "openai/gpt-oss-20b": .lmstudio.models["openai/gpt-oss-20b"],
    "mistralai/ministral-3-14b-reasoning": (.lmstudio.models["openai/gpt-oss-20b"] |
      .id = "mistralai/ministral-3-14b-reasoning" |
      .name = "Ministral 3 14B Reasoning" |
      .family = "mistral" |
      .reasoning = true |
      .limit.context = 262144 |
      .limit.output = 65536)
  }
' "$MODELS_JSON" > "$MODELS_JSON.tmp"

mv "$MODELS_JSON.tmp" "$MODELS_JSON"

echo "✅ Updated default lmstudio provider"
echo "API: http://192.168.101.21:1234/v1"
echo "Models:"
jq -r '.lmstudio.models | keys[]' "$MODELS_JSON" | while read model; do
  echo "  - $model"
done