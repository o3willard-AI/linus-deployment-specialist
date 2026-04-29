#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist - Agent Detection System
# =============================================================================
# Automatically detects which AI agent is running this script and configures
# the system accordingly to ensure compatibility.
# =============================================================================

# Source base libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${LINUS_LOGGING_LOADED:-}" ]]; then
    source "${SCRIPT_DIR}/logging.sh"
fi

# Mark agent-detection as loaded
LINUS_AGENT_DETECTION_LOADED=1

# -----------------------------------------------------------------------------
# Agent Detection Functions
# -----------------------------------------------------------------------------

# Detect the AI agent currently running this script
detect_current_agent() {
    local detected_agent="unknown"
    
    # Check environment variables first (most reliable method)
    if [[ -n "${ANTHROPIC_API_KEY:-}" ]] || [[ -n "${CLAUDE_CODE:-}" ]] || [[ -n "${CLAUDE_API_KEY:-}" ]]; then
        detected_agent="claude"
    elif [[ -n "${GOOGLE_API_KEY:-}" ]] || [[ -n "${GEMINI_API_KEY:-}" ]] || [[ -n "${GEMINI_CODE:-}" ]]; then
        detected_agent="gemini"
    elif [[ -n "${GITHUB_TOKEN:-}" ]] || [[ -n "${COPILOT:-}" ]]; then
        detected_agent="copilot"
    elif [[ -n "${CURSOR_API_KEY:-}" ]] || [[ -n "${CURSOR:-}" ]]; then
        detected_agent="cursor"
    elif [[ -n "${CLINE_API_KEY:-}" ]] || [[ -n "${CLINE:-}" ]]; then
        detected_agent="cline"
    elif [[ -n "${OPENCODE_API_KEY:-}" ]] || [[ -n "${OPENCODE:-}" ]]; then
        detected_agent="opencode"
    elif [[ -n "${HERMES_API_KEY:-}" ]] || [[ -n "${HERMES:-}" ]]; then
        detected_agent="hermes"
    elif [[ -n "${OPENCODE_API_KEY:-}" ]]; then
        detected_agent="opencode" 
    else
        # Check command line arguments for agent indicators
        if [[ "$*" == *"claude"* ]] || [[ "$*" == *"anthropic"* ]]; then
            detected_agent="claude"
        elif [[ "$*" == *"gemini"* ]] || [[ "$*" == *"google"* ]]; then
            detected_agent="gemini"
        elif [[ "$*" == *"copilot"* ]] || [[ "$*" == *"github"* ]]; then
            detected_agent="copilot"
        elif [[ "$*" == *"cursor"* ]]; then
            detected_agent="cursor" 
        elif [[ "$*" == *"cline"* ]] || [[ "$*" == *"cline-ai"* ]]; then
            detected_agent="cline"
        elif [[ "$*" == *"opencode"* ]]; then
            detected_agent="opencode"
        elif [[ "$*" == *"hermes"* ]]; then
            detected_agent="hermes"
        else
            # Fallback to checking available tools
            if command -v ssh-mcp &>/dev/null; then
                detected_agent="generic"
            else
                detected_agent="unknown"
            fi
        fi
    fi
    
    echo "$detected_agent"
}

# Get detailed agent information
get_agent_info() {
    local agent_type="$1"
    
    case "$agent_type" in
        "claude")
            cat <<EOF
{
  "name": "Claude Code",
  "type": "anthropic",
  "version": "latest",
  "mcp_support": true,
  "features": [
    "exec",
    "sudo-exec"
  ],
  "compatibility": "high"
}
EOF
            ;;
        "gemini")
            cat <<EOF
{
  "name": "Gemini Code Assist", 
  "type": "google",
  "version": "latest",
  "mcp_support": true,
  "features": [
    "exec", 
    "sudo-exec"
  ],
  "compatibility": "high"
}
EOF
            ;;
        "copilot")
            cat <<EOF
{
  "name": "GitHub Copilot",
  "type": "github", 
  "version": "latest",
  "mcp_support": true,
  "features": [
    "exec",
    "sudo-exec"
  ],
  "compatibility": "high"
}
EOF
            ;;
        "cursor")
            cat <<EOF
{
  "name": "Cursor",
  "type": "cursor",
  "version": "latest",
  "mcp_support": true,
  "features": [
    "exec",
    "sudo-exec"
  ],
  "compatibility": "high"
}
EOF
            ;;
        "cline")
            cat <<EOF
{
  "name": "Cline",
  "type": "cline",
  "version": "latest",
  "mcp_support": true,
  "features": [
    "exec", 
    "sudo-exec"
  ],
  "compatibility": "high"
}
EOF
            ;;
        "opencode")
            cat <<EOF
{
  "name": "Opencode",
  "type": "opencode",
  "version": "latest",
  "mcp_support": true,
  "features": [
    "exec",
    "sudo-exec"
  ],
  "compatibility": "high"
}
EOF
            ;;
        "hermes")
            cat <<EOF
{
  "name": "Hermes", 
  "type": "hermes",
  "version": "latest",
  "mcp_support": true,
  "features": [
    "exec",
    "sudo-exec"
  ],
  "compatibility": "high"
}
EOF
            ;;
        *)
            cat <<EOF
{
  "name": "Generic Agent",
  "type": "unknown",
  "version": "unknown", 
  "mcp_support": false,
  "features": [
    "exec",
    "sudo-exec"
  ],
  "compatibility": "medium"
}
EOF
            ;;
    esac
}

# Detect and configure agent automatically
auto_configure_agent() {
    local detected_agent=$(detect_current_agent)
    
    log_header "Auto-Configuring for Agent: $detected_agent"
    
    # Set environment variables for the detected agent
    export CURRENT_AGENT_TYPE="$detected_agent"
    export MCP_AGENT_TYPE="$detected_agent"
    
    # Load specific configuration for this agent
    case "$detected_agent" in
        "claude")
            configure_claude_agent
            ;;
        "gemini") 
            configure_gemini_agent
            ;;
        "copilot")
            configure_copilot_agent
            ;;
        "cursor")
            configure_cursor_agent
            ;;
        "cline")
            configure_cline_agent
            ;;
        "opencode")
            configure_opencode_agent
            ;;
        "hermes")
            configure_hermes_agent
            ;;
        *)
            # Generic fallback configuration
            log_info "Using generic agent configuration"
            ;;
    esac
    
    # Verify configuration
    if verify_agent_configuration; then
        log_info "Agent auto-configuration completed successfully"
        return 0
    else
        log_error "Agent auto-configuration failed"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Agent-Specific Configuration Functions
# -----------------------------------------------------------------------------

# Configure Claude Code agent
configure_claude_agent() {
    log_debug "Configuring for Claude Code agent"
    
    # Set Claude-specific environment variables
    export MCP_SERVER_TYPE="ssh-mcp" 
    export MCP_TIMEOUT=60000
    
    # Verify Claude-specific requirements
    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        log_debug "Anthropic API key detected"
    fi
    
    # Setup Claude Code specific paths or configurations
    setup_claude_specific_config
}

# Configure Gemini agent  
configure_gemini_agent() {
    log_debug "Configuring for Gemini agent"
    
    # Set Gemini-specific environment variables
    export MCP_SERVER_TYPE="ssh-mcp"
    export MCP_TIMEOUT=60000
    
    # Verify Gemini-specific requirements
    if [[ -n "${GOOGLE_API_KEY:-}" ]] || [[ -n "${GEMINI_API_KEY:-}" ]]; then
        log_debug "Google API key detected"
    fi
    
    # Setup Gemini specific configurations
    setup_gemini_specific_config
}

# Configure GitHub Copilot agent
configure_copilot_agent() {
    log_debug "Configuring for GitHub Copilot agent"
    
    # Set Copilot-specific environment variables
    export MCP_SERVER_TYPE="ssh-mcp" 
    export MCP_TIMEOUT=60000
    
    # Verify Copilot requirements
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        log_debug "GitHub token detected"
    fi
    
    # Setup Copilot specific configurations  
    setup_copilot_specific_config
}

# Configure Cursor agent
configure_cursor_agent() {
    log_debug "Configuring for Cursor agent"
    
    # Set Cursor-specific environment variables
    export MCP_SERVER_TYPE="ssh-mcp"
    export MCP_TIMEOUT=60000
    
    # Verify Cursor requirements
    if [[ -n "${CURSOR_API_KEY:-}" ]]; then
        log_debug "Cursor API key detected"
    fi
    
    # Setup Cursor specific configurations
    setup_cursor_specific_config
}

# Configure Cline agent
configure_cline_agent() {
    log_debug "Configuring for Cline agent"
    
    # Set Cline-specific environment variables
    export MCP_SERVER_TYPE="ssh-mcp" 
    export MCP_TIMEOUT=60000
    
    # Verify Cline requirements
    if [[ -n "${CLINE_API_KEY:-}" ]]; then
        log_debug "Cline API key detected"
    fi
    
    # Setup Cline specific configurations
    setup_cline_specific_config
}

# Configure Opencode agent
configure_opencode_agent() {
    log_debug "Configuring for Opencode agent"
    
    # Set Opencode-specific environment variables
    export MCP_SERVER_TYPE="ssh-mcp"
    export MCP_TIMEOUT=60000
    
    # Verify Opencode requirements
    if [[ -n "${OPENCODE_API_KEY:-}" ]]; then
        log_debug "Opencode API key detected"
    fi
    
    # Setup Opencode specific configurations
    setup_opencode_specific_config
}

# Configure Hermes agent
configure_hermes_agent() {
    log_debug "Configuring for Hermes agent"
    
    # Set Hermes-specific environment variables
    export MCP_SERVER_TYPE="ssh-mcp"
    export MCP_TIMEOUT=60000
    
    # Verify Hermes requirements
    if [[ -n "${HERMES_API_KEY:-}" ]]; then
        log_debug "Hermes API key detected"  
    fi
    
    # Setup Hermes specific configurations
    setup_hermes_specific_config
}

# -----------------------------------------------------------------------------
# Agent-Specific Configuration Helpers
# -----------------------------------------------------------------------------

# Setup Claude-specific configurations
setup_claude_specific_config() {
    log_debug "Setting up Claude Code specific configuration"
    
    # Check for Claude Code configuration files
    local claude_config_dir="${HOME}/.config/claude-code"
    if [[ -d "$claude_config_dir" ]]; then
        log_debug "Claude Code config directory found: $claude_config_dir"
    fi
    
    # Set Claude-specific MCP configuration path
    export CLAUDE_MCP_CONFIG="${claude_config_dir}/mcp.json"
}

# Setup Gemini-specific configurations
setup_gemini_specific_config() {
    log_debug "Setting up Gemini specific configuration"
    
    # Check for Gemini Code configuration files
    local gemini_config_dir="${HOME}/.config/gemini-code" 
    if [[ -d "$gemini_config_dir" ]]; then
        log_debug "Gemini Code config directory found: $gemini_config_dir"
    fi
    
    # Set Gemini-specific MCP configuration path
    export GEMINI_MCP_CONFIG="${gemini_config_dir}/mcp.json"
}

# Setup Copilot-specific configurations
setup_copilot_specific_config() {
    log_debug "Setting up GitHub Copilot specific configuration"
    
    # Check for Copilot configuration files
    local copilot_config_dir="${HOME}/.config/Code/User" 
    if [[ -d "$copilot_config_dir" ]]; then
        log_debug "GitHub Copilot config directory found: $copilot_config_dir"
    fi
    
    # Set Copilot-specific MCP configuration path
    export COPILOT_MCP_CONFIG="${copilot_config_dir}/mcp.json"
}

# Setup Cursor-specific configurations  
setup_cursor_specific_config() {
    log_debug "Setting up Cursor specific configuration"
    
    # Check for Cursor configuration files
    local cursor_config_dir="${HOME}/.cursor"
    if [[ -d "$cursor_config_dir" ]]; then
        log_debug "Cursor config directory found: $cursor_config_dir"
    fi
    
    # Set Cursor-specific MCP configuration path
    export CURSOR_MCP_CONFIG="${cursor_config_dir}/mcp.json"
}

# Setup Cline-specific configurations
setup_cline_specific_config() {
    log_debug "Setting up Cline specific configuration"
    
    # Check for Cline configuration files  
    local cline_config_dir="${HOME}/.cline"
    if [[ -d "$cline_config_dir" ]]; then
        log_debug "Cline config directory found: $cline_config_dir"
    fi
    
    # Set Cline-specific MCP configuration path
    export CLINE_MCP_CONFIG="${cline_config_dir}/mcp.json"
}

# Setup Opencode-specific configurations
setup_opencode_specific_config() {
    log_debug "Setting up Opencode specific configuration"
    
    # Check for Opencode configuration files
    local opencode_config_dir="${HOME}/.opencode" 
    if [[ -d "$opencode_config_dir" ]]; then
        log_debug "Opencode config directory found: $opencode_config_dir"
    fi
    
    # Set Opencode-specific MCP configuration path
    export OPENCODE_MCP_CONFIG="${opencode_config_dir}/mcp.json"
}

# Setup Hermes-specific configurations
setup_hermes_specific_config() {
    log_debug "Setting up Hermes specific configuration"
    
    # Check for Hermes configuration files
    local hermes_config_dir="${HOME}/.hermes" 
    if [[ -d "$hermes_config_dir" ]]; then
        log_debug "Hermes config directory found: $hermes_config_dir"
    fi
    
    # Set Hermes-specific MCP configuration path
    export HERMES_MCP_CONFIG="${hermes_config_dir}/mcp.json"
}

# -----------------------------------------------------------------------------
# Verification Functions
# -----------------------------------------------------------------------------

# Verify agent configuration is complete and correct
verify_agent_configuration() {
    local detected_agent=$(detect_current_agent)
    
    log_debug "Verifying configuration for agent: $detected_agent"
    
    # Basic verification checks
    if [[ -z "$detected_agent" ]] || [[ "$detected_agent" == "unknown" ]]; then
        log_warning "Could not detect agent type, using generic configuration"
        return 0
    fi
    
    # Verify required tools are available for this agent
    case "$detected_agent" in
        "claude")
            if ! command -v ssh-mcp &>/dev/null; then
                log_error "ssh-mcp not found for Claude Code"
                return 1
            fi
            ;;
        "gemini")
            if ! command -v ssh-mcp &>/dev/null; then
                log_error "ssh-mcp not found for Gemini Code" 
                return 1
            fi
            ;;
        "copilot")
            if ! command -v ssh-mcp &>/dev/null; then
                log_error "ssh-mcp not found for GitHub Copilot"
                return 1
            fi
            ;;
        *)
            # Generic check
            if ! command -v ssh-mcp &>/dev/null; then
                log_warning "ssh-mcp not found, but proceeding with generic configuration"
            fi
            ;;
    esac
    
    # Additional agent-specific verification would go here
    
    return 0
}

# Get current agent configuration status
get_agent_status() {
    local detected_agent=$(detect_current_agent)
    
    cat <<EOF
{
  "agent": "$detected_agent",
  "configured": true,
  "mcp_server": "ssh-mcp",
  "timeout": 60000,
  "features": [
    "exec",
    "sudo-exec"
  ],
  "environment": {
    "CURRENT_AGENT_TYPE": "$detected_agent",
    "MCP_AGENT_TYPE": "$detected_agent",
    "MCP_SERVER_TYPE": "ssh-mcp"
  }
}
EOF
}

# -----------------------------------------------------------------------------
# Agent Compatibility Report
# -----------------------------------------------------------------------------

# Generate compatibility report for current agent
generate_compatibility_report() {
    local detected_agent=$(detect_current_agent)
    
    log_header "Agent Compatibility Report"
    
    echo "Detected Agent: $detected_agent"
    echo ""
    
    # Get detailed agent info
    local agent_info=$(get_agent_info "$detected_agent")
    local name=$(echo "$agent_info" | jq -r '.name')
    local type=$(echo "$agent_info" | jq -r '.type') 
    local mcp_support=$(echo "$agent_info" | jq -r '.mcp_support')
    local compatibility=$(echo "$agent_info" | jq -r '.compatibility')
    
    echo "Agent Name: $name"
    echo "Agent Type: $type"
    echo "MCP Support: $mcp_support"
    echo "Compatibility Level: $compatibility"
    
    if [[ "$mcp_support" == "true" ]]; then
        echo ""
        echo "✓ MCP Protocol Support: Available"
        echo "✓ Compatible with Linus Deployment Specialist"
    else
        echo ""
        echo "✗ MCP Protocol Support: Not available"
        echo "⚠ Compatibility may be limited"
    fi
    
    # List supported features
    echo ""
    echo "Supported Features:"
    echo "  - exec: Execute shell commands"
    echo "  - sudo-exec: Execute with sudo privileges"
    
    if [[ "$detected_agent" != "unknown" ]]; then
        echo ""
        echo "Configuration Status: Configured for $detected_agent"
        return 0
    else
        echo ""
        echo "Configuration Status: Unknown agent type detected"
        return 1
    fi
}