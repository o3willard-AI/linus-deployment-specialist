#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist - AWS EC2 VM Provisioning
# =============================================================================
# Purpose: Create and configure EC2 instances on AWS
# Author: Linus Deployment Specialist (AI-generated)
# Version: 2.0 — Tier 3 Unified Provider Contract
# Automation Level: 1 (Non-interactive design)
#
# Required Environment Variables:
#   AWS_REGION          - AWS region (default: us-east-1)
#   AWS_ACCESS_KEY_ID   - AWS access key (auto-discovered from ~/.hermes/secrets/)
#   AWS_SECRET_ACCESS_KEY- AWS secret key (auto-discovered from ~/.hermes/secrets/)
#   OR (alternate auth methods — any ONE of these):
#     AWS_PROFILE       - Named profile in ~/.aws/config (supports SSO, AssumeRole)
#     AWS_ROLE_ARN      - IAM role ARN to assume (uses sts assume-role)
#     Instance Profile  - Running on EC2? Uses attached IAM role automatically
#   AWS_KEY_NAME        - EC2 key pair name (required)
#   VM_OS_TYPE          - OS to provision: ubuntu, almalinux, debian, rocky (default: ubuntu)
#   VM_NAME             - Instance name tag (optional)
#   VM_CPU              - vCPUs (used to select instance type, default: 2)
#   VM_RAM              - RAM in MB (used to select instance type, default: 2048)
#   VM_DISK             - Root volume size in GB (default: 20)
#
# Optional:
#   AWS_INSTANCE_TYPE   - EC2 instance type (auto-selected from CPU/RAM if unset)
#   AWS_AMI_ID          - AMI ID (auto-detected from VM_OS_TYPE if unset)
#   AWS_AMI_FALLBACKS   - Comma-separated fallback AMI IDs
#   AWS_SUBNET_ID       - VPC subnet ID (uses default VPC if unset)
#   AWS_SECURITY_GROUP  - Security group ID (auto-creates linus-default-sg if unset)
#   AWS_SSH_KEY_PATH    - Path to SSH private key (auto-discovered if unset)
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
#   7 - SSH credentials required
#   9 - Human intervention needed
#
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the unified library path resolver
source "$SCRIPT_DIR/../lib/paths.sh" || exit 1
source_lib "logging.sh" "validation.sh" "ensure-dns.sh"

# -----------------------------------------------------------------------------
# Credential auto-discovery — source from known secret files before env vars
# -----------------------------------------------------------------------------
# ─── Credential Auto-Discovery (4 auth methods) ──────────────────
# Priority: env vars → ~/.hermes/secrets/ → ~/.aws/config (SSO profile)
#          → AssumeRole → Instance Profile (automatic on EC2)
# ───────────────────────────────────────────────────────────────────

_linus_auto_discover_credentials() {
    local secret_dirs=(
        "$HOME/.hermes/secrets"
        "$HOME/.hermes/env"
    )
    local cred_files=(
        "aws-credentials"
        "aws"
        "amazon"
    )

    # 1. Static keys from secrets files
    for dir in "${secret_dirs[@]}"; do
        for fname in "${cred_files[@]}"; do
            local fpath="${dir}/${fname}"
            if [[ -f "$fpath" && -r "$fpath" ]]; then
                while IFS='=' read -r key value; do
                    [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
                    key="${key## }"; key="${key%% }"
                    value="${value## }"; value="${value%% }"
                    case "$key" in
                        AWS_ACCESS_KEY_ID)      : "${AWS_ACCESS_KEY_ID:=$value}" ;;
                        AWS_SECRET_ACCESS_KEY)   : "${AWS_SECRET_ACCESS_KEY:=$value}" ;;
                        AWS_REGION)              : "${AWS_REGION:=$value}" ;;
                        AWS_KEY_NAME)            : "${AWS_KEY_NAME:=$value}" ;;
                        AWS_PROFILE)             : "${AWS_PROFILE:=$value}" ;;
                        AWS_ROLE_ARN)            : "${AWS_ROLE_ARN:=$value}" ;;
                    esac
                done < "$fpath"
            fi
        done
    done
}

# ─── Auth Resolution ───────────────────────────────────────────────
# Resolves AWS credentials using the first available method:
#   1. Static keys (AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY)
#   2. SSO profile (AWS_PROFILE — checks sso login session expiry)
#   3. IAM Role (AWS_ROLE_ARN — calls sts assume-role)
#   4. Instance Profile (automatic on EC2 — no config needed)
#
# Exports resolved credentials to environment if needed (AssumeRole).
# Returns: 0 if any method works, non-zero if all fail.
# ───────────────────────────────────────────────────────────────────

_linus_resolve_auth() {
    # Method 1: Static keys (already exported or from secrets)
    if [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
        export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
        log_info "Auth: static IAM keys"
        return 0
    fi

    # Method 2: SSO profile (AWS_PROFILE)
    if [[ -n "${AWS_PROFILE:-}" ]]; then
        log_info "Auth: SSO profile '${AWS_PROFILE}'"
        # Check if SSO session is still valid
        local sso_check
        sso_check=$(aws sts get-caller-identity --profile "$AWS_PROFILE" 2>&1) && {
            local sso_account
            sso_account=$(echo "$sso_check" | jq -r '.Account // "unknown"' 2>/dev/null)
            log_info "  SSO session valid (account: ${sso_account})"
            return 0
        }
        # SSO session expired — instruct user
        log_warn "SSO session expired or invalid for profile '${AWS_PROFILE}'"
        log_info "  Run: aws sso login --profile ${AWS_PROFILE}"
        log_info "  Then retry this script."
        log_info ""
        log_info "  To configure SSO for the first time:"
        log_info "    aws configure sso"
        log_info "    (follow the prompts for start URL, region, account, role)"
        return 3
    fi

    # Method 3: IAM Role assumption (AWS_ROLE_ARN)
    if [[ -n "${AWS_ROLE_ARN:-}" ]]; then
        log_info "Auth: assuming IAM role '${AWS_ROLE_ARN}'"
        local role_session
        role_session=$(aws sts assume-role \
            --role-arn "$AWS_ROLE_ARN" \
            --role-session-name "linus-provision-$(date +%s)" \
            --query 'Credentials.{AccessKeyId:AccessKeyId,SecretAccessKey:SecretAccessKey,SessionToken:SessionToken}' \
            --output json 2>&1) || {
            log_error "Failed to assume role: ${AWS_ROLE_ARN}"
            log_error "  ${role_session}"
            log_info "  Ensure your base credentials have sts:AssumeRole permission."
            return 3
        }
        export AWS_ACCESS_KEY_ID=$(echo "$role_session" | jq -r '.AccessKeyId')
        export AWS_SECRET_ACCESS_KEY=$(echo "$role_session" | jq -r '.SecretAccessKey')
        export AWS_SESSION_TOKEN=$(echo "$role_session" | jq -r '.SessionToken')
        local role_account
        role_account=$(echo "$AWS_ROLE_ARN" | grep -oP '[0-9]{12}' || echo "unknown")
        log_success "  Assumed role (account: ${role_account})"
        return 0
    fi

    # Method 4: Instance Profile (running on EC2)
    # Check if we can reach the IMDS (Instance Metadata Service)
    local imds_token
    imds_token=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 10" 2>/dev/null) || imds_token=""
    if [[ -n "$imds_token" ]]; then
        local imds_account
        imds_account=$(curl -s -H "X-aws-ec2-metadata-token: $imds_token" \
            "http://169.254.169.254/latest/dynamic/instance-identity/document" 2>/dev/null \
            | jq -r '.accountId // ""' 2>/dev/null) || imds_account=""
        if [[ -n "$imds_account" ]]; then
            log_info "Auth: EC2 instance profile (account: ${imds_account})"
            return 0
        fi
    fi

    # Nothing worked
    log_error "No AWS credentials found."
    log_info ""
    log_info "  Set ONE of the following:"
    log_info "    1. AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY (static keys)"
    log_info "    2. AWS_PROFILE (SSO profile — run 'aws sso login --profile NAME')"
    log_info "    3. AWS_ROLE_ARN (IAM role — uses base credentials to assume)"
    log_info "    4. Run on EC2 (instance profile auto-detected)"
    log_info ""
    log_info "  Or save static keys to ~/.hermes/secrets/aws-credentials:"
    log_info "    AWS_ACCESS_KEY_ID=AKIA...    "
    log_info "    AWS_SECRET_ACCESS_KEY=..."
    return 3
}

_linus_auto_discover_credentials

# Configuration from environment with defaults
readonly AWS_REGION="${AWS_REGION:-us-east-1}"
readonly AWS_KEY_NAME="${AWS_KEY_NAME:-}"

# Optional overrides (can be empty — auto-detected)
AWS_INSTANCE_TYPE="${AWS_INSTANCE_TYPE:-}"
AWS_AMI_ID="${AWS_AMI_ID:-}"
AWS_SUBNET_ID="${AWS_SUBNET_ID:-}"
AWS_SECURITY_GROUP="${AWS_SECURITY_GROUP:-}"

readonly VM_NAME="${VM_NAME:-linus-vm-$(date +%s)}"
readonly VM_CPU="${VM_CPU:-2}"
readonly VM_RAM="${VM_RAM:-2048}"
readonly VM_DISK="${VM_DISK:-20}"
readonly VM_OS_TYPE="${VM_OS_TYPE:-ubuntu}"

# ─── AMI Owner Mapping (per OS type) ───────────────────────────────
# Maps VM_OS_TYPE to the AWS account that publishes official AMIs.
# Used by get_ami() when AWS_AMI_ID is not explicitly set.
declare -A AMI_OWNERS=(
    [ubuntu]="099720109477"     # Canonical
    [ubuntu2404]="099720109477"
    [ubuntu2204]="099720109477"
    [almalinux]="764336703387"  # AlmaLinux OS Foundation
    [alma9]="764336703387"
    [debian]="136693071363"     # Debian
    [debian12]="136693071363"
    [rocky]="792107900819"      # Rocky Linux
    [rocky9]="792107900819"
    [amazonlinux]="137112412989" # Amazon
    [al2023]="137112412989"
)

# AMI name filters per OS (used in describe-images query)
declare -A AMI_FILTERS=(
    [ubuntu]="ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
    [ubuntu2404]="ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
    [ubuntu2204]="ubuntu/images/hvm-ssd-gp3/ubuntu-jammy-22.04-amd64-server-*"
    [almalinux]="AlmaLinux OS 9.*x86_64*"
    [alma9]="AlmaLinux OS 9.*x86_64*"
    [debian]="debian-12-amd64-*"
    [debian12]="debian-12-amd64-*"
    [rocky]="Rocky-9-EC2-Base-*"
    [rocky9]="Rocky-9-EC2-Base-*"
    [amazonlinux]="al2023-ami-*-kernel-*-x86_64"
    [al2023]="al2023-ami-*-kernel-*-x86_64"
)

# SSH username per OS type
declare -A OS_SSH_USERS=(
    [ubuntu]="ubuntu"
    [ubuntu2404]="ubuntu"
    [ubuntu2204]="ubuntu"
    [almalinux]="ec2-user"
    [alma9]="ec2-user"
    [debian]="admin"
    [debian12]="admin"
    [rocky]="ec2-user"
    [rocky9]="ec2-user"
    [amazonlinux]="ec2-user"
    [al2023]="ec2-user"
)

# Instance type mapping based on CPU/RAM requirements
# t3.* = x86_64 (Intel), t4g.* = arm64 (Graviton)
declare -A INSTANCE_TYPES=(
    # x86_64 (Intel Xeon)
    ["1-1024"]="t3.micro"
    ["1-2048"]="t3.small"
    ["2-2048"]="t3.small"
    ["2-4096"]="t3.medium"
    ["2-8192"]="t3.large"
    ["4-8192"]="t3.large"
    ["4-16384"]="t3.xlarge"
    ["8-16384"]="t3.xlarge"
    ["8-32768"]="t3.2xlarge"
    # arm64 (AWS Graviton) — better price/performance
    ["1-1024-arm"]="t4g.micro"
    ["2-2048-arm"]="t4g.small"
    ["2-4096-arm"]="t4g.medium"
    ["4-8192-arm"]="t4g.large"
    ["4-16384-arm"]="t4g.large"
    ["8-16384-arm"]="t4g.xlarge"
    ["8-32768-arm"]="t4g.2xlarge"
)

# ─── Instance Pricing (on-demand, us-east-1, $/hour) ─────────────
# Used to calculate LINUS_COST:estimated_usd from wall time.
# Prices as of 2026-05. For other regions, multiply by region factor.
declare -A INSTANCE_PRICES=(
    # x86_64
    [t3.nano]="0.0052"    [t3.micro]="0.0104"   [t3.small]="0.0208"
    [t3.medium]="0.0416"  [t3.large]="0.0832"   [t3.xlarge]="0.1664"
    [t3.2xlarge]="0.3328"
    [t2.micro]="0.0116"   [t2.small]="0.023"    [t2.medium]="0.0464"
    [m5.large]="0.096"    [m5.xlarge]="0.192"   [m5.2xlarge]="0.384"
    [c5.large]="0.085"    [c5.xlarge]="0.17"    [c5.2xlarge]="0.34"
    # arm64 (Graviton — ~20% cheaper than x86 equivalents)
    [t4g.nano]="0.0042"   [t4g.micro]="0.0084"  [t4g.small]="0.0168"
    [t4g.medium]="0.0336" [t4g.large]="0.0672"  [t4g.xlarge]="0.1344"
    [t4g.2xlarge]="0.2688"
    [m6g.large]="0.077"   [m6g.xlarge]="0.154"  [m6g.2xlarge]="0.308"
    [c6g.large]="0.068"   [c6g.xlarge]="0.136"  [c6g.2xlarge]="0.272"
    [m7g.large]="0.081"   [m7g.xlarge]="0.163"  [m7g.2xlarge]="0.326"
)

# Architecture detection from instance type prefix
# t3.*, t2.*, m5.*, c5.* → x86_64
# t4g.*, m6g.*, c6g.*, m7g.* → arm64
declare -A INSTANCE_ARCHITECTURES=(
    [t2]="x86_64"   [t3]="x86_64"   [t3a]="x86_64"
    [m5]="x86_64"   [m5a]="x86_64"  [m6i]="x86_64"
    [c5]="x86_64"   [c5a]="x86_64"  [c6i]="x86_64"
    [r5]="x86_64"   [r5a]="x86_64"  [r6i]="x86_64"
    [t4g]="arm64"   [m6g]="arm64"   [c6g]="arm64"
    [r6g]="arm64"   [m7g]="arm64"   [c7g]="arm64"
)

# Root device name per OS type
# Ubuntu/Debian use /dev/sda1, Amazon Linux uses /dev/xvda, newer AMIs use /dev/nvme0n1
declare -A OS_ROOT_DEVICES=(
    [ubuntu]="/dev/sda1"
    [ubuntu2404]="/dev/sda1"
    [ubuntu2204]="/dev/sda1"
    [almalinux]="/dev/sda1"
    [alma9]="/dev/sda1"
    [debian]="/dev/sda1"
    [debian12]="/dev/sda1"
    [rocky]="/dev/sda1"
    [rocky9]="/dev/sda1"
    [amazonlinux]="/dev/xvda"
    [al2023]="/dev/xvda"
)

# Global variables (Tier 3 contract names)
ALLOCATED_VM_ID=""          # EC2 instance ID (i-xxxxxxxxx)
VM_IP=""                    # Public IP
VM_SSH_USER=""              # SSH username (auto-detected from OS)
VM_SSH_KEY=""               # Path to SSH private key
SELECTED_INSTANCE_TYPE=""   # Resolved instance type
SELECTED_AMI_ID=""          # Resolved AMI ID
SELECTED_ARCHITECTURE=""    # Detected architecture (x86_64 or arm64)
SELECTED_ROOT_DEVICE=""     # Root device name from AMI metadata
CREATED_SECURITY_GROUP=""   # SG created by us (not user-supplied)
LINUS_WARNINGS=()           # Accumulated non-fatal warning tags (§3.1.6)
readonly PROVISION_START_TIME=$(date +%s)  # For LINUS_COST wall time tracking
LAUNCH_TIME_S=0             # Seconds from start to instance 'running'
SSH_READY_TIME_S=0          # Seconds from start to SSH available

# ─── Warning Helper ───────────────────────────────────────────────
# Appends a warning tag to the global accumulator.
# Usage: _warn_tag "sg_creation_failed"

_warn_tag() {
    LINUS_WARNINGS+=("$1")
}

# -----------------------------------------------------------------------------
# Function: cleanup_on_error
# -----------------------------------------------------------------------------
# Cleanup function called on error (registered as EXIT trap in main)
# Terminates the instance unless LINUS_KEEP_VM=true (for debugging)
# -----------------------------------------------------------------------------

cleanup_on_error() {
    local exit_code=$?
    if [[ $exit_code -ne 0 && -n "${ALLOCATED_VM_ID:-}" ]]; then
        if [[ "${LINUS_KEEP_VM:-}" == "true" ]]; then
            log_warn "Pipeline failed (exit ${exit_code}) — keeping instance ${ALLOCATED_VM_ID} for debugging (LINUS_KEEP_VM=true)"
            return $exit_code
        fi

        log_warn "Pipeline failed (exit ${exit_code}) — terminating instance ${ALLOCATED_VM_ID}"

        # PITFALL: Error suppression — capture output for diagnosis
        local term_result
        term_result=$(aws ec2 terminate-instances \
            --instance-ids "$ALLOCATED_VM_ID" \
            --region "$AWS_REGION" 2>&1) || {
            log_error "Failed to terminate instance ${ALLOCATED_VM_ID}: ${term_result}"
        }
        log_info "Instance ${ALLOCATED_VM_ID} termination requested"

        # Verify termination (poll up to 30s)
        local verify_attempt=0
        while [[ $verify_attempt -lt 6 ]]; do
            sleep 5
            local state_check
            state_check=$(aws ec2 describe-instances \
                --instance-ids "$ALLOCATED_VM_ID" \
                --region "$AWS_REGION" \
                --query "Reservations[0].Instances[0].State.Name" \
                --output text 2>&1) || {
                # Instance already gone (describe-instances returns error on terminated+purged)
                log_success "Instance ${ALLOCATED_VM_ID} terminated and removed"
                break
            }
            if [[ "$state_check" == "terminated" ]]; then
                log_success "Instance ${ALLOCATED_VM_ID} terminated (verified)"
                break
            fi
            verify_attempt=$((verify_attempt + 1))
            log_info "  Waiting for termination... (${state_check:-unknown})"
        done
    fi
    return $exit_code
}

# -----------------------------------------------------------------------------
# Function: validate_environment
# -----------------------------------------------------------------------------
# Validates that all prerequisites are met
# Returns: 0 on success, non-zero on failure
# -----------------------------------------------------------------------------

validate_environment() {
    log_step "1" "Validating environment"

    # Check AWS CLI is installed
    check_dependencies aws jq || return 2

    # Resolve credentials (4 methods: static, SSO, AssumeRole, Instance Profile)
    _linus_resolve_auth || return $?

    # Validate AWS_KEY_NAME is provided
    if [[ -z "$AWS_KEY_NAME" ]]; then
        log_error "AWS_KEY_NAME is required (EC2 key pair name)"
        return 3
    fi

    # Verify key pair exists
    local key_check
    key_check=$(aws ec2 describe-key-pairs --key-names "$AWS_KEY_NAME" --region "$AWS_REGION" 2>&1) || {
        log_error "Key pair not found: ${AWS_KEY_NAME}"
        log_error "  ${key_check}"
        log_info "Create it with: aws ec2 create-key-pair --key-name ${AWS_KEY_NAME} --region ${AWS_REGION}"
        return 3
    }

    # Validate OS type
    validate_os "${VM_OS_TYPE}" || {
        _warn_tag "unknown_os_type"
        log_warn "Unknown OS type '${VM_OS_TYPE}' — defaulting to ubuntu"
    }

    # Determine SSH user from OS type
    VM_SSH_USER="${OS_SSH_USERS[$VM_OS_TYPE]:-ubuntu}"
    log_info "SSH user: ${VM_SSH_USER} (OS: ${VM_OS_TYPE})"

    log_success "Environment validation passed"
    return 0
}

# ─── Architecture Detection ───────────────────────────────────────
# Determines the CPU architecture for the instance.
# Priority: AWS_ARCHITECTURE env → instance type prefix → default x86_64
# Sets: SELECTED_ARCHITECTURE
# ───────────────────────────────────────────────────────────────────

detect_architecture() {
    local instance_type="$1"

    # Explicit override
    if [[ -n "${AWS_ARCHITECTURE:-}" ]]; then
        SELECTED_ARCHITECTURE="$AWS_ARCHITECTURE"
        log_info "Architecture: ${SELECTED_ARCHITECTURE} (explicit)"
        return 0
    fi

    # Detect from instance type prefix (e.g., t4g → arm64, t3 → x86_64)
    local prefix="${instance_type%%.*}"  # t4g from t4g.micro
    local detected="${INSTANCE_ARCHITECTURES[$prefix]:-}"

    if [[ -n "$detected" ]]; then
        SELECTED_ARCHITECTURE="$detected"
        log_info "Architecture: ${SELECTED_ARCHITECTURE} (detected from ${instance_type})"
        return 0
    fi

    # Default
    _warn_tag "architecture_unknown"
    log_warn "Unknown architecture for instance type '${instance_type}' — defaulting to x86_64"
    SELECTED_ARCHITECTURE="x86_64"
    return 0
}

# -----------------------------------------------------------------------------
# Function: select_instance_type
# -----------------------------------------------------------------------------
# Selects EC2 instance type based on CPU/RAM requirements.
# Uses AWS_INSTANCE_TYPE if set, otherwise maps from INSTANCE_TYPES table.
# -----------------------------------------------------------------------------

select_instance_type() {
    if [[ -n "$AWS_INSTANCE_TYPE" ]]; then
        SELECTED_INSTANCE_TYPE="$AWS_INSTANCE_TYPE"
        log_info "Using specified instance type: ${SELECTED_INSTANCE_TYPE}"
        detect_architecture "$SELECTED_INSTANCE_TYPE"
        return 0
    fi

    local key="${VM_CPU}-${VM_RAM}"
    local arch_suffix=""

    # If architecture is explicitly set to arm64, look for ARM instance types first
    if [[ "${AWS_ARCHITECTURE:-}" == "arm64" ]]; then
        arch_suffix="-arm"
    fi

    # Try exact match with architecture suffix
    if [[ -n "$arch_suffix" && -n "${INSTANCE_TYPES[${key}${arch_suffix}]:-}" ]]; then
        SELECTED_INSTANCE_TYPE="${INSTANCE_TYPES[${key}${arch_suffix}]}"
        log_info "Auto-selected ARM instance: ${SELECTED_INSTANCE_TYPE} (${VM_CPU} CPU / ${VM_RAM} MB RAM)"
        detect_architecture "$SELECTED_INSTANCE_TYPE"
        return 0
    fi

    # Try standard x86_64 match
    if [[ -n "${INSTANCE_TYPES[$key]:-}" ]]; then
        SELECTED_INSTANCE_TYPE="${INSTANCE_TYPES[$key]}"
        log_info "Auto-selected instance type: ${SELECTED_INSTANCE_TYPE} (${VM_CPU} CPU / ${VM_RAM} MB RAM)"
        detect_architecture "$SELECTED_INSTANCE_TYPE"
        return 0
    fi

    # Default fallback
    _warn_tag "instance_type_fallback"
    log_warn "No exact match for ${VM_CPU} CPU / ${VM_RAM} MB RAM, using t3.medium"
    SELECTED_INSTANCE_TYPE="t3.medium"
    detect_architecture "$SELECTED_INSTANCE_TYPE"
    return 0
}

# -----------------------------------------------------------------------------
# Function: get_ami
# -----------------------------------------------------------------------------
# Resolves the AMI ID to use, supporting multiple OS types.
# Priority: AWS_AMI_ID → AWS_AMI_FALLBACKS → auto-detect from VM_OS_TYPE
# Sets: SELECTED_AMI_ID
# Returns: 0 on success, non-zero on failure
# -----------------------------------------------------------------------------

get_ami() {
    # Explicit AMI ID — use it directly
    if [[ -n "$AWS_AMI_ID" ]]; then
        SELECTED_AMI_ID="$AWS_AMI_ID"
        log_info "Using specified AMI: ${SELECTED_AMI_ID}"
        return 0
    fi

    local os_type="${VM_OS_TYPE:-ubuntu}"
    local owner="${AMI_OWNERS[$os_type]:-}"
    local name_filter="${AMI_FILTERS[$os_type]:-}"

    if [[ -z "$owner" || -z "$name_filter" ]]; then
        log_error "No AMI mapping for OS type: ${os_type}"
        log_info "  Supported: ubuntu, almalinux, debian, rocky, amazonlinux"
        return 5
    fi

    log_info "Finding latest AMI for ${os_type} (owner: ${owner}, arch: ${SELECTED_ARCHITECTURE})..."
    log_info "  Filter: ${name_filter}"

    local ami_id ami_json
    ami_json=$(aws ec2 describe-images \
        --region "$AWS_REGION" \
        --owners "$owner" \
        --filters \
            "Name=name,Values=${name_filter}" \
            "Name=state,Values=available" \
            "Name=architecture,Values=${SELECTED_ARCHITECTURE}" \
            "Name=virtualization-type,Values=hvm" \
            "Name=root-device-type,Values=ebs" \
        --query "Images | sort_by(@, &CreationDate) | [-1].{ImageId:ImageId,RootDeviceName:RootDeviceName,Name:Name,CreationDate:CreationDate,Architecture:Architecture}" \
        --output json 2>/dev/null) || ami_json=""

    # Parse AMI details
    ami_id=$(echo "$ami_json" | jq -r '.ImageId // ""' 2>/dev/null)
    local ami_name ami_arch ami_root
    ami_name=$(echo "$ami_json" | jq -r '.Name // "unknown"' 2>/dev/null)
    ami_arch=$(echo "$ami_json" | jq -r '.Architecture // "unknown"' 2>/dev/null)
    ami_root=$(echo "$ami_json" | jq -r '.RootDeviceName // ""' 2>/dev/null)

    if [[ -n "$ami_id" && "$ami_id" != "None" ]]; then
        SELECTED_AMI_ID="$ami_id"

        # Determine root device name: AMI metadata → OS mapping → /dev/sda1 default
        if [[ -n "$ami_root" && "$ami_root" != "null" ]]; then
            SELECTED_ROOT_DEVICE="$ami_root"
        else
            SELECTED_ROOT_DEVICE="${OS_ROOT_DEVICES[$os_type]:-/dev/sda1}"
        fi

        log_success "AMI: ${SELECTED_AMI_ID}"
        log_info "  Name: ${ami_name}"
        log_info "  Architecture: ${ami_arch}"
        log_info "  Root device: ${SELECTED_ROOT_DEVICE}"
        log_info "  Created: $(echo "$ami_json" | jq -r '.CreationDate // \"unknown\"' 2>/dev/null)"
        return 0
    fi

    # Try fallback AMI IDs
    local fallbacks="${AWS_AMI_FALLBACKS:-}"
    if [[ -n "$fallbacks" ]]; then
        log_warn "AMI auto-detection failed — trying fallback AMIs: ${fallbacks}"
        IFS=',' read -ra fb_arr <<< "$fallbacks"
        for fb_id in "${fb_arr[@]}"; do
            fb_id="${fb_id## }"; fb_id="${fb_id%% }"

            # Verify the AMI exists
            if aws ec2 describe-images --region "$AWS_REGION" --image-ids "$fb_id" >/dev/null 2>&1; then
                SELECTED_AMI_ID="$fb_id"
                _warn_tag "ami_fallback_used"
                log_success "Using fallback AMI: ${SELECTED_AMI_ID}"
                return 0
            fi
        done
        log_warn "All fallback AMIs unavailable"
    fi

    log_error "Could not find AMI for ${os_type} in ${AWS_REGION}"
    log_info "  Set AWS_AMI_ID explicitly or add fallbacks via AWS_AMI_FALLBACKS"
    return 5
}

# -----------------------------------------------------------------------------
# Function: discover_ssh_key
# -----------------------------------------------------------------------------
# Auto-discovers the SSH private key for the AWS key pair.
# Search order: AWS_SSH_KEY_PATH → ~/.ssh/${AWS_KEY_NAME}.pem → ~/.ssh/id_ed25519
# Sets: VM_SSH_KEY
# Returns: 0 on success, non-zero if no key found
# -----------------------------------------------------------------------------

discover_ssh_key() {
    # Explicit path
    if [[ -n "${AWS_SSH_KEY_PATH:-}" && -f "$AWS_SSH_KEY_PATH" ]]; then
        VM_SSH_KEY="$AWS_SSH_KEY_PATH"
        log_info "SSH key: ${VM_SSH_KEY} (explicit)"
        return 0
    fi

    # Standard AWS key pair location
    local aws_key_path="$HOME/.ssh/${AWS_KEY_NAME}.pem"
    if [[ -f "$aws_key_path" ]]; then
        VM_SSH_KEY="$aws_key_path"
        log_info "SSH key: ${VM_SSH_KEY} (AWS key pair)"
        return 0
    fi

    # Fallback: standard SSH keys
    for candidate in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa"; do
        if [[ -f "$candidate" ]]; then
            VM_SSH_KEY="$candidate"
            _warn_tag "ssh_key_fallback"
            log_warn "AWS key pair .pem not found — using ${candidate} (may not match)"
            return 0
        fi
    done

    log_error "No SSH key found"
    log_info "  Expected: ${aws_key_path}"
    log_info "  Set AWS_SSH_KEY_PATH to override"
    return 6
}

# -----------------------------------------------------------------------------
# Function: get_or_create_security_group
# -----------------------------------------------------------------------------
# Resolves the security group to use. Creates linus-default-sg if needed.
# -----------------------------------------------------------------------------

get_or_create_security_group() {
    if [[ -n "$AWS_SECURITY_GROUP" ]]; then
        log_info "Using specified security group: ${AWS_SECURITY_GROUP}"
        echo "$AWS_SECURITY_GROUP"
        return 0
    fi

    local sg_name="linus-default-sg"
    local sg_desc="Linus Deployment Specialist default security group"

    # Check if security group exists
    local sg_list
    sg_list=$(aws ec2 describe-security-groups \
        --region "$AWS_REGION" \
        --filters "Name=group-name,Values=${sg_name}" \
        --query "SecurityGroups[0].GroupId" \
        --output text 2>&1) || true

    if [[ -n "$sg_list" && "$sg_list" != "None" && "$sg_list" != *"InvalidGroup.NotFound"* ]]; then
        log_info "Using existing security group: ${sg_list}"
        echo "$sg_list"
        return 0
    fi

    log_info "Creating security group: ${sg_name}"

    # Get default VPC ID
    local vpc_id
    vpc_id=$(aws ec2 describe-vpcs \
        --region "$AWS_REGION" \
        --filters "Name=is-default,Values=true" \
        --query "Vpcs[0].VpcId" \
        --output text 2>&1) || true

    if [[ -z "$vpc_id" || "$vpc_id" == "None" ]]; then
        log_error "No default VPC found in ${AWS_REGION}"
        log_info "  Set AWS_SUBNET_ID + AWS_SECURITY_GROUP explicitly"
        return 4
    fi

    # Create security group
    local sg_id
    sg_id=$(aws ec2 create-security-group \
        --region "$AWS_REGION" \
        --group-name "$sg_name" \
        --description "$sg_desc" \
        --vpc-id "$vpc_id" \
        --query "GroupId" \
        --output text 2>&1) || {
        log_error "Failed to create security group: ${sg_id}"
        return 4
    }

    CREATED_SECURITY_GROUP="$sg_id"

    # Add SSH rule
    local sg_rule_result
    sg_rule_result=$(aws ec2 authorize-security-group-ingress \
        --region "$AWS_REGION" \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 22 \
        --cidr 0.0.0.0/0 2>&1) || {
        _warn_tag "sg_ssh_rule_failed"
        log_warn "Could not add SSH rule to security group — instance may be unreachable"
    }

    log_success "Created security group: ${sg_id}"
    echo "$sg_id"
}

# ─── AMI Validation ───────────────────────────────────────────────
# Verifies the selected AMI exists, is available, and matches architecture.
# Catches stale AMI IDs and architecture mismatches before run-instances.
# Returns: 0 if AMI is launchable, non-zero otherwise
# ───────────────────────────────────────────────────────────────────

validate_ami() {
    local ami_id="$1"
    local expected_arch="${2:-x86_64}"

    log_info "Validating AMI ${ami_id}..."

    local ami_info
    ami_info=$(aws ec2 describe-images \
        --region "$AWS_REGION" \
        --image-ids "$ami_id" \
        --query "Images[0].{State:State,Architecture:Architecture,RootDeviceName:RootDeviceName,Name:Name}" \
        --output json 2>&1) || {
        log_error "AMI ${ami_id} not found or not accessible"
        log_error "  ${ami_info}"
        return 4
    }

    local state ami_arch ami_root
    state=$(echo "$ami_info" | jq -r '.State // "unknown"' 2>/dev/null)
    ami_arch=$(echo "$ami_info" | jq -r '.Architecture // ""' 2>/dev/null)
    ami_root=$(echo "$ami_info" | jq -r '.RootDeviceName // ""' 2>/dev/null)

    if [[ "$state" != "available" ]]; then
        log_error "AMI ${ami_id} state is '${state}' — not launchable"
        return 4
    fi

    if [[ -n "$ami_arch" && "$ami_arch" != "$expected_arch" ]]; then
        log_error "AMI architecture mismatch: AMI is ${ami_arch}, instance requires ${expected_arch}"
        log_info "  Cannot launch ${ami_arch} AMI on ${expected_arch} instance type"
        return 4
    fi

    # Cache root device name from AMI if not already set
    if [[ -n "$ami_root" && -z "${SELECTED_ROOT_DEVICE:-}" ]]; then
        SELECTED_ROOT_DEVICE="$ami_root"
        log_info "Root device from AMI: ${SELECTED_ROOT_DEVICE}"
    fi

    log_success "AMI validated: ${ami_id} (${state}, ${ami_arch})"
    return 0
}

# -----------------------------------------------------------------------------
# Function: create_instance
# -----------------------------------------------------------------------------
# Launches an EC2 instance with the selected configuration.
# Sets: ALLOCATED_VM_ID
# -----------------------------------------------------------------------------

create_instance() {
    log_step "2" "Creating EC2 instance"

    select_instance_type
    log_info "Instance type: ${SELECTED_INSTANCE_TYPE}"

    get_ami || return $?
    log_info "AMI: ${SELECTED_AMI_ID}"

    # Validate AMI is launchable before spending money
    validate_ami "$SELECTED_AMI_ID" "$SELECTED_ARCHITECTURE" || return $?

    local sg_id
    sg_id=$(get_or_create_security_group)
    log_info "Security group: ${sg_id}"

    # Build create-instances command with arrays (§3.1.5)
    local root_device="${SELECTED_ROOT_DEVICE:-/dev/sda1}"
    local cmd=(
        aws ec2 run-instances
        --region "$AWS_REGION"
        --image-id "$SELECTED_AMI_ID"
        --instance-type "$SELECTED_INSTANCE_TYPE"
        --key-name "$AWS_KEY_NAME"
        --security-group-ids "$sg_id"
        --block-device-mappings "DeviceName=${root_device},Ebs={VolumeSize=${VM_DISK},VolumeType=gp3}"
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${VM_NAME}}]"
        --query "Instances[0].InstanceId"
        --output text
    )

    # Add subnet if specified
    if [[ -n "$AWS_SUBNET_ID" ]]; then
        cmd+=(--subnet-id "$AWS_SUBNET_ID")
    fi

    log_info "Launching instance..."
    local instance_id
    instance_id=$("${cmd[@]}" 2>&1) || {
        log_error "Failed to create instance"
        log_error "  ${instance_id}"
        return 5
    }

    ALLOCATED_VM_ID="$instance_id"
    log_success "Instance created: ${ALLOCATED_VM_ID}"
    return 0
}

# -----------------------------------------------------------------------------
# Function: wait_for_instance
# -----------------------------------------------------------------------------
# Waits for the instance to reach 'running' state and get public IP.
# Sets: VM_IP
# -----------------------------------------------------------------------------

wait_for_instance() {
    log_step "3" "Waiting for instance to be ready"

    log_info "Waiting for instance to reach 'running' state..."
    local wait_result
    wait_result=$(aws ec2 wait instance-running \
        --region "$AWS_REGION" \
        --instance-ids "$ALLOCATED_VM_ID" 2>&1) || {
        log_error "Instance failed to start: ${wait_result}"
        return 5
    }

    log_success "Instance is running"
    LAUNCH_TIME_S=$(($(date +%s) - PROVISION_START_TIME))

    # Get public IP
    log_info "Retrieving public IP..."

    local ip_result
    ip_result=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --instance-ids "$ALLOCATED_VM_ID" \
        --query "Reservations[0].Instances[0].PublicIpAddress" \
        --output text 2>&1) || {
        log_error "Failed to query instance IP: ${ip_result}"
        return 6
    }

    if [[ -z "$ip_result" || "$ip_result" == "None" ]]; then
        _warn_tag "no_public_ip"
        log_warn "Instance has no public IP — checking if VPC has internet gateway..."
        log_info "  Instance may only be reachable within VPC"
        # Try private IP as fallback
        ip_result=$(aws ec2 describe-instances \
            --region "$AWS_REGION" \
            --instance-ids "$ALLOCATED_VM_ID" \
            --query "Reservations[0].Instances[0].PrivateIpAddress" \
            --output text 2>/dev/null) || true
        if [[ -z "$ip_result" || "$ip_result" == "None" ]]; then
            log_error "Instance has no IP at all"
            return 6
        fi
        log_warn "  Using private IP: ${ip_result}"
    fi

    VM_IP="$ip_result"
    log_success "Instance IP: ${VM_IP}"
    return 0
}

# -----------------------------------------------------------------------------
# Function: wait_for_ssh
# -----------------------------------------------------------------------------
# Waits for SSH to become available on the instance.
# Uses bash arrays for SSH arguments (§3.1.5).
# -----------------------------------------------------------------------------

wait_for_ssh() {
    log_step "4" "Waiting for SSH to be ready"

    # Auto-discover SSH key
    discover_ssh_key || return $?

    # Build SSH args as array — never string concatenation
    local ssh_args=(
        -o BatchMode=yes
        -o ConnectTimeout=5
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o ServerAliveInterval=30
        -i "$VM_SSH_KEY"
    )

    local max_wait=180
    local elapsed=0
    local interval=5

    while [[ $elapsed -lt $max_wait ]]; do
        local ssh_error
        ssh_error=$(ssh "${ssh_args[@]}" "${VM_SSH_USER}@${VM_IP}" "echo ok" 2>&1) && {
            SSH_READY_TIME_S=$(($(date +%s) - PROVISION_START_TIME))
            log_success "SSH is ready at ${VM_SSH_USER}@${VM_IP} (${SSH_READY_TIME_S}s)"
            return 0
        }

        sleep $interval
        elapsed=$((elapsed + interval))
        # Log progress every 30s
        if [[ $((elapsed % 30)) -eq 0 ]]; then
            log_info "Waiting for SSH... (${elapsed}s/${max_wait}s)"
        fi
    done

    _warn_tag "ssh_timeout"
    log_error "SSH timeout after ${max_wait}s"
    log_error "  Last attempt: ${ssh_error:-unknown}"
    return 6
}

# ─── VM Capability Verification ──────────────────────────────────
# Quality gate — verifies the instance is actually usable for workloads.
# Architecture-aware: x86 checks AVX2/SSE4.2, ARM checks NEON/ASIMD.
# Returns: 0 on VERIFIED, 8 on DEGRADED (non-fatal — warns but continues)
# ───────────────────────────────────────────────────────────────────

verify_vm_capability() {
    local vm_ip="$1"
    local vm_user="$2"

    log_step "5" "Verifying VM capability"

    local ssh_args=(
        -o BatchMode=yes
        -o ConnectTimeout=5
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o ServerAliveInterval=30
    )
    [[ -n "${VM_SSH_KEY:-}" ]] && ssh_args+=(-i "$VM_SSH_KEY")

    local all_passed=true

    # ─── Check 1: CPU features (architecture-aware) ────────────
    log_info "Checking CPU features..."
    if [[ "$SELECTED_ARCHITECTURE" == "arm64" ]]; then
        # ARM/Graviton: check for NEON/ASIMD (aarch64 standard)
        if ssh "${ssh_args[@]}" "${vm_user}@${vm_ip}" \
            "grep -q -E ' neon| asimd| fp| crc32' /proc/cpuinfo" 2>/dev/null; then
            log_info "  CPU supports NEON/ASIMD (ARM64) ✅"
        else
            log_warn "  CPU features minimal — ARM64 but NEON not confirmed"
            all_passed=false
        fi
    else
        # x86_64: check for AVX2/SSE4.2 (required for ML workloads)
        if ssh "${ssh_args[@]}" "${vm_user}@${vm_ip}" \
            "grep -q -E 'avx2|sse4_2' /proc/cpuinfo" 2>/dev/null; then
            log_info "  CPU supports AVX2/SSE4.2 ✅"
        else
            log_warn "  CPU MISSING AVX2/SSE4.2 — ML workloads may crash"
            log_warn "  Consider using a compute-optimized instance (c5/c6i/c7i)"
            all_passed=false
        fi
    fi

    # ─── Check 2: Disk space (>2 GB free) ────────────────────
    log_info "Checking disk space..."
    local disk_free
    disk_free=$(ssh "${ssh_args[@]}" "${vm_user}@${vm_ip}" \
        "df -BG / | awk 'NR==2 {print \$4}' | sed 's/G//'" 2>/dev/null) || disk_free=0
    if [[ "$disk_free" -gt 2 ]]; then
        log_info "  Disk: ${disk_free}GB free ✅"
    else
        log_warn "  Disk: ${disk_free}GB free (<2 GB) — may fail during package install"
        all_passed=false
    fi

    # ─── Check 3: DNS resolution ─────────────────────────────
    log_info "Checking DNS..."
    if ssh "${ssh_args[@]}" "${vm_user}@${vm_ip}" \
        "getent hosts amazon.com >/dev/null 2>&1" 2>/dev/null; then
        log_info "  DNS working ✅"
    else
        # Try alternative DNS test (some AMIs block amazon.com)
        if ssh "${ssh_args[@]}" "${vm_user}@${vm_ip}" \
            "getent hosts archive.ubuntu.com >/dev/null 2>&1 || getent hosts google.com >/dev/null 2>&1" 2>/dev/null; then
            log_info "  DNS working (alternate) ✅"
        else
            log_warn "  DNS not working — package managers will fail"
            all_passed=false
        fi
    fi

    # ─── Check 4: Python available ────────────────────────────
    log_info "Checking Python..."
    if ssh "${ssh_args[@]}" "${vm_user}@${vm_ip}" \
        "which python3 >/dev/null 2>&1" 2>/dev/null; then
        local py_ver
        py_ver=$(ssh "${ssh_args[@]}" "${vm_user}@${vm_ip}" \
            "python3 --version 2>&1" 2>/dev/null) || py_ver="unknown"
        log_info "  Python: ${py_ver} ✅"
    else
        log_warn "  Python not installed — most workloads will fail"
        all_passed=false
    fi

    if [[ "$all_passed" == "true" ]]; then
        log_success "VM capability VERIFIED — ready for workload"
        return 0
    fi

    _warn_tag "capability_degraded"
    log_warn "VM capability DEGRADED — some checks failed (see above)"
    return 8
}

# -----------------------------------------------------------------------------
# Function: output_result
# -----------------------------------------------------------------------------
# Outputs structured result in Tier 3 unified provider contract format.
# Uses VM_ prefix for all fields (same as Proxmox/Vast).
# -----------------------------------------------------------------------------

output_result() {
    log_step "6" "Generating output"

    local wall_time_s=$(($(date +%s) - PROVISION_START_TIME))

    # Calculate estimated cost from instance pricing
    local hourly_rate="${INSTANCE_PRICES[${SELECTED_INSTANCE_TYPE}]:-0}"
    local estimated_usd="0.0000"
    if [[ "$hourly_rate" != "0" && -n "$hourly_rate" ]]; then
        estimated_usd=$(python3 -c "
runtime_s = ${wall_time_s}
rate_hr = ${hourly_rate}
cost = (runtime_s / 3600.0) * rate_hr
print(f'{cost:.6f}')
" 2>/dev/null) || estimated_usd="unknown"
    fi

    # Structured output for parsing (LINUS_RESULT contract)
    linus_success \
        "VM_ID:${ALLOCATED_VM_ID}" \
        "VM_IP:${VM_IP}" \
        "VM_USER:${VM_SSH_USER}" \
        "VM_SSH_KEY:${VM_SSH_KEY}" \
        "VM_NAME:${VM_NAME}" \
        "VM_CPU:${VM_CPU}" \
        "VM_RAM:${VM_RAM}" \
        "VM_DISK:${VM_DISK}" \
        "VM_REGION:${AWS_REGION}" \
        "VM_OS_TYPE:${VM_OS_TYPE}" \
        "VM_AMI_ID:${SELECTED_AMI_ID}" \
        "VM_INSTANCE_TYPE:${SELECTED_INSTANCE_TYPE}" \
        "VM_ARCHITECTURE:${SELECTED_ARCHITECTURE}" \
        "COST:wall_time_s=${wall_time_s},launch_time_s=${LAUNCH_TIME_S},ssh_ready_time_s=${SSH_READY_TIME_S},instance_type=${SELECTED_INSTANCE_TYPE},hourly_rate_usd=${hourly_rate},estimated_usd=${estimated_usd}" \
        "RESOURCE:cpu_cores=${VM_CPU},ram_mb=${VM_RAM},disk_gb=${VM_DISK},instance_type=${SELECTED_INSTANCE_TYPE},architecture=${SELECTED_ARCHITECTURE},region=${AWS_REGION}" \
        "WARNINGS:${LINUS_WARNINGS[*]:-none}"
}

# -----------------------------------------------------------------------------
# Main Function
# -----------------------------------------------------------------------------

main() {
    log_header "Linus AWS EC2 Provisioning"

    # Set trap for cleanup on error
    trap cleanup_on_error EXIT

    validate_environment || exit $?
    create_instance || exit $?
    wait_for_instance || exit $?
    wait_for_ssh || exit $?
    verify_vm_capability "${VM_IP}" "${VM_SSH_USER}" || true   # Quality gate — warn but don't abort
    output_result

    # Disable cleanup trap on success
    trap - EXIT

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
