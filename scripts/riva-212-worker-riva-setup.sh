#!/bin/bash
#
# RIVA-212-WORKER-RIVA-SETUP: Ensure RIVA Server is Running on Worker Instances
#
# Purpose: Verify or start RIVA server on GPU worker instances before gRPC verification
# Prerequisites: Python virtual environment (riva-210) completed, worker instances configured
# Outputs: RIVA server status, port accessibility, service readiness confirmation
#

# Source common functions
source "$(dirname "$0")/riva-2xx-common.sh"

# Initialize script
init_script

# =============================================================================
# MAIN WORKER RIVA SETUP
# =============================================================================

main() {
    log_info "🤖 Ensuring RIVA Server is Running on Worker Instances"

    # Load configuration
    load_config

    # Validate required environment variables
    validate_env_vars "RIVA_HOST" "RIVA_PORT" "SSH_KEY_NAME"

    # Check if already completed
    if check_step_completion; then
        log_info "Worker RIVA setup already completed, continuing for verification..."
    fi

    # Step 1: Test worker connectivity
    test_worker_connectivity

    # Step 2: Check current RIVA status
    check_riva_status

    # Step 3: Ensure RIVA server is running
    ensure_riva_running

    # Step 4: Verify port accessibility
    verify_port_access

    # Step 5: Test basic gRPC connectivity
    test_basic_grpc

    # Step 6: Generate worker status report
    generate_worker_report

    # Save configuration snapshot
    save_config_snapshot

    # Mark completion
    mark_step_complete "RIVA server verified running on worker instances"

    # Print next step
    print_next_step "./scripts/riva-215-verify-riva-grpc.sh" "Verify gRPC connectivity and service discovery"
}

# =============================================================================
# WORKER SETUP FUNCTIONS
# =============================================================================

test_worker_connectivity() {
    log_info "🌐 Testing worker connectivity..."

    if test_worker_ssh; then
        log_success "✅ SSH connectivity to worker confirmed"
        log_json "worker_ssh_ok" "SSH connectivity successful" "{\"worker_host\": \"$RIVA_HOST\"}"
    else
        log_error "❌ Cannot establish SSH connection to worker"
        log_error "   Please check SSH_KEY_NAME and RIVA_HOST configuration"
        exit 1
    fi
}

check_riva_status() {
    log_info "🔍 Checking current RIVA status on worker..."

    # Check for running containers
    local container_status
    container_status="$(execute_on_worker "docker ps --filter ancestor=*riva* --format 'table {{.Names}}\\t{{.Status}}\\t{{.Ports}}'" 2>/dev/null || echo "No containers found")"

    if [[ "$container_status" == *"riva"* ]]; then
        log_success "✅ RIVA containers found running"
        log_info "Container status:"
        echo "$container_status" | while read line; do
            [[ -n "$line" ]] && log_info "  $line"
        done

        # Check if port is listening
        local port_status
        port_status="$(execute_on_worker "ss -tlnp | grep :$RIVA_PORT || echo 'Port not listening'")"

        if [[ "$port_status" != "Port not listening" ]]; then
            log_success "✅ RIVA server listening on port $RIVA_PORT"
            log_json "riva_server_running" "RIVA server confirmed running" "{\"host\": \"$RIVA_HOST\", \"port\": \"$RIVA_PORT\", \"container_status\": \"running\"}"
            return 0
        else
            log_warning "⚠️ RIVA containers running but port $RIVA_PORT not listening"
        fi
    else
        log_info "No RIVA containers currently running"
    fi

    # Check for native RIVA process
    local process_status
    process_status="$(execute_on_worker "pgrep -f riva || echo 'No riva process found'")"

    if [[ "$process_status" != "No riva process found" ]]; then
        log_info "Native RIVA process found: $process_status"
    else
        log_info "No native RIVA process found"
    fi

    log_json "riva_status_checked" "RIVA status checked on worker" "{\"container_status\": \"$container_status\", \"process_status\": \"$process_status\"}"
    return 1
}

ensure_riva_running() {
    log_info "🚀 Ensuring RIVA server is running..."

    # If RIVA is already running and accessible, skip
    if check_riva_status && check_port "$RIVA_HOST" "$RIVA_PORT" 10; then
        log_success "✅ RIVA server already running and accessible"
        return 0
    fi

    log_info "RIVA server not fully accessible, checking deployment options..."

    # Check if we have deployment scripts available
    local deployment_scripts=(
        "./scripts/riva-070-setup-traditional-riva-server.sh"
        "./scripts/riva-080-deployment-s3-microservices.sh"
    )

    local available_script=""
    for script in "${deployment_scripts[@]}"; do
        if [[ -x "$script" ]]; then
            available_script="$script"
            break
        fi
    done

    if [[ -n "$available_script" ]]; then
        log_info "Found deployment script: $available_script"

        # Check if script is already running
        if pgrep -f "$(basename "$available_script")" >/dev/null; then
            log_info "Deployment script already running, waiting for completion..."
            wait_for_riva_deployment
        else
            log_info "Starting RIVA deployment..."
            "$available_script" &
            wait_for_riva_deployment
        fi
    else
        log_warning "⚠️ No deployment scripts found, attempting manual RIVA startup..."
        attempt_manual_riva_startup
    fi
}

wait_for_riva_deployment() {
    log_info "⏳ Waiting for RIVA deployment to complete..."

    local max_wait=1800  # 30 minutes
    local wait_time=0
    local check_interval=30

    while [[ $wait_time -lt $max_wait ]]; do
        log_info "Checking RIVA status... (${wait_time}/${max_wait}s)"

        # Check if RIVA is now accessible
        if check_port "$RIVA_HOST" "$RIVA_PORT" 10; then
            log_success "✅ RIVA server is now accessible"
            return 0
        fi

        # Check deployment script status
        if ! pgrep -f "riva-.*-.*\.sh" >/dev/null; then
            log_info "Deployment scripts have completed"

            # Give RIVA a moment to fully start
            log_info "Waiting for RIVA server to initialize..."
            sleep 60

            if check_port "$RIVA_HOST" "$RIVA_PORT" 10; then
                log_success "✅ RIVA server is now accessible"
                return 0
            else
                log_warning "⚠️ Deployment completed but RIVA not accessible"
                break
            fi
        fi

        sleep $check_interval
        wait_time=$((wait_time + check_interval))
    done

    log_error "❌ Timeout waiting for RIVA deployment"
    return 1
}

attempt_manual_riva_startup() {
    log_info "🔧 Attempting manual RIVA startup..."

    # Check if RIVA images are available
    local riva_images
    riva_images="$(execute_on_worker "docker images | grep riva || echo 'No RIVA images found'")"

    if [[ "$riva_images" == "No RIVA images found" ]]; then
        log_error "❌ No RIVA Docker images found on worker"
        log_error "   Please run a RIVA deployment script first"
        return 1
    fi

    log_info "Available RIVA images:"
    echo "$riva_images" | while read line; do
        [[ -n "$line" ]] && log_info "  $line"
    done

    # Try to start RIVA with the most common configuration
    log_info "Attempting to start RIVA server..."

    local start_command
    if [[ "$riva_images" == *"riva-speech"* ]]; then
        start_command="docker run -d --name riva-server --gpus all -p $RIVA_PORT:$RIVA_PORT nvcr.io/nvidia/riva/riva-speech:2.15.0"
    else
        # Use the first available RIVA image
        local first_image
        first_image="$(echo "$riva_images" | head -1 | awk '{print $1":"$2}')"
        start_command="docker run -d --name riva-server --gpus all -p $RIVA_PORT:$RIVA_PORT $first_image"
    fi

    log_info "Executing: $start_command"
    if execute_on_worker "$start_command"; then
        log_info "RIVA container started, waiting for initialization..."

        # Wait for RIVA to start up
        local startup_wait=0
        local max_startup_wait=300  # 5 minutes

        while [[ $startup_wait -lt $max_startup_wait ]]; do
            if check_port "$RIVA_HOST" "$RIVA_PORT" 5; then
                log_success "✅ RIVA server started successfully"
                return 0
            fi

            sleep 10
            startup_wait=$((startup_wait + 10))
            log_info "Waiting for RIVA startup... (${startup_wait}/${max_startup_wait}s)"
        done

        log_error "❌ RIVA container started but not responding on port $RIVA_PORT"
        return 1
    else
        log_error "❌ Failed to start RIVA container"
        return 1
    fi
}

verify_port_access() {
    log_info "🔌 Verifying port accessibility..."

    # Test port from build box
    if check_port "$RIVA_HOST" "$RIVA_PORT" 15; then
        log_success "✅ RIVA port $RIVA_PORT accessible from build box"
        log_json "port_accessible" "RIVA port accessible" "{\"host\": \"$RIVA_HOST\", \"port\": \"$RIVA_PORT\"}"
    else
        log_error "❌ RIVA port $RIVA_PORT not accessible from build box"

        # Check if port is listening on worker
        local worker_port_check
        worker_port_check="$(execute_on_worker "ss -tlnp | grep :$RIVA_PORT || echo 'Not listening'")"

        if [[ "$worker_port_check" == "Not listening" ]]; then
            log_error "   Port is not listening on worker instance"
        else
            log_info "   Port is listening on worker: $worker_port_check"
            log_error "   Possible firewall or security group issue"
        fi

        return 1
    fi
}

test_basic_grpc() {
    log_info "🔧 Testing basic gRPC connectivity..."

    if command_exists grpcurl; then
        log_info "Testing gRPC service list..."

        if grpcurl -plaintext -max-time 15 "$RIVA_HOST:$RIVA_PORT" list >/dev/null 2>&1; then
            log_success "✅ gRPC services responding"
            log_json "grpc_accessible" "gRPC services accessible" "{\"host\": \"$RIVA_HOST\", \"port\": \"$RIVA_PORT\"}"
        else
            log_warning "⚠️ gRPC services not responding (may need time to initialize)"
            log_info "   This is normal for a freshly started RIVA server"
        fi
    else
        log_info "grpcurl not available, skipping gRPC test"
    fi
}

generate_worker_report() {
    log_info "📋 Generating worker status report..."

    local report_file="$ARTIFACTS_DIR/checks/worker-riva-status-$TIMESTAMP.json"

    {
        echo "{"
        echo "  \"timestamp\": \"$(date -Iseconds)\","
        echo "  \"script\": \"riva-212-worker-riva-setup\","
        echo "  \"worker\": {"
        echo "    \"host\": \"$RIVA_HOST\","
        echo "    \"port\": \"$RIVA_PORT\","
        echo "    \"ssh_key\": \"$SSH_KEY_NAME\""
        echo "  },"
        echo "  \"connectivity\": {"
        echo "    \"ssh_accessible\": $(test_worker_ssh && echo "true" || echo "false"),"
        echo "    \"port_accessible\": $(check_port "$RIVA_HOST" "$RIVA_PORT" 5 && echo "true" || echo "false")"
        echo "  },"
        echo "  \"riva_status\": {"

        # Get container status
        local containers="$(execute_on_worker "docker ps --filter ancestor=*riva* --format 'json' 2>/dev/null" || echo '[]')"
        echo "    \"containers_running\": $(echo "$containers" | wc -l),"

        # Get port status
        local port_listening="$(execute_on_worker "ss -tlnp | grep :$RIVA_PORT" 2>/dev/null && echo "true" || echo "false")"
        echo "    \"port_listening\": $port_listening,"

        # Get process status
        local process_count="$(execute_on_worker "pgrep -f riva | wc -l" 2>/dev/null || echo "0")"
        echo "    \"riva_processes\": $process_count"

        echo "  },"
        echo "  \"readiness\": {"
        echo "    \"ready_for_grpc_verification\": $(check_port "$RIVA_HOST" "$RIVA_PORT" 5 && echo "true" || echo "false")"
        echo "  }"
        echo "}"
    } > "$report_file"

    add_artifact "$report_file" "worker_status_report" "{\"worker_host\": \"$RIVA_HOST\"}"

    log_success "✅ Worker status report generated: $report_file"
}

# =============================================================================
# EXECUTION
# =============================================================================

main "$@"