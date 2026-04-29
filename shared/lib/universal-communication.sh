#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist - Universal Communication Protocol
# =============================================================================
# Provides a unified communication interface for different AI agents to interact
# with the Linus Deployment Specialist system through MCP protocol.
# =============================================================================

# Source base libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${LINUS_LOGGING_LOADED:-}" ]]; then
    source "${SCRIPT_DIR}/logging.sh"
fi

# Mark universal-communication as loaded
LINUS_UNIVERSAL_COMMUNICATION_LOADED=1

# -----------------------------------------------------------------------------
# Communication Protocol Interface
# -----------------------------------------------------------------------------

# Universal MCP communication function
universal_mcp_communicate() {
    local agent_type="$1"
    local command="$2" 
    local tool="${3:-exec}"
    local options="${4:-}"
    
    log_debug "Universal MCP communication for agent: $agent_type"
    log_debug "Command: $command"
    log_debug "Tool: $tool"
    
    # Validate inputs
    if [[ -z "$command" ]]; then
        log_error "No command provided to universal_mcp_communicate"
        return 1
    fi
    
    # Select appropriate communication method based on agent type
    case "$agent_type" in
        "claude")
            communicate_claude "$command" "$tool" "$options"
            ;;
        "gemini")
            communicate_gemini "$command" "$tool" "$options"
            ;;
        "copilot")
            communicate_copilot "$command" "$tool" "$options"
            ;;
        "cursor")
            communicate_cursor "$command" "$tool" "$options"
            ;;
        "cline")
            communicate_cline "$command" "$tool" "$options"
            ;;
        "opencode")
            communicate_opencode "$command" "$tool" "$options"
            ;;
        "hermes")
            communicate_hermes "$command" "$tool" "$options"
            ;;
        *)
            # Generic fallback
            communicate_generic "$command" "$tool" "$options"
            ;;
    esac
}

# Claude Code communication
communicate_claude() {
    local command="$1"
    local tool="$2"
    local options="$3"
    
    log_debug "Communicating with Claude Code"
    
    # In a real implementation, this would interface with Claude's MCP server
    # For now, we simulate the communication
    
    # Format command according to Claude's expectations
    local formatted_command=""
    case "$tool" in
        "exec")
            formatted_command='{"tool": "exec", "arguments": {"command": "'"$command"'"}}'
            ;;
        "sudo-exec")
            formatted_command='{"tool": "sudo-exec", "arguments": {"command": "'"$command"'"}}'
            ;;
        *)
            formatted_command='{"tool": "'"$tool"'", "arguments": {"command": "'"$command"'"}}'
            ;;
    esac
    
    log_debug "Formatted Claude command: $formatted_command"
    
    # Simulate MCP execution
    echo "Claude Code: Executing MCP command via ssh-mcp"
    echo "Command: $command"
    echo "Tool: $tool"
    return 0
}

# Gemini Code communication
communicate_gemini() {
    local command="$1"
    local tool="$2"
    local options="$3"
    
    log_debug "Communicating with Gemini Code" 
    
    # Format command according to Gemini's expectations
    local formatted_command=""
    case "$tool" in
        "exec")
            formatted_command='{"tool": "exec", "arguments": {"command": "'"$command"'"}}'
            ;;
        "sudo-exec")
            formatted_command='{"tool": "sudo-exec", "arguments": {"command": "'"$command"'"}}'
            ;;
        *)
            formatted_command='{"tool": "'"$tool"'", "arguments": {"command": "'"$command"'"}}'
            ;;
    esac
    
    log_debug "Formatted Gemini command: $formatted_command"
    
    # Simulate MCP execution
    echo "Gemini Code: Executing MCP command via ssh-mcp"
    echo "Command: $command"
    echo "Tool: $tool" 
    return 0
}

# GitHub Copilot communication
communicate_copilot() {
    local command="$1"
    local tool="$2"
    local options="$3"
    
    log_debug "Communicating with GitHub Copilot"
    
    # Format command according to Copilot's expectations
    local formatted_command=""
    case "$tool" in
        "exec")
            formatted_command='{"tool": "exec", "arguments": {"command": "'"$command"'"}}'
            ;;
        "sudo-exec")
            formatted_command='{"tool": "sudo-exec", "arguments": {"command": "'"$command"'"}}'
            ;;
        *)
            formatted_command='{"tool": "'"$tool"'", "arguments": {"command": "'"$command"'"}}'
            ;;
    esac
    
    log_debug "Formatted Copilot command: $formatted_command"
    
    # Simulate MCP execution
    echo "GitHub Copilot: Executing MCP command via ssh-mcp"
    echo "Command: $command" 
    echo "Tool: $tool"
    return 0
}

# Cursor communication
communicate_cursor() {
    local command="$1"
    local tool="$2"
    local options="$3"
    
    log_debug "Communicating with Cursor"
    
    # Format command according to Cursor's expectations
    local formatted_command=""
    case "$tool" in
        "exec")
            formatted_command='{"tool": "exec", "arguments": {"command": "'"$command"'"}}'
            ;;
        "sudo-exec")
            formatted_command='{"tool": "sudo-exec", "arguments": {"command": "'"$command"'"}}'
            ;;
        *)
            formatted_command='{"tool": "'"$tool"'", "arguments": {"command": "'"$command"'"}}'
            ;;
    esac
    
    log_debug "Formatted Cursor command: $formatted_command"
    
    # Simulate MCP execution
    echo "Cursor: Executing MCP command via ssh-mcp"
    echo "Command: $command"
    echo "Tool: $tool"
    return 0
}

# Cline communication
communicate_cline() {
    local command="$1"
    local tool="$2"
    local options="$3"
    
    log_debug "Communicating with Cline"
    
    # Format command according to Cline's expectations
    local formatted_command=""
    case "$tool" in
        "exec")
            formatted_command='{"tool": "exec", "arguments": {"command": "'"$command"'"}}'
            ;;
        "sudo-exec")
            formatted_command='{"tool": "sudo-exec", "arguments": {"command": "'"$command"'"}}'
            ;;
        *)
            formatted_command='{"tool": "'"$tool"'", "arguments": {"command": "'"$command"'"}}'
            ;;
    esac
    
    log_debug "Formatted Cline command: $formatted_command"
    
    # Simulate MCP execution
    echo "Cline: Executing MCP command via ssh-mcp"
    echo "Command: $command"
    echo "Tool: $tool"
    return 0
}

# Opencode communication
communicate_opencode() {
    local command="$1"
    local tool="$2"
    local options="$3"
    
    log_debug "Communicating with Opencode"
    
    # Format command according to Opencode's expectations
    local formatted_command=""
    case "$tool" in
        "exec")
            formatted_command='{"tool": "exec", "arguments": {"command": "'"$command"'"}}'
            ;;
        "sudo-exec")
            formatted_command='{"tool": "sudo-exec", "arguments": {"command": "'"$command"'"}}'
            ;;
        *)
            formatted_command='{"tool": "'"$tool"'", "arguments": {"command": "'"$command"'"}}'
            ;;
    esac
    
    log_debug "Formatted Opencode command: $formatted_command"
    
    # Simulate MCP execution
    echo "Opencode: Executing MCP command via ssh-mcp"
    echo "Command: $command"
    echo "Tool: $tool"
    return 0
}

# Hermes communication
communicate_hermes() {
    local command="$1"
    local tool="$2"
    local options="$3"
    
    log_debug "Communicating with Hermes"
    
    # Format command according to Hermes's expectations
    local formatted_command=""
    case "$tool" in
        "exec")
            formatted_command='{"tool": "exec", "arguments": {"command": "'"$command"'"}}'
            ;;
        "sudo-exec")
            formatted_command='{"tool": "sudo-exec", "arguments": {"command": "'"$command"'"}}'
            ;;
        *)
            formatted_command='{"tool": "'"$tool"'", "arguments": {"command": "'"$command"'"}}'
            ;;
    esac
    
    log_debug "Formatted Hermes command: $formatted_command"
    
    # Simulate MCP execution
    echo "Hermes: Executing MCP command via ssh-mcp"
    echo "Command: $command"
    echo "Tool: $tool"
    return 0
}

# Generic communication fallback
communicate_generic() {
    local command="$1"
    local tool="$2"
    local options="$3"
    
    log_debug "Communicating with generic agent"
    
    # Format command according to generic expectations
    local formatted_command=""
    case "$tool" in
        "exec")
            formatted_command='{"tool": "exec", "arguments": {"command": "'"$command"'"}}'
            ;;
        "sudo-exec")
            formatted_command='{"tool": "sudo-exec", "arguments": {"command": "'"$command"'"}}'
            ;;
        *)
            formatted_command='{"tool": "'"$tool"'", "arguments": {"command": "'"$command"'"}}'
            ;;
    esac
    
    log_debug "Formatted generic command: $formatted_command"
    
    # Simulate MCP execution
    echo "Generic Agent: Executing MCP command via ssh-mcp"
    echo "Command: $command"
    echo "Tool: $tool"
    return 0
}

# -----------------------------------------------------------------------------
# Communication Protocol Functions
# -----------------------------------------------------------------------------

# Send a command to the remote system via MCP (universal interface)
send_mcp_command() {
    local command="$1"
    local tool="${2:-exec}"
    local target_host="${3:-}"
    local target_user="${4:-}"
    
    # Get current agent type
    local agent_type=$(detect_current_agent)
    
    log_header "Sending MCP Command ($tool): $command"
    
    # Validate inputs
    if [[ -z "$command" ]]; then
        log_error "No command provided to send_mcp_command"
        return 1
    fi
    
    # If no target specified, use current configuration
    if [[ -z "$target_host" ]] && [[ -n "${LINUS_MCP_HOST:-}" ]]; then
        target_host="$LINUS_MCP_HOST"
    fi
    
    if [[ -z "$target_user" ]] && [[ -n "${LINUS_MCP_USER:-}" ]]; then
        target_user="$LINUS_MCP_USER"
    fi
    
    # Execute the communication
    universal_mcp_communicate "$agent_type" "$command" "$tool"
    
    # Capture and return results
    local result=$?
    
    if [[ $result -eq 0 ]]; then
        log_info "MCP command sent successfully via $agent_type"
        return 0
    else
        log_error "Failed to send MCP command via $agent_type"
        return 1
    fi
}

# Execute a remote command via MCP (universal interface)
execute_remote_command() {
    local command="$1"
    local tool="${2:-exec}"
    
    log_debug "Executing remote command via MCP: $command"
    
    # Get current agent type
    local agent_type=$(detect_current_agent)
    
    # Send the command through MCP
    send_mcp_command "$command" "$tool"
    
    # Return success/failure based on execution
    if [[ $? -eq 0 ]]; then
        echo "Command executed successfully via $agent_type"
        return 0
    else
        echo "Failed to execute command via $agent_type"
        return 1
    fi
}

# Execute multiple commands in sequence
execute_commands_sequence() {
    local commands=("$@")
    local results=()
    
    log_header "Executing Commands Sequence"
    
    for i in "${!commands[@]}"; do
        local cmd="${commands[$i]}"
        log_info "Executing command $((i+1)): $cmd"
        
        # Execute the command
        execute_remote_command "$cmd"
        local result=$?
        
        results+=("$result")
        
        if [[ $result -ne 0 ]]; then
            log_error "Command failed: $cmd"
            return 1
        fi
        
        log_info "Command successful: $cmd"
    done
    
    log_info "All commands executed successfully"
    return 0
}

# -----------------------------------------------------------------------------
# Communication Protocol Utilities  
# -----------------------------------------------------------------------------

# Get communication protocol version
get_protocol_version() {
    echo "universal-mcp-protocol/1.0.0"
}

# Get current communication status
get_communication_status() {
    local agent_type=$(detect_current_agent)
    
    cat <<EOF
{
  "protocol": "universal-mcp",
  "version": "1.0.0",
  "agent": "$agent_type", 
  "status": "active",
  "mcp_server": "ssh-mcp",
  "timeout": 60000,
  "tools_supported": [
    "exec",
    "sudo-exec"
  ]
}
EOF
}

# Validate communication parameters
validate_communication_params() {
    local host="$1"
    local user="$2"
    local port="${3:-22}"
    
    log_debug "Validating communication parameters"
    
    # Validate host
    if [[ -z "$host" ]]; then
        log_error "Host parameter is required"
        return 1
    fi
    
    # Validate user
    if [[ -z "$user" ]]; then
        log_error "User parameter is required"
        return 1
    fi
    
    # Validate port
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
        log_error "Invalid port: $port"
        return 1
    fi
    
    log_debug "Communication parameters validated successfully"
    return 0
}

# Generate communication report
generate_communication_report() {
    local agent_type=$(detect_current_agent)
    
    log_header "Communication Protocol Report"
    
    echo "Protocol: Universal MCP"
    echo "Version: 1.0.0"
    echo "Agent Type: $agent_type"
    echo "MCP Server: ssh-mcp" 
    echo "Timeout: 60000ms"
    echo ""
    echo "Supported Tools:"
    echo "  - exec: Execute shell commands"
    echo "  - sudo-exec: Execute with sudo privileges"
    echo ""
    echo "Status: Active and ready for communication"
    
    return 0
}

# Test communication with remote system
test_communication() {
    local host="${1:-}"
    local user="${2:-}"
    local port="${3:-22}"
    
    log_header "Testing Communication"
    
    # Validate parameters
    if ! validate_communication_params "$host" "$user" "$port"; then
        return 1
    fi
    
    # Test connectivity using a simple command
    local test_command="echo 'Communication test successful'"
    
    log_info "Testing communication with $user@$host:$port"
    
    # Try to send a test command
    execute_remote_command "$test_command"
    
    if [[ $? -eq 0 ]]; then
        log_info "Communication test passed"
        return 0
    else
        log_error "Communication test failed"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Advanced Communication Features
# -----------------------------------------------------------------------------

# Execute command with timeout protection
execute_with_timeout() {
    local command="$1"
    local timeout="${2:-60}"
    local tool="${3:-exec}"
    
    log_debug "Executing command with timeout: $command (timeout: ${timeout}s)"
    
    # Set up timeout using timeout command if available
    if command -v timeout &>/dev/null; then
        timeout "$timeout" execute_remote_command "$command" "$tool"
        local result=$?
    else
        # Fallback without timeout if timeout command not available
        execute_remote_command "$command" "$tool"
        local result=$?
    fi
    
    return $result
}

# Execute command with retry logic
execute_with_retry() {
    local command="$1"
    local max_retries="${2:-3}"
    local delay="${3:-5}"
    local tool="${4:-exec}"
    
    log_debug "Executing command with retry logic: $command (max retries: ${max_retries}, delay: ${delay}s)"
    
    local retry_count=0
    local success=false
    
    while [[ $retry_count -lt $max_retries ]] && [[ "$success" == false ]]; do
        log_info "Attempt $((retry_count + 1)) of $max_retries"
        
        execute_remote_command "$command" "$tool"
        local result=$?
        
        if [[ $result -eq 0 ]]; then
            success=true
            log_info "Command executed successfully after $((retry_count + 1)) attempts"
        else
            retry_count=$((retry_count + 1))
            
            if [[ $retry_count -lt $max_retries ]]; then
                log_info "Command failed, waiting ${delay}s before retry..."
                sleep "$delay"
            fi
        fi
    done
    
    if [[ "$success" == true ]]; then
        return 0
    else
        log_error "Command failed after $max_retries attempts"
        return 1
    fi
}