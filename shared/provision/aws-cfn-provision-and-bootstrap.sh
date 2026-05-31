#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist — AWS CloudFormation Provision + Bootstrap Driver
# =============================================================================
# Single entry point: provision via CloudFormation → bootstrap → summary
#
# Usage:
#   export AWS_REGION=us-east-1
#   export AWS_KEY_NAME=linus-test-key
#   export BOOTSTRAP_PACKAGES="golang-go git make"
#   aws-cfn-provision-and-bootstrap.sh
#
# Exit Codes: passthrough from provision/bootstrap phases
# =============================================================================

set -euo pipefail; IFS=$'\n\t'; export PYTHONUNBUFFERED=1

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/paths.sh" || exit 1
source_lib "logging.sh"

readonly PIPELINE_START_TIME=$(date +%s)
readonly PROVISION_SCRIPT="$SCRIPT_DIR/aws-cfn.sh"
readonly BOOTSTRAP_SCRIPT="$SCRIPT_DIR/../bootstrap/bootstrap-vm.sh"

# Config
AWS_REGION="${AWS_REGION:-us-east-1}"; AWS_KEY_NAME="${AWS_KEY_NAME:-}"
VM_OS_TYPE="${VM_OS_TYPE:-ubuntu}"; VM_CPU="${VM_CPU:-2}"; VM_RAM="${VM_RAM:-2048}"; VM_DISK="${VM_DISK:-20}"
VM_NAME="${VM_NAME:-}"; AWS_AMI_ID="${AWS_AMI_ID:-}"; AWS_SUBNET_ID="${AWS_SUBNET_ID:-}"
CFN_ROLLBACK="${CFN_ROLLBACK:-true}"; CFN_TIMEOUT="${CFN_TIMEOUT:-10}"
BOOTSTRAP_PACKAGES="${BOOTSTRAP_PACKAGES:-}"; BOOTSTRAP_REPOS="${BOOTSTRAP_REPOS:-}"

validate_driver_env() {
    [[ ! -f "$PROVISION_SCRIPT" ]] && { log_error "Provision script not found: $PROVISION_SCRIPT"; exit 2; }
    [[ ! -f "$BOOTSTRAP_SCRIPT" ]] && { log_error "Bootstrap script not found: $BOOTSTRAP_SCRIPT"; exit 2; }
    [[ -z "$AWS_KEY_NAME" ]] && { log_error "AWS_KEY_NAME is required"; exit 3; }
    log_success "Driver validated"
}

parse_linus_result() {
    local output="$1" key val
    while IFS=':' read -r key val; do
        key="${key#LINUS_}"
        [[ "$key" == "RESULT" ]] && continue
        case "$key" in
            VM_ID) PARSED_VM_ID="$val" ;; VM_IP) PARSED_VM_IP="$val" ;;
            VM_USER) PARSED_VM_USER="$val" ;; VM_SSH_KEY) PARSED_VM_SSH_KEY="$val" ;;
            VM_NAME) PARSED_VM_NAME="$val" ;; VM_OS_TYPE) PARSED_VM_OS_TYPE="$val" ;;
            VM_STACK_NAME) PARSED_STACK_NAME="$val" ;;
            COST) PARSED_COST="$val" ;;
        esac
    done < <(echo "$output" | grep -E '^LINUS_' || true)
}

run_provision() {
    log_header "Phase 1: CloudFormation Provisioning"
    log_info "Provisioning ${VM_OS_TYPE} via CloudFormation in ${AWS_REGION}..."
    local out ec=0
    out=$(AWS_REGION="$AWS_REGION" AWS_KEY_NAME="$AWS_KEY_NAME" VM_OS_TYPE="$VM_OS_TYPE" \
        VM_CPU="$VM_CPU" VM_RAM="$VM_RAM" VM_DISK="$VM_DISK" VM_NAME="$VM_NAME" \
        AWS_AMI_ID="$AWS_AMI_ID" AWS_SUBNET_ID="$AWS_SUBNET_ID" \
        CFN_ROLLBACK="$CFN_ROLLBACK" CFN_TIMEOUT="$CFN_TIMEOUT" \
        stdbuf -oL -eL bash "$PROVISION_SCRIPT" 2>&1) || ec=$?
    echo "$out"
    [[ $ec -ne 0 ]] && { log_error "Provision failed (exit $ec)"; return 4; }
    parse_linus_result "$out"
    [[ -z "${PARSED_VM_ID:-}" ]] && { log_error "No VM_ID in output"; return 4; }
    log_success "Provisioned: ${PARSED_VM_ID} @ ${PARSED_VM_IP:-N/A}"
}

run_bootstrap() {
    log_header "Phase 2: Bootstrap"
    [[ -z "${PARSED_VM_IP:-}" ]] && { log_error "No VM IP"; return 5; }
    [[ -z "$BOOTSTRAP_PACKAGES" && -z "$BOOTSTRAP_REPOS" ]] && { log_info "Skipping bootstrap (no packages/repos)"; return 0; }
    local out ec=0
    out=$(VM_IP="$PARSED_VM_IP" VM_USER="${PARSED_VM_USER:-ubuntu}" \
        BOOTSTRAP_PACKAGES="$BOOTSTRAP_PACKAGES" BOOTSTRAP_REPOS="$BOOTSTRAP_REPOS" \
        stdbuf -oL -eL bash "$BOOTSTRAP_SCRIPT" 2>&1) || ec=$?
    echo "$out"
    [[ $ec -ne 0 ]] && { log_error "Bootstrap failed (exit $ec)"; return 5; }
    log_success "Bootstrap complete"
}

print_summary() {
    local ts=$(($(date +%s) - PIPELINE_START_TIME))
    local wt=$(python3 -c "print(f'{ts//60}m {ts%60}s')" 2>/dev/null || echo "${ts}s")
    log_header "Pipeline Summary"
    log_info "  Wall time:      ${wt}"
    log_info "  Instance:       ${PARSED_VM_ID:-N/A} @ ${PARSED_VM_IP:-N/A}"
    log_info "  Stack:          ${PARSED_STACK_NAME:-N/A}"
    log_info "  OS:             ${PARSED_VM_OS_TYPE:-${VM_OS_TYPE}}"
    echo ""
    echo "LINUS_RESULT:SUCCESS"
    echo "LINUS_VM_ID:${PARSED_VM_ID}"
    echo "LINUS_VM_IP:${PARSED_VM_IP}"
    echo "LINUS_VM_USER:${PARSED_VM_USER:-ubuntu}"
    echo "LINUS_VM_STACK_NAME:${PARSED_STACK_NAME:-}"
    echo "LINUS_COST:wall_time_s=${ts}"
}

main() {
    log_header "Linus AWS CloudFormation — Provision + Bootstrap"
    validate_driver_env
    run_provision || exit 4
    run_bootstrap || exit 5
    print_summary
    log_success "Pipeline complete"
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
