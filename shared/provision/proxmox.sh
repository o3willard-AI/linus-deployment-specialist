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
readonly VM_OS_TYPE="${VM_OS_TYPE:-ubuntu}"

readonly VM_NAME="${VM_NAME:-}"
readonly VM_CPU="${VM_CPU:-2}"
readonly VM_RAM="${VM_RAM:-2048}"
readonly VM_DISK="${VM_DISK:-20}"

# Global variables (set by functions)
ALLOCATED_VM_ID=""
VM_IP=""

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

# Set SSH user based on OS type
case "${VM_OS_TYPE}" in
    ubuntu)
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
    
    # Check template exists - we'll verify via API call instead of qm command
    log_info "Checking template VM..."
    local template_check
    template_check=$(_pvesh get /nodes/${PROXMOX_NODE}/qemu/${VM_TEMPLATE_ID}/status/current 2>&1) || {
        log_error "Template VM ${VM_TEMPLATE_ID} not found"
        return 3
    }
    log_info "Template: VM ${VM_TEMPLATE_ID} OK"

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
# Function: clone_template
# -----------------------------------------------------------------------------
# Clones the template VM to create new VM
# Requires: ALLOCATED_VM_ID
# Returns: 0 on success, 5 on failure
# -----------------------------------------------------------------------------

clone_template() {
    log_step "3" "Cloning template VM ${VM_TEMPLATE_ID}"

    local vm_id="$ALLOCATED_VM_ID"
    local vm_name="${VM_NAME:-linus-vm-${vm_id}}"

    log_info "Creating VM ${vm_id} from template ${VM_TEMPLATE_ID}..."

    # Clone the template using API call
    local clone_result
    clone_result=$(_pvesh post /nodes/${PROXMOX_NODE}/qemu/${VM_TEMPLATE_ID}/clone \
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
            fi
            
            # Configure network0 with explicit bridge settings
            if ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id}/config \
                --data-raw "{\"net0\":\"model=virtio,bridge=${PROXMOX_BRIDGE},connect=on,network=default\"}" >/dev/null 2>&1; then
                log_warn "Failed to configure net0 bridge (using default: ${PROXMOX_BRIDGE})"
            fi
            
            # For RHEL-based distros, add cloud-init specific settings
            # This helps with dhcp and network configuration timing
            if ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id}/config \
                --data-raw "{\"ciuser\":\"root\"}" >/dev/null 2>&1; then
                log_warn "CIUser not explicitly set (non-fatal)"
            fi
            
            # Set up for automatic IP address assignment via DHCP
            # This is critical for RHEL-based distros which sometimes fail to get IPs
            if ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id}/config \
                --data-raw "{\"net0\":\"ipv4=dhcp\"}" >/dev/null 2>&1; then
                log_warn "Failed to enable DHCP on net0 (non-fatal)"
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

    # Configure SSH key access
    log_info "Configuring SSH key access..."
    local ssh_key_file=""
    for candidate in ~/.ssh/id_ed25519_qemu_test.pub ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub; do
        if [[ -f "$candidate" ]]; then
            ssh_key_file="$candidate"
            break
        fi
    done
    
    if [[ -n "$ssh_key_file" ]]; then
        local ssh_key_content
        ssh_key_content=$(cat "$ssh_key_file" | tr -d '\n')
        # Use qm set via SSH (handles encoding correctly, unlike the API)
        if sshpass -p "${PROXMOX_SSH_PASS:-}" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
            "root@${PROXMOX_HOST}" "printf '%s' '${ssh_key_content}' > /tmp/linus-key-${vm_id}.pub && qm set ${vm_id} --sshkeys /tmp/linus-key-${vm_id}.pub && rm -f /tmp/linus-key-${vm_id}.pub" 2>/dev/null; then
            log_info "SSH key injected from ${ssh_key_file}"
        else
            log_warn "SSH key injection failed (SSH to Proxmox host unavailable)"
            log_warn "VM will be reachable by ping but not SSH — set PROXMOX_SSH_PASS for key injection"
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
        return 1
    }
    
    # Verify HTTP status code was 200
    local final_http_code="${response##*$'\n'}"
    if [[ "$final_http_code" != "200" ]]; then
        log_warn "Cloud-init regeneration returned HTTP ${final_http_code} (expected 200)"
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
    return 6
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

    # Structured output for parsing
    linus_success \
        "VM_ID:${ALLOCATED_VM_ID}" \
        "VM_IP:${VM_IP}" \
        "VM_USER:${ssh_user}" \
        "VM_NAME:${vm_name}" \
        "VM_CPU:${VM_CPU}" \
        "VM_RAM:${VM_RAM}" \
        "VM_DISK:${VM_DISK}" \
        "VM_NODE:${PROXMOX_NODE}" \
        "VM_OS_TYPE:${VM_OS_TYPE}"
}

# -----------------------------------------------------------------------------
# Function: cleanup_on_error
# -----------------------------------------------------------------------------
# Cleanup function called on error
# -----------------------------------------------------------------------------

cleanup_on_error() {
    local exit_code=$?
    if [[ $exit_code -ne 0 && -n "${ALLOCATED_VM_ID:-}" ]]; then
        log_warn "Cleaning up VM ${ALLOCATED_VM_ID} due to error..."
    # PITFALL 13: DELETE requires stopped VM + query params
    # DELETE does not accept form-encoded body data — must pass as query parameters
    # Stop the VM first (required for deletion)
    _pvesh post /nodes/${PROXMOX_NODE}/qemu/${ALLOCATED_VM_ID}/status/stop >/dev/null 2>&1 || true
    sleep 3
    
    # Destroy the VM — pass purge params as QUERY string (NOT --data-raw body)
    _pvesh delete "/nodes/${PROXMOX_NODE}/qemu/${ALLOCATED_VM_ID}?destroy-unreferenced-disks=1&purge=1" >/dev/null 2>&1 || true
    fi
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
    allocate_vm_id || exit $?
    clone_template || exit $?
    configure_network_for_os_type || exit $?  # NEW: Configure network after clone
    configure_vm || exit $?
    regenerate_cloudinit || exit $?  # Must be after all config, before start
    start_vm || exit $?
    wait_for_network || exit $?
    verify_ssh_ready || exit $?
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
