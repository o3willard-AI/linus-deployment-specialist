#!/usr/bin/env python3
"""
Add or update LM Studio local provider in opencode models.json.
"""

import json
import os
import sys

MODELS_JSON_PATH = os.path.expanduser("~/.cache/opencode/models.json")
PROVIDER_ID = "lmstudio-local-192-168-101-21"
API_URL = "http://192.168.101.21:1234/v1"

def main():
    # Load models.json
    with open(MODELS_JSON_PATH, 'r') as f:
        data = json.load(f)
    
    # Check if provider already exists
    if PROVIDER_ID in data:
        print(f"Provider {PROVIDER_ID} already exists, updating...")
        provider = data[PROVIDER_ID]
    else:
        print(f"Creating new provider {PROVIDER_ID}...")
        # Copy from existing lmstudio provider
        if "lmstudio" not in data:
            print("Error: base lmstudio provider not found")
            sys.exit(1)
        provider = data["lmstudio"].copy()
        provider["id"] = PROVIDER_ID
        provider["name"] = f"LM Studio ({API_URL})"
    
    # Update API endpoint
    provider["api"] = API_URL + "/v1"
    
    # Keep existing models for now (will be updated separately)
    print(f"Provider API: {provider['api']}")
    
    # Add/update provider in data
    data[PROVIDER_ID] = provider
    
    # Write back
    temp_path = MODELS_JSON_PATH + ".tmp"
    with open(temp_path, 'w') as f:
        json.dump(data, f, separators=(',', ':'))  # compact JSON
    
    # Replace original
    os.rename(temp_path, MODELS_JSON_PATH)
    print(f"✅ Updated {MODELS_JSON_PATH}")
    print(f"✅ Provider {PROVIDER_ID} added/updated")
    
    # Verify
    with open(MODELS_JSON_PATH, 'r') as f:
        data = json.load(f)
        if PROVIDER_ID in data:
            print(f"✅ Verification passed: provider exists with API {data[PROVIDER_ID].get('api')}")
        else:
            print("❌ Verification failed: provider not found")

if __name__ == "__main__":
    main()