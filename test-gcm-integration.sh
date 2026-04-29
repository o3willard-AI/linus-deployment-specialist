#!/bin/bash

# Test script for Git Credential Manager integration

echo "=== Git Credential Manager Integration Test ==="
echo ""

# Source the required libraries
echo "1. Sourcing libraries..."
cd /tmp/linus-deployment-specialist

# Check if GCM is properly configured
echo "2. Checking GCM configuration..."
GCM_CONFIG=$(git config --global credential.helper 2>/dev/null)
echo "GCM configured as: $GCM_CONFIG"

if [[ -n "$GCM_CONFIG" && "$GCM_CONFIG" == *"gcm"* ]]; then
    echo "✓ GCM is properly configured"
else
    echo "✗ GCM configuration issue detected"
fi

echo ""

# Test configuration generation functions
echo "3. Testing configuration generation functions..."

# Source the config templates library
source shared/lib/config-templates.sh

echo "   a) Testing standard config generation..."
if output=$(apply_agent_config "opencode" "192.168.101.96" "sblanken" "22" 2>&1); then
    echo "✓ Standard config generation successful"
    echo "   Output: $output"
else
    echo "✗ Standard config generation failed"
    echo "   Error: $output"
fi

echo ""

echo "   b) Testing GCM-aware config generation..."
if output=$(apply_gcm_aware_config "opencode" "192.168.101.96" "sblanken" "22" 2>&1); then
    echo "✓ GCM-aware config generation successful"
    echo "   Output: $output"
else
    echo "✗ GCM-aware config generation failed"
    echo "   Error: $output"
fi

echo ""

# Test MCP helper functions
echo "4. Testing MCP helper functions..."
source shared/lib/mcp-helpers.sh

echo "   a) Checking if MCP is installed..."
if check_mcp_installed; then
    echo "✓ ssh-mcp is installed"
else
    echo "✗ ssh-mcp installation issue"
fi

echo ""
echo "=== Test Complete ==="