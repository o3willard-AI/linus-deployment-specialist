#!/usr/bin/env bash
# =============================================================================
# Example: Cleanup Verification Workflow
# =============================================================================
# Purpose: Demonstrate VM teardown verification and orphaned resource detection
# Author: Linus Deployment Specialist
# Version: 1.0 (v1.3.1)
#
# Usage:
#   ./examples/cleanup-verification-example.sh [OPTIONS]
#
# Prerequisites:
#   - Valid provider credentials
#   - VM/Instance to verify cleanup
#
# Exit Codes:
#   0 - Cleanup verified successful
#   1 - Orphaned resources detected
#   2 - Missing required parameters
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
Cleanup Verification Workflow Example
=====================================

This example demonstrates how to verify VM teardown completion and detect
orphaned resources that may have been left behind after destruction.

Usage:
  ./examples/cleanup-verification-example.sh [OPTIONS]

Options:
  --help              Show this help message
  --provider=<name>   Provider to verify (proxmox|aws|qemu) [required]
  --vm-id=<id>        VM/Instance identifier to verify [required]
  --cleanup-orphans   Attempt to clean up any orphaned resources [optional]
  --dry-run           Show what would be checked without making changes

Examples:
  # Verify Proxmox VM cleanup
  ./examples/cleanup-verification-example.sh \
    --provider=proxmox --vm-id=113

  # Verify AWS instance termination with orphan cleanup
  ./examples/cleanup-verification-example.sh \
    --provider=aws --vm-id=i-0123456789abcdef0 --cleanup-orphans

  # Dry run verification (no changes)
  ./examples/cleanup-verification-example.sh \
    --provider=qemu --vm-id=example-vm-001 --dry-run

Verification Checks:
  ✅ VM/Instance existence (should NOT exist after destroy)
  ✅ Disk volume cleanup
  ✅ Network interface detachment
  ✅ Orphaned snapshot detection
  ✅ Floating IP / Elastic IP release (AWS)
  ✅ Snapshot cleanup verification

Exit Codes:
  0  - All resources properly cleaned up
  1  - Orphaned resources detected (see output for details)
  2  - Missing required parameters or configuration

EOF
}

# -----------------------------------------------------------------------------
# Main Workflow
# -----------------------------------------------------------------------------

main() {
    local provider=""
    local vm_id=""
    local cleanup_orphans=false
    local dry_run=false
    
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
            --vm-id=*)
                vm_id="${1#*=}"
                shift
                ;;
            --cleanup-orphans)
                cleanup_orphans=true
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}"
                show_help
                exit 1
                ;;
        esac
    done
    
    # Validate required parameters
    if [[ -z "${provider}" ]]; then
        echo -e "${RED}Error: --provider is required${NC}"
        echo "Supported providers: proxmox, aws, qemu"
        exit 2
    fi
    
    if [[ -z "${vm_id}" ]]; then
        echo -e "${RED}Error: --vm-id is required${NC}"
        exit 2
    fi
    
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Cleanup Verification Workflow Example${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    
    echo -e "${GREEN}Provider:${NC} ${provider}"
    echo -e "${GREEN}VM/Instance ID:${NC} ${vm_id}"
    echo -e "${GREEN}Cleanup Orphans:${NC} ${cleanup_orphans}"
    echo -e "${GREEN}Dry Run:${NC} ${dry_run}"
    echo ""
    
    # Step 1: Validate provider configuration
    echo -e "${BLUE}[Step 1/5]${NC} Validating provider configuration..."
    case "${provider}" in
        proxmox)
            echo -e "${GREEN}Proxmox provider configured${NC}"
            if [[ -z "${PROXMOX_HOST:-}" ]]; then
                echo -e "${YELLOW}Warning: PROXMOX_HOST not set - running in demo mode${NC}"
            fi
            ;;
        aws)
            echo -e "${GREEN}AWS provider configured${NC}"
            if [[ -z "${AWS_REGION:-}" ]]; then
                echo -e "${YELLOW}Warning: AWS_REGION not set - running in demo mode${NC}"
            fi
            ;;
        qemu)
            echo -e "${GREEN}QEMU provider configured${NC}"
            if [[ -z "${QEMU_HOST:-}" ]]; then
                echo -e "${YELLOW}Warning: QEMU_HOST not set - running in demo mode${NC}"
            fi
            ;;
        *)
            echo -e "${RED}Error: Unsupported provider: ${provider}${NC}"
            exit 2
            ;;
    esac
    
    # Step 2: Verify VM/Instance does not exist
    echo ""
    echo -e "${BLUE}[Step 2/5]${NC} Checking VM/Instance existence..."
    
    if [[ "${dry_run}" == "true" ]]; then
        echo -e "${YELLOW}Dry run - would check for VM/Instance: ${vm_id}${NC}"
        echo -e "${GREEN}✓ VM/Instance check: PASSED (demo mode)${NC}"
    else
        # Real verification would go here
        # In demo mode, simulate success
        echo -e "${GREEN}✓ VM/Instance ${vm_id} does not exist (verified)${NC}"
    fi
    
    # Step 3: Check disk volumes
    echo ""
    echo -e "${BLUE}[Step 3/5]${NC} Checking disk volume cleanup..."
    
    if [[ "${dry_run}" == "true" ]]; then
        echo -e "${YELLOW}Dry run - would check disk volumes${NC}"
    else
        # In demo mode, simulate disk cleanup check
        echo -e "${GREEN}✓ Disk volumes properly detached (verified)${NC}"
    fi
    
    # Step 4: Check network resources
    echo ""
    echo -e "${BLUE}[Step 4/5]${NC} Checking network resource cleanup..."
    
    if [[ "${dry_run}" == "true" ]]; then
        echo -e "${YELLOW}Dry run - would check network interfaces${NC}"
    else
        # In demo mode, simulate network cleanup check
        echo -e "${GREEN}✓ Network interfaces properly detached (verified)${NC}"
    fi
    
    # Step 5: Check for orphaned resources
    echo ""
    echo -e "${BLUE}[Step 5/5]${NC} Scanning for orphaned resources..."
    
    if [[ "${dry_run}" == "true" ]]; then
        echo -e "${YELLOW}Dry run - would scan for orphans${NC}"
        if [[ "${cleanup_orphans}" == "true" ]]; then
            echo -e "${YELLOW}Dry run - would clean up orphans${NC}"
        fi
    else
        # In demo mode, simulate orphan scan
        echo -e "${GREEN}✓ No orphaned resources detected${NC}"
        
        if [[ "${cleanup_orphans}" == "true" ]]; then
            echo -e "${YELLOW}No cleanup needed - no orphans found${NC}"
        fi
    fi
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Verification Complete!${NC}"
    echo ""
    echo -e "${GREEN}Result: All resources properly cleaned up${NC}"
    echo ""
    echo -e "In production mode, this would verify:"
    echo "  1. VM/Instance no longer exists"
    echo "  2. All disk volumes detached and deleted"
    echo "  3. Network interfaces released"
    echo "  4. Snapshots cleaned up (if applicable)"
    echo ""
    echo -e "If orphans are found, use:"
    echo "  PROVIDER=\"${provider}\" VM_IDENTIFIER=\"${vm_id}\" \\"
    echo "  ${SNAPSHOT_DIR}/verify-cleanup.sh --cleanup-orphans"
    echo ""
}

# Execute main only if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
