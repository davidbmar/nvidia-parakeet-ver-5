#!/bin/bash
# Test script for the common logging framework
# This demonstrates all the logging capabilities

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

# Load common logging framework
source "$SCRIPT_DIR/common-logging.sh"

# Start script with banner
log_script_start "Logging Framework Test Suite"

# Test basic logging levels
log_section_start "Basic Logging Levels Test"
log_debug "This is a debug message (only visible if SCRIPT_LOG_LEVEL=10)"
log_info "This is an info message"
log_warn "This is a warning message"
log_error "This is an error message (non-fatal)"
log_success "This is a success message"
log_step "This is a step indicator"
log_progress "This is a progress indicator"
log_section_end "Basic Logging Levels Test"

# Test command execution logging
log_section_start "Command Execution Test"
log_execute "Testing basic command" "echo 'Hello World'"
log_execute "Testing command with output" "ls -la /tmp"
log_execute "Testing date command" "date '+%Y-%m-%d %H:%M:%S'"
log_section_end "Command Execution Test"

# Test failing command (but continue script)
log_section_start "Error Handling Test"
if ! log_execute "Testing failing command (expected to fail)" "ls /nonexistent/directory/that/does/not/exist" 2>/dev/null; then
    log_info "Failed command was properly logged and handled"
fi
log_section_end "Error Handling Test"

# Test configuration validation
log_section_start "Configuration Validation Test"
if [[ -f "$ENV_FILE" ]]; then
    # Test with existing config file
    MINIMAL_VARS=("USER" "HOME" "PATH")
    if log_validate_config "/etc/passwd" "${MINIMAL_VARS[@]}" 2>/dev/null; then
        log_info "Config validation test passed (this should fail)"
    else
        log_info "Config validation correctly failed for invalid config"
    fi
    
    # Test with environment variables that should exist
    EXISTING_VARS=("USER" "HOME")
    if log_validate_config "$ENV_FILE" "${EXISTING_VARS[@]}"; then
        log_success "Config validation passed for existing variables"
    else
        log_warn "Config validation failed unexpectedly"
    fi
else
    log_warn "No .env file found for testing config validation"
fi
log_section_end "Configuration Validation Test"

# Test connectivity testing
log_section_start "Connectivity Test"
if log_test_connectivity "google.com" 80 5 "HTTP connectivity to Google"; then
    log_success "Connectivity test passed"
else
    log_warn "Connectivity test failed (may be expected in restricted environments)"
fi
log_section_end "Connectivity Test"

# Test resource monitoring
log_section_start "Resource Monitoring Test"
log_resource_usage
log_section_end "Resource Monitoring Test"

# Test nested sections
log_section_start "Nested Section Test"
log_info "Starting outer section"

log_section_start "Inner Section 1"
log_info "This is inside the first inner section"
log_step "Performing inner step 1"
log_section_end "Inner Section 1"

log_section_start "Inner Section 2"  
log_info "This is inside the second inner section"
log_step "Performing inner step 2"
log_section_end "Inner Section 2"

log_info "Back in outer section"
log_section_end "Nested Section Test"

# Final summary
log_section_start "Test Summary"
log_success "All logging framework tests completed successfully"
log_info "Log file location: $LOG_FILE"
log_info "You can review the detailed logs using:"
log_info "  cat '$LOG_FILE'"
log_info "  tail -f '$LOG_FILE'"
log_info "  less '$LOG_FILE'"
log_section_end "Test Summary"

log_info "Logging framework test completed successfully"