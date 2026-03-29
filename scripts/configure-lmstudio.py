#!/usr/bin/env python3
"""
Update LM Studio provider in opencode models.json with local server models.
"""

import json
import sys
import os
import urllib.request
import subprocess

MODELS_JSON_PATH = os.path.expanduser("~/.cache/opencode/models.json")
LM_STUDIO_URL = "http://192.168.101.21:1234/v1/models"
NEW_PROVIDER_ID = "lmstudio-local-192-168-101-21"

def fetch_lmstudio_models():
    """Fetch model list from LM Studio server."""
    try:
        req = urllib.request.Request(LM_STUDIO_URL)
        with urllib.request.urlopen(req, timeout=10) as response:
            data = json.load(response)
            return [model["id"] for model in data.get("data", [])]
    except Exception as e:
        print(f"Error fetching models from LM Studio: {e}")
        sys.exit(1)

def get_model_details(model_id):
    """
    Return model details based on model ID.
    This is a heuristic mapping - adjust as needed.
    """
    # Default structure
    details = {
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
    
    # Model-specific overrides
    if "qwen" in model_id.lower():
        details["family"] = "qwen"
        details["limit"]["context"] = 262144
        details["limit"]["output"] = 65536
        if "coder" in model_id.lower():
            details["name"] = "Qwen3 Coder " + model_id.split("-")[-1].upper()
        elif "35b" in model_id.lower():
            details["name"] = "Qwen3.5 35B A3B"
    
    elif "gpt-oss" in model_id.lower():
        details["family"] = "gpt-oss"
        details["reasoning"] = True
        details["limit"]["context"] = 131072
        details["limit"]["output"] = 32768
    
    elif "mistral" in model_id.lower():
        details["family"] = "mistral"
        details["reasoning"] = "reasoning" in model_id.lower()
        details["limit"]["context"] = 262144
        details["limit"]["output"] = 65536
        if "ministral" in model_id.lower():
            details["name"] = "Ministral 3 14B Reasoning"
    
    elif "embedding" in model_id.lower():
        # Skip embedding models for now
        return None
    
    return details

def main():
    # Backup original file
    backup_path = MODELS_JSON_PATH + ".backup"
    if not os.path.exists(backup_path):
        subprocess.run(["cp", MODELS_JSON_PATH, backup_path], check=True)
        print(f"Created backup at {backup_path}")
    
    # Load models.json
    with open(MODELS_JSON_PATH, 'r') as f:
        data = json.load(f)
    
    # Fetch available models from LM Studio server
    model_ids = fetch_lmstudio_models()
    print(f"Found {len(model_ids)} models on LM Studio server:")
    for mid in model_ids:
        print(f"  - {mid}")
    
    # Create new models dictionary
    new_models = {}
    for model_id in model_ids:
        details = get_model_details(model_id)
        if details is None:
            print(f"Skipping embedding model: {model_id}")
            continue
        
        # Check if model exists in existing lmstudio provider
        existing_lmstudio = data.get("lmstudio", {}).get("models", {})
        if model_id in existing_lmstudio:
            # Keep existing details but update id and name
            existing = existing_lmstudio[model_id]
            existing["id"] = model_id
            existing["name"] = details["name"]
            new_models[model_id] = existing
            print(f"Using existing definition for {model_id}")
        else:
            new_models[model_id] = details
            print(f"Created new definition for {model_id}")
    
    # Create new provider based on existing lmstudio provider
    existing_lmstudio = data.get("lmstudio", {})
    new_provider = existing_lmstudio.copy()
    new_provider["id"] = NEW_PROVIDER_ID
    new_provider["api"] = "http://192.168.101.21:1234/v1"
    new_provider["name"] = "LM Studio (192.168.101.21)"
    new_provider["models"] = new_models
    
    # Add or replace provider in data
    data[NEW_PROVIDER_ID] = new_provider
    
    # Write updated models.json
    temp_path = MODELS_JSON_PATH + ".tmp"
    with open(temp_path, 'w') as f:
        json.dump(data, f, indent=2)
    
    # Replace original
    os.rename(temp_path, MODELS_JSON_PATH)
    print(f"\n✅ Updated {MODELS_JSON_PATH}")
    print(f"✅ Added provider: {NEW_PROVIDER_ID}")
    print(f"✅ API endpoint: {new_provider['api']}")
    print(f"✅ Models: {len(new_models)}")
    
    # Verify the update
    print("\nVerification:")
    subprocess.run(["jq", f'.{NEW_PROVIDER_ID}.api', MODELS_JSON_PATH], check=False)
    subprocess.run(["jq", f'.{NEW_PROVIDER_ID}.models | keys', MODELS_JSON_PATH], check=False)

if __name__ == "__main__":
    main()