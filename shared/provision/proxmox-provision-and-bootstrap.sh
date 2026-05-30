#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist — Proxmox VM Provision + Bootstrap Driver
# =============================================================================
# Purpose: Single entry point that runs provision + bootstrap end-to-end,
#   handling env var coupling, timing, and structured output parsing.
#
# Usage:
#   export PROXMOX_HOST=192.168.101.155
#   export VM_OS_TYPE=ubuntu
#   export BOOTSTRAP_PACKAGES="golang-go git make"
#   export BOOTSTRAP_REPOS="o3willard-AI/hermes-agent"
#   proxmox-provision-and-bootstrap.sh
#
# Exit Codes:
#   0 — Full pipeline succeeded
#   1 — General error
#   2 — Missing dependencies
#   3 — Invalid configuration
#   4 — Provisioning failed
#   5 — Bootstrap failed
#   6 — VM capability degraded (quality gate)
#
# Output:
#   LINUS_RESULT:SUCCESS LINUS_VM_ID:... LINUS_VM_IP:... LINUS_COST:wall_time_s=...
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

export PYTHONUNBUFFERED=1

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source shared libraries
source "$SCRIPT_DIR/../lib/paths.sh" || exit 1
source_lib "logging.sh"

# ─── Configuration ────────────────────────────────────────────────

readonly PIPELINE_START_TIME=$(date +%s)

# Provisioning settings (with defaults)
PROXMOX_HOST="${PROXMOX_HOST:-192.168.101.155}"
PROXMOX_NODE="${PROXMOX_NODE:-moxy}"
VM_OS_TYPE="${VM_OS_TYPE:-ubuntu}"
VM_TEMPLATE_ID="${VM_TEMPLATE_ID:-9000}"
VM_TEMPLATE_FALLBACKS="${VM_TEMPLATE_FALLBACKS:-}"
VM_CPU="${VM_CPU:-2}"
VM_RAM="${VM_RAM:-2048}"
VM_DISK="${VM_DISK:-20}"
VM_NAME="${VM_NAME:-}"

# Bootstrap settings
BOOTSTRAP_PACKAGES="${BOOTSTRAP_PACKAGES:-}"
BOOTSTRAP_REPOS="${BOOTSTRAP_REPOS:-}"

# Paths
readonly PROVISION_SCRIPT="$SCRIPT_DIR/proxmox.sh"
readonly BOOTSTRAP_SCRIPT="$SCRIPT_DIR/../bootstrap/bootstrap-vm.sh"

# ─── Validation ────────────────────────────────────────────────────

validate_driver_env() {
    if [[ ! -f "$PROVISION_SCRIPT" ]]; then
        log_error "Provision script not found: $PROVISION_SCRIPT"
        exit 2
    fi
    if [[ ! -f "$BOOTSTRAP_SCRIPT" ]]; then
        log_error "Bootstrap script not found: $BOOTSTRAP_SCRIPT"
        exit 2
    fi
    log_success "Driver environment validated"
}

# ─── Parse LINUS_RESULT ────────────────────────────────────────────

# Extracts key=value pairs from LINUS_RESULT:SUCCESS output.
# Sets: PARSED_VM_ID, PARSED_VM_IP, PARSED_VM_USER, PARSED_VM_SSH_KEY,
#       PARSED_VM_NAME, PARSED_VM_OS_TYPE, PARSED_VM_TEMPLATE_ID
parse_linus_result() {
    local output="$1"
    local key val

    while IFS=':' read -r key val; do
        # Strip "LINUS_" prefix from the key (e.g., LINUS_VM_ID → VM_ID)
        key="${key#LINUS_}"
        # Skip the "RESULT:SUCCESS" / "RESULT:FAILURE" header line
        [[ "$key" == "RESULT" ]] && continue
        case "$key" in
            VM_ID)           PARSED_VM_ID="$val" ;;
            VM_IP)           PARSED_VM_IP="$val" ;;
            VM_USER)         PARSED_VM_USER="$val" ;;
            VM_SSH_KEY)      PARSED_VM_SSH_KEY="$val" ;;
            VM_NAME)         PARSED_VM_NAME="$val" ;;
            VM_OS_TYPE)      PARSED_VM_OS_TYPE="$val" ;;
            VM_TEMPLATE_ID)  PARSED_VM_TEMPLATE_ID="$val" ;;
            COST)            PARSED_COST="$val" ;;
        esac
    done < <(echo "$output" | grep -E '^LINUS_' || true)
}

# ─── Phase 1: Provision ────────────────────────────────────────────

run_provision() {
    log_header "Phase 1: VM Provisioning"

    log_info "Provisioning ${VM_OS_TYPE} VM on ${PROXMOX_HOST} (node ${PROXMOX_NODE})..."

    local provision_output provision_ec=0

    # Run provision with all required env vars
    provision_output=$(PROXMOX_HOST="$PROXMOX_HOST" \
        PROXMOX_NODE="$PROXMOX_NODE" \
        VM_OS_TYPE="$VM_OS_TYPE" \
        VM_TEMPLATE_ID="$VM_TEMPLATE_ID" \
        VM_TEMPLATE_FALLBACKS="$VM_TEMPLATE_FALLBACKS" \
        VM_CPU="$VM_CPU" \
        VM_RAM="$VM_RAM" \
        VM_DISK="$VM_DISK" \
        VM_NAME="$VM_NAME" \
        stdbuf -oL -eL bash "$PROVISION_SCRIPT" 2>&1) || provision_ec=$?

    echo "$provision_output"

    if [[ $provision_ec -ne 0 ]]; then
        log_error "Provisioning failed with exit code $provision_ec"
        return 4
    fi

    # Parse LINUS_RESULT output
    parse_linus_result "$provision_output"

    if [[ -z "${PARSED_VM_ID:-}" ]]; then
        log_error "Failed to parse VM_ID from provision output"
        return 4
    fi
    if [[ -z "${PARSED_VM_IP:-}" ]]; then
        log_error "Failed to parse VM_IP from provision output"
        return 4
    fi

    log_success "Provisioned: VM ${PARSED_VM_ID} @ ${PARSED_VM_IP} (${PARSED_VM_USER:-ubuntu})"
}

# ─── Phase 2: Bootstrap ────────────────────────────────────────────

run_bootstrap() {
    log_header "Phase 2: VM Bootstrap"

    if [[ -z "${PARSED_VM_IP:-}" ]]; then
        log_error "No VM IP — provisioning must succeed first"
        return 5
    fi

    local vm_user="${PARSED_VM_USER:-ubuntu}"
    local os_type="${PARSED_VM_OS_TYPE:-${VM_OS_TYPE}}"
    
    # bootstrap-vm.sh auto-detects package manager (apt/dnf) via SSH
    local bootstrap_script="$BOOTSTRAP_SCRIPT"
    
    log_info "Bootstrapping VM at ${vm_user}@${PARSED_VM_IP} (OS: ${os_type})..."

    # Skip bootstrap if no packages or repos specified
    if [[ -z "$BOOTSTRAP_PACKAGES" && -z "$BOOTSTRAP_REPOS" ]]; then
        log_info "No bootstrap packages or repos specified — skipping"
        return 0
    fi

    local bootstrap_output bootstrap_ec=0

    bootstrap_output=$(VM_IP="$PARSED_VM_IP" \
        VM_USER="$vm_user" \
        BOOTSTRAP_PACKAGES="$BOOTSTRAP_PACKAGES" \
        BOOTSTRAP_REPOS="$BOOTSTRAP_REPOS" \
        stdbuf -oL -eL bash "$bootstrap_script" 2>&1) || bootstrap_ec=$?

    echo "$bootstrap_output"

    if [[ $bootstrap_ec -ne 0 ]]; then
        log_error "Bootstrap failed with exit code $bootstrap_ec"
        return 5
    fi

    log_success "Bootstrap complete"
}

# ─── Phase 3: Summary ──────────────────────────────────────────────

print_summary() {
    local end_time wall_time total_seconds
    end_time=$(date +%s)
    total_seconds=$(( end_time - PIPELINE_START_TIME ))
    wall_time=$(python3 -c "
total = ${total_seconds}
m = total // 60
s = total % 60
print(f'{m}m {s}s')
" 2>/dev/null || echo "${total_seconds}s")

    log_header "Pipeline Summary"
    log_info "  Wall time:     ${wall_time}"
    log_info "  VM ID:         ${PARSED_VM_ID:-N/A}"
    log_info "  VM IP:         ${PARSED_VM_IP:-N/A}"
    log_info "  SSH:           ${PARSED_VM_USER:-ubuntu}@${PARSED_VM_IP:-N/A}"
    log_info "  OS type:       ${PARSED_VM_OS_TYPE:-${VM_OS_TYPE}}"
    log_info "  Template:      ${PARSED_VM_TEMPLATE_ID:-N/A}"
    log_info "  Spec:          ${VM_CPU} CPU / ${VM_RAM}MB RAM / ${VM_DISK}GB disk"

    if [[ -n "${BOOTSTRAP_PACKAGES:-}" ]]; then
        log_info "  Packages:      ${BOOTSTRAP_PACKAGES}"
    fi
    if [[ -n "${BOOTSTRAP_REPOS:-}" ]]; then
        log_info "  Repos:         ${BOOTSTRAP_REPOS}"
    fi

    # Output structured result for downstream consumers
    echo ""
    echo "LINUS_RESULT:SUCCESS"
    echo "LINUS_VM_ID:${PARSED_VM_ID}"
    echo "LINUS_VM_IP:${PARSED_VM_IP}"
    echo "LINUS_VM_USER:${PARSED_VM_USER:-ubuntu}"
    echo "LINUS_VM_SSH_KEY:${PARSED_VM_SSH_KEY:-}"
    echo "LINUS_VM_NAME:${PARSED_VM_NAME:-}"
    echo "LINUS_VM_OS_TYPE:${PARSED_VM_OS_TYPE:-${VM_OS_TYPE}}"
    echo "LINUS_VM_TEMPLATE_ID:${PARSED_VM_TEMPLATE_ID:-}"
    echo "LINUS_COST:wall_time_s=${total_seconds}"
    if [[ -n "${PARSED_COST:-}" ]]; then
        echo "LINUS_PROVISION_COST:${PARSED_COST}"
    fi
}

# ─── Main ──────────────────────────────────────────────────────────

main() {
    log_header "Linus Proxmox VM — Provision + Bootstrap Pipeline"

    validate_driver_env

    # Phase 1: Provision
    if ! run_provision; then
        log_error "Pipeline failed at provisioning phase"
        exit 4
    fi

    # Phase 2: Bootstrap
    if ! run_bootstrap; then
        log_error "Pipeline failed at bootstrap phase"
        exit 5
    fi

    # Phase 3: Summary
    print_summary
    log_success "Pipeline completed successfully"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
