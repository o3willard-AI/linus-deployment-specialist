#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist - TMUX Session Management Library
# =============================================================================
# Purpose: Manage persistent TMUX sessions for complex, long-running operations
# Usage: source "${SCRIPT_DIR}/../lib/tmux-helper.sh"
# Level: 3 (Advanced - use only when Level 1 & 2 insufficient)
# =============================================================================

# Include guard
if [[ -n "${LINUS_TMUX_LOADED:-}" ]]; then
    return 0
fi

# Source logging if not already loaded
_TMUX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${LINUS_LOGGING_LOADED:-}" ]]; then
    source "${_TMUX_LIB_DIR}/logging.sh"
fi

# -----------------------------------------------------------------------------
# TMUX Session Management
# -----------------------------------------------------------------------------

tmux_check_installed() {
    if ! command -v tmux &>/dev/null; then
        log_error "TMUX is not installed"
        return 1
    fi
    return 0
}

tmux_create_session() {
    local session_name="$1"
    local command="${2:-bash}"
    local working_dir="${3:-$HOME}"

    if [[ -z "$session_name" ]]; then
        log_error "Session name required"
        return 1
    fi

    tmux_check_installed || return 1

    # Check if session already exists
    if tmux has-session -t "$session_name" 2>/dev/null; then
        log_warn "TMUX session already exists: $session_name"
        return 0
    fi

    # Create new detached session
    tmux new-session -d -s "$session_name" -c "$working_dir" "$command"
    log_success "Created TMUX session: $session_name"
}

tmux_list_sessions() {
    tmux_check_installed || return 1

    if ! tmux list-sessions 2>/dev/null; then
        log_info "No active TMUX sessions"
        return 0
    fi
}

tmux_session_exists() {
    local session_name="$1"

    if [[ -z "$session_name" ]]; then
        log_error "Session name required"
        return 1
    fi

    tmux has-session -t "$session_name" 2>/dev/null
}

tmux_kill_session() {
    local session_name="$1"

    if [[ -z "$session_name" ]]; then
        log_error "Session name required"
        return 1
    fi

    tmux_check_installed || return 1

    if tmux_session_exists "$session_name"; then
        tmux kill-session -t "$session_name"
        log_success "Killed TMUX session: $session_name"
    else
        log_warn "Session does not exist: $session_name"
    fi
}

# -----------------------------------------------------------------------------
# TMUX Window Management
# -----------------------------------------------------------------------------

tmux_create_window() {
    local session_name="$1"
    local window_name="${2:-window}"
    local command="${3:-bash}"

    if [[ -z "$session_name" ]]; then
        log_error "Session name required"
        return 1
    fi

    tmux_check_installed || return 1

    if ! tmux_session_exists "$session_name"; then
        log_error "Session does not exist: $session_name"
        return 1
    fi

    tmux new-window -t "$session_name" -n "$window_name" "$command"
    log_success "Created window '$window_name' in session: $session_name"
}

tmux_list_windows() {
    local session_name="$1"

    if [[ -z "$session_name" ]]; then
        log_error "Session name required"
        return 1
    fi

    tmux_check_installed || return 1

    if ! tmux_session_exists "$session_name"; then
        log_error "Session does not exist: $session_name"
        return 1
    fi

    tmux list-windows -t "$session_name"
}

# -----------------------------------------------------------------------------
# TMUX Interaction - Send Commands and Capture Output
# -----------------------------------------------------------------------------

tmux_send_keys() {
    local session_name="$1"
    local keys="$2"
    local window="${3:-0}"

    if [[ -z "$session_name" ]] || [[ -z "$keys" ]]; then
        log_error "Session name and keys required"
        return 1
    fi

    tmux_check_installed || return 1

    if ! tmux_session_exists "$session_name"; then
        log_error "Session does not exist: $session_name"
        return 1
    fi

    tmux send-keys -t "${session_name}:${window}" "$keys" Enter
    log_info "Sent keys to session $session_name: $keys"
}

tmux_capture_pane() {
    local session_name="$1"
    local window="${2:-0}"
    local lines="${3:-100}"

    if [[ -z "$session_name" ]]; then
        log_error "Session name required"
        return 1
    fi

    tmux_check_installed || return 1

    if ! tmux_session_exists "$session_name"; then
        log_error "Session does not exist: $session_name"
        return 1
    fi

    # Capture and print pane content
    tmux capture-pane -t "${session_name}:${window}" -p -S -${lines}
}

tmux_capture_last_line() {
    local session_name="$1"
    local window="${2:-0}"

    tmux capture-pane -t "${session_name}:${window}" -p | tail -1
}

# -----------------------------------------------------------------------------
# High-Level Workflow Functions
# -----------------------------------------------------------------------------

tmux_run_script() {
    local session_name="$1"
    local script_path="$2"
    local working_dir="${3:-$(dirname "$script_path")}"

    if [[ -z "$session_name" ]] || [[ -z "$script_path" ]]; then
        log_error "Session name and script path required"
        return 1
    fi

    if [[ ! -f "$script_path" ]]; then
        log_error "Script not found: $script_path"
        return 1
    fi

    log_info "Running script in TMUX session: $script_path"
    tmux_create_session "$session_name" "bash $script_path" "$working_dir"
}

tmux_wait_for_completion() {
    local session_name="$1"
    local timeout="${2:-300}"
    local check_interval="${3:-5}"

    if [[ -z "$session_name" ]]; then
        log_error "Session name required"
        return 1
    fi

    local elapsed=0

    log_info "Waiting for session to complete: $session_name (timeout: ${timeout}s)"

    while tmux_session_exists "$session_name"; do
        if [[ $elapsed -ge $timeout ]]; then
            log_error "Timeout waiting for session: $session_name"
            return 1
        fi

        sleep "$check_interval"
        ((elapsed+=check_interval))

        if [[ $((elapsed % 30)) -eq 0 ]]; then
            log_info "Still waiting... (${elapsed}s/${timeout}s)"
        fi
    done

    log_success "Session completed: $session_name"
    return 0
}

tmux_monitor_output() {
    local session_name="$1"
    local success_pattern="${2:-LINUS_RESULT:SUCCESS}"
    local error_pattern="${3:-LINUS_RESULT:FAILURE}"
    local timeout="${4:-300}"
    local check_interval="${5:-5}"

    if [[ -z "$session_name" ]]; then
        log_error "Session name required"
        return 1
    fi

    local elapsed=0

    log_info "Monitoring session output: $session_name"

    while tmux_session_exists "$session_name"; do
        if [[ $elapsed -ge $timeout ]]; then
            log_error "Timeout monitoring session: $session_name"
            return 1
        fi

        # Capture recent output
        local output=$(tmux_capture_pane "$session_name" 0 50)

        # Check for success pattern
        if echo "$output" | grep -q "$success_pattern"; then
            log_success "Success pattern detected in session: $session_name"
            return 0
        fi

        # Check for error pattern
        if echo "$output" | grep -q "$error_pattern"; then
            log_error "Error pattern detected in session: $session_name"
            return 1
        fi

        sleep "$check_interval"
        ((elapsed+=check_interval))

        if [[ $((elapsed % 30)) -eq 0 ]]; then
            log_info "Still monitoring... (${elapsed}s/${timeout}s)"
        fi
    done

    log_warn "Session ended without success/error pattern: $session_name"
    return 1
}

# -----------------------------------------------------------------------------
# Remote TMUX via SSH (for remote host operations)
# -----------------------------------------------------------------------------

tmux_remote_create() {
    local remote_host="$1"
    local session_name="$2"
    local command="${3:-bash}"

    if [[ -z "$remote_host" ]] || [[ -z "$session_name" ]]; then
        log_error "Remote host and session name required"
        return 1
    fi

    log_info "Creating remote TMUX session on $remote_host: $session_name"
    ssh "$remote_host" "tmux new-session -d -s '$session_name' '$command'"
}

tmux_remote_send_keys() {
    local remote_host="$1"
    local session_name="$2"
    local keys="$3"

    if [[ -z "$remote_host" ]] || [[ -z "$session_name" ]] || [[ -z "$keys" ]]; then
        log_error "Remote host, session name, and keys required"
        return 1
    fi

    ssh "$remote_host" "tmux send-keys -t '$session_name' '$keys' Enter"
}

tmux_remote_capture() {
    local remote_host="$1"
    local session_name="$2"
    local lines="${3:-100}"

    if [[ -z "$remote_host" ]] || [[ -z "$session_name" ]]; then
        log_error "Remote host and session name required"
        return 1
    fi

    ssh "$remote_host" "tmux capture-pane -t '$session_name' -p -S -${lines}"
}

tmux_remote_kill() {
    local remote_host="$1"
    local session_name="$2"

    if [[ -z "$remote_host" ]] || [[ -z "$session_name" ]]; then
        log_error "Remote host and session name required"
        return 1
    fi

    ssh "$remote_host" "tmux kill-session -t '$session_name'" 2>/dev/null || true
    log_success "Killed remote TMUX session on $remote_host: $session_name"
}

# Mark as loaded
LINUS_TMUX_LOADED=1
