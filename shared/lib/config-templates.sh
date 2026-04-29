#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist - Standardized Configuration Templates
# =============================================================================
# Provides standardized configuration templates for all supported AI agents
# to ensure consistent MCP integration across different coding agents.
# =============================================================================

# Source base libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${LINUS_LOGGING_LOADED:-}" ]]; then
    source "${SCRIPT_DIR}/logging.sh"
fi

# Mark config-templates as loaded
LINUS_CONFIG_TEMPLATES_LOADED=1

# -----------------------------------------------------------------------------
# Configuration Template Functions
# -----------------------------------------------------------------------------

# Generate standardized MCP configuration for a specific agent type
generate_agent_config_template() {
    local agent_type="$1"
    
    case "$agent_type" in
        "claude")
            generate_claude_mcp_config
            ;;
        "gemini")
            generate_gemini_mcp_config
            ;;
        "copilot")
            generate_copilot_mcp_config
            ;;
        "cursor")
            generate_cursor_mcp_config
            ;;
        "cline")
            generate_cline_mcp_config
            ;;
        "opencode")
            generate_opencode_mcp_config
            ;;
        "hermes")
            generate_hermes_mcp_config
            ;;
        *)
            # Generic fallback template
            generate_generic_mcp_config
            ;;
    esac
}

# Generate Claude Code MCP configuration
generate_claude_mcp_config() {
    cat <<EOF
{
  "mcpServers": {
    "linus-ssh": {
      "command": "ssh-mcp",
      "args": [
        "--host={{HOST}}",
        "--port={{PORT}}", 
        "--user={{USER}}",
        "--timeout=60000",
        "--maxChars=none"
      ]
    }
  }
}
EOF
}

# Generate Gemini Code MCP configuration  
generate_gemini_mcp_config() {
    cat <<EOF
{
  "mcpServers": {
    "linus-ssh": {
      "command": "ssh-mcp",
      "args": [
        "--host={{HOST}}",
        "--port={{PORT}}",
        "--user={{USER}}",
        "--timeout=60000",
        "--maxChars=none"
      ]
    }
  }
}
EOF
}

# Generate GitHub Copilot MCP configuration
generate_copilot_mcp_config() {
    cat <<EOF
{
  "mcpServers": {
    "linus-ssh": {
      "command": "ssh-mcp", 
      "args": [
        "--host={{HOST}}",
        "--port={{PORT}}",
        "--user={{USER}}",
        "--timeout=60000",
        "--maxChars=none"
      ]
    }
  }
}
EOF
}

# Generate Cursor MCP configuration
generate_cursor_mcp_config() {
    cat <<EOF
{
  "mcpServers": {
    "linus-ssh": {
      "command": "ssh-mcp",
      "args": [
        "--host={{HOST}}", 
        "--port={{PORT}}",
        "--user={{USER}}",
        "--timeout=60000",
        "--maxChars=none"
      ]
    }
  }
}
EOF
}

# Generate Cline MCP configuration
generate_cline_mcp_config() {
    cat <<EOF
{
  "mcpServers": {
    "linus-ssh": {
      "command": "ssh-mcp",
      "args": [
        "--host={{HOST}}",
        "--port={{PORT}}",
        "--user={{USER}}", 
        "--timeout=60000",
        "--maxChars=none"
      ]
    }
  }
}
EOF
}

# Generate Opencode MCP configuration
generate_opencode_mcp_config() {
    cat <<EOF
{
  "mcpServers": {
    "linus-ssh": {
      "command": "ssh-mcp",
      "args": [
        "--host={{HOST}}",
        "--port={{PORT}}",
        "--user={{USER}}",
        "--timeout=60000",
        "--maxChars=none"
      ]
    }
  }
}
EOF
}

# Generate Hermes MCP configuration
generate_hermes_mcp_config() {
    cat <<EOF
{
  "mcpServers": {
    "linus-ssh": {
      "command": "ssh-mcp",
      "args": [
        "--host={{HOST}}",
        "--port={{PORT}}", 
        "--user={{USER}}",
        "--timeout=60000",
        "--maxChars=none"
      ]
    }
  }
}
EOF
}

# Generate generic MCP configuration (fallback)
generate_generic_mcp_config() {
    cat <<EOF
{
  "mcpServers": {
    "linus-ssh": {
      "command": "ssh-mcp",
      "args": [
        "--host={{HOST}}",
        "--port={{PORT}}",
        "--user={{USER}}",
        "--timeout=60000",
        "--maxChars=none"
      ]
    }
  }
}
EOF
}

# -----------------------------------------------------------------------------
# Agent-Specific Template Functions
# -----------------------------------------------------------------------------

# Generate agent-specific command templates for execution
generate_command_template() {
    local agent_type="$1" 
    local tool_type="${2:-exec}"
    
    case "$agent_type,$tool_type" in
        "claude,exec")
            cat <<'EOF'
{
  "tool": "exec",
  "arguments": {
    "command": "{{COMMAND}}"
  }
}
EOF
            ;;
        "gemini,exec")
            cat <<'EOF'
{
  "tool": "exec", 
  "arguments": {
    "command": "{{COMMAND}}"
  }
}
EOF
            ;;
        "copilot,exec")
            cat <<'EOF'
{
  "tool": "exec",
  "arguments": {
    "command": "{{COMMAND}}"  
  }
}
EOF
            ;;
        "cursor,exec")
            cat <<'EOF'
{
  "tool": "exec",
  "arguments": {
    "command": "{{COMMAND}}"
  }
}
EOF
            ;;
        "cline,exec")
            cat <<'EOF'
{
  "tool": "exec",
  "arguments": {
    "command": "{{COMMAND}}"
  }
}
EOF
            ;;
        "opencode,exec")
            cat <<'EOF'
{
  "tool": "exec",
  "arguments": {
    "command": "{{COMMAND}}"
  }
EOF
            ;;
        "hermes,exec")
            cat <<'EOF'
{
  "tool": "exec",
  "arguments": {
    "command": "{{COMMAND}}"
  }
}
EOF
            ;;
        *)
            # Default generic template
            cat <<'EOF'
{
  "tool": "{{TOOL}}",
  "arguments": {
    "command": "{{COMMAND}}"
  }
}
EOF
            ;;
    esac
}

# Generate standardized configuration file content
generate_standardized_config() {
    local agent_type="$1"
    local host="$2"
    local user="$3" 
    local port="${4:-22}"
    local key_path="${5:-}"
    
    # Get the appropriate template for this agent
    local config_template=""
    config_template=$(generate_agent_config_template "$agent_type")
    
    # Replace placeholders with actual values
    local config_content="$config_template"
    config_content="${config_content//{{HOST}}/$host}"
    config_content="${config_content//{{USER}}/$user}"
    config_content="${config_content//{{PORT}}/$port}"
    
    if [[ -n "$key_path" ]]; then
        # For SSH key, we need to add it to the args
        local key_line="--key=$key_path"
        config_content=$(echo "$config_content" | sed "s/\"args\": \[/\"args\": \[ \"$key_line\",/")
    fi
    
    echo "$config_content"
}

# Generate Git credential-aware configuration for MCP integration
generate_gcm_aware_config() {
    local agent_type="$1"
    local host="$2"
    local user="$3" 
    local port="${4:-22}"
    local key_path="${5:-}"
    
    # First generate the standard config
    local config_content=""
    config_content=$(generate_standardized_config "$agent_type" "$host" "$user" "$port" "$key_path")
    
    # Add Git credential management information to the configuration
    # This helps the agent understand that credentials should be managed via GCM
    cat <<EOF
{
  "mcpServers": {
    "linus-ssh": {
      "command": "ssh-mcp",
      "args": [
        "--host=${host}",
        "--port=${port}",
        "--user=${user}",
        "--timeout=60000",
        "--maxChars=none"
      ]
    }
  },
  "gitCredentialManager": {
    "enabled": true,
    "provider": "gcm",
    "description": "Using Git Credential Manager for secure credential handling on the same system as the AI agent"
  }
}
EOF
}

# -----------------------------------------------------------------------------
# Configuration Validation Functions
# -----------------------------------------------------------------------------

# Validate that a configuration template is properly formatted
validate_config_template() {
    local config_content="$1"
    
    # Basic JSON validation
    if ! echo "$config_content" | jq . &>/dev/null; then
        log_error "Invalid JSON in configuration template"
        return 1
    fi
    
    # Check for required MCP structure
    if ! echo "$config_content" | jq -e '.mcpServers' &>/dev/null; then
        log_error "Missing 'mcpServers' in configuration"
        return 1
    fi
    
    log_debug "Configuration template validation passed"
    return 0
}

# Validate agent-specific configurations
validate_agent_config() {
    local agent_type="$1"
    local config_content="$2"
    
    log_debug "Validating configuration for agent: $agent_type"
    
    # First validate general structure
    if ! validate_config_template "$config_content"; then
        return 1
    fi
    
    # Agent-specific validations would go here
    case "$agent_type" in
        "claude")
            # Claude specific validation
            log_debug "Validating Claude Code configuration"
            ;;
        "gemini")
            # Gemini specific validation
            log_debug "Validating Gemini Code configuration"
            ;;
        "copilot")
            # Copilot specific validation
            log_debug "Validating GitHub Copilot configuration"
            ;;
        *)
            log_debug "Validating generic agent configuration"
            ;;
    esac
    
    return 0
}

# -----------------------------------------------------------------------------
# Configuration Management Functions  
# -----------------------------------------------------------------------------

# Apply standardized configuration for the current agent
apply_agent_config() {
    local agent_type="$1"
    local host="${2:-}"
    local user="${3:-}"
    local port="${4:-22}"
    local key_path="${5:-}"
    
    log_header "Applying Standardized Configuration for $agent_type"
    
    # Generate the configuration
    local config_content=""
    config_content=$(generate_standardized_config "$agent_type" "$host" "$user" "$port" "$key_path")
    
    if [[ -z "$config_content" ]]; then
        log_error "Failed to generate configuration for agent: $agent_type"
        return 1
    fi
    
    # Validate the configuration
    if ! validate_agent_config "$agent_type" "$config_content"; then
        log_error "Configuration validation failed for agent: $agent_type"
        return 1
    fi
    
    log_info "Configuration generated successfully for $agent_type"
    
    # Return the configuration content
    echo "$config_content"
    return 0
}

# Apply Git Credential Manager aware configuration for the current agent  
apply_gcm_aware_config() {
    local agent_type="$1"
    local host="${2:-}"
    local user="${3:-}"
    local port="${4:-22}"
    local key_path="${5:-}"
    
    log_header "Applying GCM-Aware Configuration for $agent_type"
    
    # Generate the GCM-aware configuration
    local config_content=""
    config_content=$(generate_gcm_aware_config "$agent_type" "$host" "$user" "$port" "$key_path")
    
    if [[ -z "$config_content" ]]; then
        log_error "Failed to generate GCM-aware configuration for agent: $agent_type"
        return 1
    fi
    
    # Validate the configuration
    if ! validate_agent_config "$agent_type" "$config_content"; then
        log_error "GCM-aware configuration validation failed for agent: $agent_type"
        return 1
    fi
    
    log_info "GCM-aware configuration generated successfully for $agent_type"
    
    # Return the configuration content
    echo "$config_content"
    return 0
}

# Get configuration template for a specific tool
get_tool_config() {
    local tool_name="$1"
    local agent_type="${2:-generic}"
    
    case "$tool_name" in
        "exec")
            case "$agent_type" in
                "claude")
                    echo '{"tool": "exec", "arguments": {"command": "{{COMMAND}}"}}'
                    ;;
                "gemini")
                    echo '{"tool": "exec", "arguments": {"command": "{{COMMAND}}"}}' 
                    ;;
                *)
                    echo '{"tool": "exec", "arguments": {"command": "{{COMMAND}}"}}'
                    ;;
            esac
            ;;
        "sudo-exec")
            case "$agent_type" in
                "claude")
                    echo '{"tool": "sudo-exec", "arguments": {"command": "{{COMMAND}}"}}'
                    ;;
                "gemini") 
                    echo '{"tool": "sudo-exec", "arguments": {"command": "{{COMMAND}}"}}'
                    ;;
                *)
                    echo '{"tool": "sudo-exec", "arguments": {"command": "{{COMMAND}}"}}'
                    ;;
            esac
            ;;
        *)
            # Default generic tool config
            echo '{"tool": "{{TOOL}}", "arguments": {"command": "{{COMMAND}}"}}'
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Template Utility Functions
# -----------------------------------------------------------------------------

# List all supported agent types
list_supported_agents() {
    cat <<EOF
Supported AI Agents:
- Claude Code (anthropic)
- Gemini Code Assist (google) 
- GitHub Copilot (github)
- Cursor (cursor)
- Cline (cline)
- Opencode (opencode)
- Hermes (hermes)
- Generic (fallback)

All agents use the same ssh-mcp protocol with standardized configuration templates.
EOF
}

# Generate documentation for configuration templates
generate_config_docs() {
    cat <<EOF
# Standardized Configuration Templates

This document describes the standardized configuration templates used by Linus Deployment Specialist 
to ensure consistent MCP integration across different AI coding agents.

## Agent Types

The following agent types are supported with standardized templates:

1. Claude Code - Anthropic
2. Gemini Code Assist - Google  
3. GitHub Copilot - GitHub
4. Cursor - Cursor
5. Cline - Cline
6. Opencode - Opencode
7. Hermes - Hermes
8. Generic - Fallback for unknown agents

## Configuration Structure

All configurations follow this standardized structure:
{
  "mcpServers": {
    "linus-ssh": {
      "command": "ssh-mcp",
      "args": [
        "--host={{HOST}}", 
        "--port={{PORT}}",
        "--user={{USER}}",
        "--timeout=60000",
        "--maxChars=none"
      ]
    }
  }
}

## Tool Templates

Each agent supports the following standard tools:
- exec: Execute shell commands
- sudo-exec: Execute with sudo privileges

The templates are designed to work consistently across all supported agents.
EOF
}

# Display configuration information
show_config_info() {
    local agent_type="$1"
    
    log_header "Configuration Information for $agent_type"
    
    echo "Agent Type: $agent_type"
    echo "Template Format: JSON"
    echo "MCP Server: ssh-mcp" 
    echo "Timeout: 60000ms"
    echo "Max Characters: none"
    echo ""
    echo "Supported Tools:"
    echo "  - exec: Execute shell commands"
    echo "  - sudo-exec: Execute with sudo privileges"
    
    # Show the actual template
    echo ""
    echo "Configuration Template:"
    generate_agent_config_template "$agent_type" | jq .
}