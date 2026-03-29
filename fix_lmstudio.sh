#!/bin/bash
# Fix LM Studio provider configuration

set -e

MODELS_JSON="$HOME/.cache/opencode/models.json"
PROVIDER_ID="lmstudio-local-192-168-101-21"
API_URL="http://192.168.101.21:1234/v1"

echo "Fixing LM Studio provider configuration..."

# Backup
cp "$MODELS_JSON" "$MODELS_JSON.backup.$(date +%s)"

# Create correct provider configuration
jq --arg provider_id "$PROVIDER_ID" --arg api_url "$API_URL" '
  .[$provider_id] = (.lmstudio | 
    .id = $provider_id |
    .name = "LM Studio (192.168.101.21)" |
    .api = $api_url |
    .models = {
      "qwen/qwen3-coder-30b": .models["qwen/qwen3-coder-30b"],
      "qwen/qwen3.5-35b-a3b": (.models["qwen/qwen3-30b-a3b-2507"] | 
        .id = "qwen/qwen3.5-35b-a3b" |
        .name = "Qwen3.5 35B A3B"),
      "openai/gpt-oss-20b": .models["openai/gpt-oss-20b"],
      "mistralai/ministral-3-14b-reasoning": (.models["openai/gpt-oss-20b"] |
        .id = "mistralai/ministral-3-14b-reasoning" |
        .name = "Ministral 3 14B Reasoning" |
        .family = "mistral" |
        .reasoning = true |
        .limit.context = 262144 |
        .limit.output = 65536)
    }
  )
' "$MODELS_JSON" > "$MODELS_JSON.tmp"

mv "$MODELS_JSON.tmp" "$MODELS_JSON"

echo "✅ Fixed provider configuration"
echo "Provider: $PROVIDER_ID"
echo "API: $API_URL"
echo "Models:"
jq -r ".$PROVIDER_ID.models | keys[]" "$MODELS_JSON" | while read model; do
  echo "  - $model"
done