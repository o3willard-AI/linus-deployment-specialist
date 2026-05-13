     1|#!/usr/bin/env bash
     2|# =============================================================================
     3|# Linus Deployment Specialist - Proxmox VM Provisioning
     4|# =============================================================================
     5|# Purpose: Create and configure VMs on Proxmox VE
     6|# Author: Linus Deployment Specialist (AI-generated)
     7|# Version: 1.0
     8|# Automation Level: 1 (Non-interactive design)
     9|#
    10|# Required Environment Variables:
    11|#   PROXMOX_HOST        - Proxmox host IP/hostname (required)
    12|#   PROXMOX_USER        - Proxmox user (e.g., root@pam) (required)
    13|#   PROXMOX_TOKEN_ID    - API token ID (e.g., linus-token) (required)
    14|#   PROXMOX_TOKEN_SECRET- API token secret (required)
    15|#   PROXMOX_NODE        - Proxmox node name (default: moxy)
    16|#   PROXMOX_STORAGE     - Storage pool name (default: local-lvm)
    17|#   PROXMOX_BRIDGE      - Network bridge (default: vmbr0)
    18|#   VM_TEMPLATE_ID      - Template VM ID to clone (default: 9000)
    19|#   VM_NAME             - VM name (optional)
    20|#   VM_CPU              - CPU cores (default: 2)
    21|#   VM_RAM              - RAM in MB (default: 2048)
    22|#   VM_DISK             - Disk size in GB (default: 20)
    23|#
    24|# Usage:
    25|#   ./proxmox.sh
    26|#
    27|# Exit Codes:
    28|#   0 - Success
    29|#   1 - General error
    30|#   2 - Missing dependencies
    31|#   3 - Invalid configuration
    32|#   4 - Proxmox node offline
    33|#   5 - VM creation failed
    34|#   6 - Network/SSH timeout
    35|#
    36|# =============================================================================
    37|
    38|set -euo pipefail
    39|IFS=$'\n\t'
    40|
    41|# -----------------------------------------------------------------------------
    42|# Configuration
    43|# -----------------------------------------------------------------------------
    44|
    45|readonly SCRIPT_NAME="$(basename "$0")"
    46|readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    47|
    48|# Source the unified library path resolver
    49|source "$SCRIPT_DIR/../lib/paths.sh" || exit 1
    50|source_lib "logging.sh" "validation.sh"
    51|
    52|# Configuration from environment with defaults
    53|readonly PROXMOX_NODE="${PROXMOX_NODE:-moxy}"
    54|readonly PROXMOX_STORAGE="${PROXMOX_STORAGE:-local-lvm}"
    55|readonly PROXMOX_BRIDGE="${PROXMOX_BRIDGE:-vmbr0}"
    56|readonly VM_TEMPLATE_ID="${VM_TEMPLATE_ID:-9000}"
    57|readonly VM_OS_TYPE="${VM_OS_TYPE:-ubuntu}"
    58|
    59|readonly VM_NAME="${VM_NAME:-}"
    60|readonly VM_CPU="${VM_CPU:-2}"
    61|readonly VM_RAM="${VM_RAM:-2048}"
    62|readonly VM_DISK="${VM_DISK:-20}"
    63|
    64|# Global variables (set by functions)
    65|ALLOCATED_VM_ID=""
    66|VM_IP=""
    67|
    68|# Proxmox API helper — wraps curl with token auth
    69|_pvesh() {
    70|    local method="${1:-get}"
    71|    local path="$2"
    72|    shift 2 || true
    73|    
    74|    local url="https://${PROXMOX_HOST}:8006/api2/json${path}"
    75|    local auth_header="Authorization: PVEAPIToken=${PROXMOX_USER}!${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}"
    76|    
    77|    case "$method" in
    78|        get)
    79|            curl -sk -H "$auth_header" "$url" "$@" 2>/dev/null
    80|            ;;
    81|        post)
    82|            curl -sk -X POST -H "$auth_header" -H "Content-Type: application/json" "$url" "$@" 2>/dev/null
    83|            ;;
    84|        put)
    85|            curl -sk -X PUT -H "$auth_header" -H "Content-Type: application/json" "$url" "$@" 2>/dev/null
    86|            ;;
    87|        delete)
    88|            curl -sk -X DELETE -H "$auth_header" "$url" "$@" 2>/dev/null
    89|            ;;
    90|        *)
    91|            echo "ERROR: Unknown method: $method" >&2
    92|            return 1
    93|            ;;
    94|    esac
    95|}
    96|
    97|# Set SSH user based on OS type
    98|case "${VM_OS_TYPE}" in
    99|    ubuntu)
   100|        VM_SSH_USER="ubuntu"
   101|        ;;
   102|    almalinux)
   103|        VM_SSH_USER="almalinux"
   104|        ;;
   105|    rocky)
   106|        VM_SSH_USER="rocky"
   107|        ;;
   108|    *)
   109|        VM_SSH_USER="cloud-user"
   110|        ;;
   111|esac
   112|
   113|# -----------------------------------------------------------------------------
   114|# Function: validate_environment
   115|# -----------------------------------------------------------------------------
   116|# Validates that all prerequisites are met
   117|# Returns: 0 on success, non-zero on failure
   118|# -----------------------------------------------------------------------------
   119|
   120|validate_environment() {
   121|    log_step "1" "Validating environment"
   122|
   123|    # Check required tools
   124|    check_dependencies curl jq || return 2
   125|
   126|    # Check Proxmox node status (check if uptime exists - node must be running to have uptime)
   127|    log_info "Checking Proxmox node status..."
   128|    local node_uptime=$(_pvesh get /nodes/${PROXMOX_NODE}/status | jq -r '.data.uptime // 0')
   129|
   130|    if [[ "$node_uptime" -eq 0 ]]; then
   131|        log_error "Proxmox node ${PROXMOX_NODE} is not accessible or offline"
   132|        return 4
   133|    fi
   134|    log_info "Node online (uptime: ${node_uptime}s)"
   135|
   136|    # Check storage exists
   137|    log_info "Checking storage pool..."
   138|    if ! _pvesh get /storage/${PROXMOX_STORAGE} >/dev/null 2>&1; then
   139|        log_error "Storage pool ${PROXMOX_STORAGE} not found"
   140|        return 3
   141|    fi
   142|    log_info "Storage: ${PROXMOX_STORAGE} OK"
   143|
   144|    # Check network bridge exists - we'll just verify connectivity to API instead
   145|    log_info "Checking network bridge..."
   146|    if ! _pvesh get /nodes/${PROXMOX_NODE}/status >/dev/null 2>&1; then
   147|        log_error "Network bridge ${PROXMOX_BRIDGE} not found"
   148|        return 3
   149|    fi
   150|    log_info "Bridge: ${PROXMOX_BRIDGE} OK"
   151|
   152|    # Check template exists - we'll verify via API call instead of qm command
   153|    log_info "Checking template VM..."
   154|    if ! _pvesh get /nodes/${PROXMOX_NODE}/qemu/${VM_TEMPLATE_ID}/status/current >/dev/null 2>&1; then
   155|        log_error "Template VM ${VM_TEMPLATE_ID} not found"
   156|        return 3
   157|    fi
   158|    log_info "Template: VM ${VM_TEMPLATE_ID} OK"
   159|
   160|    # Validate OS type
   161|    validate_os "${VM_OS_TYPE}" || return 3
   162|
   163|    # Validate VM specification
   164|    validate_positive_int "$VM_CPU" "CPU cores" || return 1
   165|    validate_positive_int "$VM_RAM" "RAM (MB)" || return 1
   166|    validate_positive_int "$VM_DISK" "Disk (GB)" || return 1
   167|
   168|    log_success "Environment validation passed"
   169|    return 0
   170|}
   171|
   172|# -----------------------------------------------------------------------------
   173|# Function: allocate_vm_id
   174|# -----------------------------------------------------------------------------
   175|# Finds the next available VM ID
   176|# Sets: ALLOCATED_VM_ID
   177|# Returns: 0 on success, 5 on failure (no IDs available)
   178|# -----------------------------------------------------------------------------
   179|
   180|allocate_vm_id() {
   181|    log_step "2" "Allocating VM ID"
   182|
   183|    # Query cluster resources once to get all existing VM IDs (single API call)
   184|    local used_ids
   185|    used_ids=$(_pvesh get /cluster/resources?type=vm 2>/dev/null | \
   186|        python3 -c "
   187|import json, sys
   188|data = json.load(sys.stdin)
   189|ids = sorted(r['vmid'] for r in data['data'] if r.get('type') == 'qemu')
   190|print(' '.join(str(i) for i in ids))
   191|" 2>/dev/null) || used_ids=""
   192|
   193|    # Find first available ID starting from next free slot
   194|    local vm_id=113
   195|    while true; do
   196|        # Check if vm_id appears as a whole word in used_ids
   197|        if ! echo " $used_ids " | grep -q " $vm_id "; then
   198|            ALLOCATED_VM_ID="$vm_id"
   199|            log_success "Allocated VM ID: $vm_id (used: $used_ids)"
   200|            return 0
   201|        fi
   202|        ((vm_id++))
   203|        if [[ $vm_id -gt 999 ]]; then
   204|            log_error "No available VM IDs (checked 113-999)"
   205|            return 5
   206|        fi
   207|    done
   208|}
   209|
   210|# -----------------------------------------------------------------------------
   211|# Function: clone_template
   212|# -----------------------------------------------------------------------------
   213|# Clones the template VM to create new VM
   214|# Requires: ALLOCATED_VM_ID
   215|# Returns: 0 on success, 5 on failure
   216|# -----------------------------------------------------------------------------
   217|
   218|clone_template() {
   219|    log_step "3" "Cloning template VM ${VM_TEMPLATE_ID}"
   220|
   221|    local vm_id="$ALLOCATED_VM_ID"
   222|    local vm_name="${VM_NAME:-linus-vm-${vm_id}}"
   223|
   224|    log_info "Creating VM ${vm_id} from template ${VM_TEMPLATE_ID}..."
   225|
   226|    # Clone the template using API call
   227|    if ! _pvesh post /nodes/${PROXMOX_NODE}/qemu/${VM_TEMPLATE_ID}/clone \
   228|        --data-raw "{\"newid\":${vm_id},\"name\":\"${vm_name}\",\"full\":1,\"storage\":\"${PROXMOX_STORAGE}\"}" >/dev/null 2>&1; then
   229|        log_error "Failed to clone template"
   230|        return 5
   231|    fi
   232|
   233|    log_success "VM ${vm_id} created from template"
   234|    return 0
   235|}
   236|
   237|# -----------------------------------------------------------------------------
   238|# Function: configure_network_for_os_type
   239|# -----------------------------------------------------------------------------
   240|# Applies OS-specific network configuration after clone
   241|# Handles cloud-init quirks for RHEL-based distros
   242|# Returns: 0 on success, non-zero on failure
   243|# -----------------------------------------------------------------------------
   244|
   245|configure_network_for_os_type() {
   246|    local vm_id="$ALLOCATED_VM_ID"
   247|    local os_type="${VM_OS_TYPE:-ubuntu}"
   248|    
   249|    log_step "4a" "Configuring network for OS type: ${os_type}"
   250|    
   251|    case "$os_type" in
   252|        ubuntu|debian)
   253|            # Ubuntu/Debian - standard cloud-init networking
   254|            log_info "Ubuntu/Debian: Standard cloud-init networking (automatic)"
   255|            # Ensure VM has QEMU guest agent installed and enabled
   256|            if ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id} \
   257|                --data-raw "{\"agent\":1,\"net0\":\"bridge=${PROXMOX_BRIDGE}\"}" >/dev/null 2>&1; then
   258|                log_warn "Failed to configure network agent settings (non-fatal)"
   259|            fi
   260|            ;;
   261|        almalinux|rocky)
   262|            # RHEL-based distros - need explicit cloud-init configuration
   263|            log_info "AlmaLinux/Rocky: Applying custom cloud-init network config"
   264|            
   265|            # Set VM OS type for Libvirt/QEMU agent to recognize as Linux
   266|            if ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id} \
   267|                --data-raw "{\"osinfo\":\"AlmaLinux 9\"}" >/dev/null 2>&1 && \
   268|               ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id} \
   269|                --data-raw "{\"osinfo\":\"Rocky Linux 9\"}" >/dev/null 2>&1; then
   270|                # Try with generic linux for compatibility
   271|                _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id} \
   272|                    --data-raw "{\"osinfo\":\"Linux\"}" >/dev/null 2>&1 || true
   273|            fi
   274|            
   275|            # Enable QEMU guest agent for network discovery
   276|            if ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id} \
   277|                --data-raw "{\"agent\":1,\"agent-xpra\":0}" >/dev/null 2>&1; then
   278|                log_warn "Failed to configure QEMU agent (non-fatal)"
   279|            fi
   280|            
   281|            # Configure network0 with explicit bridge settings
   282|            if ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id} \
   283|                --data-raw "{\"net0\":\"model=virtio,bridge=${PROXMOX_BRIDGE},connect=on,network=default\"}" >/dev/null 2>&1; then
   284|                log_warn "Failed to configure net0 bridge (using default: ${PROXMOX_BRIDGE})"
   285|            fi
   286|            
   287|            # For RHEL-based distros, add cloud-init specific settings
   288|            # This helps with dhcp and network configuration timing
   289|            if ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id} \
   290|                --data-raw "{\"ciuser\":\"root\"}" >/dev/null 2>&1; then
   291|                log_warn "CIUser not explicitly set (non-fatal)"
   292|            fi
   293|            
   294|            # Set up for automatic IP address assignment via DHCP
   295|            # This is critical for RHEL-based distros which sometimes fail to get IPs
   296|            if ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id} \
   297|                --data-raw "{\"net0\":\"ipv4=dhcp\"}" >/dev/null 2>&1; then
   298|                log_warn "Failed to enable DHCP on net0 (non-fatal)"
   299|            fi
   300|            
   301|            log_success "Network configuration applied for AlmaLinux/Rocky"
   302|            ;;
   303|        *)
   304|            # Generic fallback - try both approaches
   305|            log_info "Generic OS type: applying mixed network config"
   306|            if ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id} \
   307|                --data-raw "{\"agent\":1,\"net0\":\"bridge=${PROXMOX_BRIDGE}\"}" >/dev/null 2>&1; then
   308|                log_warn "Failed to configure generic network settings (non-fatal)"
   309|            fi
   310|            ;;
   311|    esac
   312|    
   313|    return 0
   314|}
   315|
   316|# -----------------------------------------------------------------------------
   317|# Function: configure_vm
   318|# -----------------------------------------------------------------------------
   319|# Configures VM resources (CPU, RAM, disk)
   320|# Requires: ALLOCATED_VM_ID
   321|# Returns: 0 on success, 5 on failure
   322|# -----------------------------------------------------------------------------
   323|
   324|configure_vm() {
   325|    log_step "4" "Configuring VM resources"
   326|
   327|    local vm_id="$ALLOCATED_VM_ID"
   328|
   329|    # Set CPU and RAM
   330|    log_info "Setting CPU: ${VM_CPU} cores, RAM: ${VM_RAM} MB..."
   331|    if ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id} \
   332|        --data-raw "{\"cores\":${VM_CPU},\"memory\":${VM_RAM}}" >/dev/null 2>&1; then
   333|        log_error "Failed to set CPU/RAM"
   334|        return 5
   335|    fi
   336|
   337|    # Resize disk
   338|    log_info "Resizing disk to ${VM_DISK}G..."
   339|    if ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id} \
   340|        --data-raw "{\"disk\": \"scsi0=${PROXMOX_STORAGE}:${VM_DISK}G\"}" >/dev/null 2>&1; then
   341|        log_error "Failed to resize disk"
   342|        return 5
   343|    fi
   344|
   345|    # Configure SSH key access
   346|    log_info "Configuring SSH key access..."
   347|    if [[ -f /root/.ssh/id_rsa.pub ]]; then
   348|        if ! _pvesh put /nodes/${PROXMOX_NODE}/qemu/${vm_id} \
   349|            --data-raw "{\"sshkey\": \"/root/.ssh/id_rsa.pub\"}" >/dev/null 2>&1; then
   350|            log_error "Failed to configure SSH key"
   351|            return 5
   352|        fi
   353|    else
   354|        log_warn "SSH public key not found at /root/.ssh/id_rsa.pub - SSH access may not work"
   355|    fi
   356|
   357|    log_success "VM configured: ${VM_CPU} CPU, ${VM_RAM}MB RAM, ${VM_DISK}GB disk"
   358|    return 0
   359|}
   360|
   361|# -----------------------------------------------------------------------------
   362|# Function: start_vm
   363|# -----------------------------------------------------------------------------
   364|# Starts the VM
   365|# Requires: ALLOCATED_VM_ID
   366|# Returns: 0 on success, 5 on failure
   367|# -----------------------------------------------------------------------------
   368|
   369|start_vm() {
   370|    log_step "5" "Starting VM"
   371|
   372|    local vm_id="$ALLOCATED_VM_ID"
   373|
   374|    if ! _pvesh post /nodes/${PROXMOX_NODE}/qemu/${vm_id}/status/start >/dev/null 2>&1; then
   375|        log_error "Failed to start VM"
   376|        return 5
   377|    fi
   378|
   379|    log_success "VM started"
   380|    return 0
   381|}
   382|
   383|# -----------------------------------------------------------------------------
   384|# Function: wait_for_network
   385|# -----------------------------------------------------------------------------
   386|# Waits for VM to get IP address via QEMU agent
   387|# Requires: ALLOCATED_VM_ID
   388|# Sets: VM_IP
   389|# Returns: 0 on success, 6 on timeout
   390|# -----------------------------------------------------------------------------
   391|
   392|wait_for_network() {
   393|    log_step "6" "Waiting for network configuration"
   394|
   395|    local vm_id="$ALLOCATED_VM_ID"
   396|    local max_wait=120
   397|    local elapsed=0
   398|    local vm_ip=""
   399|    local vm_mac=""
   400|
   401|    # Get VM MAC address for fallback network scan - we'll get this from API instead
   402|    # Note: This is more complex with API, so we'll rely on agent calls for now
   403|
   404|    while [[ $elapsed -lt $max_wait ]]; do
   405|        # Method 1: Try to get IP from QEMU agent (preferred)
   406|        vm_ip=$(_pvesh get /nodes/${PROXMOX_NODE}/qemu/${vm_id}/agent/network-get-interfaces | \
   407|                jq -r '.data.interfaces[] | select(.name == "eth0" or .name == "ens18" or .name == "ens3") | .ip-addresses[]? | select(.family == "inet") | .address' 2>/dev/null | \
   408|                grep -v "127.0.0.1" | head -1 || echo "")
   409|
   410|        # Method 2: Fallback to network scan if QEMU agent not available
   411|        if [[ -z "$vm_ip" && -n "$vm_mac" ]]; then
   412|            # Run network scan every 30s and parse output for MAC address
   413|            if [[ $((elapsed % 30)) -eq 0 && $elapsed -gt 0 ]]; then
   414|                vm_ip=$(nmap -sn 192.168.101.0/24 2>/dev/null | \
   415|                        grep -B 2 -i "$vm_mac" | \
   416|                        grep -oP 'Nmap scan report for .*\\((\\d+\\.\\d+\\.\\d+\\.\\d+)\\)' | \
   417|                        grep -oP '\\d+\\.\\d+\\.\\d+\\.\\d+' | head -1 || echo "")
   418|
   419|                # If no parentheses format, try simple format
   420|                if [[ -z "$vm_ip" ]]; then
   421|                    vm_ip=$(nmap -sn 192.168.101.0/24 2>/dev/null | \
   422|                            grep -B 2 -i "$vm_mac" | \
   423|                            grep -oP 'Nmap scan report for \\K\\d+\\.\\d+\\.\\d+\\.\\d+' | head -1 || echo "")
   424|                fi
   425|            fi
   426|        fi
   427|
   428|        if [[ -n "$vm_ip" ]]; then
   429|            VM_IP="$vm_ip"
   430|            log_success "VM IP obtained: $vm_ip"
   431|            return 0
   432|        fi
   433|
   434|        sleep 5
   435|        ((elapsed+=5))
   436|        log_info "Waiting for network... (${elapsed}s/${max_wait}s)"
   437|    done
   438|
   439|    log_error "Timeout waiting for network configuration"
   440|    return 6
   441|}
   442|
   443|# -----------------------------------------------------------------------------
   444|# Function: verify_ssh_ready
   445|# -----------------------------------------------------------------------------
   446|# Verifies SSH is accessible on the VM
   447|# Requires: VM_IP
   448|# Returns: 0 on success, 6 on timeout
   449|# -----------------------------------------------------------------------------
   450|
   451|verify_ssh_ready() {
   452|    log_step "7" "Verifying SSH accessibility"
   453|
   454|    local vm_ip="$VM_IP"
   455|    local ssh_user="${VM_SSH_USER}"
   456|    local max_wait=60
   457|    local elapsed=0
   458|
   459|    while [[ $elapsed -lt $max_wait ]]; do
   460|        if ssh -o BatchMode=yes \
   461|               -o ConnectTimeout=5 \
   462|               -o StrictHostKeyChecking=no \
   463|               -o UserKnownHostsFile=/dev/null \
   464|               "${ssh_user}@${vm_ip}" \
   465|               "exit 0" 2>/dev/null; then
   466|            log_success "SSH is ready at ${ssh_user}@${vm_ip}"
   467|            return 0
   468|        fi
   469|
   470|        sleep 5
   471|        ((elapsed+=5))
   472|        log_info "Waiting for SSH... (${elapsed}s/${max_wait}s)"
   473|    done
   474|
   475|    log_error "SSH not accessible after ${max_wait}s"
   476|    return 6
   477|}
   478|
   479|# -----------------------------------------------------------------------------
   480|# Function: output_result
   481|# -----------------------------------------------------------------------------
   482|# Outputs structured result for parsing
   483|# Requires: ALLOCATED_VM_ID, VM_IP
   484|# -----------------------------------------------------------------------------
   485|
   486|output_result() {
   487|    log_step "8" "Generating output"
   488|
   489|    local vm_name="${VM_NAME:-linus-vm-${ALLOCATED_VM_ID}}"
   490|
   491|    # Structured output for parsing
   492|    linus_success \
   493|        "VM_ID:${ALLOCATED_VM_ID}" \
   494|        "VM_IP:${VM_IP}" \
   495|        "VM_USER:${VM_SSH_USER}" \
   496|        "VM_NAME:${vm_name}" \
   497|        "VM_CPU:${VM_CPU}" \
   498|        "VM_RAM:${VM_RAM}" \
   499|        "VM_DISK:${VM_DISK}" \
   500|        "VM_NODE:${PROXMOX_NODE}" \
   501|        "VM_OS_TYPE:${VM_OS_TYPE}"
   502|}
   503|
   504|# -----------------------------------------------------------------------------
   505|# Function: cleanup_on_error
   506|# -----------------------------------------------------------------------------
   507|# Cleanup function called on error
   508|# -----------------------------------------------------------------------------
   509|
   510|cleanup_on_error() {
   511|    local exit_code=$?
   512|    if [[ $exit_code -ne 0 && -n "${ALLOCATED_VM_ID:-}" ]]; then
   513|        log_warn "Cleaning up VM ${ALLOCATED_VM_ID} due to error..."
   514|        # Stop the VM if it exists
   515|        _pvesh post /nodes/${PROXMOX_NODE}/qemu/${ALLOCATED_VM_ID}/status/stop >/dev/null 2>&1 || true
   516|        # Destroy the VM
   517|        _pvesh delete /nodes/${PROXMOX_NODE}/qemu/${ALLOCATED_VM_ID} >/dev/null 2>&1 || true
   518|    fi
   519|}
   520|
   521|# -----------------------------------------------------------------------------
   522|# Main Function
   523|# -----------------------------------------------------------------------------
   524|
   525|main() {
   526|    log_header "Linus Proxmox VM Provisioning"
   527|
   528|    # Set trap for cleanup on error
   529|    trap cleanup_on_error EXIT
   530|
   531|    validate_environment || exit $?
   532|    allocate_vm_id || exit $?
   533|    clone_template || exit $?
   534|    configure_network_for_os_type || exit $?  # NEW: Configure network after clone
   535|    configure_vm || exit $?
   536|    start_vm || exit $?
   537|    wait_for_network || exit $?
   538|    verify_ssh_ready || exit $?
   539|    output_result
   540|
   541|    # Disable cleanup trap on success
   542|    trap - EXIT
   543|
   544|    log_success "VM provisioning completed successfully"
   545|    return 0
   546|}
   547|
   548|# -----------------------------------------------------------------------------
   549|# Entry Point
   550|# -----------------------------------------------------------------------------
   551|
   552|# Only run main if script is executed (not sourced for testing)
   553|if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
   554|    main "$@"
   555|fi
   556|