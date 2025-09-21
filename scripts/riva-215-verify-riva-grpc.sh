#!/bin/bash
#
# RIVA-215-VERIFY-RIVA-GRPC: Verify gRPC Connectivity to RIVA Server on Workers
#
# Purpose: Validate gRPC connectivity and service availability on worker instances
# Prerequisites: grpcurl installed (riva-205), RIVA server running on workers
# Outputs: gRPC health reports, service discovery results, connectivity validation
#

# Source common functions
source "$(dirname "$0")/riva-2xx-common.sh"

# Initialize script
init_script

# =============================================================================
# MAIN GRPC VERIFICATION PROCESS
# =============================================================================

main() {
    log_info "🔌 Verifying gRPC Connectivity to RIVA Server on Workers"

    # Load configuration
    load_config

    # Validate required environment variables
    validate_env_vars "RIVA_HOST" "RIVA_PORT" "SSH_KEY_NAME"

    # Check if already completed
    if check_step_completion; then
        log_info "gRPC verification already completed, continuing for idempotence..."
    fi

    # Step 1: Validate tools and environment
    validate_tools_and_environment

    # Step 2: Test worker connectivity
    test_worker_connectivity

    # Step 3: Test RIVA server status on worker
    test_riva_server_status

    # Step 4: Discover gRPC services
    discover_grpc_services

    # Step 5: Test RIVA health endpoint
    test_riva_health

    # Step 6: Validate ASR models
    validate_asr_models

    # Step 7: Test connection parameters
    test_connection_parameters

    # Step 8: Performance baseline tests
    run_performance_tests

    # Step 9: Generate comprehensive report
    generate_grpc_report

    # Save configuration snapshot
    save_config_snapshot

    # Mark completion
    mark_step_complete "gRPC connectivity verification completed successfully"

    # Print next step
    print_next_step "./scripts/riva-220-tls-terminator.sh" "Setup HTTPS/WSS termination with TLS certificates"
}

# =============================================================================
# VALIDATION FUNCTIONS
# =============================================================================

validate_tools_and_environment() {
    log_info "🔍 Validating tools and environment..."

    # Check grpcurl
    if ! command_exists grpcurl; then
        log_error "❌ grpcurl not found. Please run riva-205-system-deps.sh first."
        exit 1
    fi

    local grpcurl_version="$(grpcurl --version 2>&1)"
    log_info "✅ grpcurl: $grpcurl_version"

    # Validate environment variables
    log_info "Environment check:"
    log_info "  RIVA_HOST: $RIVA_HOST"
    log_info "  RIVA_PORT: $RIVA_PORT"
    log_info "  SSH_KEY_NAME: $SSH_KEY_NAME"

    log_success "✅ Tools and environment validated"
    log_json "tools_validated" "Required tools and environment validated" "{\"grpcurl\": \"$grpcurl_version\"}"
}

test_worker_connectivity() {
    log_info "🌐 Testing worker connectivity..."

    # Test SSH connectivity
    if test_worker_ssh; then
        log_success "✅ SSH connectivity to worker confirmed"
    else
        log_error "❌ Cannot establish SSH connection to worker"
        exit 1
    fi

    # Test basic network connectivity to gRPC port
    log_info "Testing network connectivity to gRPC port..."
    if check_port "$RIVA_HOST" "$RIVA_PORT" 10; then
        log_success "✅ gRPC port $RIVA_PORT is accessible on $RIVA_HOST"
        log_json "port_accessible" "gRPC port accessible" "{\"host\": \"$RIVA_HOST\", \"port\": \"$RIVA_PORT\"}"
    else
        log_error "❌ gRPC port $RIVA_PORT is not accessible on $RIVA_HOST"
        log_error "   Check if RIVA server is running and port is open"
        exit 1
    fi
}

test_riva_server_status() {
    log_info "🤖 Testing RIVA server status on worker..."

    # Check if RIVA containers are running
    log_info "Checking RIVA container status..."
    local container_check="$(execute_on_worker "docker ps --filter ancestor=*riva* --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'" 2>/dev/null || echo "No containers found")"

    if [[ "$container_check" == *"riva"* ]]; then
        log_success "✅ RIVA containers running on worker"
        log_info "Container status:"
        echo "$container_check" | while read line; do log_info "  $line"; done
    else
        log_warning "⚠️ No RIVA containers found, checking for native service..."

        # Check for native RIVA service
        local service_check="$(execute_on_worker "pgrep -f riva || echo 'No riva process found'")"
        if [[ "$service_check" != "No riva process found" ]]; then
            log_success "✅ RIVA service running on worker"
        else
            log_error "❌ No RIVA server found on worker"
            exit 1
        fi
    fi

    log_json "riva_server_status" "RIVA server status checked" "{\"container_status\": \"$container_check\"}"
}

discover_grpc_services() {
    log_info "🔍 Discovering gRPC services..."

    # List all available services
    log_info "Listing all gRPC services..."
    local services_output=""
    if services_output="$(grpcurl -plaintext "$RIVA_HOST:$RIVA_PORT" list 2>&1)"; then
        log_success "✅ gRPC service discovery successful"
        log_info "Available services:"
        echo "$services_output" | while read service; do
            [[ -n "$service" ]] && log_info "  - $service"
        done

        # Check for required RIVA services
        local required_services=(
            "nvidia.riva.proto.RivaHealthCheck"
            "nvidia.riva.proto.RivaSpeechRecognition"
        )

        local missing_services=()
        for service in "${required_services[@]}"; do
            if echo "$services_output" | grep -q "$service"; then
                log_info "✅ Required service found: $service"
            else
                missing_services+=("$service")
                log_warning "⚠️ Required service missing: $service"
            fi
        done

        if [[ ${#missing_services[@]} -eq 0 ]]; then
            log_success "✅ All required gRPC services available"
        else
            log_error "❌ Missing required services: ${missing_services[*]}"
            exit 1
        fi

    else
        log_error "❌ gRPC service discovery failed: $services_output"
        exit 1
    fi

    log_json "grpc_services_discovered" "gRPC services discovered" "{\"services\": \"$services_output\"}"
}

test_riva_health() {
    log_info "🏥 Testing RIVA health endpoint..."

    # Test health check endpoint
    local health_output=""
    if health_output="$(grpcurl -plaintext "$RIVA_HOST:$RIVA_PORT" nvidia.riva.proto.RivaHealthCheck/GetHealth 2>&1)"; then
        log_success "✅ RIVA health check successful"
        log_info "Health status: $health_output"

        # Check if status is SERVING
        if echo "$health_output" | grep -q "SERVING"; then
            log_success "✅ RIVA server status: SERVING"
        else
            log_warning "⚠️ RIVA server status: $health_output"
        fi

        log_json "health_check_passed" "RIVA health check successful" "{\"status\": \"$health_output\"}"
    else
        log_error "❌ RIVA health check failed: $health_output"
        exit 1
    fi
}

validate_asr_models() {
    log_info "🎙️ Validating ASR models..."

    # List ASR service methods
    log_info "Listing ASR service methods..."
    local asr_methods=""
    if asr_methods="$(grpcurl -plaintext "$RIVA_HOST:$RIVA_PORT" list nvidia.riva.proto.RivaSpeechRecognition 2>&1)"; then
        log_success "✅ ASR service methods available"
        log_info "Available ASR methods:"
        echo "$asr_methods" | while read method; do
            [[ -n "$method" ]] && log_info "  - $method"
        done

        # Check for streaming recognition
        if echo "$asr_methods" | grep -q "StreamingRecognize"; then
            log_success "✅ Streaming recognition available"
        else
            log_warning "⚠️ Streaming recognition not found"
        fi

    else
        log_error "❌ Failed to list ASR methods: $asr_methods"
    fi

    # Test ASR configuration endpoint (if available)
    log_info "Testing ASR configuration..."
    local asr_config=""
    if asr_config="$(grpcurl -plaintext "$RIVA_HOST:$RIVA_PORT" nvidia.riva.proto.RivaSpeechRecognition/GetRivaSpeechRecognitionConfig 2>&1)"; then
        log_success "✅ ASR configuration retrieved"
        log_info "ASR config preview: $(echo "$asr_config" | head -3)"
    else
        log_info "ℹ️ ASR configuration endpoint not available or requires authentication"
    fi

    log_json "asr_models_validated" "ASR models validation completed" "{\"methods\": \"$asr_methods\"}"
}

test_connection_parameters() {
    log_info "🔧 Testing connection parameters..."

    # Test different timeout values
    local timeouts=(5 10 30)
    for timeout in "${timeouts[@]}"; do
        log_info "Testing with timeout: ${timeout}s"
        local start_time="$(date +%s%N)"

        if grpcurl -max-time "$timeout" -plaintext "$RIVA_HOST:$RIVA_PORT" list >/dev/null 2>&1; then
            local end_time="$(date +%s%N)"
            local duration="$((($end_time - $start_time) / 1000000))" # Convert to milliseconds
            log_info "✅ Timeout ${timeout}s: Success (${duration}ms)"
        else
            log_warning "⚠️ Timeout ${timeout}s: Failed"
        fi
    done

    # Test SSL vs plaintext (try SSL if configured)
    log_info "Testing SSL connectivity..."
    if [[ "${RIVA_SSL:-false}" == "true" ]]; then
        log_info "Testing SSL connection..."
        if grpcurl "$RIVA_HOST:$RIVA_PORT" list >/dev/null 2>&1; then
            log_success "✅ SSL connection successful"
        else
            log_warning "⚠️ SSL connection failed, falling back to plaintext"
        fi
    else
        log_info "SSL not configured, using plaintext"
    fi

    log_json "connection_parameters_tested" "Connection parameters tested" "{\"ssl_enabled\": \"${RIVA_SSL:-false}\"}"
}

run_performance_tests() {
    log_info "📊 Running performance baseline tests..."

    # Measure health check latency
    local latencies=()
    local iterations=5

    log_info "Measuring health check latency ($iterations iterations)..."
    for i in $(seq 1 $iterations); do
        local start_time="$(date +%s%N)"

        if grpcurl -plaintext "$RIVA_HOST:$RIVA_PORT" nvidia.riva.proto.RivaHealthCheck/GetHealth >/dev/null 2>&1; then
            local end_time="$(date +%s%N)"
            local latency="$((($end_time - $start_time) / 1000000))" # Convert to milliseconds
            latencies+=("$latency")
            log_info "  Iteration $i: ${latency}ms"
        else
            log_warning "  Iteration $i: Failed"
        fi

        sleep 0.5  # Brief pause between requests
    done

    # Calculate average latency
    if [[ ${#latencies[@]} -gt 0 ]]; then
        local total=0
        for lat in "${latencies[@]}"; do
            total=$((total + lat))
        done
        local avg_latency=$((total / ${#latencies[@]}))

        log_success "✅ Average health check latency: ${avg_latency}ms"

        if [[ $avg_latency -lt 100 ]]; then
            log_success "✅ Excellent latency (< 100ms)"
        elif [[ $avg_latency -lt 500 ]]; then
            log_info "ℹ️ Good latency (< 500ms)"
        else
            log_warning "⚠️ High latency (> 500ms)"
        fi

        log_json "performance_baseline" "Performance baseline established" "{\"avg_latency_ms\": $avg_latency, \"successful_requests\": ${#latencies[@]}, \"total_requests\": $iterations}"
    else
        log_error "❌ No successful performance measurements"
    fi
}

generate_grpc_report() {
    log_info "📋 Generating comprehensive gRPC report..."

    local report_file="$ARTIFACTS_DIR/checks/grpc-health-check-$TIMESTAMP.json"

    # Create comprehensive report
    {
        echo "{"
        echo "  \"timestamp\": \"$(date -Iseconds)\","
        echo "  \"script\": \"riva-215-verify-riva-grpc\","
        echo "  \"worker\": {"
        echo "    \"host\": \"$RIVA_HOST\","
        echo "    \"port\": \"$RIVA_PORT\","
        echo "    \"ssh_key\": \"$SSH_KEY_NAME\""
        echo "  },"
        echo "  \"connectivity\": {"
        echo "    \"ssh_accessible\": $(test_worker_ssh && echo "true" || echo "false"),"
        echo "    \"grpc_port_open\": $(check_port "$RIVA_HOST" "$RIVA_PORT" 5 && echo "true" || echo "false")"
        echo "  },"
        echo "  \"grpc_services\": {"

        # Get services list
        local services="$(grpcurl -plaintext "$RIVA_HOST:$RIVA_PORT" list 2>/dev/null || echo "[]")"
        echo "    \"available\": ["
        echo "$services" | sed 's/^/      "/' | sed 's/$/"/' | paste -sd ',' -
        echo "    ],"

        # Health check
        local health="$(grpcurl -plaintext "$RIVA_HOST:$RIVA_PORT" nvidia.riva.proto.RivaHealthCheck/GetHealth 2>/dev/null || echo "UNKNOWN")"
        echo "    \"health_status\": \"$health\","
        echo "    \"riva_version\": \"$(echo "$health" | grep -o 'version.*' || echo 'unknown')\""
        echo "  },"
        echo "  \"validation\": {"
        echo "    \"all_services_available\": $(echo "$services" | grep -q "RivaSpeechRecognition" && echo "true" || echo "false"),"
        echo "    \"health_serving\": $(echo "$health" | grep -q "SERVING" && echo "true" || echo "false"),"
        echo "    \"streaming_asr_available\": $(grpcurl -plaintext "$RIVA_HOST:$RIVA_PORT" list nvidia.riva.proto.RivaSpeechRecognition 2>/dev/null | grep -q "StreamingRecognize" && echo "true" || echo "false")"
        echo "  }"
        echo "}"
    } > "$report_file"

    add_artifact "$report_file" "grpc_health_check" "{\"worker_host\": \"$RIVA_HOST\"}"

    log_success "✅ gRPC health report generated: $report_file"
}

# =============================================================================
# EXECUTION
# =============================================================================

main "$@"