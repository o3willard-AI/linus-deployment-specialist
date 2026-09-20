#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist - Logging Library
# =============================================================================
# Source this file in other scripts:
#   source "$(dirname "$0")/../lib/logging.sh"
# =============================================================================

# Include guard - prevent multiple sourcing
if [[ -n "${LINUS_LOGGING_LOADED:-}" ]]; then
    return 0
fi

# Colors (if terminal supports it)
if [[ -t 1 ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[0;33m'
    readonly BLUE='\033[0;34m'
    readonly CYAN='\033[0;36m'
    readonly NC='\033[0m' # No Color
else
    readonly RED=''
    readonly GREEN=''
    readonly YELLOW=''
    readonly BLUE=''
    readonly CYAN=''
    readonly NC=''
fi

# Log file (can be overridden before sourcing)
LINUS_LOG_FILE="${LINUS_LOG_FILE:-/tmp/linus-$(date +%Y%m%d).log}"

# Ensure log directory exists
mkdir -p "$(dirname "$LINUS_LOG_FILE")" 2>/dev/null || true

# -----------------------------------------------------------------------------
# Logging Functions
# -----------------------------------------------------------------------------

log_info() {
    local msg="[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $*"
    echo -e "${BLUE}${msg}${NC}" >&2
    echo "$msg" >> "$LINUS_LOG_FILE"
}

log_warn() {
    local msg="[WARN] $(date '+%Y-%m-%d %H:%M:%S') - $*"
    echo -e "${YELLOW}${msg}${NC}" >&2
    echo "$msg" >> "$LINUS_LOG_FILE"
}

log_error() {
    local msg="[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $*"
    echo -e "${RED}${msg}${NC}" >&2
    echo "$msg" >> "$LINUS_LOG_FILE"
}

log_success() {
    local msg="[SUCCESS] $(date '+%Y-%m-%d %H:%M:%S') - $*"
    echo -e "${GREEN}${msg}${NC}" >&2
    echo "$msg" >> "$LINUS_LOG_FILE"
}

log_debug() {
    if [[ "${LINUS_DEBUG:-0}" == "1" ]]; then
        local msg="[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') - $*"
        echo -e "${CYAN}${msg}${NC}" >&2
        echo "$msg" >> "$LINUS_LOG_FILE"
    fi
}

log_step() {
    local step="$1"
    shift
    local msg="[STEP $step] $(date '+%Y-%m-%d %H:%M:%S') - $*"
    echo -e "${GREEN}${msg}${NC}" >&2
    echo "$msg" >> "$LINUS_LOG_FILE"
}

# ----------------------------------------------------------------------------
# Operator (Accountable Human) Resolution — RAE Level 0
# ----------------------------------------------------------------------------

# Resolve the accountable operator identifier.
# Priority: LINUS_OPERATOR_ID > LINUS_OPERATOR_NAME > $USER > whoami
# The operator is self-declared; no verification is performed (RAE L0).
# Never carries credential material.
resolve_operator() {
    if [[ -n "${LINUS_OPERATOR_ID:-}" ]]; then
        printf '%s' "${LINUS_OPERATOR_ID}"
    elif [[ -n "${LINUS_OPERATOR_NAME:-}" ]]; then
        printf '%s' "${LINUS_OPERATOR_NAME}"
    elif [[ -n "${USER:-}" ]]; then
        printf '%s' "${USER}"
    else
        whoami 2>/dev/null || printf '%s' "unknown"
    fi
}

# Resolve the accountable operator's human-readable name for log messages.
# Priority: LINUS_OPERATOR_NAME > LINUS_OPERATOR_ID > $USER > whoami
resolve_operator_name() {
    if [[ -n "${LINUS_OPERATOR_NAME:-}" ]]; then
        printf '%s' "${LINUS_OPERATOR_NAME}"
    elif [[ -n "${LINUS_OPERATOR_ID:-}" ]]; then
        printf '%s' "${LINUS_OPERATOR_ID}"
    elif [[ -n "${USER:-}" ]]; then
        printf '%s' "${USER}"
    else
        whoami 2>/dev/null || printf '%s' "unknown"
    fi
}

# ----------------------------------------------------------------------------
# Structured Output (for MCP/Agent parsing)
# ----------------------------------------------------------------------------

# Output a structured result that agents can parse.
# An OPERATOR:<id> pair is appended automatically for RAE accountability.
# Usage: linus_result SUCCESS "VM_ID:123" "VM_IP:192.168.1.50"
linus_result() {
    local status="$1"
    shift
    local operator
    operator="$(resolve_operator)"
    echo "LINUS_RESULT:${status}"
    for pair in "$@"; do
        echo "LINUS_${pair}"
    done
    echo "LINUS_OPERATOR:${operator}"
}

# Output success result with key-value pairs
linus_success() {
    linus_result "SUCCESS" "$@"
}

# Output failure result with error message
linus_failure() {
    local error_msg="$1"
    shift
    linus_result "FAILURE" "ERROR:${error_msg}" "$@"
}

# -----------------------------------------------------------------------------
# Progress Indicators
# -----------------------------------------------------------------------------

# Show a spinner for long-running operations
# Usage: long_command & show_spinner $! "Waiting for VM..."
show_spinner() {
    local pid=$1
    local message="${2:-Processing...}"
    local spin='-\|/'
    local i=0
    
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i+1) % 4 ))
        printf "\r${CYAN}[%c]${NC} %s" "${spin:$i:1}" "$message"
        sleep 0.1
    done
    printf "\r"
}

# Show progress bar
# Usage: show_progress 50 100 "Installing packages"
show_progress() {
    local current=$1
    local total=$2
    local message="${3:-Progress}"
    local percent=$((current * 100 / total))
    local filled=$((percent / 2))
    local empty=$((50 - filled))
    
    printf "\r${CYAN}[${NC}"
    printf "%${filled}s" | tr ' ' '='
    printf "%${empty}s" | tr ' ' '-'
    printf "${CYAN}]${NC} %3d%% %s" "$percent" "$message"
    
    if [[ $current -eq $total ]]; then
        echo ""
    fi
}

# -----------------------------------------------------------------------------
# Dividers and Headers
# -----------------------------------------------------------------------------

log_header() {
    local msg="$*"
    local len=${#msg}
    local line=$(printf '=%.0s' $(seq 1 $((len + 4))))
    
    {
        echo ""
        echo -e "${GREEN}${line}${NC}"
        echo -e "${GREEN}= ${msg} =${NC}"
        echo -e "${GREEN}${line}${NC}"
        echo ""
    } >&2
    
    {
        echo ""
        echo "$line"
        echo "= ${msg} ="
        echo "$line"
        echo ""
    } >> "$LINUS_LOG_FILE"
}

log_section() {
    local msg="$*"
    echo ""
    echo -e "${CYAN}--- ${msg} ---${NC}"
    echo ""
    
    {
        echo ""
        echo "--- ${msg} ---"
        echo ""
    } >> "$LINUS_LOG_FILE"
}

# Mark as loaded to prevent multiple sourcing
LINUS_LOGGING_LOADED=1
