#!/usr/bin/env python3
"""
Complete setup of LM Studio local provider.
"""

import json
import os
import sys
import urllib.request

MODELS_JSON_PATH = os.path.expanduser("~/.cache/opencode/models.json")
LM_STUDIO_URL = "http://192.168.101.21:1234/v1"
PROVIDER_ID = "lmstudio"

def fetch_server_models():
    """Fetch model list from LM Studio server."""
    try:
        req = urllib.request.Request(f"{LM_STUDIO_URL}/models")
        with urllib.request.urlopen(req, timeout=10) as response:
            data = json.load(response)
            return [model["id"] for model in data.get("data", [])]
    except Exception as e:
        print(f"Error fetching models: {e}")
        sys.exit(1)

def create_model_definition(model_id, existing_defs):
    """Create model definition."""
    # Use existing definition if available
    if model_id in existing_defs:
        return existing_defs[model_id]
    
    # Create new definition
    base_name = model_id.split("/")[-1]
    family = model_id.split("/")[0] if "/" in model_id else "unknown"
    
    # Defaults
    definition = {
        "id": model_id,
        "name": base_name.replace("-", " ").title(),
        "family": family,
        "attachment": False,
        "reasoning": False,
        "tool_call": True,
        "temperature": True,
        "release_date": "2025-01-01",
        "last_updated": "2025-01-01",
        "modalities": {"input": ["text"], "output": ["text"]},
        "open_weights": True,
        "cost": {"input": 0, "output": 0},
        "limit": {"context": 131072, "output": 32768}
    }
    
    # Model-specific adjustments
    if "qwen" in model_id.lower():
        definition["family"] = "qwen"
        definition["limit"]["context"] = 262144
        definition["limit"]["output"] = 65536
        if "coder" in model_id.lower():
            definition["name"] = f"Qwen3 Coder {base_name.split('-')[-1].upper()}"
        elif "35b" in model_id.lower():
            definition["name"] = "Qwen3.5 35B A3B"
    
    elif "gpt-oss" in model_id.lower():
        definition["family"] = "gpt-oss"
        definition["reasoning"] = True
    
    elif "mistral" in model_id.lower() or "ministral" in model_id.lower():
        definition["family"] = "mistral"
        definition["reasoning"] = "reasoning" in model_id.lower()
        definition["limit"]["context"] = 262144
        definition["limit"]["output"] = 65536
    
    elif "embedding" in model_id.lower():
        # Skip embedding models
        return None
    
    return definition

def main():
    # Load models.json
    with open(MODELS_JSON_PATH, 'r') as f:
        data = json.load(f)
    
    # Fetch server models
    print("Fetching models from LM Studio server...")
    server_model_ids = fetch_server_models()
    print(f"Found {len(server_model_ids)} models")
    
    # Filter out embedding models
    server_model_ids = [mid for mid in server_model_ids if "embedding" not in mid]
    print(f"Using {len(server_model_ids)} chat models")
    
    # Get or create provider
    if PROVIDER_ID in data:
        provider = data[PROVIDER_ID]
        print(f"Updating existing provider {PROVIDER_ID}")
    else:
        # Copy from lmstudio provider
        if "lmstudio" not in data:
            print("Error: base lmstudio provider not found")
            sys.exit(1)
        provider = data["lmstudio"].copy()
        provider["id"] = PROVIDER_ID
        provider["name"] = f"LM Studio (192.168.101.21)"
        print(f"Created new provider {PROVIDER_ID}")
    
    # Set correct API endpoint (single /v1)
    provider["api"] = LM_STUDIO_URL
    print(f"API endpoint: {provider['api']}")
    
    # Get existing model definitions from provider
    existing_defs = provider.get("models", {})
    
    # Build new models dict
    new_models = {}
    for model_id in server_model_ids:
        definition = create_model_definition(model_id, existing_defs)
        if definition is None:
            print(f"Skipping embedding model: {model_id}")
            continue
        new_models[model_id] = definition
        print(f"  - {model_id}")
    
    provider["models"] = new_models
    
    # Update data
    data[PROVIDER_ID] = provider
    
    # Write back (compact format to match original)
    temp_path = MODELS_JSON_PATH + ".tmp"
    with open(temp_path, 'w') as f:
        json.dump(data, f, separators=(',', ':'))
    
    # Replace original
    os.rename(temp_path, MODELS_JSON_PATH)
    
    print(f"\n✅ Successfully configured {PROVIDER_ID}")
    print(f"✅ API: {provider['api']}")
    print(f"✅ Models: {len(new_models)}")
    
    # Quick verification
    with open(MODELS_JSON_PATH, 'r') as f:
        data = json.load(f)
        if PROVIDER_ID in data:
            print("✅ Provider verified in models.json")
            api = data[PROVIDER_ID]["api"]
            model_count = len(data[PROVIDER_ID]["models"])
            print(f"✅ API: {api}, Models: {model_count}")
        else:
            print("❌ Provider not found after write")

if __name__ == "__main__":
    main()