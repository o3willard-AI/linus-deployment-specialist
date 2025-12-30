#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist - AWS EC2 VM Provisioning
# =============================================================================
# Purpose: Create and configure EC2 instances on AWS
# Author: Linus Deployment Specialist (AI-generated)
# Version: 1.0
# Automation Level: 1 (Non-interactive design)
#
# Required Environment Variables:
#   AWS_REGION          - AWS region (default: us-east-1)
#   AWS_INSTANCE_TYPE   - EC2 instance type (default: t3.micro)
#   AWS_AMI_ID          - Ubuntu AMI ID (default: auto-detect latest Ubuntu 24.04)
#   AWS_KEY_NAME        - SSH key pair name (required)
#   AWS_SUBNET_ID       - VPC subnet ID (optional, uses default VPC if not set)
#   AWS_SECURITY_GROUP  - Security group ID (optional, creates one if not set)
#   VM_NAME             - Instance name tag (optional)
#   VM_CPU              - vCPUs (used to select instance type, default: 2)
#   VM_RAM              - RAM in MB (used to select instance type, default: 2048)
#   VM_DISK             - Root volume size in GB (default: 20)
#
# Usage:
#   export AWS_REGION=us-west-2
#   export AWS_KEY_NAME=my-keypair
#   ./aws.sh
#
# Exit Codes:
#   0 - Success
#   1 - General error
#   2 - Missing dependencies
#   3 - Invalid configuration
#   4 - AWS API error
#   5 - Instance creation failed
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

# Source libraries
source "${SCRIPT_DIR}/../lib/logging.sh"
source "${SCRIPT_DIR}/../lib/validation.sh"

# Configuration from environment with defaults
readonly AWS_REGION="${AWS_REGION:-us-east-1}"
readonly AWS_INSTANCE_TYPE="${AWS_INSTANCE_TYPE:-}"
readonly AWS_AMI_ID="${AWS_AMI_ID:-}"
readonly AWS_KEY_NAME="${AWS_KEY_NAME:-}"
readonly AWS_SUBNET_ID="${AWS_SUBNET_ID:-}"
readonly AWS_SECURITY_GROUP="${AWS_SECURITY_GROUP:-}"

readonly VM_NAME="${VM_NAME:-linus-vm-$(date +%s)}"
readonly VM_CPU="${VM_CPU:-2}"
readonly VM_RAM="${VM_RAM:-2048}"
readonly VM_DISK="${VM_DISK:-20}"

# Instance type mapping based on CPU/RAM requirements
declare -A INSTANCE_TYPES=(
    ["1-1024"]="t3.micro"
    ["1-2048"]="t3.small"
    ["2-2048"]="t3.small"
    ["2-4096"]="t3.medium"
    ["2-8192"]="t3.large"
    ["4-8192"]="t3.large"
    ["4-16384"]="t3.xlarge"
    ["8-16384"]="t3.xlarge"
    ["8-32768"]="t3.2xlarge"
)

# Global variables
INSTANCE_ID=""
INSTANCE_IP=""
INSTANCE_USER="ubuntu"
CREATED_SECURITY_GROUP=""

# -----------------------------------------------------------------------------
# Function: cleanup
# -----------------------------------------------------------------------------

cleanup() {
    local exit_code=$?

    if [[ $exit_code -ne 0 && -n "$INSTANCE_ID" ]]; then
        log_warn "Cleaning up failed instance: ${INSTANCE_ID}"
        aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION" >/dev/null 2>&1 || true
    fi

    if [[ -n "$CREATED_SECURITY_GROUP" ]]; then
        log_debug "Leaving security group for reuse: ${CREATED_SECURITY_GROUP}"
    fi
}

trap cleanup EXIT

# -----------------------------------------------------------------------------
# Function: validate_environment
# -----------------------------------------------------------------------------

validate_environment() {
    log_step "1" "Validating environment"

    # Check AWS CLI is installed
    check_dependencies aws jq || return 2

    # Check AWS credentials are configured
    if ! aws sts get-caller-identity --region "$AWS_REGION" >/dev/null 2>&1; then
        log_error "AWS credentials not configured or invalid"
        return 3
    fi

    # Validate AWS_KEY_NAME is provided
    if [[ -z "$AWS_KEY_NAME" ]]; then
        log_error "AWS_KEY_NAME is required (SSH key pair name)"
        return 3
    fi

    # Verify key pair exists
    if ! aws ec2 describe-key-pairs --key-names "$AWS_KEY_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
        log_error "Key pair not found: ${AWS_KEY_NAME}"
        log_info "Create it with: aws ec2 create-key-pair --key-name ${AWS_KEY_NAME}"
        return 3
    fi

    log_success "Environment validation passed"
    return 0
}

# -----------------------------------------------------------------------------
# Function: select_instance_type
# -----------------------------------------------------------------------------

select_instance_type() {
    if [[ -n "$AWS_INSTANCE_TYPE" ]]; then
        echo "$AWS_INSTANCE_TYPE"
        return 0
    fi

    local key="${VM_CPU}-${VM_RAM}"

    if [[ -n "${INSTANCE_TYPES[$key]:-}" ]]; then
        echo "${INSTANCE_TYPES[$key]}"
        return 0
    fi

    # Default fallback
    log_warn "No exact match for ${VM_CPU} CPU / ${VM_RAM}MB RAM, using t3.medium" >&2
    echo "t3.medium"
}

# -----------------------------------------------------------------------------
# Function: get_ubuntu_ami
# -----------------------------------------------------------------------------

get_ubuntu_ami() {
    if [[ -n "$AWS_AMI_ID" ]]; then
        echo "$AWS_AMI_ID"
        return 0
    fi

    log_info "Finding latest Ubuntu 24.04 AMI..." >&2

    local ami_id
    ami_id=$(aws ec2 describe-images \
        --region "$AWS_REGION" \
        --owners 099720109477 \
        --filters \
            "Name=name,Values=ubuntu/images/hvm-ssd*/ubuntu-noble-24.04-amd64-server-*" \
            "Name=state,Values=available" \
        --query "Images | sort_by(@, &CreationDate) | [-1].ImageId" \
        --output text)

    if [[ -z "$ami_id" || "$ami_id" == "None" ]]; then
        log_error "Could not find Ubuntu 24.04 AMI" >&2
        return 5
    fi

    echo "$ami_id"
}

# -----------------------------------------------------------------------------
# Function: get_or_create_security_group
# -----------------------------------------------------------------------------

get_or_create_security_group() {
    if [[ -n "$AWS_SECURITY_GROUP" ]]; then
        echo "$AWS_SECURITY_GROUP"
        return 0
    fi

    local sg_name="linus-default-sg"
    local sg_desc="Linus Deployment Specialist default security group"

    # Check if security group exists
    local sg_id
    sg_id=$(aws ec2 describe-security-groups \
        --region "$AWS_REGION" \
        --filters "Name=group-name,Values=${sg_name}" \
        --query "SecurityGroups[0].GroupId" \
        --output text 2>/dev/null || echo "")

    if [[ -n "$sg_id" && "$sg_id" != "None" ]]; then
        log_info "Using existing security group: ${sg_id}" >&2
        echo "$sg_id"
        return 0
    fi

    log_info "Creating security group: ${sg_name}" >&2

    # Get default VPC ID
    local vpc_id
    vpc_id=$(aws ec2 describe-vpcs \
        --region "$AWS_REGION" \
        --filters "Name=is-default,Values=true" \
        --query "Vpcs[0].VpcId" \
        --output text)

    if [[ -z "$vpc_id" || "$vpc_id" == "None" ]]; then
        log_error "No default VPC found" >&2
        return 4
    fi

    # Create security group
    sg_id=$(aws ec2 create-security-group \
        --region "$AWS_REGION" \
        --group-name "$sg_name" \
        --description "$sg_desc" \
        --vpc-id "$vpc_id" \
        --query "GroupId" \
        --output text)

    CREATED_SECURITY_GROUP="$sg_id"

    # Add SSH rule
    aws ec2 authorize-security-group-ingress \
        --region "$AWS_REGION" \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 22 \
        --cidr 0.0.0.0/0 >/dev/null

    log_success "Created security group: ${sg_id}" >&2
    echo "$sg_id"
}

# -----------------------------------------------------------------------------
# Function: create_instance
# -----------------------------------------------------------------------------

create_instance() {
    log_step "2" "Creating EC2 instance"

    local instance_type
    instance_type=$(select_instance_type)
    log_info "Instance type: ${instance_type}"

    local ami_id
    ami_id=$(get_ubuntu_ami)
    log_info "AMI: ${ami_id}"

    local sg_id
    sg_id=$(get_or_create_security_group)
    log_info "Security group: ${sg_id}"

    # Build create-instances command
    local cmd=(
        aws ec2 run-instances
        --region "$AWS_REGION"
        --image-id "$ami_id"
        --instance-type "$instance_type"
        --key-name "$AWS_KEY_NAME"
        --security-group-ids "$sg_id"
        --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=${VM_DISK},VolumeType=gp3}"
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${VM_NAME}}]"
        --query "Instances[0].InstanceId"
        --output text
    )

    # Add subnet if specified
    if [[ -n "$AWS_SUBNET_ID" ]]; then
        cmd+=(--subnet-id "$AWS_SUBNET_ID")
    fi

    log_info "Launching instance..."
    INSTANCE_ID=$("${cmd[@]}")

    if [[ -z "$INSTANCE_ID" ]]; then
        log_error "Failed to create instance"
        return 5
    fi

    log_success "Instance created: ${INSTANCE_ID}"
    return 0
}

# -----------------------------------------------------------------------------
# Function: wait_for_instance
# -----------------------------------------------------------------------------

wait_for_instance() {
    log_step "3" "Waiting for instance to be ready"

    log_info "Waiting for instance to reach 'running' state..."
    if ! aws ec2 wait instance-running \
        --region "$AWS_REGION" \
        --instance-ids "$INSTANCE_ID"; then
        log_error "Instance failed to start"
        return 5
    fi

    log_success "Instance is running"

    # Get public IP
    log_info "Retrieving public IP..."
    INSTANCE_IP=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --instance-ids "$INSTANCE_ID" \
        --query "Reservations[0].Instances[0].PublicIpAddress" \
        --output text)

    if [[ -z "$INSTANCE_IP" || "$INSTANCE_IP" == "None" ]]; then
        log_error "Instance has no public IP"
        return 6
    fi

    log_success "Instance IP: ${INSTANCE_IP}"
    return 0
}

# -----------------------------------------------------------------------------
# Function: wait_for_ssh
# -----------------------------------------------------------------------------

wait_for_ssh() {
    log_step "4" "Waiting for SSH to be ready"

    # Determine SSH key path
    local ssh_key_path="${AWS_SSH_KEY_PATH:-$HOME/.ssh/${AWS_KEY_NAME}.pem}"

    if [[ ! -f "$ssh_key_path" ]]; then
        log_error "SSH key not found: ${ssh_key_path}" >&2
        return 6
    fi

    local max_wait=180
    local elapsed=0
    local interval=5

    while [[ $elapsed -lt $max_wait ]]; do
        if timeout 5 ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
            "${INSTANCE_USER}@${INSTANCE_IP}" "echo SSH ready" >/dev/null 2>&1; then
            log_success "SSH is ready at ${INSTANCE_USER}@${INSTANCE_IP}"
            return 0
        fi

        sleep $interval
        elapsed=$((elapsed + interval))
        log_info "Waiting for SSH... (${elapsed}s/${max_wait}s)"
    done

    log_error "SSH timeout after ${max_wait}s"
    return 6
}

# -----------------------------------------------------------------------------
# Function: output_result
# -----------------------------------------------------------------------------

output_result() {
    log_step "5" "Generating output"

    linus_result "SUCCESS" \
        "INSTANCE_ID:${INSTANCE_ID}" \
        "INSTANCE_IP:${INSTANCE_IP}" \
        "INSTANCE_USER:${INSTANCE_USER}" \
        "INSTANCE_NAME:${VM_NAME}" \
        "INSTANCE_TYPE:$(select_instance_type)" \
        "INSTANCE_REGION:${AWS_REGION}" \
        "DISK_SIZE:${VM_DISK}"
}

# -----------------------------------------------------------------------------
# Main Function
# -----------------------------------------------------------------------------

main() {
    log_header "Linus AWS EC2 Provisioning"

    validate_environment || exit $?
    create_instance || exit $?
    wait_for_instance || exit $?
    wait_for_ssh || exit $?
    output_result

    log_success "EC2 instance provisioning completed successfully"
    return 0
}

# -----------------------------------------------------------------------------
# Entry Point
# -----------------------------------------------------------------------------

# Only run main if script is executed (not sourced for testing)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
