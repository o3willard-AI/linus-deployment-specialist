#!/usr/bin/env bash
# =============================================================================
# Example: Pre-Bootstrap Snapshot Workflow
# =============================================================================
# Purpose: Demonstrate snapshot creation before bootstrap for instant rollback
# Author: Linus Deployment Specialist
# Version: 1.0 (v1.3.1)
#
# Usage:
#   ./examples/pre-bootstrap-snapshot-example.sh [--help]
#
# Prerequisites:
#   - Valid Proxmox/AWS/QEMU credentials set in environment
#   - At least one bootstrap script available
#
# Exit Codes:
#   0 - Success
#   1 - Execution failed
#   2 - Missing dependencies
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPTS_DIR="$(cd "$(dirname "$0")/../shared" && pwd)"
SNAPSHOT_DIR="${SCRIPTS_DIR}/snapshot"

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

show_help() {
    cat << 'EOF'
Pre-Bootstrap Snapshot Workflow Example
========================================

This example demonstrates how to create a snapshot before running bootstrap
scripts, enabling instant rollback if the bootstrap fails.

Usage:
  ./examples/pre-bootstrap-snapshot-example.sh [OPTIONS]

Options:
  --help              Show this help message
  --provider=<name>   Provider to use (proxmox|aws|qemu) [default: proxmox]
  --vm-name=<name>    VM name to provision [default: example-vm-$(date +%Y%m%d)]
  --bootstrap=<file>  Bootstrap script to run [default: ubuntu.sh]

Examples:
  # Basic usage (Proxmox, Ubuntu bootstrap)
  ./examples/pre-bootstrap-snapshot-example.sh

  # AWS with custom VM name
  ./examples/pre-bootstrap-snapshot-example.sh \
    --provider=aws --vm-name=dev-instance-001

  # QEMU with AlmaLinux bootstrap
  ./examples/pre-bootstrap-snapshot-example.sh \
    --provider=qemu --bootstrap=almalinux.sh

Workflow:
  1. Create snapshot before bootstrap
  2. Run bootstrap script
  3. If bootstrap fails, snapshot is offered for restore
  4. On success, snapshot is logged for future use

Key Benefits:
  ✅ Zero downtime rollback on bootstrap failure
  ✅ Consistent test environments
  ✅ Time machine for experimentation
  ✅ Automated recovery process

Dependencies:
  - PROVIDER environment variable set
  - VM_IDENTIFIER and VM_IP (for some providers)
  - Bootstrap script available in shared/bootstrap/

EOF
}

# -----------------------------------------------------------------------------
# Main Workflow
# -----------------------------------------------------------------------------

main() {
    local provider="proxmox"
    local vm_name="example-vm-$(date +%Y%m%d%H%M%S)"
    local bootstrap_script="ubuntu.sh"
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                show_help
                exit 0
                ;;
            --provider=*)
                provider="${1#*=}"
                shift
                ;;
            --vm-name=*)
                vm_name="${1#*=}"
                shift
                ;;
            --bootstrap=*)
                bootstrap_script="${1#*=}"
                shift
                ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}"
                show_help
                exit 1
                ;;
        esac
    done
    
    # Check prerequisites
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Pre-Bootstrap Snapshot Workflow Example${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    
    # Check if bootstrap script exists
    if [[ ! -f "${SCRIPTS_DIR}/bootstrap/${bootstrap_script}" ]]; then
        echo -e "${RED}Error: Bootstrap script not found: ${SCRIPTS_DIR}/bootstrap/${bootstrap_script}${NC}"
        echo "Available bootstrap scripts:"
        ls -1 "${SCRIPTS_DIR}/bootstrap/"
        exit 1
    fi
    
    echo -e "${GREEN}Provider:${NC} ${provider}"
    echo -e "${GREEN}VM Name:${NC} ${vm_name}"
    echo -e "${GREEN}Bootstrap:${NC} ${bootstrap_script}"
    echo ""
    
    # Step 1: Validate provider is configured
    echo -e "${BLUE}[Step 1/4]${NC} Validating provider configuration..."
    case "${provider}" in
        proxmox)
            if [[ -z "${PROXMOX_HOST:-}" ]] || [[ -z "${PROXMOX_USER:-}" ]]; then
                echo -e "${YELLOW}Warning: Proxmox credentials not set. Running in demo mode.${NC}"
            fi
            ;;
        aws)
            if [[ -z "${AWS_REGION:-}" ]] || [[ -z "${AWS_KEY_NAME:-}" ]]; then
                echo -e "${YELLOW}Warning: AWS credentials not set. Running in demo mode.${NC}"
            fi
            ;;
        qemu)
            if [[ -z "${QEMU_HOST:-}" ]] || [[ -z "${QEMU_USER:-}" ]]; then
                echo -e "${YELLOW}Warning: QEMU credentials not set. Running in demo mode.${NC}"
            fi
            ;;
        *)
            echo -e "${RED}Error: Unsupported provider: ${provider}${NC}"
            echo "Supported providers: proxmox, aws, qemu"
            exit 1
            ;;
    esac
    
    # Step 2: Create snapshot before bootstrap
    echo ""
    echo -e "${BLUE}[Step 2/4]${NC} Creating snapshot before bootstrap..."
    
    local snapshot_name="pre-bootstrap-${vm_name}-$(date +%Y%m%d%H%M%S)"
    
    if [[ -x "${SNAPSHOT_DIR}/save-snapshot.sh" ]]; then
        echo "Snapshot name: ${snapshot_name}"
        echo "Script: ${SNAPSHOT_DIR}/save-snapshot.sh"
        
        # In real usage, this would run the actual snapshot command
        # PROVIDER="${provider}" VM_IDENTIFIER="${vm_name}" VM_IP="${vm_ip:-}" \
        #   "${SNAPSHOT_DIR}/save-snapshot.sh"
        
        echo -e "${GREEN}Snapshot created (demo mode): ${snapshot_name}${NC}"
    else
        echo -e "${YELLOW}save-snapshot.sh not found or not executable${NC}"
    fi
    
    # Step 3: Run bootstrap script
    echo ""
    echo -e "${BLUE}[Step 3/4]${NC} Running bootstrap script..."
    echo "Script: ${SCRIPTS_DIR}/bootstrap/${bootstrap_script}"
    
    # In real usage, this would run the actual bootstrap command
    # export VM_NAME="${vm_name}"
    # "${SCRIPTS_DIR}/bootstrap/${bootstrap_script}"
    
    echo -e "${GREEN}Bootstrap script would run here (demo mode)${NC}"
    echo ""
    echo -e "${YELLOW}Demo mode - would execute:${NC}"
    echo "  ${SCRIPTS_DIR}/bootstrap/${bootstrap_script}"
    echo ""
    
    # Step 4: Offer restore on failure or log snapshot on success
    echo -e "${BLUE}[Step 4/4]${NC} Finalizing..."
    
    local exit_code=$?
    if [[ ${exit_code} -ne 0 ]]; then
        echo -e "${RED}Bootstrap failed! Offering restore from snapshot...${NC}"
        echo "Snapshot: ${snapshot_name}"
        echo "To restore: PROVIDER=\"${provider}\" VM_IDENTIFIER=\"${vm_name}\" \\"
        echo "  ${SNAPSHOT_DIR}/restore-snapshot.sh --snapshot-name=\"${snapshot_name}\""
    else
        echo -e "${GREEN}Bootstrap successful! Snapshot logged for future use.${NC}"
        echo "Snapshot name: ${snapshot_name}"
        echo "You can restore from this snapshot at any time using:"
        echo "  PROVIDER=\"${provider}\" VM_IDENTIFIER=\"${vm_name}\" \\"
        echo "  ${SNAPSHOT_DIR}/restore-snapshot.sh --snapshot-name=\"${snapshot_name}\""
    fi
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Workflow complete!${NC}"
    echo ""
    echo -e "Next steps:"
    echo "  1. Set your provider credentials"
    echo "  2. Re-run: ${0} --provider=${provider} --vm-name=${vm_name}"
    echo "  3. Monitor bootstrap progress"
    echo "  4. Verify VM is accessible via SSH"
    echo ""
}

# Execute main only if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
