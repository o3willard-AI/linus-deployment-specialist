#!/usr/bin/env python3
"""
Update the lmstudio-local-192-168-101-21 provider models to match server.
"""

import json
import sys
import os
import urllib.request

MODELS_JSON_PATH = os.path.expanduser("~/.cache/opencode/models.json")
LM_STUDIO_URL = "http://192.168.101.21:1234/v1/models"
PROVIDER_ID = "lmstudio"

def fetch_server_models():
    """Fetch model list from LM Studio server."""
    try:
        req = urllib.request.Request(LM_STUDIO_URL)
        with urllib.request.urlopen(req, timeout=10) as response:
            data = json.load(response)
            return [model["id"] for model in data.get("data", [])]
    except Exception as e:
        print(f"Error fetching models: {e}")
        sys.exit(1)

def get_model_template(model_id, existing_models):
    """Get model definition template."""
    # Check if we have an existing definition for this exact ID
    if model_id in existing_models:
        return existing_models[model_id]
    
    # Check for similar model (same base name)
    # For qwen/qwen3.5-35b-a3b, use qwen/qwen3-30b-a3b-2507 as template
    if model_id == "qwen/qwen3.5-35b-a3b":
        template_id = "qwen/qwen3-30b-a3b-2507"
        if template_id in existing_models:
            template = existing_models[template_id].copy()
            template["id"] = model_id
            template["name"] = "Qwen3.5 35B A3B"
            return template
    
    # For mistralai/ministral-3-14b-reasoning
    if model_id == "mistralai/ministral-3-14b-reasoning":
        # Use openai/gpt-oss-20b as template (has reasoning=true)
        template = existing_models.get("openai/gpt-oss-20b", {}).copy()
        template["id"] = model_id
        template["name"] = "Ministral 3 14B Reasoning"
        template["family"] = "mistral"
        template["reasoning"] = True
        template["limit"]["context"] = 262144
        template["limit"]["output"] = 65536
        return template
    
    # Default template
    return {
        "id": model_id,
        "name": model_id.split("/")[-1].replace("-", " ").title(),
        "family": model_id.split("/")[0] if "/" in model_id else "unknown",
        "attachment": False,
        "reasoning": False,
        "tool_call": True,
        "temperature": True,
        "release_date": "2025-01-01",
        "last_updated": "2025-01-01",
        "modalities": {
            "input": ["text"],
            "output": ["text"]
        },
        "open_weights": True,
        "cost": {
            "input": 0,
            "output": 0
        },
        "limit": {
            "context": 131072,
            "output": 32768
        }
    }

def main():
    # Load models.json
    with open(MODELS_JSON_PATH, 'r') as f:
        data = json.load(f)
    
    # Fetch server models
    server_models = fetch_server_models()
    print(f"Server models: {server_models}")
    
    # Filter out embedding models
    server_models = [m for m in server_models if "embedding" not in m]
    print(f"Filtered models: {server_models}")
    
    # Get existing models from provider
    provider = data.get(PROVIDER_ID)
    if not provider:
        print(f"Provider {PROVIDER_ID} not found!")
        sys.exit(1)
    
    existing_models = provider.get("models", {})
    
    # Build new models dict
    new_models = {}
    for model_id in server_models:
        new_models[model_id] = get_model_template(model_id, existing_models)
        print(f"Added model: {model_id}")
    
    # Update provider
    provider["models"] = new_models
    data[PROVIDER_ID] = provider
    
    # Write back
    temp_path = MODELS_JSON_PATH + ".tmp"
    with open(temp_path, 'w') as f:
        json.dump(data, f, indent=2)
    
    # Replace original
    os.rename(temp_path, MODELS_JSON_PATH)
    print(f"\n✅ Updated {PROVIDER_ID} with {len(new_models)} models")
    
    # Verification
    print("\nVerification:")
    with open(MODELS_JSON_PATH, 'r') as f:
        data = json.load(f)
        models = data[PROVIDER_ID]["models"]
        print(f"Model count: {len(models)}")
        for mid in models.keys():
            print(f"  - {mid}")

if __name__ == "__main__":
    main()