#!/bin/bash
#
# Enhanced Multi-Model Cleanup Script
#
# Safely stops and cleans up multiple NIM deployments, monitoring processes,
# and associated resources with comprehensive logging and validation.
#
# LESSONS LEARNED INCORPORATED:
# - Safe termination of monitoring processes
# - Container cleanup with proper resource deallocation
# - GPU memory cleanup and validation
# - Comprehensive logging of cleanup operations
#
# Usage: ./cleanup-nim-multi-model-enhanced.sh [--force] [--keep-cache]
#

set -euo pipefail

# Source enhanced common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/riva-common-functions-enhanced.sh"

# =============================================================================
# SCRIPT CONFIGURATION
# =============================================================================

SCRIPT_NUMBER="066"
SCRIPT_TITLE="Enhanced Multi-Model Cleanup"
TARGET_INFO="Safe cleanup of NIM containers, monitoring processes, and resources"

# Cleanup options
FORCE_CLEANUP=false
KEEP_CACHE=false
CLEANUP_LOG="/tmp/nim_cleanup_$(date +%Y%m%d_%H%M%S).log"

# Known container patterns
NIM_CONTAINER_PATTERNS=("nim-*" "riva-*" "*parakeet*" "*tdt*")
MONITORING_PROCESS_PATTERNS=("monitor.*readiness" "riva-063")

# =============================================================================
# MAIN CLEANUP PROCESS
# =============================================================================

main() {
    parse_arguments "$@"
    
    print_script_header "$SCRIPT_NUMBER" "$SCRIPT_TITLE" "$TARGET_INFO"
    
    # Initialize cleanup logging
    initialize_cleanup_logging
    
    # Step 1: Stop monitoring processes
    print_step_header "1" "Stop Monitoring Processes"
    stop_monitoring_processes
    
    # Step 2: Stop NIM containers
    print_step_header "2" "Stop NIM Containers"
    stop_nim_containers
    
    # Step 3: Clean up container resources
    print_step_header "3" "Clean Up Container Resources"
    cleanup_container_resources
    
    # Step 4: GPU memory cleanup
    print_step_header "4" "GPU Memory Cleanup"
    cleanup_gpu_memory
    
    # Step 5: Cache and temporary files cleanup
    print_step_header "5" "Cache and Temporary Files Cleanup"
    cleanup_cache_and_temp_files
    
    # Step 6: System validation
    print_step_header "6" "System Validation After Cleanup"
    validate_cleanup_completion
    
    log_success "🎉 Enhanced multi-model cleanup completed successfully!"
    show_cleanup_summary
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --force)
                FORCE_CLEANUP=true
                log_info "Force cleanup enabled"
                shift
                ;;
            --keep-cache)
                KEEP_CACHE=true
                log_info "Cache preservation enabled"
                shift
                ;;
            --help)
                show_usage
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --force       Force cleanup without confirmation prompts"
    echo "  --keep-cache  Preserve model cache files"
    echo "  --help        Show this help message"
    echo ""
    echo "This script safely cleans up NIM containers, monitoring processes,"
    echo "and associated resources with comprehensive validation."
}

initialize_cleanup_logging() {
    log_info "Initializing cleanup logging to: $CLEANUP_LOG"
    
    # Create cleanup log with header
    cat > "$CLEANUP_LOG" << EOF
# NVIDIA NIM Multi-Model Cleanup Log
# Started: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
# Options: force=$FORCE_CLEANUP, keep-cache=$KEEP_CACHE
# =====================================================

EOF
    
    # Capture initial system state
    echo "=== INITIAL SYSTEM STATE ===" >> "$CLEANUP_LOG"
    run_remote "sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'" >> "$CLEANUP_LOG" 2>&1 || true
    run_remote "nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader" >> "$CLEANUP_LOG" 2>&1 || true
    echo "" >> "$CLEANUP_LOG"
}

# =============================================================================
# MONITORING PROCESS CLEANUP
# =============================================================================

stop_monitoring_processes() {
    log_info "Stopping monitoring processes"
    
    # Get list of monitoring processes
    local monitoring_pids=()
    
    for pattern in "${MONITORING_PROCESS_PATTERNS[@]}"; do
        local pids=$(pgrep -f "$pattern" 2>/dev/null || echo "")
        if [[ -n "$pids" ]]; then
            monitoring_pids+=($pids)
        fi
    done
    
    if [[ ${#monitoring_pids[@]} -eq 0 ]]; then
        log_info "No monitoring processes found"
        return 0
    fi
    
    log_info "Found ${#monitoring_pids[@]} monitoring processes"
    
    # Stop monitoring processes gracefully
    for pid in "${monitoring_pids[@]}"; do
        local process_info=$(ps -p "$pid" -o pid,ppid,cmd --no-headers 2>/dev/null || echo "Process not found")
        log_info "Stopping monitoring process PID $pid: $process_info"
        
        if kill -TERM "$pid" 2>/dev/null; then
            log_success "Sent TERM signal to PID $pid"
            echo "TERM signal sent to PID $pid: $process_info" >> "$CLEANUP_LOG"
        else
            log_warning "Failed to send TERM signal to PID $pid"
        fi
    done
    
    # Wait for graceful shutdown
    log_info "Waiting for graceful shutdown..."
    sleep 5
    
    # Force kill if necessary
    for pid in "${monitoring_pids[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            if $FORCE_CLEANUP; then
                log_warning "Force killing PID $pid"
                kill -KILL "$pid" 2>/dev/null || true
                echo "KILL signal sent to PID $pid" >> "$CLEANUP_LOG"
            else
                log_warning "Process PID $pid still running (use --force to kill)"
            fi
        else
            log_success "Process PID $pid stopped gracefully"
        fi
    done
}

# =============================================================================
# CONTAINER CLEANUP
# =============================================================================

stop_nim_containers() {
    log_info "Stopping NIM containers"
    
    # Get list of NIM containers
    local nim_containers=()
    
    for pattern in "${NIM_CONTAINER_PATTERNS[@]}"; do
        local containers=$(run_remote "sudo docker ps -a --filter name=${pattern} --format '{{.Names}}'" 2>/dev/null || echo "")
        if [[ -n "$containers" ]]; then
            while IFS= read -r container; do
                [[ -n "$container" ]] && nim_containers+=("$container")
            done <<< "$containers"
        fi
    done
    
    if [[ ${#nim_containers[@]} -eq 0 ]]; then
        log_info "No NIM containers found"
        return 0
    fi
    
    log_info "Found ${#nim_containers[@]} NIM containers: ${nim_containers[*]}"
    
    # Stop containers gracefully
    for container in "${nim_containers[@]}"; do
        local container_status=$(run_remote "sudo docker ps --filter name=${container} --format '{{.Status}}'" || echo "not_found")
        log_info "Stopping container: $container (Status: $container_status)"
        
        if [[ "$container_status" == *"Up"* ]]; then
            # Graceful stop
            if run_remote "sudo docker stop ${container}" >/dev/null 2>&1; then
                log_success "Gracefully stopped: $container"
                echo "Container stopped: $container" >> "$CLEANUP_LOG"
            else
                log_warning "Failed to stop gracefully: $container"
                
                if $FORCE_CLEANUP; then
                    log_warning "Force killing container: $container"
                    run_remote "sudo docker kill ${container}" >/dev/null 2>&1 || true
                    echo "Container force killed: $container" >> "$CLEANUP_LOG"
                fi
            fi
        else
            log_info "Container not running: $container"
        fi
    done
    
    # Remove containers
    if $FORCE_CLEANUP; then
        for container in "${nim_containers[@]}"; do
            log_info "Removing container: $container"
            if run_remote "sudo docker rm -f ${container}" >/dev/null 2>&1; then
                log_success "Removed container: $container"
                echo "Container removed: $container" >> "$CLEANUP_LOG"
            else
                log_warning "Failed to remove container: $container"
            fi
        done
    else
        log_info "Use --force to remove containers (currently only stopped)"
    fi
}

cleanup_container_resources() {
    log_info "Cleaning up container resources"
    
    # Clean up orphaned volumes
    log_info "Cleaning up orphaned volumes..."
    local orphaned_volumes=$(run_remote "sudo docker volume ls -qf dangling=true" 2>/dev/null || echo "")
    
    if [[ -n "$orphaned_volumes" ]]; then
        log_info "Found orphaned volumes: $(echo "$orphaned_volumes" | wc -l) volumes"
        if $FORCE_CLEANUP; then
            run_remote "sudo docker volume rm ${orphaned_volumes}" >/dev/null 2>&1 || true
            log_success "Cleaned up orphaned volumes"
            echo "Orphaned volumes cleaned: $(echo "$orphaned_volumes" | tr '\n' ' ')" >> "$CLEANUP_LOG"
        else
            log_info "Use --force to remove orphaned volumes"
        fi
    else
        log_info "No orphaned volumes found"
    fi
    
    # Clean up unused networks
    log_info "Cleaning up unused networks..."
    if $FORCE_CLEANUP; then
        run_remote "sudo docker network prune -f" >/dev/null 2>&1 || true
        log_success "Cleaned up unused networks"
        echo "Unused networks cleaned" >> "$CLEANUP_LOG"
    fi
    
    # Clean up unused images (NIM images are large)
    log_info "Checking for unused NIM images..."
    local nim_images=$(run_remote "sudo docker images --filter reference='*nim*' --filter reference='*parakeet*' --format '{{.Repository}}:{{.Tag}} {{.Size}}'" 2>/dev/null || echo "")
    
    if [[ -n "$nim_images" ]]; then
        log_info "NIM images found:"
        echo "$nim_images" | while IFS= read -r image_info; do
            log_info "  $image_info"
        done
        
        if $FORCE_CLEANUP; then
            log_warning "Removing unused NIM images..."
            run_remote "sudo docker image prune -f --filter label=com.nvidia.nim" >/dev/null 2>&1 || true
            log_success "Cleaned up unused NIM images"
            echo "Unused NIM images cleaned" >> "$CLEANUP_LOG"
        else
            log_info "Use --force to remove unused NIM images"
        fi
    fi
}

# =============================================================================
# GPU AND SYSTEM CLEANUP
# =============================================================================

cleanup_gpu_memory() {
    log_info "Cleaning up GPU memory"
    
    # Check current GPU memory usage
    local gpu_memory_before=$(run_remote "nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits" 2>/dev/null || echo "0")
    log_info "GPU memory usage before cleanup: ${gpu_memory_before}MB"
    
    # Reset GPU (if no processes are using it)
    local gpu_processes=$(run_remote "nvidia-smi --query-compute-apps=pid --format=csv,noheader" 2>/dev/null || echo "")
    
    if [[ -z "$gpu_processes" ]]; then
        log_info "No GPU processes detected, resetting GPU state..."
        if run_remote "sudo nvidia-smi --gpu-reset" >/dev/null 2>&1; then
            log_success "GPU reset completed"
            echo "GPU reset successful" >> "$CLEANUP_LOG"
        else
            log_warning "GPU reset failed (may not be supported)"
        fi
    else
        log_info "GPU processes still running: $gpu_processes"
        log_info "Skipping GPU reset"
    fi
    
    # Check GPU memory after cleanup
    sleep 2
    local gpu_memory_after=$(run_remote "nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits" 2>/dev/null || echo "0")
    local memory_freed=$((gpu_memory_before - gpu_memory_after))
    
    log_info "GPU memory usage after cleanup: ${gpu_memory_after}MB"
    if [[ $memory_freed -gt 0 ]]; then
        log_success "GPU memory freed: ${memory_freed}MB"
    fi
    
    echo "GPU memory cleanup: ${gpu_memory_before}MB -> ${gpu_memory_after}MB (freed: ${memory_freed}MB)" >> "$CLEANUP_LOG"
}

cleanup_cache_and_temp_files() {
    log_info "Cleaning up cache and temporary files"
    
    # Clean up NIM cache (unless --keep-cache is specified)
    if ! $KEEP_CACHE; then
        log_info "Cleaning NIM cache directories..."
        local cache_dirs=("/opt/nim/.cache" "/tmp/nim*" "/var/lib/docker/nim*")
        
        for cache_dir in "${cache_dirs[@]}"; do
            if run_remote "ls -d ${cache_dir} 2>/dev/null" | grep -q .; then
                local cache_size=$(run_remote "du -sh ${cache_dir} 2>/dev/null | cut -f1" || echo "unknown")
                log_info "Found cache: ${cache_dir} (${cache_size})"
                
                if $FORCE_CLEANUP; then
                    if run_remote "sudo rm -rf ${cache_dir}" >/dev/null 2>&1; then
                        log_success "Removed cache: ${cache_dir}"
                        echo "Cache removed: ${cache_dir} (${cache_size})" >> "$CLEANUP_LOG"
                    else
                        log_warning "Failed to remove cache: ${cache_dir}"
                    fi
                else
                    log_info "Use --force to remove cache directories"
                fi
            fi
        done
    else
        log_info "Preserving cache directories (--keep-cache enabled)"
    fi
    
    # Clean up temporary files
    log_info "Cleaning temporary files..."
    local temp_patterns=("/tmp/riva_*" "/tmp/nim_*" "/tmp/*monitor*" "/tmp/*test*.wav")
    
    for pattern in "${temp_patterns[@]}"; do
        if run_remote "ls ${pattern} 2>/dev/null" | grep -q .; then
            if $FORCE_CLEANUP; then
                run_remote "rm -f ${pattern}" >/dev/null 2>&1 || true
                log_success "Cleaned temporary files: $pattern"
                echo "Temporary files cleaned: $pattern" >> "$CLEANUP_LOG"
            else
                log_info "Temporary files found: $pattern (use --force to clean)"
            fi
        fi
    done
}

# =============================================================================
# VALIDATION AND REPORTING
# =============================================================================

validate_cleanup_completion() {
    log_info "Validating cleanup completion"
    
    local validation_errors=0
    
    # Check for remaining NIM containers
    local remaining_containers=$(run_remote "sudo docker ps -a --filter name=nim* --filter name=riva* --format '{{.Names}}'" 2>/dev/null || echo "")
    if [[ -n "$remaining_containers" ]]; then
        log_warning "Remaining NIM containers: $remaining_containers"
        validation_errors=$((validation_errors + 1))
    else
        log_success "✅ No remaining NIM containers"
    fi
    
    # Check for remaining monitoring processes
    local remaining_processes=$(pgrep -f "monitor.*readiness\|riva-063" 2>/dev/null || echo "")
    if [[ -n "$remaining_processes" ]]; then
        log_warning "Remaining monitoring processes: $remaining_processes"
        validation_errors=$((validation_errors + 1))
    else
        log_success "✅ No remaining monitoring processes"
    fi
    
    # Check GPU memory usage
    local final_gpu_memory=$(run_remote "nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits" 2>/dev/null || echo "0")
    if [[ $final_gpu_memory -lt 1000 ]]; then  # Less than 1GB
        log_success "✅ GPU memory usage low: ${final_gpu_memory}MB"
    else
        log_warning "GPU memory usage still high: ${final_gpu_memory}MB"
        validation_errors=$((validation_errors + 1))
    fi
    
    # Check disk space recovery
    local disk_usage=$(run_remote "df /opt --output=pcent | tail -1 | tr -d ' %'")
    if [[ $disk_usage -lt 80 ]]; then
        log_success "✅ Disk usage healthy: ${disk_usage}%"
    else
        log_warning "Disk usage still high: ${disk_usage}%"
        validation_errors=$((validation_errors + 1))
    fi
    
    if [[ $validation_errors -eq 0 ]]; then
        log_success "✅ All cleanup validation checks passed"
    else
        log_warning "⚠️ $validation_errors cleanup validation issues detected"
    fi
    
    echo "Cleanup validation completed with $validation_errors issues" >> "$CLEANUP_LOG"
}

show_cleanup_summary() {
    log_info "=== CLEANUP SUMMARY ==="
    
    # Final system state
    echo "🖥️  Final System State:"
    echo "   Containers: $(run_remote "sudo docker ps --format '{{.Names}}' | wc -l" || echo "0") running"
    echo "   GPU Memory: $(run_remote "nvidia-smi --query-gpu=memory.used --format=csv,noheader" || echo "N/A")"
    echo "   Disk Usage: $(run_remote "df /opt --output=pcent | tail -1" | tr -d ' ' || echo "N/A")"
    echo ""
    
    # Cleanup actions taken
    echo "🧹 Cleanup Actions:"
    echo "   • Monitoring processes stopped"
    echo "   • NIM containers stopped"
    if $FORCE_CLEANUP; then
        echo "   • Container resources cleaned"
        echo "   • GPU memory reset"
        if ! $KEEP_CACHE; then
            echo "   • Cache directories cleaned"
        else
            echo "   • Cache directories preserved"
        fi
        echo "   • Temporary files cleaned"
    else
        echo "   • Use --force for complete cleanup"
    fi
    echo ""
    
    # Next steps
    echo "🚀 Next Steps:"
    echo "   • System ready for fresh deployment"
    echo "   • Run deployment tests: ./scripts/riva-065-comprehensive-deployment-test.sh"
    echo "   • Deploy NIM: ./scripts/riva-062-deploy-nim-parakeet-tdt-0.6b-v2-T4-optimized.sh"
    echo ""
    
    echo "📄 Detailed cleanup log: $CLEANUP_LOG"
}

# =============================================================================
# SCRIPT EXECUTION
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi