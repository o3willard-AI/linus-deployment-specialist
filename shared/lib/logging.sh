#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist - Logging Library
# =============================================================================
# Source this file in other scripts:
#   source "$(dirname "$0")/../lib/logging.sh"
# =============================================================================

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
    echo -e "${BLUE}${msg}${NC}"
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
    echo -e "${GREEN}${msg}${NC}"
    echo "$msg" >> "$LINUS_LOG_FILE"
}

log_debug() {
    if [[ "${LINUS_DEBUG:-0}" == "1" ]]; then
        local msg="[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') - $*"
        echo -e "${CYAN}${msg}${NC}"
        echo "$msg" >> "$LINUS_LOG_FILE"
    fi
}

log_step() {
    local step="$1"
    shift
    local msg="[STEP $step] $(date '+%Y-%m-%d %H:%M:%S') - $*"
    echo -e "${GREEN}${msg}${NC}"
    echo "$msg" >> "$LINUS_LOG_FILE"
}

# -----------------------------------------------------------------------------
# Structured Output (for MCP/Agent parsing)
# -----------------------------------------------------------------------------

# Output a structured result that agents can parse
# Usage: linus_result SUCCESS "VM_ID:123" "VM_IP:192.168.1.50"
linus_result() {
    local status="$1"
    shift
    echo "LINUS_RESULT:${status}"
    for pair in "$@"; do
        echo "LINUS_${pair}"
    done
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
    
    echo ""
    echo -e "${GREEN}${line}${NC}"
    echo -e "${GREEN}= ${msg} =${NC}"
    echo -e "${GREEN}${line}${NC}"
    echo ""
    
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
