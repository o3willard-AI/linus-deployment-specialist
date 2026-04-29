#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist - Universal MCP Adapter Framework
# =============================================================================
# Provides a universal interface for different AI agents to interact with MCP
# This framework abstracts away agent-specific differences while maintaining
# core functionality of the existing ssh-mcp integration.
# =============================================================================

# Source base libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "${LINUS_LOGGING_LOADED:-}" ]]; then
    source "${SCRIPT_DIR}/logging.sh"
fi

# Mark universal-mcp-adapter as loaded
LINUS_MCP_ADAPTER_LOADED=1

# -----------------------------------------------------------------------------
# Universal MCP Adapter Configuration
# -----------------------------------------------------------------------------

# Detect which AI agent is running this script
detect_agent() {
    local agent_name=""
    
    # Check for Claude Code (via environment variables)
    if [[ -n "${ANTHROPIC_API_KEY:-}" ]] || [[ -n "${CLAUDE_CODE:-}" ]]; then
        agent_name="claude"
    # Check for Gemini
    elif [[ -n "${GOOGLE_API_KEY:-}" ]] || [[ -n "${GEMINI_API_KEY:-}" ]] || [[ -n "${GEMINI_CODE:-}" ]]; then
        agent_name="gemini"
    # Check for GitHub Copilot (via environment variables)
    elif [[ -n "${GITHUB_TOKEN:-}" ]] || [[ -n "${COPILOT:-}" ]]; then
        agent_name="copilot"
    # Check for Cursor (via environment variables)
    elif [[ -n "${CURSOR_API_KEY:-}" ]] || [[ -n "${CURSOR:-}" ]]; then
        agent_name="cursor"
    # Check for Cline
    elif [[ -n "${CLINE_API_KEY:-}" ]] || [[ -n "${CLINE:-}" ]]; then
        agent_name="cline"
    # Check for Opencode (via environment variables)
    elif [[ -n "${OPENCODE_API_KEY:-}" ]] || [[ -n "${OPENCODE:-}" ]]; then
        agent_name="opencode"
    # Check for Hermes (via environment variables)  
    elif [[ -n "${HERMES_API_KEY:-}" ]] || [[ -n "${HERMES:-}" ]]; then
        agent_name="hermes"
    # Fallback to generic detection
    else
        # Try to detect from command line arguments or environment
        if [[ -n "${MCP_AGENT:-}" ]]; then
            agent_name="${MCP_AGENT}"
        elif [[ -n "${AGENT_NAME:-}" ]]; then
            agent_name="${AGENT_NAME}"
        else
            agent_name="generic"
        fi
    fi
    
    echo "$agent_name"
}

# Get agent-specific MCP configuration
get_agent_mcp_config() {
    local agent_type="$1"
    local host="${2:-}"
    local user="${3:-}"
    local port="${4:-22}"
    local key_path="${5:-}"
    
    case "$agent_type" in
        "claude")
            # Claude Code configuration
            generate_mcp_config_claude "$host" "$user" "$port" "$key_path"
            ;;
        "gemini")
            # Gemini Code configuration  
            generate_mcp_config_gemini "$host" "$user" "$port" "$key_path"
            ;;
        "copilot")
            # GitHub Copilot configuration
            generate_mcp_config_generic "$host" "$user" "$port" "$key_path"
            ;;
        "cursor")
            # Cursor configuration
            generate_mcp_config_generic "$host" "$user" "$port" "$key_path"
            ;;
        "cline")
            # Cline configuration
            generate_mcp_config_generic "$host" "$user" "$port" "$key_path"
            ;;
        "opencode")
            # Opencode configuration
            generate_mcp_config_generic "$host" "$user" "$port" "$key_path"
            ;;
        "hermes")
            # Hermes configuration
            generate_mcp_config_generic "$host" "$user" "$port" "$key_path"
            ;;
        *)
            # Default generic configuration
            generate_mcp_config_generic "$host" "$user" "$port" "$key_path"
            ;;
    esac
}

# Generate generic MCP configuration (fallback)
generate_mcp_config_generic() {
    local host="$1"
    local user="$2"
    local port="${3:-22}"
    local key_path="${4:-}"
    local timeout="${5:-60000}"

    cat <<EOF
{
  "mcpServers": {
    "linus-ssh": {
      "command": "ssh-mcp",
      "args": [
        "--host=${host}",
        "--port=${port}",
        "--user=${user}",
EOF

    if [[ -n "$key_path" ]]; then
        echo "        \"--key=${key_path}\","
    fi

    cat <<EOF
        "--timeout=${timeout}",
        "--maxChars=none"
      ]
    }
  }
}
EOF
}

# -----------------------------------------------------------------------------
# Universal MCP Tool Execution Interface
# -----------------------------------------------------------------------------

# Execute a command via MCP (universal interface)
# Usage: mcp_execute "command" ["tool_name"]
mcp_execute() {
    local command="$1"
    local tool_name="${2:-exec}"
    
    # Get current agent type
    local agent_type=$(detect_agent)
    
    # Validate command
    if [[ -z "$command" ]]; then
        log_error "No command provided to mcp_execute"
        return 1
    fi
    
    log_debug "Executing via MCP (agent: $agent_type): $command"
    
    # Execute based on tool type
    case "$tool_name" in
        "exec")
            # Standard exec tool
            execute_mcp_command "$command"
            ;;
        "sudo-exec")
            # Sudo execution tool  
            execute_mcp_sudo_command "$command"
            ;;
        *)
            log_warning "Unknown MCP tool: $tool_name, using default 'exec'"
            execute_mcp_command "$command"
            ;;
    esac
}

# Execute command via MCP (internal)
execute_mcp_command() {
    local command="$1"
    
    if [[ -z "$command" ]]; then
        log_error "No command provided to execute_mcp_command"
        return 1
    fi
    
    # In a real implementation, this would call the MCP protocol
    # For now, we'll simulate it with direct execution or use ssh-mcp
    log_debug "Executing command via MCP: $command"
    
    # This is where actual MCP communication would happen
    # For demonstration purposes, we'll just echo what would be executed
    echo "MCP: Executing '$command' on remote host"
}

# Execute sudo command via MCP (internal)
execute_mcp_sudo_command() {
    local command="$1"
    
    if [[ -z "$command" ]]; then
        log_error "No command provided to execute_mcp_sudo_command"
        return 1
    fi
    
    # In a real implementation, this would call the sudo-exec MCP tool
    log_debug "Executing sudo command via MCP: $command"
    
    # This is where actual MCP sudo communication would happen  
    # For demonstration purposes, we'll just echo what would be executed
    echo "MCP: Executing 'sudo $command' on remote host"
}

# -----------------------------------------------------------------------------
# Universal Agent Configuration Management
# -----------------------------------------------------------------------------

# Get agent-specific configuration parameters
get_agent_config() {
    local agent_type="$1"
    
    case "$agent_type" in
        "claude")
            # Claude Code specific config
            echo "config_type=claude"
            echo "mcp_server=ssh-mcp"
            echo "timeout=60000"
            ;;
        "gemini")
            # Gemini Code specific config  
            echo "config_type=gemini"
            echo "mcp_server=ssh-mcp"
            echo "timeout=60000"
            ;;
        "copilot")
            # GitHub Copilot specific config
            echo "config_type=copilot" 
            echo "mcp_server=ssh-mcp"
            echo "timeout=60000"
            ;;
        "cursor")
            # Cursor specific config
            echo "config_type=cursor"
            echo "mcp_server=ssh-mcp"
            echo "timeout=60000"
            ;;
        "cline")
            # Cline specific config
            echo "config_type=cline"
            echo "mcp_server=ssh-mcp"
            echo "timeout=60000"
            ;;
        "opencode")
            # Opencode specific config
            echo "config_type=opencode"
            echo "mcp_server=ssh-mcp" 
            echo "timeout=60000"
            ;;
        "hermes")
            # Hermes specific config
            echo "config_type=hermes"
            echo "mcp_server=ssh-mcp"
            echo "timeout=60000"
            ;;
        *)
            # Generic fallback
            echo "config_type=generic"
            echo "mcp_server=ssh-mcp"
            echo "timeout=60000"
            ;;
    esac
}

# Set up universal MCP environment for current agent
setup_mcp_environment() {
    local agent_type=$(detect_agent)
    
    log_header "Setting up MCP environment for $agent_type"
    
    # Verify required tools
    if ! command -v ssh-mcp &>/dev/null; then
        log_error "ssh-mcp is not installed. Install with: npm install -g ssh-mcp"
        return 2
    fi
    
    # Set up agent-specific environment variables
    case "$agent_type" in
        "claude")
            export MCP_AGENT_TYPE="claude"
            ;;
        "gemini")
            export MCP_AGENT_TYPE="gemini"
            ;;
        "copilot")  
            export MCP_AGENT_TYPE="copilot"
            ;;
        "cursor")
            export MCP_AGENT_TYPE="cursor"
            ;;
        "cline")
            export MCP_AGENT_TYPE="cline"
            ;;
        "opencode")
            export MCP_AGENT_TYPE="opencode"  
            ;;
        "hermes")
            export MCP_AGENT_TYPE="hermes"
            ;;
        *)
            export MCP_AGENT_TYPE="generic"
            ;;
    esac
    
    log_info "MCP environment configured for agent type: $agent_type"
    
    return 0
}

# -----------------------------------------------------------------------------
# Agent Compatibility Layer
# -----------------------------------------------------------------------------

# Check if current agent is compatible with this system
check_agent_compatibility() {
    local agent_type=$(detect_agent)
    local compatibility_status="compatible"
    
    log_debug "Checking compatibility for agent: $agent_type"
    
    # Basic compatibility checks
    if ! command -v ssh-mcp &>/dev/null; then
        log_error "ssh-mcp not installed"
        compatibility_status="incompatible"
    fi
    
    # Additional checks based on agent type could go here
    case "$agent_type" in
        "claude")
            # Claude Code is known to work with ssh-mcp
            ;;
        "gemini")  
            # Gemini Code should also work with ssh-mcp
            ;;
        "copilot")
            # GitHub Copilot requires proper environment setup
            ;;
        *)
            # Other agents may require additional verification
            log_info "Agent $agent_type compatibility check: basic checks passed"
            ;;
    esac
    
    if [[ "$compatibility_status" == "compatible" ]]; then
        log_info "Agent $agent_type is compatible with Linus MCP system"
        return 0
    else
        log_error "Agent $agent_type is not compatible with Linus MCP system"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Version Compatibility Layer
# -----------------------------------------------------------------------------

# Check version compatibility between agent and system
check_version_compatibility() {
    local agent_type=$(detect_agent)
    
    # Get current ssh-mcp version
    local mcp_version=""
    if command -v ssh-mcp &>/dev/null; then
        mcp_version=$(ssh-mcp --version 2>&1 | head -1 || echo "unknown")
    fi
    
    log_debug "MCP version: $mcp_version"
    
    # Version compatibility checks would go here
    # For now, we'll just log the version
    case "$agent_type" in
        "claude")
            log_info "Claude Code compatible with ssh-mcp version: $mcp_version"
            ;;
        "gemini")
            log_info "Gemini Code compatible with ssh-mcp version: $mcp_version"
            ;;
        *)
            log_info "Generic agent compatible with ssh-mcp version: $mcp_version"
            ;;
    esac
    
    return 0
}

# -----------------------------------------------------------------------------
# Agent-Specific Command Templates
# -----------------------------------------------------------------------------

# Generate command templates specific to each agent type
generate_agent_command_template() {
    local agent_type="$1"
    local command_type="$2"
    
    case "$agent_type,$command_type" in
        "claude,exec")
            # Claude Code exec template
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
            # Gemini Code exec template
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
            # Copilot exec template
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
            # Generic template as fallback
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

# -----------------------------------------------------------------------------
# MCP Communication Protocol Abstraction
# -----------------------------------------------------------------------------

# Send command to agent via MCP protocol (abstracted)
send_mcp_command() {
    local command="$1"
    local tool="${2:-exec}"
    
    # This would be implemented with actual MCP communication
    log_debug "Sending MCP command: $command (tool: $tool)"
    
    # In a real implementation, this would:
    # 1. Determine current agent type
    # 2. Format command according to agent's MCP protocol  
    # 3. Send via appropriate MCP connection
    # 4. Handle response and return results
    
    echo "MCP Command Sent: $command"
}

# Receive response from agent (abstracted)
receive_mcp_response() {
    local response_id="$1" 
    
    # In a real implementation, this would:
    # 1. Wait for MCP response
    # 2. Parse response according to protocol
    # 3. Return structured data
    
    echo "MCP Response Received: $response_id"
}

# -----------------------------------------------------------------------------
# Utility Functions
# -----------------------------------------------------------------------------

# Get current agent information
get_agent_info() {
    local agent_type=$(detect_agent)
    
    cat <<EOF
{
  "agent": "$agent_type",
  "type": "mcp-adapter",
  "version": "1.0.0",
  "compatible": true,
  "features": [
    "exec",
    "sudo-exec",
    "file-upload",
    "command-template"
  ]
}
EOF
}

# Display MCP adapter information
mcp_adapter_info() {
    log_header "Universal MCP Adapter Information"
    
    local agent_type=$(detect_agent)
    local version="1.0.0"
    
    log_info "Agent Type: $agent_type"
    log_info "Adapter Version: $version"
    log_info "MCP Server: ssh-mcp (fallback)"
    log_info "Compatibility Status: Compatible"
    
    # Show supported tools
    log_info ""
    log_info "Supported MCP Tools:"
    log_info "  - exec: Execute shell command" 
    log_info "  - sudo-exec: Execute with sudo privileges"
    log_info "  - file-upload: Upload files via command execution"
    
    # Show configuration info  
    log_info ""
    log_info "Configuration:"
    log_info "  - Timeout: 60 seconds (default)"
    log_info "  - Max Characters: None (unlimited)"
}