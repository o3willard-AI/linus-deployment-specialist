#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist — AWS CloudFormation Provisioning
# =============================================================================
# Purpose: Provision EC2 instances via CloudFormation (declarative IaC).
#   Automatic rollback on failure. Stack visible in AWS Console.
#
# Required:
#   AWS_KEY_NAME        - EC2 key pair name
#   AWS_REGION          - AWS region (default: us-east-1)
#   Auth: same 4 methods as aws.sh (static keys, SSO, AssumeRole, instance profile)
#
# Optional: VM_OS_TYPE, VM_CPU, VM_RAM, VM_DISK, VM_NAME, AWS_AMI_ID,
#           AWS_SUBNET_ID, CFN_ROLLBACK, CFN_TIMEOUT
#
# Usage:
#   export AWS_KEY_NAME=linus-test-key
#   ./aws-cfn.sh
#
# Exit Codes:
#   0 — Success    2 — Missing deps    3 — Invalid config
#   4 — CFN failure    5 — Outputs missing    6 — Connection timeout
# =============================================================================

set -euo pipefail; IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CFN_TEMPLATE="$SCRIPT_DIR/templates/ec2-instance.yaml"

source "$SCRIPT_DIR/../lib/paths.sh" || exit 1
source_lib "logging.sh" "validation.sh"

# ═══════════════════════════════════════════════════════════════════
# Credential Auto-Discovery (4 auth methods — same as aws.sh)
# ═══════════════════════════════════════════════════════════════════

_linus_auto_discover_credentials() {
    local secret_dirs=("$HOME/.hermes/secrets" "$HOME/.hermes/env")
    local cred_files=("aws-credentials" "aws" "amazon")
    for dir in "${secret_dirs[@]}"; do
        for fname in "${cred_files[@]}"; do
            local fpath="${dir}/${fname}"
            if [[ -f "$fpath" && -r "$fpath" ]]; then
                while IFS='=' read -r key value; do
                    [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
                    key="${key## }"; key="${key%% }"; value="${value## }"; value="${value%% }"
                    case "$key" in
                        AWS_ACCESS_KEY_ID)    : "${AWS_ACCESS_KEY_ID:=$value}" ;;
                        AWS_SECRET_ACCESS_KEY) : "${AWS_SECRET_ACCESS_KEY:=$value}" ;;
                        AWS_REGION)            : "${AWS_REGION:=$value}" ;;
                        AWS_KEY_NAME)          : "${AWS_KEY_NAME:=$value}" ;;
                        AWS_PROFILE)           : "${AWS_PROFILE:=$value}" ;;
                        AWS_ROLE_ARN)          : "${AWS_ROLE_ARN:=$value}" ;;
                    esac
                done < "$fpath"
            fi
        done
    done
}

_linus_resolve_auth() {
    # 1. Static keys
    if [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
        export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
        log_info "Auth: static IAM keys"; return 0
    fi
    # 2. SSO profile
    if [[ -n "${AWS_PROFILE:-}" ]]; then
        log_info "Auth: SSO profile '${AWS_PROFILE}'"
        if aws sts get-caller-identity --profile "$AWS_PROFILE" >/dev/null 2>&1; then
            log_info "  SSO session valid"; return 0
        fi
        log_warn "SSO session expired. Run: aws sso login --profile ${AWS_PROFILE}"
        return 3
    fi
    # 3. AssumeRole
    if [[ -n "${AWS_ROLE_ARN:-}" ]]; then
        log_info "Auth: assuming role '${AWS_ROLE_ARN}'"
        local role
        role=$(aws sts assume-role --role-arn "$AWS_ROLE_ARN" \
            --role-session-name "linus-cfn-$(date +%s)" \
            --query 'Credentials.{A:AccessKeyId,S:SecretAccessKey,T:SessionToken}' \
            --output json 2>&1) || { log_error "AssumeRole failed: ${role}"; return 3; }
        export AWS_ACCESS_KEY_ID=$(echo "$role" | jq -r '.A')
        export AWS_SECRET_ACCESS_KEY=$(echo "$role" | jq -r '.S')
        export AWS_SESSION_TOKEN=$(echo "$role" | jq -r '.T')
        log_success "  Role assumed"; return 0
    fi
    # 4. Instance Profile (IMDS)
    local token
    token=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 10" 2>/dev/null) || token=""
    if [[ -n "$token" ]]; then
        if curl -s -H "X-aws-ec2-metadata-token: $token" \
            "http://169.254.169.254/latest/dynamic/instance-identity/document" 2>/dev/null | jq -e '.accountId' >/dev/null 2>&1; then
            log_info "Auth: EC2 instance profile"; return 0
        fi
    fi
    log_error "No AWS credentials. Set AWS_ACCESS_KEY_ID+AWS_SECRET_ACCESS_KEY, AWS_PROFILE, AWS_ROLE_ARN, or run on EC2."
    return 3
}

_linus_auto_discover_credentials

# ═══════════════════════════════════════════════════════════════════
# Configuration
# ═══════════════════════════════════════════════════════════════════

readonly AWS_REGION="${AWS_REGION:-us-east-1}"
readonly AWS_KEY_NAME="${AWS_KEY_NAME:-}"
readonly VM_OS_TYPE="${VM_OS_TYPE:-ubuntu}"
readonly VM_CPU="${VM_CPU:-2}"; readonly VM_RAM="${VM_RAM:-2048}"; readonly VM_DISK="${VM_DISK:-20}"
VM_NAME="${VM_NAME:-linus-cfn-$(date +%s)}"
readonly CFN_STACK_NAME="${VM_NAME//[._]/-}"
readonly CFN_ROLLBACK="${CFN_ROLLBACK:-true}"
readonly CFN_TIMEOUT="${CFN_TIMEOUT:-10}"
AWS_AMI_ID="${AWS_AMI_ID:-}"; AWS_SUBNET_ID="${AWS_SUBNET_ID:-}"; AWS_INSTANCE_TYPE="${AWS_INSTANCE_TYPE:-}"
readonly AWS_CLI_PROFILE="${AWS_PROFILE:+--profile $AWS_PROFILE}"

# OS defaults (simplified — CFN uses SSM default or explicit AMI)
declare -A OS_SSH_USERS=([ubuntu]="ubuntu" [almalinux]="ec2-user" [debian]="admin" [rocky]="ec2-user" [amazonlinux]="ec2-user")
VM_SSH_USER="${OS_SSH_USERS[$VM_OS_TYPE]:-ubuntu}"

# Globals (Tier 3 contract)
ALLOCATED_VM_ID=""; VM_IP=""; VM_SSH_KEY=""
SELECTED_INSTANCE_TYPE=""; SELECTED_AMI_ID=""; SELECTED_ARCHITECTURE="x86_64"
LINUS_WARNINGS=(); readonly PROVISION_START_TIME=$(date +%s)
LAUNCH_TIME_S=0; SSH_READY_TIME_S=0
_warn_tag() { LINUS_WARNINGS+=("$1"); }

# Instance type mapping
declare -A INSTANCE_TYPES=(
    ["1-1024"]="t3.micro" ["2-2048"]="t3.small" ["2-4096"]="t3.medium"
    ["2-8192"]="t3.large" ["4-8192"]="t3.large" ["4-16384"]="t3.xlarge"
    ["8-16384"]="t3.xlarge" ["8-32768"]="t3.2xlarge"
)

# ═══════════════════════════════════════════════════════════════════
# Functions
# ═══════════════════════════════════════════════════════════════════

select_instance_type() {
    [[ -n "$AWS_INSTANCE_TYPE" ]] && { SELECTED_INSTANCE_TYPE="$AWS_INSTANCE_TYPE"; return 0; }
    SELECTED_INSTANCE_TYPE="${INSTANCE_TYPES[${VM_CPU}-${VM_RAM}]:-t3.medium}"
}

cleanup() {
    local ec=$?
    if [[ $ec -ne 0 && -n "${ALLOCATED_VM_ID:-}" && "${LINUS_KEEP_VM:-}" != "true" ]]; then
        log_warn "Deleting CloudFormation stack ${CFN_STACK_NAME}"
        aws cloudformation delete-stack --stack-name "$CFN_STACK_NAME" \
            --region "$AWS_REGION" $AWS_CLI_PROFILE >/dev/null 2>&1 || true
    fi
    return $ec
}

validate_environment() {
    log_step "1" "Validating environment (CloudFormation)"
    check_dependencies aws jq || return 2
    [[ ! -f "$CFN_TEMPLATE" ]] && { log_error "Template not found: $CFN_TEMPLATE"; return 2; }
    _linus_resolve_auth || return $?
    [[ -z "$AWS_KEY_NAME" ]] && { log_error "AWS_KEY_NAME is required"; return 3; }
    aws ec2 describe-key-pairs --key-names "$AWS_KEY_NAME" --region "$AWS_REGION" $AWS_CLI_PROFILE >/dev/null 2>&1 \
        || { log_error "Key pair not found: ${AWS_KEY_NAME}"; return 3; }
    log_success "Environment validated (CFN template: $(basename "$CFN_TEMPLATE"))"
}

resolve_ami_cfn() {
    local os="${VM_OS_TYPE:-ubuntu}"
    case "$os" in
        ubuntu|ubuntu2404)
            local ami
            ami=$(aws ec2 describe-images --region "$AWS_REGION" --owners 099720109477 \
                --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
                    "Name=state,Values=available" "Name=architecture,Values=${SELECTED_ARCHITECTURE}" \
                --query "Images | sort_by(@, &CreationDate) | [-1].ImageId" --output text $AWS_CLI_PROFILE 2>/dev/null) || ami=""
            if [[ -n "$ami" && "$ami" != "None" ]]; then SELECTED_AMI_ID="$ami"; echo "$ami"; return 0; fi
            ;;
    esac
    _warn_tag "ami_fallback_default"
    log_warn "Using default AMI (Amazon Linux 2023)"
    echo "ami-0fbcf351e82d18381"  # Default from template
}

create_stack() {
    log_step "2" "Creating CloudFormation stack"
    select_instance_type
    log_info "Stack: ${CFN_STACK_NAME} | Type: ${SELECTED_INSTANCE_TYPE} | Region: ${AWS_REGION}"

    local params=(
        "ParameterKey=InstanceType,ParameterValue=${SELECTED_INSTANCE_TYPE}"
        "ParameterKey=KeyName,ParameterValue=${AWS_KEY_NAME}"
        "ParameterKey=VolumeSize,ParameterValue=${VM_DISK}"
        "ParameterKey=InstanceName,ParameterValue=${VM_NAME}"
    )
    [[ -n "$AWS_AMI_ID" ]] && params+=("ParameterKey=AmiId,ParameterValue=${AWS_AMI_ID}") \
        || params+=("ParameterKey=AmiId,ParameterValue=$(resolve_ami_cfn)")
    [[ -n "$AWS_SUBNET_ID" ]] && params+=("ParameterKey=SubnetId,ParameterValue=${AWS_SUBNET_ID}")

    aws cloudformation validate-template --template-body "file://${CFN_TEMPLATE}" \
        --region "$AWS_REGION" $AWS_CLI_PROFILE >/dev/null 2>&1 \
        || { log_error "CFN template validation failed"; return 4; }

    local disable_rollback=""
    [[ "$CFN_ROLLBACK" != "true" ]] && disable_rollback="--disable-rollback"

    local result
    result=$(aws cloudformation create-stack --stack-name "$CFN_STACK_NAME" \
        --template-body "file://${CFN_TEMPLATE}" --parameters "${params[@]}" \
        --capabilities CAPABILITY_IAM $disable_rollback \
        --timeout-in-minutes "$CFN_TIMEOUT" --region "$AWS_REGION" \
        $AWS_CLI_PROFILE --query "StackId" --output text 2>&1) \
        || { log_error "Create stack failed: ${result}"; return 4; }
    log_success "Stack: ${result}"
}

wait_for_stack() {
    log_step "3" "Waiting for stack"
    log_info "Waiting for CREATE_COMPLETE (timeout: ${CFN_TIMEOUT}m)..."
    aws cloudformation wait stack-create-complete --stack-name "$CFN_STACK_NAME" \
        --region "$AWS_REGION" $AWS_CLI_PROFILE 2>&1 || {
        local events
        events=$(aws cloudformation describe-stack-events --stack-name "$CFN_STACK_NAME" \
            --region "$AWS_REGION" $AWS_CLI_PROFILE \
            --query "StackEvents[?ResourceStatus==\`CREATE_FAILED\`].[ResourceType,ResourceStatusReason]" \
            --output text 2>/dev/null || echo "unknown")
        log_error "Stack failed: ${events}"; return 4
    }
    LAUNCH_TIME_S=$(($(date +%s) - PROVISION_START_TIME))
    log_success "Stack ready (${LAUNCH_TIME_S}s)"
}

get_stack_outputs() {
    log_step "4" "Retrieving outputs"
    local out
    out=$(aws cloudformation describe-stacks --stack-name "$CFN_STACK_NAME" \
        --region "$AWS_REGION" $AWS_CLI_PROFILE --query "Stacks[0].Outputs" --output json 2>&1) \
        || { log_error "Outputs failed: ${out}"; return 5; }
    ALLOCATED_VM_ID=$(echo "$out" | jq -r '.[] | select(.OutputKey=="InstanceId") | .OutputValue')
    VM_IP=$(echo "$out" | jq -r '.[] | select(.OutputKey=="PublicIp") | .OutputValue')
    [[ -z "$ALLOCATED_VM_ID" || "$ALLOCATED_VM_ID" == "null" ]] && { log_error "No InstanceId in outputs"; return 5; }
    [[ -z "$VM_IP" || "$VM_IP" == "null" ]] && { VM_IP=$(echo "$out" | jq -r '.[] | select(.OutputKey=="PrivateIp") | .OutputValue'); _warn_tag "no_public_ip"; }
    log_success "Instance: ${ALLOCATED_VM_ID} @ ${VM_IP}"
}

discover_ssh_key() {
    [[ -n "${AWS_SSH_KEY_PATH:-}" && -f "$AWS_SSH_KEY_PATH" ]] && { VM_SSH_KEY="$AWS_SSH_KEY_PATH"; return 0; }
    local p="$HOME/.ssh/${AWS_KEY_NAME}.pem"
    [[ -f "$p" ]] && { VM_SSH_KEY="$p"; return 0; }
    for c in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa"; do
        [[ -f "$c" ]] && { VM_SSH_KEY="$c"; _warn_tag "ssh_key_fallback"; return 0; }
    done
    log_error "No key found"; return 6
}

wait_for_ssh() {
    log_step "5" "Waiting for connectivity"
    discover_ssh_key || return $?
    local args=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no
                -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30 -i "$VM_SSH_KEY")
    local max=180 elapsed=0
    while [[ $elapsed -lt $max ]]; do
        if ssh "${args[@]}" "${VM_SSH_USER}@${VM_IP}" "echo ok" 2>/dev/null; then
            SSH_READY_TIME_S=$(($(date +%s) - PROVISION_START_TIME))
            log_success "Connected (${SSH_READY_TIME_S}s)"; return 0
        fi
        sleep 5; elapsed=$((elapsed + 5))
    done
    _warn_tag "ssh_timeout"; return 6
}

output_result() {
    log_step "6" "Output"
    local wt=$(($(date +%s) - PROVISION_START_TIME))
    linus_success \
        "VM_ID:${ALLOCATED_VM_ID}" "VM_IP:${VM_IP}" "VM_USER:${VM_SSH_USER}" \
        "VM_SSH_KEY:${VM_SSH_KEY}" "VM_NAME:${VM_NAME}" \
        "VM_CPU:${VM_CPU}" "VM_RAM:${VM_RAM}" "VM_DISK:${VM_DISK}" \
        "VM_REGION:${AWS_REGION}" "VM_OS_TYPE:${VM_OS_TYPE}" \
        "VM_INSTANCE_TYPE:${SELECTED_INSTANCE_TYPE}" \
        "VM_ARCHITECTURE:${SELECTED_ARCHITECTURE}" \
        "VM_PROVIDER:cloudformation" "VM_STACK_NAME:${CFN_STACK_NAME}" \
        "COST:wall_time_s=${wt},launch_time_s=${LAUNCH_TIME_S},ssh_ready_time_s=${SSH_READY_TIME_S}" \
        "RESOURCE:cpu_cores=${VM_CPU},ram_mb=${VM_RAM},disk_gb=${VM_DISK},instance_type=${SELECTED_INSTANCE_TYPE}" \
        "WARNINGS:${LINUS_WARNINGS[*]:-none}"
}

main() {
    log_header "Linus AWS CloudFormation Provisioning"
    trap cleanup EXIT
    validate_environment || exit $?
    create_stack || exit $?
    wait_for_stack || exit $?
    get_stack_outputs || exit $?
    wait_for_ssh || exit $?
    output_result
    trap - EXIT
    log_success "CloudFormation provisioning completed"
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
