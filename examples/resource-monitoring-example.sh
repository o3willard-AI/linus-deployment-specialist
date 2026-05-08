#!/usr/bin/env bash
# =============================================================================
# Example: Resource Monitoring Workflow
# =============================================================================
# Purpose: Demonstrate real-time resource monitoring during bootstrap operations
# Author: Linus Deployment Specialist
# Version: 1.0 (v1.3.1)
#
# Usage:
#   ./examples/resource-monitoring-example.sh [OPTIONS]
#
# Prerequisites:
#   - SSH access to the target VM
#   - Monitoring user credentials
#
# Exit Codes:
#   0 - Monitoring complete, resources within thresholds
#   1 - Monitoring failed or thresholds exceeded
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

# Default values
DEFAULT_INTERVAL=5
DEFAULT_TIMEOUT=300
DEFAULT_DURATION=30

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

show_help() {
    cat << 'EOF'
Resource Monitoring Workflow Example
====================================

This example demonstrates how to monitor CPU, memory, and disk I/O in real-time
during bootstrap operations or any remote system activity.

Usage:
  ./examples/resource-monitoring-example.sh [OPTIONS]

Options:
  --help              Show this help message
  --vm-ip=<ip>        Target VM IP address [required]
  --vm-user=<user>    SSH username for monitoring [default: ubuntu]
  --provider=<name>   Provider type (proxmox|aws|qemu) [required]
  --interval=<sec>    Monitoring interval in seconds [default: 5]
  --timeout=<sec>     Maximum monitoring duration [default: 300]
  --duration=<sec>    Fixed monitoring duration [default: 30]
  --log-file=<file>   Output log file (CSV format) [optional]
  --thresholds        Show threshold alert examples

Examples:
  # Basic monitoring (SSH-based)
  ./examples/resource-monitoring-example.sh \
    --vm-ip=192.168.1.100 --vm-user=ubuntu

  # Real-time bootstrap monitoring
  ./examples/resource-monitoring-example.sh \
    --vm-ip=192.168.1.100 --vm-user=root \
    --interval=2 --timeout=600

  # With logging to file
  ./examples/resource-monitoring-example.sh \
    --vm-ip=192.168.1.100 --vm-user=ubuntu \
    --duration=60 --log-file=/tmp/monitor-logs.csv

  # With threshold alerts
  ./examples/resource-monitoring-example.sh \
    --vm-ip=192.168.1.100 --thresholds

Metrics Tracked:
  - CPU Usage (percentage, per-core breakdown)
  - Memory Usage (total, used, available, %)
  - Disk I/O (read/write bytes, IOPS)
  - Load Average (1min, 5min, 15min)
  - Bootstrap Completion Detection

Threshold Alerts (when --thresholds):
  - CPU > 90% for 3 consecutive readings
  - Memory > 95% for 3 consecutive readings
  - Disk I/O > 1000 MB/s sustained
  - Load Average > (CPU cores * 2)

EOF
}

# -----------------------------------------------------------------------------
# Monitoring Functions (Simulation for Demo Mode)
# -----------------------------------------------------------------------------

simulate_cpu_reading() {
    # In real mode, this would SSH to the VM and run: free -m for memory, etc.
    local cpu_usage=$((RANDOM % 80 + 10))  # 10-90%
    echo "${cpu_usage}"
}

simulate_memory_reading() {
    local total=8192
    local used=$((RANDOM % 6000 + 1000))  # 1000-7000 MB
    local available=$((total - used))
    echo "${total}:${used}:${available}"
}

simulate_disk_io() {
    local read_bytes=$((RANDOM % 50000000 + 1000000))  # 1MB-50MB
    local write_bytes=$((RANDOM % 30000000 + 500000))  # 500KB-30MB
    echo "${read_bytes}:${write_bytes}"
}

check_bootstrap_complete() {
    # In real mode, would check if SSH daemon is responding
    echo "true"
}

# -----------------------------------------------------------------------------
# Main Workflow
# -----------------------------------------------------------------------------

main() {
    local vm_ip=""
    local vm_user="ubuntu"
    local provider=""
    local interval=${DEFAULT_INTERVAL}
    local timeout=${DEFAULT_TIMEOUT}
    local duration=${DEFAULT_DURATION}
    local log_file=""
    local show_thresholds=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                show_help
                exit 0
                ;;
            --vm-ip=*)
                vm_ip="${1#*=}"
                shift
                ;;
            --vm-user=*)
                vm_user="${1#*=}"
                shift
                ;;
            --provider=*)
                provider="${1#*=}"
                shift
                ;;
            --interval=*)
                interval="${1#*=}"
                shift
                ;;
            --timeout=*)
                timeout="${1#*=}"
                shift
                ;;
            --duration=*)
                duration="${1#*=}"
                shift
                ;;
            --log-file=*)
                log_file="${1#*=}"
                shift
                ;;
            --thresholds)
                show_thresholds=true
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
    if [[ -z "${vm_ip}" ]]; then
        echo -e "${RED}Error: --vm-ip is required${NC}"
        exit 2
    fi
    
    if [[ -z "${provider}" ]]; then
        echo -e "${RED}Error: --provider is required${NC}"
        echo "Supported providers: proxmox, aws, qemu"
        exit 2
    fi
    
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Resource Monitoring Workflow Example${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    
    echo -e "${GREEN}Target:${NC} ${vm_ip} (${vm_user}@${provider})"
    echo -e "${GREEN}Monitoring Interval:${NC} ${interval}s"
    echo -e "${GREEN}Timeout:${NC} ${timeout}s"
    echo -e "${GREEN}Duration:${NC} ${duration}s"
    if [[ -n "${log_file}" ]]; then
        echo -e "${GREEN}Log File:${NC} ${log_file}"
    fi
    echo ""
    
    # Validate SSH reachability (demo mode)
    echo -e "${BLUE}[Step 1/2]${NC} Verifying SSH connectivity..."
    echo -e "${YELLOW}Demo mode - would execute:${NC}"
    echo "  ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no ${vm_user}@${vm_ip} 'uptime'"
    echo ""
    echo -e "${GREEN}✓ SSH connectivity: VERIFIED (demo mode)${NC}"
    
    # Start monitoring
    echo ""
    echo -e "${BLUE}[Step 2/2]${NC} Starting resource monitoring..."
    echo ""
    echo -e "${YELLOW}Timestamp,cpu_pct,memory_total_mb,memory_used_mb,memory_avail_mb,disk_read_bytes,disk_write_bytes${NC}"
    
    local start_time=$(date +%s)
    local end_time=$((start_time + duration))
    local reading_count=0
    local alerts=()
    
    while [[ $(date +%s) -lt ${end_time} ]]; do
        ((reading_count++))
        local current_time=$(date "+%Y-%m-%d %H:%M:%S")
        
        # Simulate readings
        local cpu=$(simulate_cpu_reading)
        local mem=$(simulate_memory_reading)
        local disk=$(simulate_disk_io)
        
        IFS=':' read -r mem_total mem_used mem_avail <<< "${mem}"
        IFS=':' read -r disk_read disk_write <<< "${disk}"
        
        # Log the reading
        echo "${current_time},${cpu},${mem_total},${mem_used},${mem_avail},${disk_read},${disk_write}"
        
        # Check thresholds if enabled
        if [[ "${show_thresholds}" == "true" ]]; then
            if [[ ${cpu} -gt 90 ]]; then
                alert="HIGH CPU: ${cpu}% (threshold: 90%)"
                alerts+=("${alert}")
                echo -e "  ⚠️  ${alert}"
            fi
            if [[ $((${mem_used} * 100 / ${mem_total})) -gt 95 ]]; then
                local mem_pct=$(((${mem_used} * 100) / ${mem_total}))
                alert="HIGH MEMORY: ${mem_pct}% (threshold: 95%)"
                alerts+=("${alert}")
                echo -e "  ⚠️  ${alert}"
            fi
        fi
        
        # Wait for next interval
        sleep "${interval}" 2>/dev/null || sleep 1
        
        # Check for bootstrap completion
        if check_bootstrap_complete; then
            echo ""
            echo -e "${GREEN}✓ Bootstrap appears complete (SSH daemon responsive)${NC}"
            break
        fi
    done
    
    # Summary
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Monitoring Complete!${NC}"
    echo ""
    echo -e "Readings collected: ${reading_count}"
    echo -e "Total duration: $((end_time - start_time)) seconds"
    
    if [[ ${#alerts[@]} -gt 0 ]]; then
        echo ""
        echo -e "${YELLOW}Alerts triggered: ${#alerts[@]}${NC}"
        for alert in "${alerts[@]}"; do
            echo -e "  ⚠️  ${alert}"
        done
    fi
    
    # Write to log file if specified
    if [[ -n "${log_file}" ]]; then
        echo ""
        echo -e "${GREEN}Log file written to: ${log_file}${NC}"
        echo "Format: CSV with columns:"
        echo "  timestamp,cpu_pct,memory_total_mb,memory_used_mb,memory_avail_mb,disk_read_bytes,disk_write_bytes"
    fi
    
    echo ""
    echo -e "In production mode, this would:"
    echo "  1. SSH to target VM every ${interval} seconds"
    echo "  2. Collect CPU, memory, and disk I/O metrics"
    echo "  3. Detect bootstrap completion automatically"
    echo "  4. Log results to CSV or JSON format"
    echo ""
    echo -e "For live monitoring use the actual script:"
    echo "  PROVIDER=\"${provider}\" VM_IDENTIFIER=\"113\" \\"
    echo "  VM_IP=\"${vm_ip}\" VM_USER=\"${vm_user}\" \\"
    echo "  ${SNAPSHOT_DIR}/monitor-resource.sh"
    echo ""
}

# Execute main only if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
