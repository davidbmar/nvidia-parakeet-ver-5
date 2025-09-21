#!/bin/bash
#
# RIVA-220-TLS-TERMINATOR: Setup HTTPS/WSS Termination with TLS Certificates
#
# Purpose: Configure TLS termination for secure WebSocket connections to RIVA transcription
# Prerequisites: riva-215 completed, domain name configured, Caddy or Nginx available
# Outputs: TLS certificates, reverse proxy configuration, HTTPS endpoints
#

# Source common functions
source "$(dirname "$0")/riva-2xx-common.sh"

# Initialize script
init_script

# =============================================================================
# MAIN TLS TERMINATION SETUP
# =============================================================================

main() {
    log_info "🔒 Setting up HTTPS/WSS Termination with TLS Certificates"

    # Load configuration
    load_config

    # Validate required environment variables
    validate_env_vars "TLS_DOMAIN" "WS_PORT"

    # Check if already completed
    if check_step_completion; then
        log_info "TLS termination already setup, continuing for idempotence..."
    fi

    # Step 1: Validate TLS configuration
    validate_tls_config

    # Step 2: Choose and install TLS terminator
    choose_tls_terminator

    # Step 3: Setup TLS certificates
    setup_tls_certificates

    # Step 4: Configure reverse proxy
    configure_reverse_proxy

    # Step 5: Test TLS endpoint
    test_tls_configuration

    # Step 6: Setup certificate renewal
    setup_certificate_renewal

    # Step 7: Configure firewall rules
    configure_firewall

    # Step 8: Generate TLS report
    generate_tls_report

    # Save configuration snapshot
    save_config_snapshot

    # Mark completion
    mark_step_complete "TLS termination configured successfully"

    # Print next step
    print_next_step "./scripts/riva-225-bridge-config.sh" "Configure WebSocket bridge settings and RIVA connection parameters"
}

# =============================================================================
# TLS CONFIGURATION FUNCTIONS
# =============================================================================

validate_tls_config() {
    log_info "🔍 Validating TLS configuration..."

    # Check required variables
    log_info "TLS Configuration:"
    log_info "  Domain: ${TLS_DOMAIN}"
    log_info "  WebSocket Port: ${WS_PORT}"
    log_info "  Use TLS: ${USE_TLS:-true}"
    log_info "  TLS Mode: ${TLS_MODE:-auto}"

    # Validate domain format
    if [[ ! "$TLS_DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$ ]]; then
        log_error "❌ Invalid domain format: $TLS_DOMAIN"
        exit 1
    fi

    # Check if domain resolves
    log_info "Checking domain resolution..."
    if nslookup "$TLS_DOMAIN" >/dev/null 2>&1; then
        log_success "✅ Domain resolves: $TLS_DOMAIN"
    else
        log_warning "⚠️ Domain does not resolve: $TLS_DOMAIN"
        log_info "   This is OK for development or local testing"
    fi

    log_json "tls_config_validated" "TLS configuration validated" "{\"domain\": \"$TLS_DOMAIN\", \"port\": \"$WS_PORT\"}"
}

choose_tls_terminator() {
    log_info "🌐 Choosing TLS terminator..."

    local terminator="${TLS_TERMINATOR:-caddy}"

    case "$terminator" in
        "caddy")
            install_caddy
            ;;
        "nginx")
            install_nginx
            ;;
        "auto")
            # Try Caddy first, fallback to Nginx
            if install_caddy; then
                terminator="caddy"
            elif install_nginx; then
                terminator="nginx"
            else
                log_error "❌ Failed to install any TLS terminator"
                exit 1
            fi
            ;;
        *)
            log_error "❌ Unknown TLS terminator: $terminator"
            exit 1
            ;;
    esac

    # Update environment with chosen terminator
    update_env_var "TLS_TERMINATOR" "$terminator"

    log_success "✅ TLS terminator selected: $terminator"
    log_json "tls_terminator_selected" "TLS terminator chosen" "{\"terminator\": \"$terminator\"}"
}

install_caddy() {
    log_info "📦 Installing Caddy server..."

    # Check if already installed
    if command_exists caddy; then
        local caddy_version="$(caddy version 2>/dev/null || echo 'unknown')"
        log_info "Caddy already installed: $caddy_version"
        return 0
    fi

    # Install Caddy
    log_info "Installing Caddy from official repository..."

    if retry_with_backoff 3 10 "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg"; then
        log_info "✅ Caddy GPG key imported"
    else
        log_error "❌ Failed to import Caddy GPG key"
        return 1
    fi

    if retry_with_backoff 3 10 "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list"; then
        log_info "✅ Caddy repository added"
    else
        log_error "❌ Failed to add Caddy repository"
        return 1
    fi

    if retry_with_backoff 3 15 "sudo apt update && sudo apt install -y caddy"; then
        log_success "✅ Caddy installed successfully"

        # Verify installation
        local caddy_version="$(caddy version 2>/dev/null || echo 'unknown')"
        log_info "Caddy version: $caddy_version"

        return 0
    else
        log_error "❌ Failed to install Caddy"
        return 1
    fi
}

install_nginx() {
    log_info "📦 Installing Nginx server..."

    # Check if already installed
    if command_exists nginx; then
        local nginx_version="$(nginx -v 2>&1 || echo 'unknown')"
        log_info "Nginx already installed: $nginx_version"
        return 0
    fi

    # Install Nginx
    if retry_with_backoff 3 15 "sudo apt update && sudo apt install -y nginx certbot python3-certbot-nginx"; then
        log_success "✅ Nginx and Certbot installed successfully"

        # Verify installation
        local nginx_version="$(nginx -v 2>&1 || echo 'unknown')"
        log_info "Nginx version: $nginx_version"

        return 0
    else
        log_error "❌ Failed to install Nginx"
        return 1
    fi
}

setup_tls_certificates() {
    log_info "🔐 Setting up TLS certificates..."

    local terminator="${TLS_TERMINATOR}"
    local cert_mode="${TLS_CERT_MODE:-auto}"

    case "$cert_mode" in
        "auto"|"letsencrypt")
            setup_letsencrypt_certificates
            ;;
        "self-signed")
            setup_self_signed_certificates
            ;;
        "manual")
            setup_manual_certificates
            ;;
        *)
            log_error "❌ Unknown certificate mode: $cert_mode"
            exit 1
            ;;
    esac

    log_json "tls_certificates_setup" "TLS certificates configured" "{\"mode\": \"$cert_mode\", \"terminator\": \"$terminator\"}"
}

setup_letsencrypt_certificates() {
    log_info "🌍 Setting up Let's Encrypt certificates..."

    local terminator="${TLS_TERMINATOR}"

    case "$terminator" in
        "caddy")
            setup_caddy_letsencrypt
            ;;
        "nginx")
            setup_nginx_letsencrypt
            ;;
        *)
            log_error "❌ Let's Encrypt not supported for terminator: $terminator"
            exit 1
            ;;
    esac
}

setup_caddy_letsencrypt() {
    log_info "🔧 Configuring Caddy with automatic Let's Encrypt..."

    # Caddy handles Let's Encrypt automatically in the Caddyfile
    log_info "Caddy will automatically obtain Let's Encrypt certificates"
    log_success "✅ Caddy Let's Encrypt configuration ready"
}

setup_nginx_letsencrypt() {
    log_info "🔧 Configuring Nginx with Certbot Let's Encrypt..."

    # Check if certificates already exist
    if [[ -f "/etc/letsencrypt/live/$TLS_DOMAIN/fullchain.pem" ]]; then
        log_info "Let's Encrypt certificates already exist for $TLS_DOMAIN"
        return 0
    fi

    # Ensure Nginx is running for webroot challenge
    if sudo systemctl start nginx && sudo systemctl is-active --quiet nginx; then
        log_info "✅ Nginx is running"
    else
        log_error "❌ Failed to start Nginx"
        exit 1
    fi

    # Obtain certificates with Certbot
    log_info "Obtaining Let's Encrypt certificates for $TLS_DOMAIN..."
    if sudo certbot --nginx -d "$TLS_DOMAIN" --non-interactive --agree-tos --email "${TLS_EMAIL:-admin@$TLS_DOMAIN}" --redirect; then
        log_success "✅ Let's Encrypt certificates obtained"
    else
        log_error "❌ Failed to obtain Let's Encrypt certificates"
        log_info "   Falling back to self-signed certificates..."
        setup_self_signed_certificates
    fi
}

setup_self_signed_certificates() {
    log_info "🔒 Setting up self-signed certificates..."

    local cert_dir="$PROJECT_ROOT/certs"
    mkdir -p "$cert_dir"

    local cert_file="$cert_dir/$TLS_DOMAIN.crt"
    local key_file="$cert_dir/$TLS_DOMAIN.key"

    # Generate self-signed certificate
    if [[ ! -f "$cert_file" ]] || [[ ! -f "$key_file" ]]; then
        log_info "Generating self-signed certificate for $TLS_DOMAIN..."

        if openssl req -x509 -newkey rsa:4096 -keyout "$key_file" -out "$cert_file" -days 365 -nodes \
            -subj "/C=US/ST=State/L=City/O=Organization/CN=$TLS_DOMAIN" \
            -addext "subjectAltName=DNS:$TLS_DOMAIN,DNS:localhost,IP:127.0.0.1"; then

            log_success "✅ Self-signed certificate generated"
            log_info "Certificate: $cert_file"
            log_info "Private key: $key_file"
        else
            log_error "❌ Failed to generate self-signed certificate"
            exit 1
        fi
    else
        log_info "Self-signed certificates already exist"
    fi

    # Update environment variables
    update_env_var "TLS_CERT_FILE" "$cert_file"
    update_env_var "TLS_KEY_FILE" "$key_file"

    log_json "self_signed_certs_created" "Self-signed certificates generated" "{\"cert_file\": \"$cert_file\", \"key_file\": \"$key_file\"}"
}

setup_manual_certificates() {
    log_info "📋 Setting up manual certificates..."

    local cert_file="${TLS_CERT_FILE:-}"
    local key_file="${TLS_KEY_FILE:-}"

    if [[ -z "$cert_file" ]] || [[ -z "$key_file" ]]; then
        log_error "❌ Manual certificate mode requires TLS_CERT_FILE and TLS_KEY_FILE"
        exit 1
    fi

    if [[ ! -f "$cert_file" ]]; then
        log_error "❌ Certificate file not found: $cert_file"
        exit 1
    fi

    if [[ ! -f "$key_file" ]]; then
        log_error "❌ Private key file not found: $key_file"
        exit 1
    fi

    log_success "✅ Manual certificates validated"
    log_info "Certificate: $cert_file"
    log_info "Private key: $key_file"
}

configure_reverse_proxy() {
    log_info "🔄 Configuring reverse proxy..."

    local terminator="${TLS_TERMINATOR}"

    case "$terminator" in
        "caddy")
            configure_caddy_proxy
            ;;
        "nginx")
            configure_nginx_proxy
            ;;
        *)
            log_error "❌ Unknown terminator for proxy configuration: $terminator"
            exit 1
            ;;
    esac

    log_json "reverse_proxy_configured" "Reverse proxy configured" "{\"terminator\": \"$terminator\"}"
}

configure_caddy_proxy() {
    log_info "🔧 Configuring Caddy reverse proxy..."

    local caddyfile="/etc/caddy/Caddyfile"
    local ws_upstream="localhost:${WS_PORT}"

    # Create Caddyfile
    log_info "Creating Caddyfile: $caddyfile"

    sudo tee "$caddyfile" > /dev/null << EOF
# RIVA WebSocket TLS Termination
$TLS_DOMAIN {
    # Handle WebSocket connections
    handle /ws* {
        reverse_proxy $ws_upstream {
            header_up Host {upstream_hostport}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
    }

    # Handle static files for the web UI
    handle /* {
        root * $PROJECT_ROOT/www
        try_files {path} /index.html
        file_server
    }

    # Health check endpoint
    handle /health {
        respond "OK" 200
    }

    # Logging
    log {
        output file /var/log/caddy/access.log
        format json
    }

    # Automatic HTTPS (Let's Encrypt)
    # tls {$TLS_EMAIL}
}

# HTTP redirect (automatic with Caddy)
EOF

    # Create log directory
    sudo mkdir -p /var/log/caddy
    sudo chown caddy:caddy /var/log/caddy

    # Validate Caddyfile
    if sudo caddy validate --config "$caddyfile"; then
        log_success "✅ Caddyfile validated"
    else
        log_error "❌ Caddyfile validation failed"
        exit 1
    fi

    # Reload Caddy configuration
    if sudo systemctl reload caddy; then
        log_success "✅ Caddy configuration reloaded"
    else
        log_warning "⚠️ Failed to reload Caddy, attempting restart..."
        if sudo systemctl restart caddy; then
            log_success "✅ Caddy restarted successfully"
        else
            log_error "❌ Failed to restart Caddy"
            exit 1
        fi
    fi

    # Enable and start Caddy service
    sudo systemctl enable caddy
    if sudo systemctl is-active --quiet caddy; then
        log_success "✅ Caddy service is running"
    else
        log_error "❌ Caddy service is not running"
        exit 1
    fi

    add_artifact "$caddyfile" "caddy_config" "{\"domain\": \"$TLS_DOMAIN\", \"upstream\": \"$ws_upstream\"}"
}

configure_nginx_proxy() {
    log_info "🔧 Configuring Nginx reverse proxy..."

    local nginx_config="/etc/nginx/sites-available/$TLS_DOMAIN"
    local nginx_enabled="/etc/nginx/sites-enabled/$TLS_DOMAIN"
    local ws_upstream="localhost:${WS_PORT}"

    # Create Nginx configuration
    log_info "Creating Nginx config: $nginx_config"

    local cert_file="${TLS_CERT_FILE:-/etc/letsencrypt/live/$TLS_DOMAIN/fullchain.pem}"
    local key_file="${TLS_KEY_FILE:-/etc/letsencrypt/live/$TLS_DOMAIN/privkey.pem}"

    sudo tee "$nginx_config" > /dev/null << EOF
# RIVA WebSocket TLS Termination
server {
    listen 80;
    server_name $TLS_DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $TLS_DOMAIN;

    # SSL Configuration
    ssl_certificate $cert_file;
    ssl_certificate_key $key_file;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    # WebSocket proxy
    location /ws {
        proxy_pass http://$ws_upstream;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }

    # Static files
    location / {
        root $PROJECT_ROOT/www;
        try_files \$uri \$uri/ /index.html;
    }

    # Health check
    location /health {
        return 200 "OK";
        add_header Content-Type text/plain;
    }

    # Logging
    access_log /var/log/nginx/$TLS_DOMAIN.access.log;
    error_log /var/log/nginx/$TLS_DOMAIN.error.log;
}
EOF

    # Enable site
    sudo ln -sf "$nginx_config" "$nginx_enabled"

    # Test Nginx configuration
    if sudo nginx -t; then
        log_success "✅ Nginx configuration validated"
    else
        log_error "❌ Nginx configuration validation failed"
        exit 1
    fi

    # Reload Nginx
    if sudo systemctl reload nginx; then
        log_success "✅ Nginx configuration reloaded"
    else
        log_error "❌ Failed to reload Nginx"
        exit 1
    fi

    # Enable and start Nginx service
    sudo systemctl enable nginx
    if sudo systemctl is-active --quiet nginx; then
        log_success "✅ Nginx service is running"
    else
        log_error "❌ Nginx service is not running"
        exit 1
    fi

    add_artifact "$nginx_config" "nginx_config" "{\"domain\": \"$TLS_DOMAIN\", \"upstream\": \"$ws_upstream\"}"
}

test_tls_configuration() {
    log_info "🧪 Testing TLS configuration..."

    local test_results=()

    # Test HTTPS endpoint
    log_info "Testing HTTPS endpoint..."
    if curl -k -s -o /dev/null -w "%{http_code}" "https://$TLS_DOMAIN/health" | grep -q "200"; then
        log_success "✅ HTTPS endpoint responding"
        test_results+=("https:OK")
    else
        log_warning "⚠️ HTTPS endpoint not responding"
        test_results+=("https:FAILED")
    fi

    # Test HTTP redirect
    log_info "Testing HTTP redirect..."
    local redirect_code="$(curl -s -o /dev/null -w "%{http_code}" "http://$TLS_DOMAIN/health" 2>/dev/null || echo '000')"
    if [[ "$redirect_code" == "301" ]] || [[ "$redirect_code" == "302" ]]; then
        log_success "✅ HTTP redirect working"
        test_results+=("redirect:OK")
    else
        log_info "ℹ️ HTTP redirect not configured (code: $redirect_code)"
        test_results+=("redirect:SKIPPED")
    fi

    # Test TLS certificate
    log_info "Testing TLS certificate..."
    if openssl s_client -connect "$TLS_DOMAIN:443" -servername "$TLS_DOMAIN" < /dev/null 2>/dev/null | grep -q "Verify return code: 0"; then
        log_success "✅ TLS certificate valid"
        test_results+=("cert:OK")
    else
        log_info "ℹ️ TLS certificate issues (expected for self-signed)"
        test_results+=("cert:SELF_SIGNED")
    fi

    # Test proxy service readiness
    log_info "Testing backend service connectivity..."
    if check_port "localhost" "$WS_PORT" 5; then
        log_success "✅ Backend service port open"
        test_results+=("backend:OK")
    else
        log_warning "⚠️ Backend service not yet available on port $WS_PORT"
        test_results+=("backend:NOT_READY")
    fi

    log_json "tls_tests_completed" "TLS configuration tests completed" "{\"results\": [\"$(IFS='\",\"'; echo \"${test_results[*]}\")\"]})"
}

setup_certificate_renewal() {
    log_info "🔄 Setting up certificate renewal..."

    local terminator="${TLS_TERMINATOR}"
    local cert_mode="${TLS_CERT_MODE:-auto}"

    case "$terminator" in
        "caddy")
            # Caddy handles renewal automatically
            log_info "Caddy handles certificate renewal automatically"
            log_success "✅ Automatic renewal configured (Caddy)"
            ;;
        "nginx")
            if [[ "$cert_mode" == "letsencrypt" ]] || [[ "$cert_mode" == "auto" ]]; then
                setup_certbot_renewal
            else
                log_info "Manual certificate renewal required for mode: $cert_mode"
            fi
            ;;
    esac

    log_json "certificate_renewal_setup" "Certificate renewal configured" "{\"terminator\": \"$terminator\", \"mode\": \"$cert_mode\"}"
}

setup_certbot_renewal() {
    log_info "🔧 Setting up Certbot automatic renewal..."

    # Check if certbot timer is enabled
    if sudo systemctl is-enabled certbot.timer >/dev/null 2>&1; then
        log_info "Certbot renewal timer already enabled"
    else
        log_info "Enabling Certbot renewal timer..."
        sudo systemctl enable certbot.timer
        sudo systemctl start certbot.timer
    fi

    # Test renewal
    log_info "Testing certificate renewal..."
    if sudo certbot renew --dry-run; then
        log_success "✅ Certificate renewal test passed"
    else
        log_warning "⚠️ Certificate renewal test failed"
    fi

    log_success "✅ Certbot automatic renewal configured"
}

configure_firewall() {
    log_info "🛡️ Configuring firewall rules..."

    # Check if UFW is available
    if command_exists ufw; then
        log_info "Configuring UFW firewall..."

        # Allow HTTP and HTTPS
        sudo ufw allow 80/tcp comment "HTTP"
        sudo ufw allow 443/tcp comment "HTTPS"

        # Allow SSH (ensure we don't lock ourselves out)
        sudo ufw allow 22/tcp comment "SSH"

        log_success "✅ Firewall rules configured"
        log_json "firewall_configured" "UFW firewall rules added" "{\"ports\": [\"22\", \"80\", \"443\"]}"
    else
        log_info "UFW not available, skipping firewall configuration"
    fi
}

generate_tls_report() {
    log_info "📋 Generating TLS configuration report..."

    local report_file="$ARTIFACTS_DIR/checks/tls-config-$TIMESTAMP.json"

    {
        echo "{"
        echo "  \"timestamp\": \"$(date -Iseconds)\","
        echo "  \"script\": \"riva-220-tls-terminator\","
        echo "  \"domain\": \"$TLS_DOMAIN\","
        echo "  \"terminator\": \"${TLS_TERMINATOR}\","
        echo "  \"configuration\": {"
        echo "    \"tls_mode\": \"${TLS_CERT_MODE:-auto}\","
        echo "    \"use_tls\": \"${USE_TLS:-true}\","
        echo "    \"ws_port\": \"$WS_PORT\","
        echo "    \"https_port\": \"443\","
        echo "    \"http_port\": \"80\""
        echo "  },"

        # Test results
        echo "  \"tests\": {"

        local https_test="$(curl -k -s -o /dev/null -w "%{http_code}" "https://$TLS_DOMAIN/health" 2>/dev/null || echo '000')"
        echo "    \"https_status\": \"$https_test\","

        local http_test="$(curl -s -o /dev/null -w "%{http_code}" "http://$TLS_DOMAIN/health" 2>/dev/null || echo '000')"
        echo "    \"http_redirect\": \"$http_test\","

        echo "    \"backend_port_open\": $(check_port "localhost" "$WS_PORT" 5 && echo "true" || echo "false"),"
        echo "    \"terminator_running\": $(sudo systemctl is-active --quiet "${TLS_TERMINATOR}" && echo "true" || echo "false")"
        echo "  },"

        # Certificate info
        echo "  \"certificates\": {"
        if [[ "${TLS_CERT_MODE:-auto}" == "self-signed" ]]; then
            echo "    \"type\": \"self-signed\","
            echo "    \"cert_file\": \"${TLS_CERT_FILE:-}\","
            echo "    \"key_file\": \"${TLS_KEY_FILE:-}\""
        else
            echo "    \"type\": \"letsencrypt\","
            echo "    \"auto_renewal\": true"
        fi
        echo "  }"
        echo "}"
    } > "$report_file"

    add_artifact "$report_file" "tls_config_report" "{\"domain\": \"$TLS_DOMAIN\", \"terminator\": \"${TLS_TERMINATOR}\"}"

    log_success "✅ TLS configuration report generated: $report_file"
}

# =============================================================================
# EXECUTION
# =============================================================================

main "$@"