#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist - MCP Helper Library
# =============================================================================
# Provides helper functions for working with MCP SSH server
# MCP Server: ssh-mcp (https://github.com/tufantunc/ssh-mcp)
# Tools: exec, sudo-exec
# =============================================================================

# Source logging library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${LINUS_LOGGING_LOADED:-}" ]]; then
    source "${SCRIPT_DIR}/logging.sh"
fi

# Mark mcp-helpers as loaded
LINUS_MCP_HELPERS_LOADED=1

# -----------------------------------------------------------------------------
# MCP Configuration
# -----------------------------------------------------------------------------

# Check if MCP SSH server package is installed
check_mcp_installed() {
    if ! command -v ssh-mcp &>/dev/null; then
        log_error "ssh-mcp is not installed. Install with: npm install -g ssh-mcp"
        return 2
    fi
    log_debug "ssh-mcp is installed"
    return 0
}

# Validate MCP connection parameters
# Usage: validate_mcp_params "host" "user" ["port"]
validate_mcp_params() {
    local host="$1"
    local user="$2"
    local port="${3:-22}"

    if [[ -z "$host" ]]; then
        log_error "MCP host is required"
        return 1
    fi

    if [[ -z "$user" ]]; then
        log_error "MCP user is required"
        return 1
    fi

    if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
        log_error "Invalid port: $port"
        return 1
    fi

    log_debug "MCP parameters valid: ${user}@${host}:${port}"
    return 0
}

# -----------------------------------------------------------------------------
# MCP Configuration File Management
# -----------------------------------------------------------------------------

# Generate MCP server configuration for Claude
# Usage: generate_mcp_config_claude "host" "user" ["port"] ["key_path"] > config.json
generate_mcp_config_claude() {
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

# Generate MCP server configuration for Gemini
# Usage: generate_mcp_config_gemini "host" "user" ["port"] ["key_path"] > config.json
generate_mcp_config_gemini() {
    # Gemini uses same format as Claude
    generate_mcp_config_claude "$@"
}

# -----------------------------------------------------------------------------
# MCP Tool Invocation Documentation
# -----------------------------------------------------------------------------

# NOTE: These functions are DOCUMENTATION ONLY
# They describe how MCP tools should be invoked by AI agents.
# Actual invocation happens through the MCP protocol, not bash functions.

# Execute command on remote server via MCP
# USAGE (by AI agent via MCP):
#   Tool: exec
#   Parameters: { "command": "ls -la /tmp" }
mcp_exec_doc() {
    cat <<'EOF'
MCP Tool: exec
Description: Execute a shell command on the remote server
Parameters:
  - command (required): Shell command to execute
Example invocation by AI agent:
  {
    "tool": "exec",
    "arguments": {
      "command": "apt update && apt install -y curl"
    }
  }
Timeout: Configurable via --timeout (default: 60000ms)
Notes: Commands longer than --maxChars will be rejected
EOF
}

# Execute command with sudo via MCP
# USAGE (by AI agent via MCP):
#   Tool: sudo-exec
#   Parameters: { "command": "systemctl restart nginx" }
mcp_sudo_exec_doc() {
    cat <<'EOF'
MCP Tool: sudo-exec
Description: Execute a shell command with sudo privileges
Parameters:
  - command (required): Shell command to execute as root
Example invocation by AI agent:
  {
    "tool": "sudo-exec",
    "arguments": {
      "command": "systemctl restart nginx"
    }
  }
Requirements: --sudoPassword must be configured if sudo requires password
Notes: Can be disabled with --disableSudo flag
EOF
}

# -----------------------------------------------------------------------------
# Helper Functions for Script Uploads
# -----------------------------------------------------------------------------

# Since ssh-mcp doesn't have file upload capability, we need to transfer
# scripts via command execution (cat with heredoc or echo)

# Upload a script file to remote server via command execution
# Usage: upload_script_via_mcp "/local/path/script.sh" "/remote/path/script.sh"
# NOTE: This is a HELPER for generating the command to send via MCP exec tool
generate_upload_script_command() {
    local local_path="$1"
    local remote_path="$2"

    if [[ ! -f "$local_path" ]]; then
        log_error "Local file not found: $local_path"
        return 1
    fi

    # Read the file and generate a command to recreate it remotely
    # Using base64 encoding to handle special characters safely
    local encoded_content=$(base64 -w 0 "$local_path")

    cat <<EOF
echo '${encoded_content}' | base64 -d > ${remote_path} && chmod +x ${remote_path}
EOF
}

# Generate command to create a file with content on remote server
# Usage: generate_create_file_command "content" "/remote/path/file.txt"
generate_create_file_command() {
    local content="$1"
    local remote_path="$2"

    # Escape single quotes in content
    local escaped_content="${content//\'/\'\\\'\'}"

    cat <<EOF
cat > ${remote_path} << 'LINUS_EOF'
${escaped_content}
LINUS_EOF
EOF
}

# -----------------------------------------------------------------------------
# Command Building Helpers
# -----------------------------------------------------------------------------

# Build a safe SSH command string (escapes properly)
# Usage: build_ssh_command "ls -la" "/tmp"
build_ssh_command() {
    local cmd="$1"
    shift
    local args=("$@")

    # Join args with proper escaping
    local full_cmd="$cmd"
    for arg in "${args[@]}"; do
        # Escape single quotes
        arg="${arg//\'/\'\\\'\'}"
        full_cmd="$full_cmd '$arg'"
    done

    echo "$full_cmd"
}

# Check if a remote file exists
# Returns: Command string to use with MCP exec
generate_file_exists_check() {
    local remote_path="$1"
    echo "test -f '${remote_path}' && echo 'EXISTS' || echo 'NOT_FOUND'"
}

# Check if a remote directory exists
# Returns: Command string to use with MCP exec
generate_dir_exists_check() {
    local remote_path="$1"
    echo "test -d '${remote_path}' && echo 'EXISTS' || echo 'NOT_FOUND'"
}

# Check if a command is available on remote
# Returns: Command string to use with MCP exec
generate_command_exists_check() {
    local cmd_name="$1"
    echo "command -v '${cmd_name}' &>/dev/null && echo 'EXISTS' || echo 'NOT_FOUND'"
}

# -----------------------------------------------------------------------------
# MCP Server Information
# -----------------------------------------------------------------------------

# Display information about the installed MCP server
mcp_info() {
    log_header "MCP SSH Server Information"

    if check_mcp_installed; then
        local version=$(npm list -g ssh-mcp 2>/dev/null | grep ssh-mcp@ | sed 's/.*ssh-mcp@//')
        log_info "Package: ssh-mcp"
        log_info "Version: ${version:-unknown}"
        log_info "Repository: https://github.com/tufantunc/ssh-mcp"
        log_info ""
        log_info "Available Tools:"
        log_info "  - exec: Execute shell command on remote server"
        log_info "  - sudo-exec: Execute shell command with sudo"
        log_info ""
        log_info "Installation: npm install -g ssh-mcp"
    else
        log_error "ssh-mcp is not installed"
        return 2
    fi
}

# -----------------------------------------------------------------------------
# Environment Variable Standards
# -----------------------------------------------------------------------------

# Get MCP connection string from environment
# Expects: LINUS_MCP_HOST, LINUS_MCP_USER, LINUS_MCP_PORT, LINUS_MCP_KEY
get_mcp_connection_env() {
    local host="${LINUS_MCP_HOST:-${PROXMOX_HOST:-}}"
    local user="${LINUS_MCP_USER:-${PROXMOX_USER:-root}}"
    local port="${LINUS_MCP_PORT:-22}"
    local key="${LINUS_MCP_KEY:-}"

    if [[ -z "$host" ]]; then
        log_error "LINUS_MCP_HOST or PROXMOX_HOST must be set"
        return 1
    fi

    echo "$host|$user|$port|$key"
}
