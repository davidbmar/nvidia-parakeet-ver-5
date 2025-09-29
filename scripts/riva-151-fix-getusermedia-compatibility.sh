#!/bin/bash
set -euo pipefail

# Script: riva-151-fix-getusermedia-compatibility.sh
# Purpose: Fix getUserMedia compatibility issues in WebSocket client
# Prerequisites: WebSocket bridge setup completed
# Validation: Browser can access microphone over HTTPS

# Source common functions if available, but don't fail if missing
if [[ -f "$(dirname "$0")/riva-common-functions.sh" ]]; then
    source "$(dirname "$0")/riva-common-functions.sh" 2>/dev/null || true
    # Try to load config, but provide fallbacks
    if command -v load_config >/dev/null 2>&1; then
        load_config
    fi
fi

# Fallback logging functions if not available from common functions
if ! command -v log_info >/dev/null 2>&1; then
    log_info() { echo "ℹ️  $*"; }
    log_success() { echo "✅ $*"; }
    log_error() { echo "❌ $*" >&2; }
    log_warning() { echo "⚠️  $*"; }
fi

log_info "🎤 Fixing getUserMedia compatibility issues..."

# File paths
CLIENT_JS="$(pwd)/static/riva-websocket-client.js"
BACKUP_FILE="${CLIENT_JS}.backup-$(date +%Y%m%d-%H%M%S)"

# Validate prerequisites
validate_prerequisites() {
    log_info "🔍 Validating prerequisites..."

    if [[ ! -f "$CLIENT_JS" ]]; then
        log_error "WebSocket client not found: $CLIENT_JS"
        exit 1
    fi

    log_success "Prerequisites validated"
}

# Check if getUserMedia fix is already applied
check_existing_fix() {
    log_info "🔍 Checking for existing getUserMedia fix..."

    if grep -q "Check for getUserMedia support with fallbacks" "$CLIENT_JS"; then
        log_info "✅ getUserMedia fix already applied"
        return 0
    else
        log_info "❌ getUserMedia fix not found - applying fix..."
        return 1
    fi
}

# Apply getUserMedia compatibility fix
apply_getusermedia_fix() {
    log_info "🔧 Applying getUserMedia compatibility fix..."

    # Create backup
    cp "$CLIENT_JS" "$BACKUP_FILE"
    log_info "📄 Backup created: $BACKUP_FILE"

    # Apply the fix using a temporary file for safe editing
    local temp_file=$(mktemp)

    # Use awk to replace the getUserMedia section
    awk '
    /async initializeAudio\(\) \{/ {
        print $0
        getline; print $0  # try {
        getline; print $0  # console.log...
        print ""
        print "            // Check for getUserMedia support with fallbacks"
        print "            let getUserMedia = null;"
        print "            if (navigator.mediaDevices && navigator.mediaDevices.getUserMedia) {"
        print "                getUserMedia = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);"
        print "            } else if (navigator.getUserMedia) {"
        print "                getUserMedia = (constraints) => {"
        print "                    return new Promise((resolve, reject) => {"
        print "                        navigator.getUserMedia(constraints, resolve, reject);"
        print "                    });"
        print "                };"
        print "            } else if (navigator.webkitGetUserMedia) {"
        print "                getUserMedia = (constraints) => {"
        print "                    return new Promise((resolve, reject) => {"
        print "                        navigator.webkitGetUserMedia(constraints, resolve, reject);"
        print "                    });"
        print "                };"
        print "            } else if (navigator.mozGetUserMedia) {"
        print "                getUserMedia = (constraints) => {"
        print "                    return new Promise((resolve, reject) => {"
        print "                        navigator.mozGetUserMedia(constraints, resolve, reject);"
        print "                    });"
        print "                };"
        print "            } else {"
        print "                throw new Error('\''getUserMedia is not supported in this browser. Please use HTTPS or a modern browser.'\'');"
        print "            }"
        print ""
        # Skip the original getUserMedia line
        while (getline && !/this\.mediaStream = await navigator\.mediaDevices\.getUserMedia/) {
            if (!/^[[:space:]]*\/\/ Request microphone access[[:space:]]*$/) {
                print $0
            }
        }
        # Print the replacement line
        print "            // Request microphone access"
        print "            this.mediaStream = await getUserMedia(this.audioConfig.constraints);"
        next
    }
    { print }
    ' "$CLIENT_JS" > "$temp_file"

    # Check if the replacement was successful
    if grep -q "Check for getUserMedia support with fallbacks" "$temp_file"; then
        mv "$temp_file" "$CLIENT_JS"
        log_success "✅ getUserMedia compatibility fix applied"
    else
        rm "$temp_file"
        log_error "❌ Failed to apply getUserMedia fix"
        log_error "Restoring backup..."
        mv "$BACKUP_FILE" "$CLIENT_JS"
        exit 1
    fi
}

# Add enhanced error handling for getUserMedia
add_error_handling() {
    log_info "🛡️ Adding enhanced error handling..."

    # Add better error messages for common getUserMedia failures
    cat >> "$CLIENT_JS" << 'EOF'

    /**
     * Get user-friendly error message for getUserMedia failures
     */
    static getUserMediaErrorMessage(error) {
        switch (error.name) {
            case 'NotAllowedError':
                return 'Microphone access denied. Please allow microphone access and try again.';
            case 'NotFoundError':
                return 'No microphone found. Please connect a microphone and try again.';
            case 'NotReadableError':
                return 'Microphone is busy or not accessible. Please close other applications using the microphone.';
            case 'OverconstrainedError':
                return 'Microphone does not support the requested settings. Please try with different settings.';
            case 'SecurityError':
                return 'Microphone access blocked due to security restrictions. Please use HTTPS.';
            case 'TypeError':
                return 'getUserMedia is not supported. Please use a modern browser with HTTPS.';
            default:
                return `Microphone access failed: ${error.message || error.name || 'Unknown error'}`;
        }
    }
EOF

    log_success "✅ Enhanced error handling added"
}

# Test the fix
test_fix() {
    log_info "🧪 Testing getUserMedia fix..."

    # Check that the fix is present
    if grep -q "Check for getUserMedia support with fallbacks" "$CLIENT_JS"; then
        log_success "✅ getUserMedia fallback code detected"
    else
        log_error "❌ getUserMedia fix not found in file"
        return 1
    fi

    # Check for error handling function
    if grep -q "getUserMediaErrorMessage" "$CLIENT_JS"; then
        log_success "✅ Error handling function detected"
    else
        log_warning "⚠️  Error handling function not found"
    fi

    # Validate JavaScript syntax
    if node -c "$CLIENT_JS" 2>/dev/null; then
        log_success "✅ JavaScript syntax is valid"
    else
        log_error "❌ JavaScript syntax error detected"
        log_error "Restoring backup..."
        mv "$BACKUP_FILE" "$CLIENT_JS"
        return 1
    fi
}

# Validate results
validate_results() {
    log_info "✅ Validating getUserMedia compatibility fix..."

    # Check file exists and is readable
    if [[ -f "$CLIENT_JS" && -r "$CLIENT_JS" ]]; then
        log_success "WebSocket client file is accessible"
    else
        log_error "WebSocket client file is not accessible"
        return 1
    fi

    # Check for compatibility code
    local compat_patterns=(
        "Check for getUserMedia support with fallbacks"
        "navigator.mediaDevices.getUserMedia"
        "navigator.getUserMedia"
        "navigator.webkitGetUserMedia"
        "navigator.mozGetUserMedia"
    )

    for pattern in "${compat_patterns[@]}"; do
        if grep -q "$pattern" "$CLIENT_JS"; then
            log_success "✅ Found compatibility pattern: $pattern"
        else
            log_error "❌ Missing compatibility pattern: $pattern"
            return 1
        fi
    done

    log_success "✅ getUserMedia compatibility fix completed successfully"
}

# Main execution
main() {
    validate_prerequisites

    if check_existing_fix; then
        log_info "Fix already applied, skipping..."
    else
        apply_getusermedia_fix
        add_error_handling
        test_fix
    fi

    validate_results

    log_success "🎉 getUserMedia compatibility fix is ready!"
    log_info ""
    log_info "📋 What this fix provides:"
    log_info "   ✅ Fallback support for older browsers"
    log_info "   ✅ Better error messages for microphone issues"
    log_info "   ✅ Guidance to use HTTPS for security requirements"
    log_info ""
    log_info "🔒 HTTPS is still required for microphone access in modern browsers"
    log_info "   Run: scripts/riva-150-setup-https-demo-server.sh"
}

# Run main function
main "$@"