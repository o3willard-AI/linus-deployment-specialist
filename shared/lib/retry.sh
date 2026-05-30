#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist — Retry & Recovery Library
# =============================================================================
# Purpose: Centralized retry logic, error classification, and multi-strategy
#   recovery for the Wild West of Vast GPU wrangling.
#
# Source this file in other scripts:
#   source "$SCRIPT_DIR/../lib/retry.sh"
#
# Design principles:
#   - Transient errors get exponential backoff with jitter
#   - Host-bad errors trigger destroy + re-search (caller's responsibility)
#   - Strategy-fail errors try alternate approaches
#   - Fatal errors surface immediately with clear diagnostics
# =============================================================================

# Library guard
if [[ -n "${LINUS_RETRY_LOADED:-}" ]]; then
    return 0
fi
LINUS_RETRY_LOADED=1

# -----------------------------------------------------------------------------
# Error Classification
# -----------------------------------------------------------------------------

# is_retryable_error <exit_code> <phase>
#   Returns 0 if the error is likely transient and worth retrying.
#   Phase helps contextualize — SSH timeout might be retryable, but
#   SSH timeout during build verification is fatal (instance broken).
#   Exit codes:
#     0 — retryable (caller should retry or escalate)
#     1 — fatal (caller should abort and surface)
is_retryable_error() {
    local exit_code="$1"
    local phase="${2:-unknown}"

    # Fatal exit codes from the Linus contract
    # 2 = missing deps, 3 = invalid config, 4 = provider offline
    # These mean the environment is broken, not the remote host
    case "$exit_code" in
        2|3)
            echo "FATAL:exit_code_${exit_code}:environment_broken" >&2
            return 1
            ;;
    esac

    # Phase-specific classification
    case "$phase" in
        offer_search)
            # Empty results could be API hiccup or genuinely no hosts
            # Retry a few times before relaxing filters
            [[ $exit_code -eq 5 ]] && { echo "RETRY:offer_search_empty" >&2; return 0; }
            [[ $exit_code -eq 4 ]] && { echo "RETRY:api_transient" >&2; return 0; }
            ;;

        wait_running)
            # Exit 5 = CDI/GPU passthrough failure → host is bad, don't retry same host
            [[ $exit_code -eq 5 ]] && { echo "FATAL:cdi_passthrough_failure:try_different_host" >&2; return 1; }
            # Exit 6 = timeout → might still come up, retry with longer wait
            [[ $exit_code -eq 6 ]] && { echo "RETRY:instance_still_booting" >&2; return 0; }
            ;;

        ssh_wait)
            # SSH timeout could be network flakiness or host problem
            # Retry with different strategies before giving up
            [[ $exit_code -eq 6 ]] && { echo "RETRY:ssh_timeout" >&2; return 0; }
            ;;

        model_download)
            # Network failures, partial downloads → retry with resume
            [[ $exit_code -eq 5 ]] && { echo "RETRY:download_failed" >&2; return 0; }
            ;;

        server_health)
            # Server slow to start, transient 503 → retry
            [[ $exit_code -eq 7 ]] && { echo "RETRY:server_not_ready" >&2; return 0; }
            [[ $exit_code -eq 6 ]] && { echo "FATAL:server_crash" >&2; return 1; }
            ;;

        inference_verify)
            # Model still loading, transient failure → retry
            [[ $exit_code -eq 6 ]] && { echo "RETRY:model_loading" >&2; return 0; }
            ;;

        *)
            # Unknown phase — be conservative, treat exit 4/5/6/7 as retryable
            case "$exit_code" in
                4|5|6|7) echo "RETRY:exit_code_${exit_code}" >&2; return 0 ;;
                *)       echo "FATAL:exit_code_${exit_code}" >&2; return 1 ;;
            esac
            ;;
    esac

    # Default: non-zero exit is fatal
    echo "FATAL:exit_code_${exit_code}" >&2
    return 1
}

# -----------------------------------------------------------------------------
# Retry with Exponential Backoff
# -----------------------------------------------------------------------------

# retry_with_backoff <label> <max_attempts> <initial_delay_secs> <command...>
#   Runs command up to max_attempts times with exponential backoff + jitter.
#   Stops early if is_retryable_error says the error is fatal.
#   Returns 0 on success, last exit code on exhaustion.
#
#   Backoff: initial_delay × 2^(attempt-1) ± 50% jitter
#   Example: 3 attempts, 5s initial → waits 5s, 10s, 20s
#
#   Output: logs each attempt to stderr via log_info/log_warn
retry_with_backoff() {
    local label="$1"
    local max_attempts="$2"
    local initial_delay="$3"
    shift 3

    local attempt=0
    local delay=0
    local exit_code=0

    while [[ $attempt -lt $max_attempts ]]; do
        ((attempt++))

        if [[ $attempt -gt 1 ]]; then
            # Exponential backoff with jitter (±50%)
            local half_delay=$((delay / 2))
            local jitter=$((RANDOM % (delay + 1) - half_delay))
            [[ $jitter -lt 0 ]] && jitter=0
            local wait_time=$((delay + jitter))

            log_warn "[${label}] Attempt ${attempt}/${max_attempts} — waiting ${wait_time}s..."
            sleep "$wait_time"
        fi

        log_info "[${label}] Attempt ${attempt}/${max_attempts}..."

        # Run the command
        set +e
        "$@" 2>&1
        exit_code=$?
        set -e

        if [[ $exit_code -eq 0 ]]; then
            log_info "[${label}] Succeeded on attempt ${attempt}"
            return 0
        fi

        # Check if error is fatal — if so, don't retry
        if ! is_retryable_error "$exit_code" "$label" 2>/dev/null; then
            log_error "[${label}] Fatal error on attempt ${attempt} — not retrying"
            return $exit_code
        fi

        # Set delay for next iteration
        if [[ $delay -eq 0 ]]; then
            delay=$initial_delay
        else
            delay=$((delay * 2))
        fi
    done

    log_error "[${label}] Exhausted ${max_attempts} attempts. Last exit: ${exit_code}"
    return $exit_code
}

# -----------------------------------------------------------------------------
# SSH Multi-Strategy Recovery
# -----------------------------------------------------------------------------

# retry_ssh <host> <port> <ssh_key> <command>
#   Tries SSH with escalating strategies to handle Vast proxy weirdness:
#     1. Standard BatchMode SSH
#     2. PTY allocation (-tt) for shells that require it
#     3. Simpler echo command to test basic connectivity
#   Returns 0 on first successful strategy, 6 on all failures.
#
#   Pitfall guard #9: Vast SSH proxy rejects complex commands (exit 255).
#   This function tries a simple echo probe first, then escalates.
retry_ssh() {
    local host="$1"
    local port="$2"
    local ssh_key="$3"
    local command="$4"

    local ssh_base="ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    [[ -n "$ssh_key" && "$ssh_key" != "none" ]] && ssh_base="$ssh_base -i $ssh_key"

    # Strategy 1: Standard non-interactive SSH
    log_info "[ssh] Strategy 1: standard SSH to ${host}:${port}"
    if $ssh_base -p "$port" "root@${host}" "$command" >/dev/null 2>&1; then
        return 0
    fi

    # Strategy 2: PTY allocation — some Vast hosts require a TTY
    log_info "[ssh] Strategy 2: PTY mode to ${host}:${port}"
    if $ssh_base -tt -p "$port" "root@${host}" "$command" >/dev/null 2>&1; then
        log_warn "[ssh] PTY mode required — host ${host} has non-standard shell config"
        # Update SSH base for subsequent calls
        SSH_PTY_REQUIRED=1
        return 0
    fi

    # Strategy 3: Simple echo probe — is SSH even working?
    log_info "[ssh] Strategy 3: echo probe to ${host}:${port}"
    local probe_out
    if probe_out=$($ssh_base -p "$port" "root@${host}" "echo ALIVE" 2>&1); then
        log_warn "[ssh] Basic SSH works but command failed. Command may be too complex for Vast proxy."
        log_warn "[ssh] Probe output: ${probe_out}"
        # SSH works, but the command failed — try scp+nohup pattern
        SSH_USE_SCP_NOHUP=1
        return 0
    fi

    # Strategy 4: Try with different UserKnownHostsFile + longer timeout
    log_info "[ssh] Strategy 4: relaxed SSH to ${host}:${port}"
    ssh_base="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 -o BatchMode=yes -o ServerAliveInterval=10"
    [[ -n "$ssh_key" && "$ssh_key" != "none" ]] && ssh_base="$ssh_base -i $ssh_key"
    if $ssh_base -p "$port" "root@${host}" "$command" >/dev/null 2>&1; then
        return 0
    fi

    log_error "[ssh] All 4 strategies failed for ${host}:${port}"
    return 6
}

# retry_ssh_with_backoff <max_attempts> <host> <port> <ssh_key> <command>
#   Combines retry_with_backoff + retry_ssh for resilient SSH operations.
retry_ssh_with_backoff() {
    local max_attempts="$1"
    local host="$2"
    local port="$3"
    local ssh_key="$4"
    local command="$5"

    local attempt=0
    local delay=5

    while [[ $attempt -lt $max_attempts ]]; do
        ((attempt++))

        if [[ $attempt -gt 1 ]]; then
            log_warn "[ssh-retry] Attempt ${attempt}/${max_attempts} — waiting ${delay}s..."
            sleep "$delay"
            delay=$((delay * 2))
        fi

        if retry_ssh "$host" "$port" "$ssh_key" "$command"; then
            return 0
        fi
    done

    return 6
}

# -----------------------------------------------------------------------------
# Model Download Recovery
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Remote Command Execution (scp+execute pattern)
# -----------------------------------------------------------------------------
# Vast proxy frequently drops multi-line inline SSH commands (exit 255,
# only welcome banner). The reliable pattern: scp a script, then execute it.
#
# remote_execute <ssh_host> <ssh_port> <ssh_key> <commands...>
#   Writes commands to /tmp/hermes-cmd.sh on remote, executes it.
#   Returns exit code of remote script.
#   ssh_key can be "" to auto-discover, or "none" to skip -i flag.
remote_execute() {
    local ssh_host="$1"
    local ssh_port="$2"
    local ssh_key="$3"
    shift 3

    local ssh_args=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30 -o ServerAliveCountMax=3)
    [[ -n "$ssh_key" && "$ssh_key" != "none" ]] && ssh_args+=(-i "$ssh_key")
    ssh_args+=(-p "$ssh_port")

    # Write commands to remote /tmp
    printf '%s\n' "$@" | ssh "${ssh_args[@]}" "root@${ssh_host}" "cat > /tmp/hermes-cmd.sh" 2>/dev/null || {
        log_warn "[remote] Failed to upload command script"
        return 1
    }

    # Execute and capture exit code
    ssh "${ssh_args[@]}" "root@${ssh_host}" "bash /tmp/hermes-cmd.sh" 2>/dev/null
}

# retry_model_download <ssh_host> <ssh_port> <ssh_key> <model_url> <model_path> <max_attempts>
#   Downloads model with multi-strategy recovery:
#     1. curl with resume support (-C -)
#     2. wget fallback (some hosts have broken curl)
#   Uses scp+execute pattern to avoid Vast proxy multi-line SSH failures.
#   Returns 0 on success, 5 on all failures.
retry_model_download() {
    local ssh_host="$1"
    local ssh_port="$2"
    local ssh_key="$3"
    local model_url="$4"
    local model_path="$5"
    local max_attempts="${6:-5}"

    local ssh_args=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30 -o ServerAliveCountMax=3)
    [[ -n "$ssh_key" && "$ssh_key" != "none" ]] && ssh_args+=(-i "$ssh_key")
    ssh_args+=(-p "$ssh_port")

    local model_dir
    model_dir=$(dirname "$model_path")
    local model_file
    model_file=$(basename "$model_path")

    local attempt=0
    local delay=10

    while [[ $attempt -lt $max_attempts ]]; do
        ((attempt++))

        if [[ $attempt -gt 1 ]]; then
            log_warn "[download] Attempt ${attempt}/${max_attempts} — waiting ${delay}s..."
            sleep "$delay"
            delay=$((delay * 2))
        fi

        log_info "[download] Attempt ${attempt}/${max_attempts}: curl with resume"

        # Strategy 1: curl via scp+execute
        local dl_script="mkdir -p ${model_dir} && cd ${model_dir} && curl -L -C - -o '${model_file}' '${model_url}' --connect-timeout 30 --max-time 3600 --retry 3 --progress-bar"
        printf '%s\n' "$dl_script" | ssh "${ssh_args[@]}" "root@${ssh_host}" "cat > /tmp/hermes-dl.sh" 2>/dev/null
        if ssh "${ssh_args[@]}" "root@${ssh_host}" "bash /tmp/hermes-dl.sh" 2>/dev/null; then
            # Verify size
            local dl_size
            dl_size=$(ssh "${ssh_args[@]}" "root@${ssh_host}" "stat -c%s '${model_path}' 2>/dev/null || echo 0" 2>/dev/null) || dl_size=0
            if [[ "$dl_size" -gt 1048576 ]]; then
                log_info "[download] Success: ${dl_size} bytes"
                return 0
            fi
            log_warn "[download] File too small (${dl_size} bytes) — retrying"
        fi

        # Strategy 2: wget fallback
        log_info "[download] Attempt ${attempt}/${max_attempts}: wget fallback"
        local wget_script="mkdir -p ${model_dir} && cd ${model_dir} && wget -c -O '${model_file}' '${model_url}' --timeout=30 --tries=3 --progress=bar:force"
        printf '%s\n' "$wget_script" | ssh "${ssh_args[@]}" "root@${ssh_host}" "cat > /tmp/hermes-dl.sh" 2>/dev/null
        if ssh "${ssh_args[@]}" "root@${ssh_host}" "bash /tmp/hermes-dl.sh" 2>/dev/null; then
            local dl_size
            dl_size=$(ssh "${ssh_args[@]}" "root@${ssh_host}" "stat -c%s '${model_path}' 2>/dev/null || echo 0" 2>/dev/null) || dl_size=0
            if [[ "$dl_size" -gt 1048576 ]]; then
                log_info "[download] Success via wget: ${dl_size} bytes"
                return 0
            fi
        fi
    done

    log_error "[download] Exhausted ${max_attempts} attempts"
    return 5
}

# -----------------------------------------------------------------------------
# Server Health Retry
# -----------------------------------------------------------------------------

# retry_health_check <health_url> <max_attempts> <delay_secs>
#   Polls health endpoint with retry. Returns 0 when server is healthy.
#   Distinguishes between "not ready yet" (retry) and "crashed" (fatal via log check).
retry_health_check() {
    local health_url="$1"
    local max_attempts="${2:-24}"   # 24 × 5s = 2 min
    local delay="${3:-5}"

    local attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        ((attempt++))

        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" "$health_url" 2>/dev/null) || http_code="000"

        if [[ "$http_code" == "200" ]]; then
            log_info "[health] Server healthy (attempt ${attempt})"
            return 0
        fi

        if [[ "$http_code" == "000" ]]; then
            log_warn "[health] Server unreachable (attempt ${attempt}/${max_attempts})"
        else
            log_info "[health] HTTP ${http_code} — waiting (attempt ${attempt}/${max_attempts})"
        fi

        sleep "$delay"
    done

    log_error "[health] Server not healthy after ${max_attempts} attempts"
    return 7
}
