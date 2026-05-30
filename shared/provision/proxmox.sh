#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist - Proxmox VM Provisioning
# =============================================================================
# Purpose: Create and configure VMs on Proxmox VE
# Author: Linus Deployment Specialist (AI-generated)
# Version: 1.0
# Automation Level: 1 (Non-interactive design)
#
# Required Environment Variables:
#   PROXMOX_HOST        - Proxmox host IP/hostname (required)
#   PROXMOX_USER        - Proxmox user (e.g., root@pam) (required)
#   PROXMOX_TOKEN_ID    - API token ID (e.g., linus-token) (required)
#   PROXMOX_TOKEN_SECRET- API token secret (required)
#   PROXMOX_NODE        - Proxmox node name (default: moxy)
#   PROXMOX_STORAGE     - Storage pool name (default: local-lvm)
#   PROXMOX_BRIDGE      - Network bridge (default: vmbr0)
#   VM_TEMPLATE_ID      - Template VM ID to clone (default: 9000)
#   VM_NAME             - VM name (optional)
#   VM_CPU              - CPU cores (default: 2)
#   VM_RAM              - RAM in MB (default: 2048)
#   VM_DISK             - Disk size in GB (default: 20)
#
# Usage:
#   ./proxmox.sh
#
# Exit Codes:
#   0 - Success
#   1 - General error
#   2 - Missing dependencies
#   3 - Invalid configuration
#   4 - Proxmox node offline
#   5 - VM creation failed
#   6 - Network/SSH timeout
#   7 - SSH credentials required (PROXMOX_SSH_PASS not set for template bootstrap)
#   9 - Template bootstrap needed (human intervention: provide SSH credentials)
#
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source the unified library path resolver
source "$SCRIPT_DIR/../lib/paths.sh" || exit 1
source_lib "logging.sh" "validation.sh" "ensure-dns.sh"

# -----------------------------------------------------------------------------
# Credential auto-discovery — source from known secret files before env vars
# -----------------------------------------------------------------------------
# Look up credentials from ~/.hermes/secrets/ if not already in environment
_linus_auto_discover_credentials() {
    local secret_dirs=(
        "$HOME/.hermes/secrets"
        "$HOME/.hermes/env"
    )
    local cred_files=(
        "proxmox-token-${PROXMOX_HOST:-192.168.101.155}"
        "proxmox-${PROXMOX_HOST:-192.168.101.155}"
        "proxmox-token"
        "proxmox"
    )
    
    for dir in "${secret_dirs[@]}"; do
        for fname in "${cred_files[@]}"; do
            local fpath="${dir}/${fname}"
            if [[ -f "$fpath" && -r "$fpath" ]]; then
                # Source the file to load PROXMOX_TOKEN_SECRET, PROXMOX_SSH_PASS, etc.
                # Only set variables that aren't already in the environment
                while IFS='=' read -r key value; do
                    [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
                    key="${key## }"; key="${key%% }"
                    value="${value## }"; value="${value%% }"
                    case "$key" in
                        PROXMOX_TOKEN_SECRET) : "${PROXMOX_TOKEN_SECRET:=$value}" ;;
                        PROXMOX_SSH_PASS)     : "${PROXMOX_SSH_PASS:=$value}" ;;
                        PROXMOX_PASS)          : "${PROXMOX_SSH_PASS:=$value}" ;;
                        PROXMOX_USER)          : "${PROXMOX_USER:=$value}" ;;
                        PROXMOX_TOKEN_ID)      : "${PROXMOX_TOKEN_ID:=$value}" ;;
                        PROXMOX_HOST)          : "${PROXMOX_HOST:=$value}" ;;
                    esac
                done < "$fpath"
            fi
        done
    done
}

_linus_auto_discover_credentials

# Configuration from environment with defaults
readonly PROXMOX_NODE="${PROXMOX_NODE:-moxy}"
readonly PROXMOX_STORAGE="${PROXMOX_STORAGE:-local-lvm}"
readonly PROXMOX_BRIDGE="${PROXMOX_BRIDGE:-vmbr0}"
readonly VM_TEMPLATE_ID="${VM_TEMPLATE_ID:-9000}"
readonly VM_TEMPLATE_FALLBACKS="${VM_TEMPLATE_FALLBACKS:-}"
readonly VM_OS_TYPE="${VM_OS_TYPE:-ubuntu}"

readonly VM_NAME="${VM_NAME:-}"
readonly VM_CPU="${VM_CPU:-2}"
readonly VM_RAM="${VM_RAM:-2048}"
readonly VM_DISK="${VM_DISK:-20}"

# ─── ISO Bootstrap Configuration ─────────────────────────────────
# When no templates exist, the deployment specialist can download cloud
# images via the Proxmox API (no SSH needed) and create templates via
# a one-time SSH qm importdisk call. This is the self-healing path.
readonly ISO_STORAGE="${ISO_STORAGE:-local}"                     # Storage for ISO downloads (must support 'iso' content type)
readonly TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local-lvm}"       # Storage for imported VM disk
readonly TEMPLATE_BASE_ID="${TEMPLATE_BASE_ID:-9005}"            # First VM ID for auto-created templates (9005-9010 range)
readonly BOOTSTRAP_TEMPLATE="${BOOTSTRAP_TEMPLATE:-false}"       # Set to 'true' to create template from ISO when none exist
readonly BOOTSTRAP_TIMEOUT="${BOOTSTRAP_TIMEOUT:-900}"           # Max seconds for ISO download (600-900 MB images)

# Known-good cloud image URLs — stable, vendor-published, cloud-init ready
declare -A KNOWN_CLOUD_IMAGES=(
    [ubuntu-2404]="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img|ubuntu-24.04-cloudimg-amd64.img|sha256:|~600 MB|Ubuntu 24.04 LTS (Noble Numbat)"
    [ubuntu-2204]="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img|ubuntu-22.04-cloudimg-amd64.img|sha256:|~550 MB|Ubuntu 22.04 LTS (Jammy Jellyfish)"
    [almalinux-9]="https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2|alma-9-cloudimg-amd64.qcow2|sha256:|~900 MB|AlmaLinux 9"
    [debian-12]="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2|debian-12-cloudimg-amd64.qcow2|sha256:|~500 MB|Debian 12 (Bookworm)"
    [rocky-9]="https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2|rocky-9-cloudimg-amd64.qcow2|sha256:|~900 MB|Rocky Linux 9"
)

# Global variables (set by functions)
ALLOCATED_VM_ID=""
VM_IP=""
VM_SSH_KEY=""  # Discovered SSH key path (set by configure_vm)
SELECTED_TEMPLATE_ID=""     # Set by select_template
SELECTED_TEMPLATE_OSTYPE="" # Set by select_template
DISCOVERED_TEMPLATES=()     # Array of "id:name:ostype" — set by discover_templates
LINUS_WARNINGS=()           # Accumulated non-fatal warning tags (§3.1.6)
DOWNLOADED_ISO_VOLID=""     # Set by download_cloud_image
DOWNLOADED_ISO_FILENAME=""  # Set by download_cloud_image
_CREATED_TEMPLATE_ID=""     # Set by create_template_from_image
PROXMOX_FREE_RAM_MB=0       # Set by discover_host_capacity
readonly PROVISION_START_TIME=$(date +%s)  # For LINUS_COST wall time tracking

# ─── Warning Helper ───────────────────────────────────────────────
# Appends a warning tag to the global accumulator.
# Usage: _warn_tag "qemu_agent_failed"

_warn_tag() {
    LINUS_WARNINGS+=("$1")
}

# Proxmox API helper — wraps curl with token auth
_pvesh() {
    local method="${1:-get}"
    local path="$2"
    shift 2 || true
    
    local url="https://${PROXMOX_HOST}:8006/api2/json${path}"
    local auth_header="Authorization: PVEAPIToken=${PROXMOX_USER}!${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}"
    
    # Only add Content-Type when data arguments are provided (e.g., --data-raw)
    # POST/PUT endpoints without data reject Content-Type: application/json (HTTP 501)
    local ct_header=()
    for arg in "$@"; do
        if [[ "$arg" == --data* ]]; then
            ct_header=(-H "Content-Type: application/json")
            break
        fi
    done
    
    # Capture stderr to a temp file so we can log it on failure
    local _errfile
    _errfile=$(mktemp) || { echo "ERROR: _pvesh: cannot create temp file" >&2; return 1; }
    
    local _exit_code=0
    case "$method" in
        get)
            curl -sk -H "$auth_header" "$url" "$@" 2>"$_errfile"
            _exit_code=$?
            ;;
        post)
            curl -sk --fail -X POST -H "$auth_header" "${ct_header[@]}" "$url" "$@" 2>"$_errfile"
            _exit_code=$?
            ;;
        put)
            curl -sk --fail -X PUT -H "$auth_header" "${ct_header[@]}" "$url" "$@" 2>"$_errfile"
            _exit_code=$?
            ;;
        delete)
            curl -sk --fail -X DELETE -H "$auth_header" "$url" "$@" 2>"$_errfile"
            _exit_code=$?
            ;;
        *)
            echo "ERROR: Unknown method: $method" >&2
            rm -f "$_errfile"
            return 1
            ;;
    esac
    
    # On failure, log the curl stderr for diagnosis
    if [[ $_exit_code -ne 0 ]]; then
        local _errmsg
        _errmsg=$(<"$_errfile")
        [[ -n "$_errmsg" ]] && echo "[ERROR] _pvesh $method $path: $_errmsg" >> "${LINUS_LOG_FILE:-/tmp/linus.log}"
    fi
    rm -f "$_errfile"
    return $_exit_code
}

# Proxmox config setter — converts key=value pairs to JSON for PUT /config
# Usage: _pvesh_set $VMID --cores 2 --memory 2048 --ipconfig0 "ip=10.0.0.1/24,gw=10.0.0.1"
# Supports: cores, memory, ipconfig0, agent, ciuser, ostype, net0, sshkeys, name
_pvesh_set() {
    local vm_id="$1"; shift
    local -A fields
    local key value
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cores)       fields["cores"]="$2"; shift 2 ;;
            --memory)      fields["memory"]="$2"; shift 2 ;;
            --ipconfig0)   fields["ipconfig0"]="$2"; shift 2 ;;
            --agent)       fields["agent"]="$2"; shift 2 ;;
            --ciuser)      fields["ciuser"]="$2"; shift 2 ;;
            --ostype)      fields["ostype"]="$2"; shift 2 ;;
            --net0)        fields["net0"]="$2"; shift 2 ;;
            --sshkeys)     fields["sshkeys"]="$2"; shift 2 ;;
            --name)        fields["name"]="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    
    [[ ${#fields[@]} -eq 0 ]] && { echo "ERROR: _pvesh_set: no fields provided" >&2; return 1; }
    
    # Build JSON object
    local json="{"
    local first=true
    for key in "${!fields[@]}"; do
        value="${fields[$key]}"
        value="${value//\\/\\\\}"; value="${value//\"/\\\"}"
        if $first; then first=false; else json+=","; fi
        case "$key" in
            cores|memory) json+="\"${key}\":${value}" ;;
            *)            json+="\"${key}\":\"${value}\"" ;;
        esac
    done
    json+="}"
    
    _pvesh put "/nodes/${PROXMOX_NODE}/qemu/${vm_id}/config" --data-raw "$json"
}

# Set SSH user from the selected template's actual ciuser config (§3.4).
# Falls back to OS-type-based detection if template config doesn't specify.
_detected_os="${SELECTED_TEMPLATE_OSTYPE:-${VM_OS_TYPE:-ubuntu}}"

# Read template's existing ciuser — don't guess
template_ciuser=""
if [[ -n "${SELECTED_TEMPLATE_ID:-}" ]]; then
    template_ciuser=$(read_template_config "$SELECTED_TEMPLATE_ID" | jq -r '.data.ciuser // ""' 2>/dev/null) || template_ciuser=""
fi

if [[ -n "$template_ciuser" && "$template_ciuser" != "null" ]]; then
    VM_SSH_USER="$template_ciuser"
    log_info "SSH user from template config: ${VM_SSH_USER} (ciuser)"
else
    case "${_detected_os}" in
        ubuntu|debian)
            VM_SSH_USER="ubuntu"
            ;;
        almalinux)
            VM_SSH_USER="almalinux"
            ;;
        rocky)
            VM_SSH_USER="rocky"
            ;;
        *)
            VM_SSH_USER="cloud-user"
            ;;
    esac
    log_info "SSH user from OS detection: ${VM_SSH_USER} (detected OS: ${_detected_os})"
fi

# ─── LLM Eval Helper ─────────────────────────────────────────────
# Calls llm-eval.py for non-deterministic touch points.
# Returns decision text; falls back to deterministic silently.

_linus_llm_eval() {
    local mode="$1"
    local input_text="$2"
    local eval_script="${REPO_ROOT:-$SCRIPT_DIR/..}/shared/lib/llm-eval.py"
    
    if [[ ! -f "$eval_script" ]]; then
        eval_script="$SCRIPT_DIR/../lib/llm-eval.py"
    fi
    
    if [[ ! -f "$eval_script" ]]; then
        return 1  # No evaluator available
    fi
    
    python3 "$eval_script" "$mode" <<< "$input_text" 2>/dev/null || true
}

# ─── Template Bootstrap Handler ───────────────────────────────────
# Called when discover_templates() or select_template() fails.
# If PROXMOX_SSH_PASS is set, auto-bootstraps from ISO.
# Otherwise, outputs NEEDS_TEMPLATE_BOOTSTRAP for the operating agent.
# Returns: 0 if bootstrapped successfully, non-zero to abort
# ───────────────────────────────────────────────────────────────────

_handle_missing_templates() {
    local os_key="${VM_OS_TYPE:-ubuntu}"

    # Auto-bootstrap path: SSH credentials available + bootstrap requested
    if [[ "${BOOTSTRAP_TEMPLATE:-false}" == "true" ]] && [[ -n "${PROXMOX_SSH_PASS:-}" ]]; then
        log_warn "No templates found — attempting auto-bootstrap from cloud image"
        if bootstrap_template_from_iso "$os_key"; then
            # Re-run template discovery/selection with fresh data
            if discover_templates && select_template; then
                log_success "Template bootstrap successful — proceeding with provisioning"
                return 0
            fi
            log_error "Template created but selection still failed"
            return 3
        fi
        log_error "Template bootstrap failed"
        return 5
    fi

    # Agent information path: no SSH credentials — tell the operating agent
    output_bootstrap_instructions "$os_key"
    return 9  # Exit code 9 = "needs human intervention (template bootstrap)"
}

# -----------------------------------------------------------------------------
# Function: validate_environment
# -----------------------------------------------------------------------------
# Validates that all prerequisites are met
# Returns: 0 on success, non-zero on failure
# -----------------------------------------------------------------------------

validate_environment() {
    log_step "1" "Validating environment"

    # PITFALL 22: Error suppression hides root causes - replace key >/dev/null 2>&1 with capture-then-log-on-failure pattern
    
    # Check Proxmox node status (check if uptime exists - node must be running to have uptime)
    log_info "Checking Proxmox node status..."
    local node_uptime=$(_pvesh get /nodes/${PROXMOX_NODE}/status 2>&1 | jq -r '.data.uptime // 0') || {
        log_error "Proxmox node ${PROXMOX_NODE} is not accessible or offline"
        return 4
    }
    
    if [[ "$node_uptime" -eq 0 ]]; then
        log_error "Proxmox node ${PROXMOX_NODE} is not accessible or offline"
        return 4
    fi
    log_info "Node online (uptime: ${node_uptime}s)"
    
    # Check storage exists
    log_info "Checking storage pool..."
    local storage_check
    storage_check=$(_pvesh get /storage/${PROXMOX_STORAGE} 2>&1) || {
        log_error "Storage pool ${PROXMOX_STORAGE} not found"
        return 3
    }
    log_info "Storage: ${PROXMOX_STORAGE} OK"
    
    # Check network bridge exists - we'll just verify connectivity to API instead
    log_info "Checking network bridge..."
    local bridge_check
    bridge_check=$(_pvesh get /nodes/${PROXMOX_NODE}/status 2>&1) || {
        log_error "Network bridge ${PROXMOX_BRIDGE} not found"
        return 3
    }
    log_info "Bridge: ${PROXMOX_BRIDGE} OK"
    
    # Check templates exist via discovery (single API call, no 404 problem)
    log_info "Checking templates..."
    if ! discover_templates; then
        _handle_missing_templates || return $?
    fi
    
    if ! select_template; then
        _handle_missing_templates || return $?
    fi

    # Validate OS type
    validate_os "${VM_OS_TYPE}" || return 3

    # Validate VM specification
    validate_positive_int "$VM_CPU" "CPU cores" || return 1
    validate_positive_int "$VM_RAM" "RAM (MB)" || return 1
    validate_positive_int "$VM_DISK" "Disk (GB)" || return 1

    log_success "Environment validation passed"
    return 0
}

# -----------------------------------------------------------------------------
# Function: detect_network_config
# -----------------------------------------------------------------------------
# Queries the Proxmox host's bridge configuration to detect subnet and gateway.
# Handles DHCP-on-router, DHCP-on-host, and no-DHCP setups dynamically.
# Sets: SUBNET_PREFIX (first 3 octets), GATEWAY_IP, VM_CIDR
# Returns: 0 on success, non-zero on failure (falls back to hardcoded defaults)
# -----------------------------------------------------------------------------

detect_network_config() {
    log_step "1b" "Detecting network configuration"

    local bridge_info
    bridge_info=$(_pvesh get /nodes/${PROXMOX_NODE}/network 2>/dev/null | \
        python3 -c "
import json, sys, ipaddress
data = json.load(sys.stdin).get('data', [])
for iface in data:
    if iface.get('iface') == '${PROXMOX_BRIDGE}' and iface.get('type') == 'bridge':
        cidr = iface.get('cidr', '')
        gw = iface.get('gateway', '')
        if cidr:
            net = ipaddress.ip_network(cidr, strict=False)
            # First 3 octets for VM IP assignment
            prefix = '.'.join(str(net.network_address).split('.')[:3])
            print(f'PREFIX={prefix}|GATEWAY={gw}|CIDR={cidr}')
        break
" 2>/dev/null) || true

    if [[ -n "$bridge_info" ]]; then
        SUBNET_PREFIX=$(echo "$bridge_info" | grep -oP 'PREFIX=\K[^|]+')
        GATEWAY_IP=$(echo "$bridge_info" | grep -oP 'GATEWAY=\K[^|]+')
        VM_CIDR=$(echo "$bridge_info" | grep -oP 'CIDR=\K[^|]+')
        log_success "Network detected: ${SUBNET_PREFIX}.0/24, gateway=${GATEWAY_IP}"
    else
        log_warn "Could not detect network from API, using env/fallback"
        SUBNET_PREFIX="${PROXMOX_SUBNET_PREFIX:-192.168.101}"
        GATEWAY_IP="${PROXMOX_GATEWAY:-192.168.101.2}"
        VM_CIDR="${SUBNET_PREFIX}.0/24"
        log_info "Using: ${SUBNET_PREFIX}.0/24, gateway=${GATEWAY_IP}"
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Function: discover_host_capacity
# -----------------------------------------------------------------------------
# Queries Proxmox node status and storage to determine free resources.
# Used by multi-VM orchestrators to avoid over-provisioning the host.
# Sets: PROXMOX_FREE_RAM_MB, PROXMOX_FREE_DISK_GB, PROXMOX_TOTAL_CPUS
# Returns: 0 on success, 1 on API error (non-fatal — capacity tracking disabled)
# -----------------------------------------------------------------------------

discover_host_capacity() {
    log_step "1c" "Discovering host capacity"

    local node_status storage_info
    
    node_status=$(_pvesh get /nodes/${PROXMOX_NODE}/status 2>/dev/null) || {
        log_warn "Could not query node status — capacity tracking disabled"
        _warn_tag "capacity_discovery_failed"
        return 1
    }
    
    PROXMOX_FREE_RAM_MB=$(echo "$node_status" | jq -r '.data.memory.free // 0' | awk '{print int($1/1048576)}')
    PROXMOX_TOTAL_CPUS=$(echo "$node_status" | jq -r '.data.cpuinfo.cpus // 0')
    
    storage_info=$(_pvesh get "/nodes/${PROXMOX_NODE}/storage/${PROXMOX_STORAGE}/status" 2>/dev/null) || {
        log_warn "Could not query storage — disk tracking disabled"
        PROXMOX_FREE_DISK_GB=0
        return 1
    }
    
    local total_bytes used_bytes
    total_bytes=$(echo "$storage_info" | jq -r '.data.total // 0')
    used_bytes=$(echo "$storage_info" | jq -r '.data.used // 0')
    PROXMOX_FREE_DISK_GB=$(awk "BEGIN {print int(($total_bytes - $used_bytes) / 1073741824)}")
    
    log_info "Host capacity: ${PROXMOX_FREE_RAM_MB}MB RAM free, ${PROXMOX_FREE_DISK_GB}GB disk free, ${PROXMOX_TOTAL_CPUS} CPUs"
    return 0
}

# -----------------------------------------------------------------------------
# Function: allocate_vm_id
# -----------------------------------------------------------------------------
# Finds the next available VM ID
# Sets: ALLOCATED_VM_ID
# Returns: 0 on success, 5 on failure (no IDs available)
# -----------------------------------------------------------------------------

allocate_vm_id() {
    log_step "2" "Allocating VM ID"

    # Query cluster resources once to get all existing VM IDs (single API call)
    local used_ids
    used_ids=$(_pvesh get /cluster/resources?type=vm 2>/dev/null | \
        python3 -c "
import json, sys
data = json.load(sys.stdin)
ids = sorted(r['vmid'] for r in data['data'] if r.get('type') == 'qemu')
print(' '.join(str(i) for i in ids))
" 2>/dev/null) || used_ids=""

    # Find first available ID starting from next free slot
    local vm_id=113
    while true; do
        if ! echo " $used_ids " | grep -q " $vm_id "; then
            ALLOCATED_VM_ID="$vm_id"
            # Static IP: {subnet}.{vmid} (no DHCP on most Proxmox bridges)
            ALLOCATED_VM_IP="${SUBNET_PREFIX}.${vm_id}"
            
            # Capacity guard: warn/refuse if host is near resource limits
            if [[ -n "${PROXMOX_FREE_RAM_MB:-}" && $VM_RAM -gt $((PROXMOX_FREE_RAM_MB - 1024)) ]]; then
                log_warn "Low host RAM: ${PROXMOX_FREE_RAM_MB}MB free, VM needs ${VM_RAM}MB (1GB headroom reserved)"
            fi
            if [[ -n "${PROXMOX_FREE_DISK_GB:-}" && ${PROXMOX_FREE_DISK_GB:-0} -gt 0 && $VM_DISK -gt ${PROXMOX_FREE_DISK_GB:-0} ]]; then
                log_error "Insufficient host disk: ${PROXMOX_FREE_DISK_GB}GB free, VM needs ${VM_DISK}GB"
                return 7
            fi
            
            log_success "Allocated VM ID: $vm_id (IP: $ALLOCATED_VM_IP, subnet: $VM_CIDR)"
            return 0
        fi
        ((vm_id++))
        if [[ $vm_id -gt 250 ]]; then
            log_error "No available VM IDs (checked 113-250)"
            return 5
        fi
    done
}

# -----------------------------------------------------------------------------
# Function: discover_templates
# -----------------------------------------------------------------------------
# Discovers all available templates on the node by listing all VMs and filtering
# for template=1. Single API call — no 404 problem unlike per-template status checks.
# Sets: DISCOVERED_TEMPLATES (array of "id:name:ostype" strings)
# Returns: 0 on success, non-zero if no templates found
# -----------------------------------------------------------------------------

discover_templates() {
    log_info "Discovering templates on node ${PROXMOX_NODE}..."
    
    DISCOVERED_TEMPLATES=()
    
    local templates_json
    templates_json=$(_pvesh get "/nodes/${PROXMOX_NODE}/qemu" 2>/dev/null) || {
        log_warn "Could not list VMs — template discovery failed"
        return 1
    }
    
    # Parse: extract vmid, name, and template flag
    while IFS= read -r line; do
        DISCOVERED_TEMPLATES+=("$line")
    done < <(echo "$templates_json" | python3 -c "
import json, sys
data = json.load(sys.stdin).get('data', [])
for vm in data:
    if vm.get('template') == 1:
        vmid = vm.get('vmid', '')
        name = vm.get('name', 'unknown')
        # Try to detect OS type from name
        ostype = 'unknown'
        name_lower = name.lower()
        if 'ubuntu' in name_lower:
            ostype = 'ubuntu'
        elif 'alma' in name_lower:
            ostype = 'almalinux'
        elif 'rocky' in name_lower:
            ostype = 'rocky'
        elif 'debian' in name_lower:
            ostype = 'debian'
        print(f'{vmid}:{name}:{ostype}')
" 2>/dev/null)
    
    if [[ ${#DISCOVERED_TEMPLATES[@]} -eq 0 ]]; then
        log_error "No templates found on node ${PROXMOX_NODE}"
        return 1
    fi
    
    log_success "Discovered ${#DISCOVERED_TEMPLATES[@]} template(s)"
    for t in "${DISCOVERED_TEMPLATES[@]}"; do
        log_info "  Template: $t"
    done
    return 0
}

# -----------------------------------------------------------------------------
# Function: select_template
# -----------------------------------------------------------------------------
# Selects the best template from discovered templates or fallback list.
# Priority: exact VM_TEMPLATE_ID match → VM_TEMPLATE_FALLBACKS → any template
# matching VM_OS_TYPE → any template
# Sets: SELECTED_TEMPLATE_ID, SELECTED_TEMPLATE_OSTYPE
# Returns: 0 on success, 3 if no template found
# -----------------------------------------------------------------------------

select_template() {
    log_step "2b" "Selecting template"
    
    # Normalize OS type for matching
    local os_filter="${VM_OS_TYPE:-ubuntu}"
    
    # First: try the explicitly requested template ID
    if [[ -n "${VM_TEMPLATE_ID:-}" ]]; then
        for t in "${DISCOVERED_TEMPLATES[@]}"; do
            local t_id="${t%%:*}"
            if [[ "$t_id" == "$VM_TEMPLATE_ID" ]]; then
                SELECTED_TEMPLATE_ID="$t_id"
                SELECTED_TEMPLATE_OSTYPE=$(echo "$t" | cut -d: -f3)
                log_success "Selected requested template: VM ${t_id} (${SELECTED_TEMPLATE_OSTYPE})"
                return 0
            fi
        done
        log_warn "Requested template VM ${VM_TEMPLATE_ID} not found — trying fallbacks"
    fi
    
    # Second: try fallback chain
    local fallbacks="${VM_TEMPLATE_FALLBACKS:-}"
    if [[ -n "$fallbacks" ]]; then
        IFS=',' read -ra fb_arr <<< "$fallbacks"
        for fb_id in "${fb_arr[@]}"; do
            fb_id="${fb_id## }"; fb_id="${fb_id%% }"  # trim whitespace
            for t in "${DISCOVERED_TEMPLATES[@]}"; do
                local t_id="${t%%:*}"
                if [[ "$t_id" == "$fb_id" ]]; then
                    SELECTED_TEMPLATE_ID="$t_id"
                    SELECTED_TEMPLATE_OSTYPE=$(echo "$t" | cut -d: -f3)
                    log_success "Selected fallback template: VM ${t_id} (${SELECTED_TEMPLATE_OSTYPE})"
                    return 0
                fi
            done
        done
        log_warn "No fallback templates found — trying OS-type match"
    fi
    
    # Third: match by OS type
    # If multiple matches, use LLM touch point (PP-TP1) to pick the best
    local matching_templates=()
    for t in "${DISCOVERED_TEMPLATES[@]}"; do
        local t_os=$(echo "$t" | cut -d: -f3)
        if [[ "$t_os" == "$os_filter" ]]; then
            matching_templates+=("$t")
        fi
    done
    
    if [[ ${#matching_templates[@]} -eq 1 ]]; then
        SELECTED_TEMPLATE_ID="${matching_templates[0]%%:*}"
        SELECTED_TEMPLATE_OSTYPE=$(echo "${matching_templates[0]}" | cut -d: -f3)
        log_success "Selected OS-matched template: VM ${SELECTED_TEMPLATE_ID} (${SELECTED_TEMPLATE_OSTYPE})"
        return 0
    elif [[ ${#matching_templates[@]} -gt 1 ]]; then
        # PP-TP1: Multiple matching templates — use LLM to pick best
        local template_list
        template_list=$(printf '%s\n' "${matching_templates[@]}")
        local llm_choice
        llm_choice=$(_linus_llm_eval "proxmox-template-select" "Requested OS: ${os_filter}
Available templates:
${template_list}
Select the best template VM ID." 2>/dev/null) || llm_choice=""
        
        if [[ -n "$llm_choice" ]]; then
            # Verify the LLM picked a valid template ID
            for t in "${matching_templates[@]}"; do
                if [[ "${t%%:*}" == "$llm_choice" ]]; then
                    SELECTED_TEMPLATE_ID="$llm_choice"
                    SELECTED_TEMPLATE_OSTYPE=$(echo "$t" | cut -d: -f3)
                    log_success "LLM selected template: VM ${SELECTED_TEMPLATE_ID} (${SELECTED_TEMPLATE_OSTYPE})"
                    return 0
                fi
            done
        fi
        # LLM failed or returned invalid — fall through to first match
        log_info "LLM template selection unavailable — using first match"
        SELECTED_TEMPLATE_ID="${matching_templates[0]%%:*}"
        SELECTED_TEMPLATE_OSTYPE=$(echo "${matching_templates[0]}" | cut -d: -f3)
        log_success "Selected OS-matched template: VM ${SELECTED_TEMPLATE_ID} (${SELECTED_TEMPLATE_OSTYPE})"
        return 0
    fi
    
    # Last resort: any template
    if [[ ${#DISCOVERED_TEMPLATES[@]} -gt 0 ]]; then
        local t="${DISCOVERED_TEMPLATES[0]}"
        SELECTED_TEMPLATE_ID="${t%%:*}"
        SELECTED_TEMPLATE_OSTYPE=$(echo "$t" | cut -d: -f3)
        log_warn "No OS match — using first available template: VM ${SELECTED_TEMPLATE_ID} (${SELECTED_TEMPLATE_OSTYPE})"
        return 0
    fi
    
    log_error "No templates available on node ${PROXMOX_NODE}"
    return 3
}

# -----------------------------------------------------------------------------
# Function: read_template_config
# -----------------------------------------------------------------------------
# Reads the existing configuration of a template VM before modifying it.
# Returns config as JSON. Used to preserve existing ciuser, ostype, cpu settings
# rather than guessing OS defaults (§3.4).
#
# Args: template_id
# Returns: JSON config on stdout, empty on error
# -----------------------------------------------------------------------------

read_template_config() {
    local template_id="$1"
    _pvesh get "/nodes/${PROXMOX_NODE}/qemu/${template_id}/config" 2>/dev/null || echo "{}"
}

# =============================================================================
# Template Bootstrap Functions (ISO download + template creation)
# =============================================================================
# These functions implement the self-healing path when no VM templates exist:
#   1. Download cloud image via Proxmox API (no SSH)
#   2. Import disk + create template via SSH (one-time qm importdisk)
#   3. Re-discover templates (the new one now exists)
#
# When PROXMOX_SSH_PASS is NOT set, output NEEDS_TEMPLATE_BOOTSTRAP instead of
# failing — the operating agent informs the user and collects SSH credentials.
# =============================================================================

# ─── get_known_iso_info ────────────────────────────────────────────
# Returns the known cloud image info for an OS type.
# Output format: url|filename|checksum_type:checksum|size|description
# Args: os_key (e.g., "ubuntu-2404", "almalinux-9")
# Returns: pipe-delimited info on stdout, empty on unknown OS
# ───────────────────────────────────────────────────────────────────

get_known_iso_info() {
    local os_key="$1"
    # Map VM_OS_TYPE values to our known image keys
    case "${os_key}" in
        ubuntu|ubuntu2404) os_key="ubuntu-2404" ;;
        ubuntu2204|jammy)  os_key="ubuntu-2204" ;;
        almalinux|alma9)   os_key="almalinux-9" ;;
        debian|debian12)   os_key="debian-12" ;;
        rocky|rocky9)      os_key="rocky-9" ;;
    esac
    echo "${KNOWN_CLOUD_IMAGES[$os_key]:-}"
}

# ─── find_iso_in_storage ───────────────────────────────────────────
# Checks whether a cloud image ISO already exists in Proxmox storage.
# Args: filename (e.g. "ubuntu-24.04-cloudimg-amd64.img")
# Returns: 0 and prints volid on stdout if found, 1 if not found
# ───────────────────────────────────────────────────────────────────

find_iso_in_storage() {
    local target_filename="$1"
    local storage="${2:-${ISO_STORAGE}}"

    log_info "Checking for existing ISO in storage ${storage}..."

    local content_json
    content_json=$(_pvesh get "/nodes/${PROXMOX_NODE}/storage/${storage}/content" 2>/dev/null) || {
        log_warn "Could not query storage content"
        return 1
    }

    # Search for matching filename
    local found
    found=$(echo "$content_json" | python3 -c "
import json, sys
data = json.load(sys.stdin).get('data', [])
for item in data:
    volid = item.get('volid', '')
    if '${target_filename}' in volid:
        print(volid)
        break
" 2>/dev/null)

    if [[ -n "$found" ]]; then
        log_success "ISO already exists: ${found}"
        echo "$found"
        return 0
    fi

    log_info "ISO '${target_filename}' not found in storage"
    return 1
}

# ─── download_cloud_image ──────────────────────────────────────────
# Downloads a cloud image ISO via the Proxmox download-url API.
# Args: os_key, [filename], [checksum]
# Returns: 0 on success (sets DOWNLOADED_ISO_VOLID), non-zero on failure
# ───────────────────────────────────────────────────────────────────

download_cloud_image() {
    local os_key="$1"
    local custom_filename="${2:-}"
    local checksum="${3:-}"

    local iso_info
    iso_info=$(get_known_iso_info "$os_key")
    if [[ -z "$iso_info" ]]; then
        log_error "No known cloud image URL for OS: ${os_key}"
        return 9
    fi

    local iso_url filename iso_size description
    IFS='|' read -r iso_url filename _checksum_info iso_size description <<< "$iso_info"
    filename="${custom_filename:-$filename}"

    log_step "B1" "Downloading ${description} cloud image"
    log_info "  URL: ${iso_url}"
    log_info "  Filename: ${filename}"
    log_info "  Size: ${iso_size}"
    log_info "  Storage: ${ISO_STORAGE}"

    # First check if already downloaded
    local existing
    if existing=$(find_iso_in_storage "$filename" 2>/dev/null) && [[ -n "$existing" ]]; then
        DOWNLOADED_ISO_VOLID="$existing"
        DOWNLOADED_ISO_FILENAME="$filename"
        log_success "Using existing ISO: ${existing}"
        return 0
    fi

    # Build the download request payload
    local payload
    payload=$(python3 -c "
import json
payload = {
    'content': 'iso',
    'filename': '${filename}',
    'url': '${iso_url}',
    'node': '${PROXMOX_NODE}',
    'storage': '${ISO_STORAGE}'
}
if '${checksum}': payload['checksum'] = '${checksum}'
if '${checksum}' and 'sha256' in '${checksum}': payload['checksum-algorithm'] = 'sha256'
json.dump(payload, open('/tmp/linus-iso-payload.json', 'w'))
")

    # Fire the download — this is async (returns UPID like clone)
    local response upid
    response=$(curl -sk --fail -X POST \
        -H "Authorization: PVEAPIToken=${PROXMOX_USER}!${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
        -H "Content-Type: application/json" \
        --data-binary @/tmp/linus-iso-payload.json \
        "https://${PROXMOX_HOST}:8006/api2/json/nodes/${PROXMOX_NODE}/storage/${ISO_STORAGE}/download-url" 2>&1) || {
        local exit_code=$?
        log_error "ISO download request failed (curl exit ${exit_code}): ${response}"
        rm -f /tmp/linus-iso-payload.json
        return 5
    }
    rm -f /tmp/linus-iso-payload.json

    upid=$(echo "$response" | python3 -c "import json,sys; print(json.load(sys.stdin).get('data',''))" 2>/dev/null)
    if [[ -z "$upid" ]]; then
        log_error "No task UPID in download response: ${response}"
        return 5
    fi

    log_info "Download started — task: ${upid}"

    # Poll until download completes
    if ! poll_download_task "$upid" "$BOOTSTRAP_TIMEOUT"; then
        log_error "ISO download failed or timed out"
        return 5
    fi

    # Verify the ISO appears in storage
    local verify_volid
    verify_volid=$(find_iso_in_storage "$filename" 2>/dev/null) || true
    if [[ -z "$verify_volid" ]]; then
        log_error "ISO download task completed but file not found in storage"
        return 5
    fi

    DOWNLOADED_ISO_VOLID="$verify_volid"
    DOWNLOADED_ISO_FILENAME="$filename"
    log_success "Cloud image downloaded: ${verify_volid}"
    return 0
}

# ─── poll_download_task ────────────────────────────────────────────
# Polls an async Proxmox task (from download-url) until completion.
# Args: upid, [timeout_seconds=900]
# Returns: 0 on success, 1 on timeout, 2 on task failure
# ───────────────────────────────────────────────────────────────────

poll_download_task() {
    local upid="$1"
    local timeout="${2:-900}"
    local elapsed=0
    local interval=10

    log_info "Waiting for download to complete (timeout: ${timeout}s)..."

    while [[ $elapsed -lt $timeout ]]; do
        local status_json
        status_json=$(_pvesh get "/nodes/${PROXMOX_NODE}/tasks/${upid}/status" 2>/dev/null) || {
            sleep $interval
            elapsed=$((elapsed + interval))
            continue
        }

        local task_status exitstatus
        task_status=$(echo "$status_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('data',{}).get('status',''))" 2>/dev/null)
        exitstatus=$(echo "$status_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('data',{}).get('exitstatus',''))" 2>/dev/null)

        case "$task_status" in
            stopped)
                if [[ "$exitstatus" == "OK" ]]; then
                    log_success "Download completed (${elapsed}s)"
                    return 0
                else
                    log_error "Download task failed: ${exitstatus}"
                    return 2
                fi
                ;;
            "")
                # Task not yet available — keep polling
                ;;
        esac

        # Progress indicator every 30 seconds
        if [[ $((elapsed % 30)) -eq 0 && $elapsed -gt 0 ]]; then
            log_info "  Download in progress... (${elapsed}s elapsed)"
        fi

        sleep $interval
        elapsed=$((elapsed + interval))
    done

    log_error "Download timed out after ${timeout}s"
    return 1
}

# ─── create_template_from_image ────────────────────────────────────
# Converts a downloaded cloud image into a Proxmox VM template.
# THIS IS THE ONLY FUNCTION THAT REQUIRES SSH TO THE PROXMOX HOST.
# Uses qm importdisk + qm template — no REST API equivalent exists.
#
# Args: template_vmid, os_type (e.g. "ubuntu"), cpu_cores, ram_mb, disk_gb
# Requires: PROXMOX_SSH_PASS (temporary, not stored), DOWNLOADED_ISO_FILENAME
# Returns: 0 on success, non-zero on failure
# ───────────────────────────────────────────────────────────────────

create_template_from_image() {
    local template_vmid="$1"
    local os_type="${2:-ubuntu}"
    local cpu="${3:-2}"
    local ram="${4:-2048}"
    local disk="${5:-20}"

    if [[ -z "${PROXMOX_SSH_PASS:-}" ]]; then
        log_error "PROXMOX_SSH_PASS is required for template creation (qm importdisk needs SSH)"
        log_error "This is a one-time operation per OS image. Set PROXMOX_SSH_PASS and re-run."
        return 7
    fi

    if [[ -z "${DOWNLOADED_ISO_FILENAME:-}" ]]; then
        log_error "No ISO filename — run download_cloud_image first"
        return 3
    fi

    local iso_path="/var/lib/vz/template/iso/${DOWNLOADED_ISO_FILENAME}"
    local ostype_flag

    # Map OS type to Proxmox ostype flag
    case "$os_type" in
        ubuntu|debian) ostype_flag="l26" ;;   # Linux 2.6+ kernel
        almalinux|rocky) ostype_flag="l26" ;;
        *) ostype_flag="l26" ;;
    esac

    log_step "B2" "Creating VM template from cloud image"
    log_info "  VM ID: ${template_vmid}"
    log_info "  OS type: ${os_type} (ostype=${ostype_flag})"
    log_info "  CPU: ${cpu} cores, RAM: ${ram} MB, Disk: ${disk} GB"
    log_info "  ISO path: ${iso_path}"
    log_info "  Storage: ${TEMPLATE_STORAGE}"
    log_info "  THIS REQUIRES TEMPORARY SSH ACCESS TO PROXMOX HOST (one-time)"

    # Write a local script that will be scp'd to Proxmox host and executed.
    # This avoids the escaping nightmare of inline SSH commands.
    local script_path="/tmp/linus-create-template-${template_vmid}.sh"
    python3 -c "
script = '''#!/bin/bash
set -euo pipefail
echo \"[qm] Creating VM ${template_vmid}...\"
qm create ${template_vmid} \\
    --name '${os_type}-cloud-template' \\
    --memory ${ram} \\
    --cores ${cpu} \\
    --net0 virtio,bridge=vmbr0 \\
    --ostype ${ostype_flag} \\
    --scsihw virtio-scsi-pci

echo \"[qm] Importing disk from ${iso_path}...\"
qm importdisk ${template_vmid} '${iso_path}' ${TEMPLATE_STORAGE}

echo \"[qm] Attaching disk...\"
UNUSED=\$(qm config ${template_vmid} | grep -E '^unused0:' | cut -d' ' -f2)
qm set ${template_vmid} --scsi0 \"\${UNUSED}\"

echo \"[qm] Configuring cloud-init...\"
qm set ${template_vmid} --ide2 ${TEMPLATE_STORAGE}:cloudinit
qm set ${template_vmid} --boot c --bootdisk scsi0
qm set ${template_vmid} --serial0 socket --vga serial0
qm set ${template_vmid} --agent enabled=1
qm set ${template_vmid} --cpu host

echo \"[qm] Converting to template...\"
qm template ${template_vmid}

echo \"TEMPLATE_OK:${template_vmid}\"
'''
with open('${script_path}', 'w') as f:
    f.write(script)
"

    # Copy script to Proxmox host
    local scp_result
    scp_result=$(sshpass -p "${PROXMOX_SSH_PASS}" scp \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        "${script_path}" "root@${PROXMOX_HOST}:/tmp/linus-create-template.sh" 2>&1) || {
        log_error "Failed to copy template creation script to Proxmox host:"
        log_error "${scp_result}"
        rm -f "${script_path}"
        return 5
    }
    rm -f "${script_path}"

    # Execute the script on Proxmox host
    local ssh_result
    ssh_result=$(sshpass -p "${PROXMOX_SSH_PASS}" ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        -o ServerAliveInterval=30 \
        "root@${PROXMOX_HOST}" \
        "bash /tmp/linus-create-template.sh && rm -f /tmp/linus-create-template.sh" 2>&1) || {
        log_error "Template creation via SSH failed:"
        log_error "${ssh_result}"
        return 5
    }

    log_info "qm output: ${ssh_result}"

    if echo "$ssh_result" | grep -q "TEMPLATE_OK:${template_vmid}"; then
        log_success "Template ${template_vmid} created from cloud image"
        _CREATED_TEMPLATE_ID="${template_vmid}"
        return 0
    fi

    log_error "Template creation output did not confirm success"
    return 5
}

# ─── bootstrap_template_from_iso ───────────────────────────────────
# Full bootstrap flow: download ISO → create template → re-discover.
# This is the single entry point for the self-healing path.
#
# Args: os_key (e.g., "ubuntu-2404")
# Requires: PROXMOX_SSH_PASS (temporary, for qm importdisk only)
# Returns: 0 on success (template created + discoverable), non-zero on failure
# ───────────────────────────────────────────────────────────────────

bootstrap_template_from_iso() {
    local os_key="$1"
    local template_vmid="${TEMPLATE_BASE_ID}"

    log_header "Template Bootstrap — Creating template from cloud image"
    log_info "No templates found. Bootstrapping ${os_key} template from ISO."
    log_info "This downloads ~600-900 MB via Proxmox API (no SSH) + one SSH command."

    # Step 1: Download cloud image via API
    if ! download_cloud_image "$os_key"; then
        log_error "Failed to download cloud image for ${os_key}"
        return 5
    fi

    # Step 2: Create template from downloaded image (SSH required here)
    if ! create_template_from_image "$template_vmid" "${VM_OS_TYPE}" "$VM_CPU" "$VM_RAM" "$VM_DISK"; then
        log_error "Failed to create template from cloud image"
        return 5
    fi

    # Step 3: Re-discover templates (the new one should appear)
    log_info "Re-discovering templates after bootstrap..."
    if ! discover_templates; then
        log_error "Template ${template_vmid} created but not discoverable — check storage"
        return 5
    fi

    # Step 4: Verify the new template is in the list
    local found_new=false
    for t in "${DISCOVERED_TEMPLATES[@]}"; do
        if [[ "${t%%:*}" == "${template_vmid}" ]]; then
            found_new=true
            break
        fi
    done

    if [[ "$found_new" != "true" ]]; then
        log_error "Template ${template_vmid} created but not found in discovery"
        return 5
    fi

    log_success "Template bootstrap complete — VM ${template_vmid} ready for cloning"
    return 0
}

# ─── output_bootstrap_instructions ─────────────────────────────────
# Outputs structured NEEDS_TEMPLATE_BOOTSTRAP result for the operating agent.
# The agent reads this and prompts the user for temporary SSH credentials.
# ───────────────────────────────────────────────────────────────────

output_bootstrap_instructions() {
    local os_key="$1"
    local iso_info
    iso_info=$(get_known_iso_info "$os_key")

    if [[ -z "$iso_info" ]]; then
        linus_failure "No known cloud image for OS: ${os_key}" \
            "BOOTSTRAP_AVAILABLE_OS:ubuntu-2404 ubuntu-2204 almalinux-9 debian-12 rocky-9"
        return 9
    fi

    local iso_url filename iso_size description
    IFS='|' read -r iso_url filename _checksum iso_size description <<< "$iso_info"

    log_info "No templates found on node ${PROXMOX_NODE}"
    log_info "Template bootstrap required — operating agent will request SSH credentials"

    linus_result "NEEDS_TEMPLATE_BOOTSTRAP" \
        "BOOTSTRAP_NODE:${PROXMOX_NODE}" \
        "BOOTSTRAP_OS_KEY:${os_key}" \
        "BOOTSTRAP_OS_TYPE:${VM_OS_TYPE}" \
        "BOOTSTRAP_OS_DESCRIPTION:${description}" \
        "BOOTSTRAP_ISO_URL:${iso_url}" \
        "BOOTSTRAP_ISO_FILENAME:${filename}" \
        "BOOTSTRAP_ISO_SIZE:${iso_size}" \
        "BOOTSTRAP_STORAGE:${ISO_STORAGE}" \
        "BOOTSTRAP_TEMPLATE_STORAGE:${TEMPLATE_STORAGE}" \
        "BOOTSTRAP_TEMPLATE_ID:${TEMPLATE_BASE_ID}" \
        "BOOTSTRAP_STEPS:1) Download ISO via Proxmox API (no SSH, ~${iso_size}) → 2) Import disk + create template via SSH (one-time, needs PROXMOX_SSH_PASS) → 3) Clone template + provision as normal" \
        "BOOTSTRAP_INSTRUCTIONS:Set PROXMOX_SSH_PASS (temporary, not stored) and re-run with BOOTSTRAP_TEMPLATE=true to auto-create the template. Or provide SSH credentials to the operating agent."
}

# -----------------------------------------------------------------------------
# Function: clone_template
# -----------------------------------------------------------------------------
# Clones the template VM to create new VM
# Requires: ALLOCATED_VM_ID
# Returns: 0 on success, 5 on failure
# -----------------------------------------------------------------------------

clone_template() {
    log_step "3" "Cloning template VM ${SELECTED_TEMPLATE_ID}"

    local vm_id="$ALLOCATED_VM_ID"
    local vm_name="${VM_NAME:-linus-vm-${vm_id}}"
    local template_id="${SELECTED_TEMPLATE_ID}"

    log_info "Creating VM ${vm_id} from template ${template_id}..."

    # Clone the template using API call
    local clone_result
    clone_result=$(_pvesh post /nodes/${PROXMOX_NODE}/qemu/${template_id}/clone \
        --data-raw "{\"newid\":${vm_id},\"name\":\"${vm_name}\",\"full\":1,\"storage\":\"${PROXMOX_STORAGE}\"}" 2>/dev/null)
    
    if [[ -z "$clone_result" ]]; then
        log_error "Failed to clone template (no response)"
        return 5
    fi

    # Wait for clone task to complete (API returns immediately, clone runs async)
    local max_wait=120
    local elapsed=0
    while [[ $elapsed -lt $max_wait ]]; do
        local lock_status
        lock_status=$(_pvesh get /nodes/${PROXMOX_NODE}/qemu/${vm_id}/status/current 2>/dev/null | \
            python3 -c "import json,sys; print(json.load(sys.stdin).get('data',{}).get('lock','none'))" 2>/dev/null) || lock_status="error"
        
        if [[ "$lock_status" == "none" ]]; then
            log_success "VM ${vm_id} created from template (${elapsed}s)"
            return 0
        fi
        
        sleep 3
        ((elapsed+=3))
        if [[ $((elapsed % 15)) -eq 0 ]]; then
            log_info "Waiting for clone to complete... (${elapsed}s/${max_wait}s)"
        fi
    done

    log_error "Clone task did not complete within ${max_wait}s"
    return 5
}

# -----------------------------------------------------------------------------
# Function: configure_network_for_os_type
# -----------------------------------------------------------------------------
# Applies OS-specific network configuration after clone
# Handles cloud-init quirks for RHEL-based distros
# Returns: 0 on success, non-zero on failure
# -----------------------------------------------------------------------------

configure_network_for_os_type() {
    local vm_id="$ALLOCATED_VM_ID"
    local os_type="${VM_OS_TYPE:-ubuntu}"
    
    log_step "4a" "Configuring network for OS type: ${os_type}"
    # Configure network for OS type - handle cloud-init quirks
    case "$os_type" in
        ubuntu|debian)
            # Ubuntu/Debian - configure static IP (no DHCP on vmbr0)
            log_info "Ubuntu/Debian: Configuring static IP ${ALLOCATED_VM_IP}/24 gw ${GATEWAY_IP}"
            
            # PITFALL 17: Adding dns= to ipconfig0 silently breaks networking
            # The configure_network_for_os_type function should NEVER include dns= in ipconfig0
            # Add a validation check that strips dns= if accidentally included
            local ipconfig0_value="ip=${ALLOCATED_VM_IP}/24,gw=${GATEWAY_IP}"
            
            # If there's already a DNS setting, strip it (this is the guardrail)
            if [[ "$ipconfig0_value" == *"dns="* ]]; then
                log_warn "Detected dns= in ipconfig0 - stripping for Proxmox compatibility"
                ipconfig0_value=$(echo "$ipconfig0_value" | sed 's/,dns=[^,]*//g' | sed 's/dns=[^,]*,//g')
            fi
            
            if ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id}/config \
                --data-raw "{\"agent\":1,\"ipconfig0\":\"${ipconfig0_value}\"}" >/dev/null 2>&1; then
                log_warn "Failed to configure static IP (non-fatal)"
            fi
            ;;
        almalinux|rocky)
            # RHEL-based distros - need explicit cloud-init configuration
            log_info "AlmaLinux/Rocky: Applying custom cloud-init network config"
            
            # Set VM OS type for Libvirt/QEMU agent to recognize as Linux
            if ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id}/config \
                --data-raw "{\"osinfo\":\"AlmaLinux 9\"}" >/dev/null 2>&1 && \
               ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id}/config \
                --data-raw "{\"osinfo\":\"Rocky Linux 9\"}" >/dev/null 2>&1; then
                # Try with generic linux for compatibility
                _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id}/config \
                    --data-raw "{\"osinfo\":\"Linux\"}" >/dev/null 2>&1 || true
            fi
            
            # Enable QEMU guest agent for network discovery
            if ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id}/config \
                --data-raw "{\"agent\":1,\"agent-xpra\":0}" >/dev/null 2>&1; then
                log_warn "Failed to configure QEMU agent (non-fatal)"
                _warn_tag "qemu_agent_failed"
            fi
            
            # Configure network0 with explicit bridge settings
            if ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id}/config \
                --data-raw "{\"net0\":\"model=virtio,bridge=${PROXMOX_BRIDGE},connect=on,network=default\"}" >/dev/null 2>&1; then
                log_warn "Failed to configure net0 bridge (using default: ${PROXMOX_BRIDGE})"
                _warn_tag "net0_bridge_failed"
            fi
            
            # For RHEL-based distros, add cloud-init specific settings
            # Use the detected SSH user (almalinux/rocky), NOT root — the template
            # already has ciuser set correctly and SSH key goes to that user's home
            local _rhel_ssh_user="${VM_SSH_USER:-almalinux}"
            if ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id}/config \
                --data-raw "{\"ciuser\":\"${_rhel_ssh_user}\"}" >/dev/null 2>&1; then
                log_warn "CIUser not explicitly set (non-fatal)"
            fi
            
            # Set up for automatic IP address assignment via DHCP
            # This is critical for RHEL-based distros which sometimes fail to get IPs
            if ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id}/config \
                --data-raw "{\"net0\":\"ipv4=dhcp\"}" >/dev/null 2>&1; then
                log_warn "Failed to enable DHCP on net0 (non-fatal)"
                _warn_tag "dhcp_config_failed"
            fi
            
            log_success "Network configuration applied for AlmaLinux/Rocky"
            ;;
        *)
            # Generic fallback - try both approaches
            log_info "Generic OS type: applying mixed network config"
            if ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id}/config \
                --data-raw "{\"agent\":1,\"net0\":\"bridge=${PROXMOX_BRIDGE}\"}" >/dev/null 2>&1; then
                log_warn "Failed to configure generic network settings (non-fatal)"
            fi
            ;;
    esac
    
    # Verify ipconfig0 took effect (prevents silent config failures)
    local actual_ipconfig
    actual_ipconfig=$(_pvesh get /nodes/${PROXMOX_NODE}/qemu/${vm_id}/config | jq -r '.data.ipconfig0 // "MISSING"')
    if [[ "$actual_ipconfig" != *"${ALLOCATED_VM_IP}"* ]]; then
        log_warn "ipconfig0 mismatch: expected ${ALLOCATED_VM_IP}, got '${actual_ipconfig}'"
        log_warn "Retrying with explicit ipconfig0..."
        _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id}/config \
            --data-raw "{\"ipconfig0\":\"ip=${ALLOCATED_VM_IP}/24,gw=${GATEWAY_IP}\"}" >/dev/null 2>&1 || true
    else
        log_info "ipconfig0 verified: ${actual_ipconfig}"
    fi
    
    return 0
}

# -----------------------------------------------------------------------------
# Function: configure_vm
# -----------------------------------------------------------------------------
# Configures VM resources (CPU, RAM, disk)
# Requires: ALLOCATED_VM_ID
# Returns: 0 on success, 5 on failure
# -----------------------------------------------------------------------------

configure_vm() {
    log_step "4" "Configuring VM resources"

    local vm_id="$ALLOCATED_VM_ID"

    # PITFALL 25: Default kvm64 CPU lacks AVX2/SSE4.2 — breaks numpy/pytorch.
    # Set cpu=host so the VM exposes the full host CPU feature set (AVX2, SSE4.2).
    # Does NOT pin VM to current physical host — migration between compatible CPUs still works.
    log_info "Setting CPU type: host (AVX2/SSE4.2 enabled)..."
    if ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id}/config \
        --data-raw '{"cpu":"host"}' >/dev/null 2>&1; then
        log_warn "Failed to set cpu=host (non-fatal — VM will use kvm64 default)"
        _warn_tag "cpu_host_failed"
    fi

    # Set CPU and RAM
    log_info "Setting CPU: ${VM_CPU} cores, RAM: ${VM_RAM} MB..."
    if ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id}/config \
        --data-raw "{\"cores\":${VM_CPU},\"memory\":${VM_RAM}}" >/dev/null 2>&1; then
        log_error "Failed to set CPU/RAM"
        return 5
    fi

    # PITFALL 8: Disk resize uses /resize, not /config
    # The /config endpoint does NOT accept disk changes - it's wrong and silently ignored
    # configure_vm already correctly uses /resize 
    log_info "Resizing disk to ${VM_DISK}G..."
    if ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id}/resize \
        --data-raw "{\"disk\":\"scsi0\",\"size\":\"${VM_DISK}G\"}" >/dev/null 2>&1; then
        log_error "Failed to resize disk"
        return 5
    fi

    # Configure SSH key access — two-tier: API first, sshpass fallback
    # PITFALL 23: Proxmox API requires URL-encoded sshkeys. Sending raw key
    # content fails with HTTP 400 "invalid urlencoded string". Pre-encode with
    # Python's urllib.parse.quote(key, safe='') before JSON serialization.
    log_info "Configuring SSH key access..."
    local ssh_key_file=""
    for candidate in ~/.ssh/id_ed25519_qemu_test.pub ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub; do
        if [[ -f "$candidate" ]]; then
            ssh_key_file="$candidate"
            break
        fi
    done
    
    if [[ -n "$ssh_key_file" ]]; then
        VM_SSH_KEY="$ssh_key_file"  # Save for output_result
        local ssh_key_content encoded_key
        ssh_key_content=$(cat "$ssh_key_file" | tr -d '\n')
        # URL-encode the key: spaces→%20, +→%2B, /→%2F
        encoded_key=$(python3 -c "import urllib.parse; print(urllib.parse.quote(open('${ssh_key_file}').read().strip(), safe=''))" 2>/dev/null) || encoded_key=""
        
        # Tier 1: API-based injection (works without Proxmox host SSH access)
        if [[ -n "$encoded_key" ]] && _pvesh_set "$vm_id" --sshkeys "$encoded_key" 2>/dev/null; then
            log_info "SSH key injected via API from ${ssh_key_file}"
        # Tier 2: Fall back to sshpass + qm set (requires PROXMOX_SSH_PASS)
        elif [[ -n "${PROXMOX_SSH_PASS:-}" ]]; then
            log_info "API key injection failed, falling back to sshpass..."
            if sshpass -p "${PROXMOX_SSH_PASS}" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
                "root@${PROXMOX_HOST}" "printf '%s' '${ssh_key_content}' > /tmp/linus-key-${vm_id}.pub && qm set ${vm_id} --sshkeys /tmp/linus-key-${vm_id}.pub && rm -f /tmp/linus-key-${vm_id}.pub" 2>/dev/null; then
                log_info "SSH key injected via sshpass from ${ssh_key_file}"
            else
                log_warn "SSH key injection failed (both API and sshpass)"
                log_warn "VM will be reachable by ping but not SSH"
                _warn_tag "ssh_key_injection_failed"
            fi
        else
            log_warn "API key injection failed and PROXMOX_SSH_PASS not set"
            log_warn "VM will be reachable by ping but not SSH"
        fi
    else
        log_warn "No SSH public key found (~/.ssh/id_*.pub) - SSH access will not work"
        log_warn "Generate one with: ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_qemu_test"
    fi

    log_success "VM configured: ${VM_CPU} CPU, ${VM_RAM}MB RAM, ${VM_DISK}GB disk"
    return 0
}

# -----------------------------------------------------------------------------
# Function: regenerate_cloudinit
# -----------------------------------------------------------------------------
# Regenerates cloud-init ISO after all config changes (network, SSH, etc.)
# Must run AFTER configure_network_for_os_type and configure_vm
# Requires: ALLOCATED_VM_ID
# Returns: 0 on success, non-zero on failure
# -----------------------------------------------------------------------------

regenerate_cloudinit() {
    local vm_id="$ALLOCATED_VM_ID"
    log_info "Regenerating cloud-init ISO with final config..."
    # Small delay to ensure all config changes are committed before regeneration
    sleep 2
    # Use direct curl (no Content-Type header) — the cloudinit endpoint
    # doesn't accept a JSON body and rejects POST with that header set
    local auth_header="Authorization: PVEAPIToken=${PROXMOX_USER}!${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}"
    local url="https://${PROXMOX_HOST}:8006/api2/json/nodes/${PROXMOX_NODE}/qemu/${vm_id}/cloudinit"
    local response
    local http_code
    
    # PITFALL 9: Cloud-init Content-Type trap - regenerate_cloudinit must use direct curl without Content-Type header
    # The cloudinit endpoint with any HTTP method rejects requests that include 
    # Content-Type: application/json with no body (returns HTTP 400/501) 
    response=$(curl -sk --fail -X PUT -H "$auth_header" -w "\n%{http_code}" "$url" 2>&1) || {
        http_code="${response##*$'\n'}"
        log_warn "Cloud-init regeneration failed (HTTP ${http_code})"
        _warn_tag "cloudinit_regen_failed"
        return 1
    }
    
    # Verify HTTP status code was 200
    local final_http_code="${response##*$'\n'}"
    if [[ "$final_http_code" != "200" ]]; then
        log_warn "Cloud-init regeneration returned HTTP ${final_http_code} (expected 200)"
        _warn_tag "cloudinit_http_${final_http_code}"
        return 1
    fi
    
    log_info "Cloud-init ISO regenerated for VM ${vm_id}"
    return 0
}

# -----------------------------------------------------------------------------
# Function: start_vm
# -----------------------------------------------------------------------------
# Starts the VM
# Requires: ALLOCATED_VM_ID
# Returns: 0 on success, 5 on failure
# -----------------------------------------------------------------------------

start_vm() {
    log_step "5" "Starting VM"

    local vm_id="$ALLOCATED_VM_ID"

    if ! _pvesh post /nodes/${PROXMOX_NODE}/qemu/${vm_id}/status/start >/dev/null 2>&1; then
        log_error "Failed to start VM"
        return 5
    fi

    log_success "VM started"
    return 0
}

# -----------------------------------------------------------------------------
# Function: wait_for_network
# -----------------------------------------------------------------------------
# Waits for VM to get IP address via QEMU agent
# Requires: ALLOCATED_VM_ID
# Sets: VM_IP
# Returns: 0 on success, 6 on timeout
# -----------------------------------------------------------------------------

wait_for_network() {
    log_step "6" "Waiting for network configuration"

    local vm_id="$ALLOCATED_VM_ID"
    local vm_ip="${ALLOCATED_VM_IP}"
    local max_wait=300  # 5 minutes for cloud-init on first boot
    local elapsed=0

    log_info "Waiting for VM to respond at ${vm_ip}..."

    while [[ $elapsed -lt $max_wait ]]; do
        # Ping the known static IP
        if ping -c 1 -W 2 "$vm_ip" >/dev/null 2>&1; then
            VM_IP="$vm_ip"
            log_success "VM reachable at $vm_ip (${elapsed}s)"
            return 0
        fi

        sleep 5
        ((elapsed+=5))
        if [[ $((elapsed % 30)) -eq 0 ]]; then
            log_info "Waiting for ${vm_ip}... (${elapsed}s/${max_wait}s)"
        fi
    done

    log_error "Timeout waiting for ${vm_ip} to respond (${max_wait}s)"
    return 6
}

# -----------------------------------------------------------------------------
# Function: verify_ssh_ready
# -----------------------------------------------------------------------------
# Verifies SSH is accessible on the VM
# Requires: VM_IP
# Returns: 0 on success, 6 on timeout
# -----------------------------------------------------------------------------

verify_ssh_ready() {
    log_step "7" "Verifying SSH accessibility"

    local vm_ip="$VM_IP"
    local ssh_user="${VM_SSH_USER:-ubuntu}"
    # PITFALL 11: Ubuntu 24.04 first-boot cloud-init timeout
    # network configuration, SSH key injection, and multiple cloud-init modules.
    # On Proxmox VE 8.2.2, this cycle **consistently takes >120s** (observed
    # 120-180s on 2 CPU / 2 GB RAM / 20 GB disk). A 120s SSH timeout is not
    # enough.
    # 
    # The root-resize step alone can take 30-60s on larger disks.
    # 
    # **Fix:** Set verify_ssh_ready() timeout to at least **300 seconds** for
    # Ubuntu 24.04 clones. This accounts for first-boot cloud-init delay,
    # package upgrades, and disk resizing operations.
    local max_wait=300  # Ubuntu 24.04 first-boot cloud-init (resize + config + keys) >120s
    local elapsed=0

    # Find SSH key that was injected
    local ssh_key=""
    for candidate in ~/.ssh/id_ed25519_qemu_test ~/.ssh/id_ed25519 ~/.ssh/id_rsa; do
        if [[ -f "$candidate" ]]; then
            ssh_key="$candidate"
            break
        fi
    done
    
    # Build SSH args as an array (avoids word-splitting issues)
    local ssh_args=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
    if [[ -n "$ssh_key" ]]; then
        ssh_args+=(-i "$ssh_key")
        log_info "Using SSH key: ${ssh_key}"
    fi

    while [[ $elapsed -lt $max_wait ]]; do
        # Capture SSH error for diagnostics (don't suppress stderr)
        local ssh_error
        ssh_error=$(ssh "${ssh_args[@]}" \
               "${ssh_user}@${vm_ip}" \
               "exit 0" 2>&1) && {
            log_success "SSH is ready at ${ssh_user}@${vm_ip}"
            return 0
        }
        # Log first 3 failures for diagnosis
        if [[ $elapsed -le 15 ]]; then
            log_info "SSH attempt failed: ${ssh_error}"
        fi

        sleep 5
        ((elapsed+=5))
        if [[ $((elapsed % 30)) -eq 0 ]]; then
            log_info "Waiting for SSH... (${elapsed}s/${max_wait}s)"
        fi
    done

    # Diagnostic: try SSH with verbose output to capture the actual error
    log_warn "SSH diagnostic — ssh_key=[${ssh_key}]"
    log_warn "SSH diagnostic (verbose):"
    ssh -vv "${ssh_args[@]}" \
        "${ssh_user}@${vm_ip}" \
        "exit 0" 2>&1 | grep -iE 'debug1.*(Offering|Authenticat|Trying|identity|auth|Accepted|denied|closed|Permission|key type)' | tail -5 || true

    log_error "SSH not accessible after ${max_wait}s"
    _warn_tag "ssh_timeout"
    return 6
}

# -----------------------------------------------------------------------------
# Function: verify_vm_capability
# -----------------------------------------------------------------------------
# Verifies the VM is capable of running workloads — not just that SSH works.
# Checks: CPU supports AVX2/SSE4.2 (ML workloads), >2GB free disk, DNS works,
#         Python is installed.
# Requires: VM_IP
# Returns: 0 on success, 8 on capability failure (quality gate)
# -----------------------------------------------------------------------------

verify_vm_capability() {
    log_step "7b" "Verifying VM capability"

    local vm_ip="$VM_IP"
    local ssh_user="${VM_SSH_USER:-ubuntu}"
    
    # Build SSH args (same as verify_ssh_ready)
    local ssh_key=""
    for candidate in ~/.ssh/id_ed25519_qemu_test ~/.ssh/id_ed25519 ~/.ssh/id_rsa; do
        if [[ -f "$candidate" ]]; then
            ssh_key="$candidate"
            break
        fi
    done
    
    local ssh_args=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
    [[ -n "$ssh_key" ]] && ssh_args+=(-i "$ssh_key")

    local all_passed=true
    
    # Check 1: CPU supports AVX2/SSE4.2 (pitfall #25 — kvm64 CPU breaks numpy)
    log_info "Checking CPU features..."
    if ssh "${ssh_args[@]}" "${ssh_user}@${vm_ip}" \
        "grep -q -E 'avx2|sse4_2' /proc/cpuinfo" 2>/dev/null; then
        log_info "  CPU supports AVX2/SSE4.2 ✅"
    else
        log_warn "  CPU MISSING AVX2/SSE4.2 — ML workloads may crash (kvm64 CPU type)"
        log_warn "  Fix: set cpu=host in VM config before start"
        all_passed=false
    fi
    
    # Check 2: >2 GB free disk space
    log_info "Checking disk space..."
    local disk_free
    disk_free=$(ssh "${ssh_args[@]}" "${ssh_user}@${vm_ip}" \
        "df -BG / | awk 'NR==2 {print \$4}' | sed 's/G//'" 2>/dev/null) || disk_free=0
    if [[ "$disk_free" -gt 2 ]]; then
        log_info "  Disk: ${disk_free}GB free ✅"
    else
        log_warn "  Disk: ${disk_free}GB free (<2 GB) — may fail during package install"
        all_passed=false
    fi
    
    # Check 3: DNS works
    log_info "Checking DNS..."
    if ssh "${ssh_args[@]}" "${ssh_user}@${vm_ip}" \
        "getent hosts archive.ubuntu.com >/dev/null 2>&1" 2>/dev/null; then
        log_info "  DNS working ✅"
    else
        log_warn "  DNS not working — apt-get will fail"
        all_passed=false
    fi
    
    # Check 4: Python available
    log_info "Checking Python..."
    if ssh "${ssh_args[@]}" "${ssh_user}@${vm_ip}" \
        "which python3 >/dev/null 2>&1" 2>/dev/null; then
        local py_ver
        py_ver=$(ssh "${ssh_args[@]}" "${ssh_user}@${vm_ip}" \
            "python3 --version 2>&1" 2>/dev/null) || py_ver="unknown"
        log_info "  Python: ${py_ver} ✅"
    else
        log_warn "  Python not installed — bootstrap may fail"
        all_passed=false
    fi
    
    if $all_passed; then
        log_success "VM capability VERIFIED — ready for workload"
        return 0
    else
        # PP-TP3: Capability degraded — use LLM to assess severity
        local cap_summary="VM at ${vm_ip}:\n"
        if ssh "${ssh_args[@]}" "${ssh_user}@${vm_ip}" "grep -q -E 'avx2|sse4_2' /proc/cpuinfo" 2>/dev/null; then
            cap_summary+="- CPU: AVX2/SSE4.2 ✅\n"
        else
            cap_summary+="- CPU: MISSING AVX2/SSE4.2 ❌\n"
        fi
        cap_summary+="- Disk: ${disk_free}GB free\n"
        cap_summary+="- DNS: $(ssh "${ssh_args[@]}" "${ssh_user}@${vm_ip}" "getent hosts archive.ubuntu.com >/dev/null 2>&1 && echo '✅' || echo '❌'" 2>/dev/null)\n"
        cap_summary+="- OS type: ${VM_OS_TYPE}"
        
        local llm_assessment
        llm_assessment=$(_linus_llm_eval "proxmox-bootstrap-judge" "${cap_summary}" 2>/dev/null) || llm_assessment=""
        
        if [[ "$llm_assessment" == "VERIFIED" ]]; then
            log_success "LLM override: VM assessed as VERIFIED despite heuristic warnings"
            return 0
        fi
        
        log_warn "VM capability DEGRADED — some checks failed (see above)"
        _warn_tag "capability_degraded"
        if [[ -n "$llm_assessment" ]]; then
            log_info "LLM assessment: ${llm_assessment}"
        fi
        # Return 8 = quality gate failure (not a hard error, but degraded)
        return 8
    fi
}

# -----------------------------------------------------------------------------
# Function: output_result
# -----------------------------------------------------------------------------
# Outputs structured result for parsing
# Requires: ALLOCATED_VM_ID, VM_IP
# -----------------------------------------------------------------------------

output_result() {
    log_step "8" "Generating output"

    local vm_name="${VM_NAME:-linus-vm-${ALLOCATED_VM_ID}}"
    local ssh_user="${VM_SSH_USER:-ubuntu}"
    local wall_time_s=$(($(date +%s) - PROVISION_START_TIME))

    # Structured output for parsing (LINUS_RESULT contract)
    linus_success \
        "VM_ID:${ALLOCATED_VM_ID}" \
        "VM_IP:${VM_IP}" \
        "VM_USER:${ssh_user}" \
        "VM_SSH_KEY:${VM_SSH_KEY:-}" \
        "VM_NAME:${vm_name}" \
        "VM_CPU:${VM_CPU}" \
        "VM_RAM:${VM_RAM}" \
        "VM_DISK:${VM_DISK}" \
        "VM_NODE:${PROXMOX_NODE}" \
        "VM_OS_TYPE:${VM_OS_TYPE}" \
        "VM_TEMPLATE_ID:${SELECTED_TEMPLATE_ID}" \
        "COST:wall_time_s=${wall_time_s}" \
        "RESOURCE:cpu_cores=${VM_CPU},ram_mb=${VM_RAM},disk_gb=${VM_DISK},host_free_ram_mb=${PROXMOX_FREE_RAM_MB:-0},host_free_disk_gb=${PROXMOX_FREE_DISK_GB:-0}" \
        "WARNINGS:${LINUS_WARNINGS[*]:-none}"
}

# -----------------------------------------------------------------------------
# Function: cleanup_on_error
# -----------------------------------------------------------------------------
# Cleanup function called on error (registered as EXIT trap in main)
# Destroys the VM unless LINUS_KEEP_VM=true (for debugging)
# -----------------------------------------------------------------------------

cleanup_on_error() {
    local exit_code=$?
    if [[ $exit_code -ne 0 && -n "${ALLOCATED_VM_ID:-}" ]]; then
        if [[ "${LINUS_KEEP_VM:-}" == "true" ]]; then
            log_warn "Pipeline failed (exit ${exit_code}) — keeping VM ${ALLOCATED_VM_ID} for debugging (LINUS_KEEP_VM=true)"
            return $exit_code
        fi
        
        log_warn "Pipeline failed (exit ${exit_code}) — destroying VM ${ALLOCATED_VM_ID}"
        
        # PITFALL 13: DELETE requires stopped VM + query params
        # DELETE does not accept form-encoded body data — must pass as query parameters
        # Stop the VM first (required for deletion)
        local stop_result
        stop_result=$(_pvesh post /nodes/${PROXMOX_NODE}/qemu/${ALLOCATED_VM_ID}/status/stop 2>&1) || true
        log_info "VM ${ALLOCATED_VM_ID} stop: ${stop_result:-ok}"
        sleep 3
        
        # Destroy the VM — pass purge params as QUERY string (NOT --data-raw body)
        local destroy_result
        destroy_result=$(_pvesh delete "/nodes/${PROXMOX_NODE}/qemu/${ALLOCATED_VM_ID}?destroy-unreferenced-disks=1&purge=1" 2>&1) || true
        
        # Verify destroy succeeded
        sleep 2
        if _pvesh get /nodes/${PROXMOX_NODE}/qemu/${ALLOCATED_VM_ID}/status/current >/dev/null 2>&1; then
            log_error "VM ${ALLOCATED_VM_ID} may still exist after destroy attempt — manual cleanup may be needed"
        else
            log_success "VM ${ALLOCATED_VM_ID} destroyed"
        fi
    fi
    return $exit_code
}

# -----------------------------------------------------------------------------
# Main Function
# -----------------------------------------------------------------------------

main() {
    log_header "Linus Proxmox VM Provisioning"

    # Set trap for cleanup on error
    trap cleanup_on_error EXIT

    validate_environment || exit $?
    detect_network_config || exit $?
    discover_host_capacity || true  # Non-fatal: capacity warning only, pipeline continues
    allocate_vm_id || exit $?
    clone_template || exit $?
    configure_network_for_os_type || exit $?
    configure_vm || exit $?
    regenerate_cloudinit || exit $?  # Must be after all config, before start
    start_vm || exit $?
    wait_for_network || exit $?
    verify_ssh_ready || exit $?
    verify_vm_capability || true     # Quality gate — warn but don't abort
    output_result

    # Disable cleanup trap on success
    trap - EXIT

    log_success "VM provisioning completed successfully"
    return 0
}

# -----------------------------------------------------------------------------
# Entry Point
# -----------------------------------------------------------------------------

# Only run main if script is executed (not sourced for testing)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
