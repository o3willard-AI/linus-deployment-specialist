#!/usr/bin/env bash
# =============================================================================
# Linus Deployment Specialist - Resource Monitoring Script
# =============================================================================
# Purpose: Monitor CPU, memory, and disk usage during bootstrap operations
# Author: Linus Deployment Specialist (AI-generated)
# Version: 1.0
# Automation Level: 2
#
# This script:
# 1. Monitors resource usage at configurable intervals
# 2. Detects when bootstrap operations are complete (resource usage drops)
# 3. Provides visibility into bootstrap performance
# 4. Can detect performance bottlenecks
#
# Usage:
#   ./monitor-resource.sh [options]
#
# Example:
#   # Monitor for 300 seconds, report every 10 seconds
#   ./monitor-resource.sh --timeout 300 --interval 10
#
# Exit Codes:
#   0 - Monitoring complete (bootstrap finished)
#   1 - Timeout reached (bootstrap still running)
#   2 - Invalid configuration
#   3 - Monitoring error
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

# Monitoring configuration
readonly DEFAULT_TIMEOUT="${DEFAULT_TIMEOUT:-300}"
readonly DEFAULT_INTERVAL="${DEFAULT_INTERVAL:-10}"
readonly DEFAULT_LOG_DIR="${DEFAULT_LOG_DIR:-/tmp/linus-monitor}"

# Runtime variables (set from command line or defaults)
MONITOR_TIMEOUT="${MONITOR_TIMEOUT:-${DEFAULT_TIMEOUT}}"
MONITOR_INTERVAL="${MONITOR_INTERVAL:-${DEFAULT_INTERVAL}}"
LOG_DIR="${LOG_DIR:-${DEFAULT_LOG_DIR}}"

# State tracking
BOOTSTRAP_STARTED=false
LAST_CPU_USAGE=0
LAST_MEM_USAGE=0
LAST_DISK_IO=0
PEAK_CPU=0
PEAK_MEM=0
PEAK_DISK=0
BOOTSTRAP_ACTIVITY_COUNT=0

# -----------------------------------------------------------------------------
# Functions
# -----------------------------------------------------------------------------

function show_help() {
    cat << EOF
Linus Deployment Specialist - Resource Monitoring Script
=========================================================
Purpose: Monitor CPU, memory, and disk usage during bootstrap

Usage:
  ${SCRIPT_NAME} [options]

Options:
  --timeout, -t SECONDS    Maximum monitoring duration (default: ${DEFAULT_TIMEOUT})
  --interval, -i SECONDS   Sampling interval (default: ${DEFAULT_INTERVAL})
  --log-dir, -l PATH       Log directory (default: ${DEFAULT_LOG_DIR})
  --detect-activity        Auto-detect bootstrap completion (default: true)
  --report-only            Only generate report, don't monitor

Examples:
  # Monitor for 300 seconds with 10-second intervals
  ${SCRIPT_NAME} --timeout 300 --interval 10
  
  # Quick monitoring for 60 seconds
  ${SCRIPT_NAME} -t 60 -i 5
  
  # Continuous monitoring until activity stops
  ${SCRIPT_NAME} --timeout 600

Output:
  - Real-time resource usage to stdout
  - Detailed CSV log in ${LOG_DIR}/monitor-*.csv
  - Summary report at end
  - Auto-detects when bootstrap completes

Exit Codes:
  0 - Monitoring complete (bootstrap finished)
  1 - Timeout reached (bootstrap still running)
  2 - Invalid configuration
  3 - Monitoring error

EOF
}

function get_cpu_usage() {
    # Get CPU usage from /proc/stat
    local cpu_line1 cpu_line2
    local user1 nice1 system1 idle1 iowait1 irq1 softirq1 steal1
    local user2 nice2 system2 idle2 iowait2 irq2 softirq2 steal2
    local total1 total2 idle_total1 idle_total2
    
    cpu_line1=$(head -1 /proc/stat)
    sleep 0.1
    cpu_line2=$(head -1 /proc/stat)
    
    read -r _ user1 nice1 system1 idle1 iowait1 irq1 softirq1 steal1 _ <<< "${cpu_line1}"
    read -r _ user2 nice2 system2 idle2 iowait2 irq2 softirq2 steal2 _ <<< "${cpu_line2}"
    
    total1=$((user1 + nice1 + system1 + idle1 + iowait1 + irq1 + softirq1 + steal1))
    total2=$((user2 + nice2 + system2 + idle2 + iowait2 + irq2 + softirq2 + steal2))
    
    idle_total1=$((idle1 + iowait1))
    idle_total2=$((idle2 + iowait2))
    
    local cpu_usage=0
    if [[ $total2 -gt $total1 ]]; then
        local active_diff=$((total2 - total1 - idle_total2 + idle_total1))
        local total_diff=$((total2 - total1))
        if [[ $total_diff -gt 0 ]]; then
            cpu_usage=$((100 * active_diff / total_diff))
        fi
    fi
    
    echo ${cpu_usage}
}

function get_memory_usage() {
    # Get memory usage from /proc/meminfo
    local mem_total mem_available
    
    mem_total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    mem_available=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    
    if [[ -z "${mem_available}" ]]; then
        # Fallback for older kernels
        local mem_free buffers cached
        mem_free=$(grep MemFree /proc/meminfo | awk '{print $2}')
        buffers=$(grep Buffers /proc/meminfo | awk '{print $2}')
        cached=$(grep "^Cached:" /proc/meminfo | awk '{print $2}')
        mem_available=$((mem_free + buffers + cached))
    fi
    
    local mem_used=$((mem_total - mem_available))
    local mem_percent=0
    if [[ $mem_total -gt 0 ]]; then
        mem_percent=$((100 * mem_used / mem_total))
    fi
    
    echo ${mem_percent}
}

function get_disk_io() {
    # Get disk I/O from /proc/diskstats
    local disk_io=0
    
    if [[ -f /proc/diskstats ]]; then
        # Sum all read + write sectors for all disks
        while read -r major minor name reads_merged sectors_read time_read writes_merged sectors_written time_written; do
            if [[ "$name" =~ ^[sv]d[a-z]$ ]] || [[ "$name" =~ ^nvme[0-9]+n[0-9]+$ ]]; then
                local sector_size=512
                local read_bytes=$((sectors_read * sector_size))
                local write_bytes=$((sectors_written * sector_size))
                disk_io=$((disk_io + read_bytes + write_bytes))
            fi
        done < /proc/diskstats
    fi
    
    echo ${disk_io}
}

function log_resources() {
    local timestamp cpu mem disk
    timestamp=$(date +%Y-%m-%dT%H:%M:%SZ)
    cpu=$(get_cpu_usage)
    mem=$(get_memory_usage)
    disk=$(get_disk_io)
    
    # Update peaks
    [[ $cpu -gt $PEAK_CPU ]] && PEAK_CPU=$cpu
    [[ $mem -gt $PEAK_MEM ]] && PEAK_MEM=$mem
    [[ $disk -gt $PEAK_DISK ]] && PEAK_DISK=$disk
    
    # Log to file
    local log_file="${LOG_DIR}/monitor-$(date +%Y%m%d-%H%M%S).csv"
    echo "timestamp,cpu_percent,memory_percent,disk_io_bytes,activity" >> "${log_file}"
    echo "${timestamp},${cpu},${mem},${disk},$((cpu > 50 || mem > 70 || disk > $((LAST_DISK_IO + 100000000))))" >> "${log_file}"
    
    # Update last values
    LAST_CPU_USAGE=$cpu
    LAST_MEM_USAGE=$mem
    LAST_DISK_IO=$disk
    
    # Increment activity count if significant
    if [[ $cpu -gt 50 ]] || [[ $mem -gt 70 ]]; then
        ((BOOTSTRAP_ACTIVITY_COUNT++))
    fi
    
    # Print to stdout
    printf "%s | CPU: %3d%% | MEM: %3d%% | DISK_IO: %12d bytes | Activity: %s\n" \
        "${timestamp}" \
        "${cpu}" \
        "${mem}" \
        "${disk}" \
        "$([ $cpu -gt 50 ] || [ $mem -gt 70 ] && echo "HIGH" || echo "NORMAL")"
}

function check_bootstrap_complete() {
    local threshold_seconds="${1:-180}"
    local recent_activity="${2:-0}"
    
    # Check if no activity for threshold seconds
    if [[ $recent_activity -eq 0 ]] && [[ $BOOTSTRAP_ACTIVITY_COUNT -lt 3 ]]; then
        return 0  # Bootstrap likely complete
    fi
    
    return 1  # Bootstrap still running
}

function start_activity_tracker() {
    # Run bootstrap command in background and monitor activity
    local bootstrap_command="$1"
    
    log_info "Starting bootstrap command: ${bootstrap_command}"
    
    # Run bootstrap and capture output
    local bootstrap_output
    if ! bootstrap_output=$(${bootstrap_command} 2>&1); then
        local exit_code=$?
        log_error "Bootstrap failed with exit code: ${exit_code}"
        echo "LINUS_BOOTSTRAP_EXIT:${exit_code}"
        return ${exit_code}
    fi
    
    echo "${bootstrap_output}"
    echo "LINUS_BOOTSTRAP_EXIT:0"
    
    return 0
}

function generate_report() {
    local timeout_reached="$1"
    
    echo ""
    echo "=========================================="
    echo "Resource Monitoring Report"
    echo "=========================================="
    echo "Timestamp:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Timeout:      ${MONITOR_TIMEOUT}s"
    echo "Interval:     ${MONITOR_INTERVAL}s"
    echo "Timeout Used: $([ "$timeout_reached" == "true" ] && echo 'Yes' || echo 'No')"
    echo ""
    echo "Peak Resource Usage:"
    echo "  CPU:     ${PEAK_CPU}%"
    echo "  Memory:  ${PEAK_MEM}%"
    echo "  Disk IO: ${PEAK_DISK} bytes"
    echo ""
    echo "Activity Summary:"
    echo "  Activity Samples: ${BOOTSTRAP_ACTIVITY_COUNT}"
    echo ""
    echo "Log Files:"
    ls -la "${LOG_DIR}"/monitor-*.csv 2>/dev/null || echo "  No log files found"
    echo "=========================================="
    
    # Output structured results
    echo ""
    echo "LINUS_MONITOR_COMPLETE:$( [ "$timeout_reached" == "true" ] && echo 'TIMEOUT' || echo 'SUCCESS' )"
    echo "LINUS_MONITOR_PEAK_CPU:${PEAK_CPU}"
    echo "LINUS_MONITOR_PEAK_MEM:${PEAK_MEM}"
    echo "LINUS_MONITOR_PEAK_DISK:${PEAK_DISK}"
    echo "LINUS_MONITOR_ACTIVITY:${BOOTSTRAP_ACTIVITY_COUNT}"
    echo "LINUS_MONITOR_TIMEOUT:${MONITOR_TIMEOUT}"
    echo "LINUS_MONITOR_INTERVAL:${MONITOR_INTERVAL}"
    echo "LINUS_MONITOR_LOG_DIR:${LOG_DIR}"
}

# -----------------------------------------------------------------------------
# Main Execution
# -----------------------------------------------------------------------------

main() {
    local timeout_reached=false
    
    # Check for help
    if [[ $# -gt 0 ]] && [[ "$1" == "--help" || "$1" == "-h" ]]; then
        show_help
        exit 0
    fi
    
    # Parse command line options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --timeout|-t)
                MONITOR_TIMEOUT="$2"
                shift 2
                ;;
            --interval|-i)
                MONITOR_INTERVAL="$2"
                shift 2
                ;;
            --log-dir|-l)
                LOG_DIR="$2"
                shift 2
                ;;
            --report-only)
                generate_report "true"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 2
                ;;
        esac
    done
    
    log_header "Resource Monitor"
    log_info "Timeout: ${MONITOR_TIMEOUT}s, Interval: ${MONITOR_INTERVAL}s"
    
    # Create log directory
    mkdir -p "${LOG_DIR}"
    
    echo ""
    log_info "Starting resource monitoring..."
    log_info "Press Ctrl+C to stop early (will generate partial report)"
    echo ""
    
    local elapsed=0
    local last_activity_count=0
    local consecutive_idle=0
    local max_idle_threshold=3  # 3 intervals of idle = 30 seconds (default)
    
    trap 'echo ""; log_info "Monitoring interrupted, generating report..."; timeout_reached=true; generate_report "true"; exit 0' INT TERM
    
    # Monitoring loop
    while [[ $elapsed -lt $MONITOR_TIMEOUT ]]; do
        # Log current resources
        log_resources
        
        # Check for bootstrap completion (3 consecutive idle intervals)
        if [[ $BOOTSTRAP_ACTIVITY_COUNT -eq $last_activity_count ]]; then
            ((consecutive_idle++))
            if [[ $consecutive_idle -ge $max_idle_threshold ]]; then
                log_info "Bootstrap appears complete (no activity for ${((consecutive_idle * MONITOR_INTERVAL))}s)"
                break
            fi
        else
            consecutive_idle=0
            last_activity_count=$BOOTSTRAP_ACTIVITY_COUNT
        fi
        
        ((elapsed += MONITOR_INTERVAL))
        sleep ${MONITOR_INTERVAL}
    done
    
    # Check if timeout was reached
    if [[ $elapsed -ge $MONITOR_TIMEOUT ]]; then
        timeout_reached=true
        log_warn "Monitoring timeout reached after ${MONITOR_TIMEOUT}s"
    else
        log_info "Monitoring completed successfully after ${elapsed}s"
    fi
    
    # Generate final report
    generate_report "${timeout_reached}"
    
    # Return appropriate exit code
    if [[ "$timeout_reached" == "true" ]]; then
        exit 1
    fi
    exit 0
}

# Execute main only if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
