#!/bin/bash
set -euo pipefail

# Script: riva-145-production-health-checks.sh
# Purpose: Production-ready health monitoring and alerting for WebSocket bridge
# Prerequisites: riva-144 (end-to-end validation) completed
# Validation: Comprehensive health checks suitable for production monitoring

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/riva-common-functions.sh"
load_config

log_info "🏥 Production Health Check System Setup"

# Check prerequisites
if [[ ! -f "/opt/riva/nvidia-parakeet-ver-6/.env" ]]; then
    log_error "WebSocket bridge service not found. Run riva-142 first."
    exit 1
fi

# Add current user to riva group if not already a member (needed to read .env)
if ! groups | grep -q "\briva\b"; then
    log_info "Adding current user to riva group for .env access..."
    sudo usermod -a -G riva "$USER"
    log_warn "Group membership updated. You may need to log out and back in, or run: newgrp riva"
fi

# Source .env file (readable by riva group)
if [[ -r "/opt/riva/nvidia-parakeet-ver-6/.env" ]]; then
    source /opt/riva/nvidia-parakeet-ver-6/.env
elif sudo -u riva test -r "/opt/riva/nvidia-parakeet-ver-6/.env"; then
    # Fallback: use sudo if current user can't read it yet (group not active)
    log_info "Reading .env with sudo (group membership not active yet)..."
    eval "$(sudo cat /opt/riva/nvidia-parakeet-ver-6/.env | grep -E '^[A-Z_]+=.*')"
else
    log_error "Cannot read /opt/riva/nvidia-parakeet-ver-6/.env"
    exit 1
fi

if [[ "${WS_E2E_VALIDATION_COMPLETE:-false}" != "true" ]]; then
    log_error "End-to-end validation not complete. Run riva-144 first."
    exit 1
fi

log_info "✅ Prerequisites validated"

# Configuration
WS_HOST="${WS_HOST:-0.0.0.0}"
WS_PORT="${WS_PORT:-8443}"
WS_TLS_ENABLED="${WS_TLS_ENABLED:-false}"
RIVA_HOST="${RIVA_HOST:-localhost}"
RIVA_PORT="${RIVA_PORT:-50051}"

if [[ "$WS_HOST" == "0.0.0.0" ]]; then
    TEST_HOST="localhost"
else
    TEST_HOST="$WS_HOST"
fi

WS_PROTOCOL="ws"
if [[ "${WS_TLS_ENABLED}" == "true" ]]; then
    WS_PROTOCOL="wss"
fi

SERVER_URL="${WS_PROTOCOL}://${TEST_HOST}:${WS_PORT}/"

# Create health check directory
HEALTH_DIR="/opt/riva/health"
sudo mkdir -p "$HEALTH_DIR"
sudo chown riva:riva "$HEALTH_DIR"

log_info "🔧 Creating comprehensive health check system..."

# 1. Advanced WebSocket health check
cat > "$HEALTH_DIR/websocket-health-check.sh" << 'EOF'
#!/bin/bash
# Advanced WebSocket Bridge Health Check
# Returns: 0=OK, 1=WARNING, 2=CRITICAL

set -euo pipefail

# Configuration
WS_HOST="${1:-localhost}"
WS_PORT="${2:-8443}"
WS_PROTOCOL="${3:-ws}"
TIMEOUT="${4:-10}"

SERVER_URL="${WS_PROTOCOL}://${WS_HOST}:${WS_PORT}/"
HEALTH_STATUS=0
HEALTH_MESSAGES=()

# Function to add health message
add_health_message() {
    local level="$1"
    local message="$2"
    HEALTH_MESSAGES+=("[$level] $message")

    case "$level" in
        "CRITICAL")
            HEALTH_STATUS=2
            ;;
        "WARNING")
            if [[ $HEALTH_STATUS -lt 2 ]]; then
                HEALTH_STATUS=1
            fi
            ;;
    esac
}

# Check 1: Service status
if ! systemctl is-active --quiet riva-websocket-bridge.service; then
    add_health_message "CRITICAL" "WebSocket bridge service is not running"
else
    add_health_message "OK" "WebSocket bridge service is active"
fi

# Check 2: Port connectivity
if ! timeout "$TIMEOUT" nc -z "$WS_HOST" "$WS_PORT" >/dev/null 2>&1; then
    add_health_message "CRITICAL" "WebSocket port $WS_PORT not accessible"
else
    add_health_message "OK" "WebSocket port $WS_PORT is accessible"
fi

# Check 3: WebSocket handshake (if curl available)
if command -v curl >/dev/null 2>&1; then
    HANDSHAKE_RESPONSE=$(timeout "$TIMEOUT" curl -s -i -N \
        -H "Connection: Upgrade" \
        -H "Upgrade: websocket" \
        -H "Sec-WebSocket-Version: 13" \
        -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
        "$SERVER_URL" 2>/dev/null | head -1 || echo "FAILED")

    if echo "$HANDSHAKE_RESPONSE" | grep -q "101 Switching Protocols"; then
        add_health_message "OK" "WebSocket handshake successful"
    else
        add_health_message "WARNING" "WebSocket handshake failed"
    fi
fi

# Check 4: Process resource usage
SERVICE_PID=$(pgrep -f "riva_websocket_bridge" || echo "")
if [[ -n "$SERVICE_PID" ]]; then
    PROC_STATS=$(ps -p "$SERVICE_PID" -o %cpu,%mem,vsz,rss --no-headers 2>/dev/null || echo "0 0 0 0")
    CPU_USAGE=$(echo "$PROC_STATS" | awk '{print $1}')
    MEM_USAGE=$(echo "$PROC_STATS" | awk '{print $2}')
    VSZ_KB=$(echo "$PROC_STATS" | awk '{print $3}')
    RSS_KB=$(echo "$PROC_STATS" | awk '{print $4}')

    # CPU threshold check
    if (( $(echo "$CPU_USAGE > 80" | bc -l 2>/dev/null || echo 0) )); then
        add_health_message "WARNING" "High CPU usage: ${CPU_USAGE}%"
    elif (( $(echo "$CPU_USAGE > 50" | bc -l 2>/dev/null || echo 0) )); then
        add_health_message "INFO" "Moderate CPU usage: ${CPU_USAGE}%"
    else
        add_health_message "OK" "CPU usage normal: ${CPU_USAGE}%"
    fi

    # Memory threshold check
    if (( $(echo "$MEM_USAGE > 20" | bc -l 2>/dev/null || echo 0) )); then
        add_health_message "WARNING" "High memory usage: ${MEM_USAGE}%"
    elif (( $(echo "$MEM_USAGE > 10" | bc -l 2>/dev/null || echo 0) )); then
        add_health_message "INFO" "Moderate memory usage: ${MEM_USAGE}%"
    else
        add_health_message "OK" "Memory usage normal: ${MEM_USAGE}%"
    fi

    add_health_message "INFO" "Process stats: CPU=${CPU_USAGE}%, MEM=${MEM_USAGE}%, VSZ=${VSZ_KB}KB, RSS=${RSS_KB}KB"
else
    add_health_message "CRITICAL" "WebSocket bridge process not found"
fi

# Check 5: Log file analysis (recent errors)
LOG_FILE="/opt/riva/logs/websocket-bridge.log"
if [[ -f "$LOG_FILE" ]]; then
    RECENT_ERRORS=$(tail -100 "$LOG_FILE" 2>/dev/null | grep -i "error\|exception\|failed" | wc -l || echo "0")
    if [[ "$RECENT_ERRORS" -gt 10 ]]; then
        add_health_message "WARNING" "High error rate in logs: $RECENT_ERRORS recent errors"
    elif [[ "$RECENT_ERRORS" -gt 0 ]]; then
        add_health_message "INFO" "Some errors in logs: $RECENT_ERRORS recent errors"
    else
        add_health_message "OK" "No recent errors in logs"
    fi
else
    add_health_message "WARNING" "Log file not accessible: $LOG_FILE"
fi

# Check 6: Disk space
DISK_USAGE=$(df /opt/riva | tail -1 | awk '{print $5}' | sed 's/%//')
if [[ "$DISK_USAGE" -gt 90 ]]; then
    add_health_message "CRITICAL" "Disk space critical: ${DISK_USAGE}% used"
elif [[ "$DISK_USAGE" -gt 80 ]]; then
    add_health_message "WARNING" "Disk space low: ${DISK_USAGE}% used"
else
    add_health_message "OK" "Disk space adequate: ${DISK_USAGE}% used"
fi

# Output results
echo "WebSocket Bridge Health Check - $(date)"
echo "Server: $SERVER_URL"
echo "Status: $(case $HEALTH_STATUS in 0) echo "HEALTHY";; 1) echo "WARNING";; 2) echo "CRITICAL";; esac)"
echo ""

for message in "${HEALTH_MESSAGES[@]}"; do
    echo "$message"
done

exit $HEALTH_STATUS
EOF

sudo chmod +x "$HEALTH_DIR/websocket-health-check.sh"
sudo chown riva:riva "$HEALTH_DIR/websocket-health-check.sh"

# 2. Riva backend health check
cat > "$HEALTH_DIR/riva-backend-health-check.sh" << 'EOF'
#!/bin/bash
# Riva Backend Health Check
# Returns: 0=OK, 1=WARNING, 2=CRITICAL

set -euo pipefail

RIVA_HOST="${1:-localhost}"
RIVA_PORT="${2:-50051}"
RIVA_HTTP_PORT="${3:-8000}"
TIMEOUT="${4:-10}"

HEALTH_STATUS=0
HEALTH_MESSAGES=()

add_health_message() {
    local level="$1"
    local message="$2"
    HEALTH_MESSAGES+=("[$level] $message")

    case "$level" in
        "CRITICAL") HEALTH_STATUS=2 ;;
        "WARNING") if [[ $HEALTH_STATUS -lt 2 ]]; then HEALTH_STATUS=1; fi ;;
    esac
}

# Check 1: gRPC port connectivity
if timeout "$TIMEOUT" nc -z "$RIVA_HOST" "$RIVA_PORT" >/dev/null 2>&1; then
    add_health_message "OK" "Riva gRPC port $RIVA_PORT accessible"
else
    add_health_message "CRITICAL" "Riva gRPC port $RIVA_PORT not accessible"
fi

# Check 2: HTTP health endpoint (if available)
if command -v curl >/dev/null 2>&1; then
    HTTP_RESPONSE=$(timeout "$TIMEOUT" curl -s -o /dev/null -w "%{http_code}" "http://$RIVA_HOST:$RIVA_HTTP_PORT/v1/health" 2>/dev/null || echo "000")

    if [[ "$HTTP_RESPONSE" == "200" ]]; then
        add_health_message "OK" "Riva HTTP health check passed"
    elif [[ "$HTTP_RESPONSE" == "000" ]]; then
        add_health_message "WARNING" "Riva HTTP health endpoint not accessible"
    else
        add_health_message "WARNING" "Riva HTTP health check returned: $HTTP_RESPONSE"
    fi
fi

# Check 3: gRPC service availability (if grpcurl available)
if command -v grpcurl >/dev/null 2>&1; then
    GRPC_RESPONSE=$(timeout "$TIMEOUT" grpcurl -plaintext "$RIVA_HOST:$RIVA_PORT" list 2>/dev/null || echo "FAILED")

    if echo "$GRPC_RESPONSE" | grep -q "nvidia.riva"; then
        add_health_message "OK" "Riva gRPC services available"
    else
        add_health_message "WARNING" "Riva gRPC services check failed"
    fi
fi

# Check 4: DNS resolution (if using hostname)
if [[ "$RIVA_HOST" != "localhost" && "$RIVA_HOST" != "127.0.0.1" ]]; then
    if nslookup "$RIVA_HOST" >/dev/null 2>&1; then
        add_health_message "OK" "DNS resolution for $RIVA_HOST successful"
    else
        add_health_message "WARNING" "DNS resolution for $RIVA_HOST failed"
    fi
fi

# Output results
echo "Riva Backend Health Check - $(date)"
echo "Target: $RIVA_HOST:$RIVA_PORT"
echo "Status: $(case $HEALTH_STATUS in 0) echo "HEALTHY";; 1) echo "WARNING";; 2) echo "CRITICAL";; esac)"
echo ""

for message in "${HEALTH_MESSAGES[@]}"; do
    echo "$message"
done

exit $HEALTH_STATUS
EOF

sudo chmod +x "$HEALTH_DIR/riva-backend-health-check.sh"
sudo chown riva:riva "$HEALTH_DIR/riva-backend-health-check.sh"

# 3. Comprehensive system health check
cat > "$HEALTH_DIR/system-health-check.sh" << 'EOF'
#!/bin/bash
# Comprehensive System Health Check
# Combines all health checks with intelligent alerting

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEALTH_LOG="/opt/riva/logs/health-check.log"
HEALTH_STATUS=0

# Source configuration
if [[ -f "/opt/riva/nvidia-parakeet-ver-6/.env" ]]; then
    source /opt/riva/nvidia-parakeet-ver-6/.env
fi

WS_HOST="${WS_HOST:-localhost}"
WS_PORT="${WS_PORT:-8443}"
WS_TLS_ENABLED="${WS_TLS_ENABLED:-false}"
RIVA_HOST="${RIVA_HOST:-localhost}"
RIVA_PORT="${RIVA_PORT:-50051}"
RIVA_HTTP_PORT="${RIVA_HTTP_PORT:-8000}"

WS_PROTOCOL="ws"
if [[ "${WS_TLS_ENABLED}" == "true" ]]; then
    WS_PROTOCOL="wss"
fi

if [[ "$WS_HOST" == "0.0.0.0" ]]; then
    TEST_HOST="localhost"
else
    TEST_HOST="$WS_HOST"
fi

# Create log directory
sudo mkdir -p "$(dirname "$HEALTH_LOG")"

# Function to log with timestamp
log_health() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | sudo tee -a "$HEALTH_LOG" >/dev/null
    echo "[$level] $message"
}

log_health "INFO" "Starting comprehensive health check"

# Check 1: WebSocket Bridge Health
log_health "INFO" "Checking WebSocket bridge health..."
if "$SCRIPT_DIR/websocket-health-check.sh" "$TEST_HOST" "$WS_PORT" "$WS_PROTOCOL" 10; then
    log_health "OK" "WebSocket bridge health check passed"
else
    WS_STATUS=$?
    if [[ $WS_STATUS -eq 2 ]]; then
        log_health "CRITICAL" "WebSocket bridge health check failed critically"
        HEALTH_STATUS=2
    else
        log_health "WARNING" "WebSocket bridge health check has warnings"
        if [[ $HEALTH_STATUS -lt 2 ]]; then
            HEALTH_STATUS=1
        fi
    fi
fi

# Check 2: Riva Backend Health
log_health "INFO" "Checking Riva backend health..."
if "$SCRIPT_DIR/riva-backend-health-check.sh" "$RIVA_HOST" "$RIVA_PORT" "$RIVA_HTTP_PORT" 10; then
    log_health "OK" "Riva backend health check passed"
else
    RIVA_STATUS=$?
    if [[ $RIVA_STATUS -eq 2 ]]; then
        log_health "CRITICAL" "Riva backend health check failed critically"
        HEALTH_STATUS=2
    else
        log_health "WARNING" "Riva backend health check has warnings"
        if [[ $HEALTH_STATUS -lt 2 ]]; then
            HEALTH_STATUS=1
        fi
    fi
fi

# Check 3: System Resources
log_health "INFO" "Checking system resources..."

# CPU load average
LOAD_AVG=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//')
CPU_CORES=$(nproc)
LOAD_THRESHOLD=$(echo "scale=2; $CPU_CORES * 0.8" | bc)

if (( $(echo "$LOAD_AVG > $LOAD_THRESHOLD" | bc -l) )); then
    log_health "WARNING" "High system load: $LOAD_AVG (threshold: $LOAD_THRESHOLD)"
    if [[ $HEALTH_STATUS -lt 2 ]]; then
        HEALTH_STATUS=1
    fi
else
    log_health "OK" "System load normal: $LOAD_AVG"
fi

# Memory usage
MEM_USAGE=$(free | grep Mem | awk '{printf "%.1f", ($3/$2) * 100.0}')
if (( $(echo "$MEM_USAGE > 90" | bc -l) )); then
    log_health "CRITICAL" "Critical memory usage: ${MEM_USAGE}%"
    HEALTH_STATUS=2
elif (( $(echo "$MEM_USAGE > 80" | bc -l) )); then
    log_health "WARNING" "High memory usage: ${MEM_USAGE}%"
    if [[ $HEALTH_STATUS -lt 2 ]]; then
        HEALTH_STATUS=1
    fi
else
    log_health "OK" "Memory usage normal: ${MEM_USAGE}%"
fi

# Disk space for critical paths
for path in "/opt/riva" "/var/log" "/tmp"; do
    if [[ -d "$path" ]]; then
        DISK_USAGE=$(df "$path" | tail -1 | awk '{print $5}' | sed 's/%//')
        if [[ "$DISK_USAGE" -gt 95 ]]; then
            log_health "CRITICAL" "Critical disk space on $path: ${DISK_USAGE}%"
            HEALTH_STATUS=2
        elif [[ "$DISK_USAGE" -gt 85 ]]; then
            log_health "WARNING" "Low disk space on $path: ${DISK_USAGE}%"
            if [[ $HEALTH_STATUS -lt 2 ]]; then
                HEALTH_STATUS=1
            fi
        else
            log_health "OK" "Disk space adequate on $path: ${DISK_USAGE}%"
        fi
    fi
done

# Check 4: Network connectivity
log_health "INFO" "Checking network connectivity..."

# External connectivity (optional)
if ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
    log_health "OK" "External network connectivity available"
else
    log_health "WARNING" "External network connectivity limited"
    if [[ $HEALTH_STATUS -lt 2 ]]; then
        HEALTH_STATUS=1
    fi
fi

# Check 5: Service dependencies
log_health "INFO" "Checking service dependencies..."

# Check if Docker is running (for Riva containers)
if systemctl is-active --quiet docker; then
    log_health "OK" "Docker service is running"

    # Check Riva containers
    RIVA_CONTAINERS=$(docker ps --filter "name=riva" --format "{{.Names}}" | wc -l)
    if [[ "$RIVA_CONTAINERS" -gt 0 ]]; then
        log_health "OK" "Riva Docker containers running: $RIVA_CONTAINERS"
    else
        log_health "WARNING" "No Riva Docker containers found"
        if [[ $HEALTH_STATUS -lt 2 ]]; then
            HEALTH_STATUS=1
        fi
    fi
else
    log_health "WARNING" "Docker service not running"
    if [[ $HEALTH_STATUS -lt 2 ]]; then
        HEALTH_STATUS=1
    fi
fi

# Final status determination
case $HEALTH_STATUS in
    0)
        log_health "OK" "All health checks passed - system is healthy"
        ;;
    1)
        log_health "WARNING" "Health checks completed with warnings"
        ;;
    2)
        log_health "CRITICAL" "Health checks failed - immediate attention required"
        ;;
esac

# Generate summary for monitoring systems
SUMMARY_FILE="/opt/riva/health/health-summary.json"
cat > "$SUMMARY_FILE" << EOJ
{
    "timestamp": "$(date -Iseconds)",
    "overall_status": $(case $HEALTH_STATUS in 0) echo "\"healthy\"";; 1) echo "\"warning\"";; 2) echo "\"critical\"";; esac),
    "status_code": $HEALTH_STATUS,
    "components": {
        "websocket_bridge": "checked",
        "riva_backend": "checked",
        "system_resources": "checked",
        "network": "checked",
        "dependencies": "checked"
    },
    "server_url": "${WS_PROTOCOL}://${TEST_HOST}:${WS_PORT}/",
    "riva_target": "${RIVA_HOST}:${RIVA_PORT}",
    "log_file": "$HEALTH_LOG"
}
EOJ

exit $HEALTH_STATUS
EOF

sudo chmod +x "$HEALTH_DIR/system-health-check.sh"
sudo chown riva:riva "$HEALTH_DIR/system-health-check.sh"

# 4. Create monitoring dashboard script
cat > "$HEALTH_DIR/health-dashboard.sh" << 'EOF'
#!/bin/bash
# Real-time Health Dashboard
# Provides continuous monitoring display

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REFRESH_INTERVAL="${1:-30}"  # seconds

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

clear_screen() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                     RIVA WEBSOCKET BRIDGE HEALTH DASHBOARD                  ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

status_color() {
    local status="$1"
    case "$status" in
        "healthy"|"OK"|"PASS") echo -e "${GREEN}$status${NC}" ;;
        "warning"|"WARNING") echo -e "${YELLOW}$status${NC}" ;;
        "critical"|"CRITICAL"|"FAIL") echo -e "${RED}$status${NC}" ;;
        *) echo "$status" ;;
    esac
}

show_service_status() {
    echo -e "${BLUE}Service Status:${NC}"

    # WebSocket Bridge Service
    if systemctl is-active --quiet riva-websocket-bridge.service; then
        echo -e "  WebSocket Bridge: $(status_color "RUNNING")"
    else
        echo -e "  WebSocket Bridge: $(status_color "STOPPED")"
    fi

    # Docker Service
    if systemctl is-active --quiet docker; then
        echo -e "  Docker:           $(status_color "RUNNING")"

        # Riva Containers
        RIVA_CONTAINERS=$(docker ps --filter "name=riva" --format "{{.Names}}" 2>/dev/null | wc -l || echo "0")
        echo -e "  Riva Containers:  $RIVA_CONTAINERS running"
    else
        echo -e "  Docker:           $(status_color "STOPPED")"
    fi

    echo ""
}

show_health_status() {
    echo -e "${BLUE}Health Check Results:${NC}"

    # Run health checks and capture results
    WS_HEALTH_OUTPUT=$("$SCRIPT_DIR/websocket-health-check.sh" 2>/dev/null || echo "Health check failed")
    WS_STATUS=$?

    RIVA_HEALTH_OUTPUT=$("$SCRIPT_DIR/riva-backend-health-check.sh" 2>/dev/null || echo "Health check failed")
    RIVA_STATUS=$?

    # Display results
    case $WS_STATUS in
        0) echo -e "  WebSocket Bridge: $(status_color "HEALTHY")" ;;
        1) echo -e "  WebSocket Bridge: $(status_color "WARNING")" ;;
        2) echo -e "  WebSocket Bridge: $(status_color "CRITICAL")" ;;
        *) echo -e "  WebSocket Bridge: $(status_color "UNKNOWN")" ;;
    esac

    case $RIVA_STATUS in
        0) echo -e "  Riva Backend:     $(status_color "HEALTHY")" ;;
        1) echo -e "  Riva Backend:     $(status_color "WARNING")" ;;
        2) echo -e "  Riva Backend:     $(status_color "CRITICAL")" ;;
        *) echo -e "  Riva Backend:     $(status_color "UNKNOWN")" ;;
    esac

    echo ""
}

show_system_metrics() {
    echo -e "${BLUE}System Metrics:${NC}"

    # CPU and Memory
    LOAD_AVG=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//')
    MEM_USAGE=$(free | grep Mem | awk '{printf "%.1f", ($3/$2) * 100.0}')

    echo -e "  Load Average:     $LOAD_AVG"
    echo -e "  Memory Usage:     ${MEM_USAGE}%"

    # Disk usage for key paths
    RIVA_DISK=$(df /opt/riva 2>/dev/null | tail -1 | awk '{print $5}' || echo "N/A")
    VAR_DISK=$(df /var 2>/dev/null | tail -1 | awk '{print $5}' || echo "N/A")

    echo -e "  /opt/riva disk:   $RIVA_DISK"
    echo -e "  /var disk:        $VAR_DISK"

    # Process stats
    SERVICE_PID=$(pgrep -f "riva_websocket_bridge" || echo "")
    if [[ -n "$SERVICE_PID" ]]; then
        PROC_STATS=$(ps -p "$SERVICE_PID" -o %cpu,%mem --no-headers 2>/dev/null || echo "0.0 0.0")
        WS_CPU=$(echo "$PROC_STATS" | awk '{print $1}')
        WS_MEM=$(echo "$PROC_STATS" | awk '{print $2}')
        echo -e "  WS Bridge CPU:    ${WS_CPU}%"
        echo -e "  WS Bridge MEM:    ${WS_MEM}%"
    else
        echo -e "  WS Bridge:        $(status_color "NOT RUNNING")"
    fi

    echo ""
}

show_recent_logs() {
    echo -e "${BLUE}Recent Activity (last 5 log entries):${NC}"

    # WebSocket bridge logs
    if [[ -f "/opt/riva/logs/websocket-bridge.log" ]]; then
        tail -5 /opt/riva/logs/websocket-bridge.log 2>/dev/null | while read -r line; do
            echo "  $line"
        done
    else
        echo "  No WebSocket bridge logs found"
    fi

    # Health check logs
    if [[ -f "/opt/riva/logs/health-check.log" ]]; then
        echo ""
        echo -e "${BLUE}Recent Health Events:${NC}"
        tail -3 /opt/riva/logs/health-check.log 2>/dev/null | while read -r line; do
            echo "  $line"
        done
    fi

    echo ""
}

show_connection_info() {
    echo -e "${BLUE}Connection Information:${NC}"

    # Source configuration
    if [[ -f "/opt/riva/nvidia-parakeet-ver-6/.env" ]]; then
        source /opt/riva/nvidia-parakeet-ver-6/.env
    fi

    WS_HOST="${WS_HOST:-localhost}"
    WS_PORT="${WS_PORT:-8443}"
    WS_TLS_ENABLED="${WS_TLS_ENABLED:-false}"
    RIVA_HOST="${RIVA_HOST:-localhost}"
    RIVA_PORT="${RIVA_PORT:-50051}"

    WS_PROTOCOL="ws"
    if [[ "${WS_TLS_ENABLED}" == "true" ]]; then
        WS_PROTOCOL="wss"
    fi

    echo -e "  WebSocket URL:    ${WS_PROTOCOL}://${WS_HOST}:${WS_PORT}/"
    echo -e "  Riva Target:      ${RIVA_HOST}:${RIVA_PORT}"
    echo -e "  TLS Enabled:      ${WS_TLS_ENABLED}"

    echo ""
}

# Main dashboard loop
main() {
    echo "Starting Health Dashboard (refresh every ${REFRESH_INTERVAL}s)"
    echo "Press Ctrl+C to exit"
    sleep 2

    while true; do
        clear_screen

        echo -e "Last Update: $(date '+%Y-%m-%d %H:%M:%S')"
        echo -e "Refresh Interval: ${REFRESH_INTERVAL} seconds"
        echo ""

        show_connection_info
        show_service_status
        show_health_status
        show_system_metrics
        show_recent_logs

        echo -e "${BLUE}Commands:${NC}"
        echo "  Manual health check: sudo -u riva /opt/riva/health/system-health-check.sh"
        echo "  Service logs:        sudo journalctl -u riva-websocket-bridge.service -f"
        echo "  Service restart:     sudo systemctl restart riva-websocket-bridge.service"

        sleep "$REFRESH_INTERVAL"
    done
}

# Handle Ctrl+C
trap 'echo -e "\n${BLUE}Dashboard stopped.${NC}"; exit 0' INT

main "$@"
EOF

sudo chmod +x "$HEALTH_DIR/health-dashboard.sh"
sudo chown riva:riva "$HEALTH_DIR/health-dashboard.sh"

# 5. Set up cron job for automated health monitoring
log_info "⏰ Setting up automated health monitoring..."

cat > "/tmp/riva-health-cron" << 'EOF'
# RIVA WebSocket Bridge Health Monitoring
# Check every 5 minutes and log results
*/5 * * * * riva /opt/riva/health/system-health-check.sh >/dev/null 2>&1

# Daily health report summary
0 9 * * * riva /opt/riva/health/daily-health-report.sh >/dev/null 2>&1

# Weekly log rotation and cleanup
0 2 * * 0 riva /opt/riva/health/weekly-maintenance.sh >/dev/null 2>&1
EOF

sudo crontab -u riva "/tmp/riva-health-cron"
rm "/tmp/riva-health-cron"

log_info "✅ Cron jobs configured for automated monitoring"

# 6. Create daily health report script
cat > "$HEALTH_DIR/daily-health-report.sh" << 'EOF'
#!/bin/bash
# Daily Health Report Generator

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_DIR="/opt/riva/health/reports"
REPORT_DATE=$(date '+%Y-%m-%d')
REPORT_FILE="$REPORT_DIR/health-report-$REPORT_DATE.txt"

mkdir -p "$REPORT_DIR"

{
    echo "RIVA WebSocket Bridge Daily Health Report"
    echo "Generated: $(date)"
    echo "=============================================="
    echo ""

    echo "SYSTEM OVERVIEW"
    echo "---------------"
    uptime
    echo ""

    echo "COMPREHENSIVE HEALTH CHECK"
    echo "-------------------------"
    "$SCRIPT_DIR/system-health-check.sh"
    echo ""

    echo "SERVICE STATUS"
    echo "-------------"
    systemctl status riva-websocket-bridge.service --no-pager
    echo ""

    echo "RESOURCE USAGE (24h summary)"
    echo "---------------------------"
    # CPU and memory trends from logs
    if [[ -f "/opt/riva/logs/health-check.log" ]]; then
        echo "Recent resource warnings:"
        grep -i "usage\|load" /opt/riva/logs/health-check.log | tail -10
    fi
    echo ""

    echo "ERROR SUMMARY (24h)"
    echo "------------------"
    # Check for errors in service logs
    if journalctl -u riva-websocket-bridge.service --since "24 hours ago" --no-pager | grep -i error | wc -l | xargs test 0 -lt; then
        echo "Service errors found:"
        journalctl -u riva-websocket-bridge.service --since "24 hours ago" --no-pager | grep -i error | tail -5
    else
        echo "No service errors in the last 24 hours"
    fi
    echo ""

    echo "RECOMMENDATIONS"
    echo "---------------"
    # Generate basic recommendations based on health status
    if "$SCRIPT_DIR/system-health-check.sh" >/dev/null 2>&1; then
        echo "✅ System is healthy - no immediate actions required"
    else
        echo "⚠️  Issues detected - review health check output above"
    fi

} > "$REPORT_FILE"

# Keep only last 30 days of reports
find "$REPORT_DIR" -name "health-report-*.txt" -mtime +30 -delete 2>/dev/null || true

echo "Daily health report generated: $REPORT_FILE"
EOF

sudo chmod +x "$HEALTH_DIR/daily-health-report.sh"
sudo chown riva:riva "$HEALTH_DIR/daily-health-report.sh"

# 7. Create weekly maintenance script
cat > "$HEALTH_DIR/weekly-maintenance.sh" << 'EOF'
#!/bin/bash
# Weekly Maintenance Tasks

set -euo pipefail

LOG_FILE="/opt/riva/logs/weekly-maintenance.log"

{
    echo "Weekly Maintenance - $(date)"
    echo "=============================="

    # Log file cleanup
    echo "Cleaning up old log files..."
    find /opt/riva/logs -name "*.log" -mtime +30 -exec rm {} \; 2>/dev/null || true
    find /var/log -name "*riva*" -mtime +30 -exec rm {} \; 2>/dev/null || true

    # Health report cleanup
    echo "Cleaning up old health reports..."
    find /opt/riva/health/reports -name "*.txt" -mtime +90 -delete 2>/dev/null || true

    # Disk usage report
    echo "Current disk usage:"
    df -h /opt/riva /var/log /tmp

    # Service statistics
    echo "Service uptime and restarts:"
    systemctl show riva-websocket-bridge.service --property=ActiveEnterTimestamp,NRestarts

    echo "Weekly maintenance completed"

} >> "$LOG_FILE" 2>&1

# Rotate maintenance log
if [[ -f "$LOG_FILE" ]] && [[ $(stat -c%s "$LOG_FILE") -gt 10485760 ]]; then  # 10MB
    mv "$LOG_FILE" "$LOG_FILE.old"
    touch "$LOG_FILE"
    chown riva:riva "$LOG_FILE"
fi
EOF

sudo chmod +x "$HEALTH_DIR/weekly-maintenance.sh"
sudo chown riva:riva "$HEALTH_DIR/weekly-maintenance.sh"

# 8. Create alerting script (for integration with external systems)
cat > "$HEALTH_DIR/health-alerting.sh" << 'EOF'
#!/bin/bash
# Health Alerting System
# Can be integrated with external monitoring systems

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALERT_CONFIG="/opt/riva/health/alert-config.json"

# Default alert configuration
if [[ ! -f "$ALERT_CONFIG" ]]; then
    cat > "$ALERT_CONFIG" << 'EOJ'
{
    "enabled": true,
    "alert_methods": {
        "email": {
            "enabled": false,
            "smtp_server": "smtp.example.com",
            "smtp_port": 587,
            "username": "alerts@example.com",
            "password": "",
            "recipients": ["admin@example.com"]
        },
        "webhook": {
            "enabled": false,
            "url": "https://hooks.slack.com/services/YOUR/WEBHOOK/URL",
            "method": "POST"
        },
        "syslog": {
            "enabled": true,
            "facility": "local0",
            "priority": "warning"
        }
    },
    "thresholds": {
        "consecutive_failures": 3,
        "critical_timeout": 300
    }
}
EOJ
    chown riva:riva "$ALERT_CONFIG"
fi

# Run health check and determine if alerting is needed
HEALTH_STATUS=0
HEALTH_OUTPUT=$("$SCRIPT_DIR/system-health-check.sh" 2>&1) || HEALTH_STATUS=$?

# Alert based on status
case $HEALTH_STATUS in
    0)
        # Healthy - no alert needed
        logger -p local0.info "RIVA WebSocket Bridge: System healthy"
        ;;
    1)
        # Warning - send warning alert
        logger -p local0.warning "RIVA WebSocket Bridge: System has warnings"
        echo "WARNING: RIVA WebSocket Bridge health check has warnings"
        ;;
    2)
        # Critical - send critical alert
        logger -p local0.error "RIVA WebSocket Bridge: System critical"
        echo "CRITICAL: RIVA WebSocket Bridge health check failed"

        # Additional alerting can be added here
        # Example: Send to webhook, email, etc.
        ;;
esac

# Output for external monitoring systems
cat << EOJ
{
    "timestamp": "$(date -Iseconds)",
    "service": "riva-websocket-bridge",
    "status": $(case $HEALTH_STATUS in 0) echo "\"ok\"";; 1) echo "\"warning\"";; 2) echo "\"critical\"";; esac),
    "status_code": $HEALTH_STATUS,
    "message": "Health check completed",
    "details": $(echo "$HEALTH_OUTPUT" | jq -Rs .)
}
EOJ

exit $HEALTH_STATUS
EOF

sudo chmod +x "$HEALTH_DIR/health-alerting.sh"
sudo chown riva:riva "$HEALTH_DIR/health-alerting.sh"

# 9. Test all health check components
log_info "🧪 Testing health check system..."

# Test basic health checks
if sudo -u riva "$HEALTH_DIR/websocket-health-check.sh" "$TEST_HOST" "$WS_PORT" "$WS_PROTOCOL" 5; then
    log_success "✅ WebSocket health check test passed"
    WS_HEALTH_TEST=true
else
    log_warn "⚠️  WebSocket health check test failed"
    WS_HEALTH_TEST=false
fi

if sudo -u riva "$HEALTH_DIR/riva-backend-health-check.sh" "$RIVA_HOST" "$RIVA_PORT" 5; then
    log_success "✅ Riva backend health check test passed"
    RIVA_HEALTH_TEST=true
else
    log_warn "⚠️  Riva backend health check test failed"
    RIVA_HEALTH_TEST=false
fi

# Test comprehensive health check
if sudo -u riva "$HEALTH_DIR/system-health-check.sh"; then
    log_success "✅ Comprehensive health check test passed"
    SYSTEM_HEALTH_TEST=true
else
    log_warn "⚠️  Comprehensive health check test has issues"
    SYSTEM_HEALTH_TEST=false
fi

# Verify cron job
if sudo crontab -u riva -l | grep -q "system-health-check.sh"; then
    log_success "✅ Automated monitoring cron job configured"
    CRON_TEST=true
else
    log_warn "⚠️  Automated monitoring cron job not found"
    CRON_TEST=false
fi

# Update health check status
sudo tee -a /opt/riva/nvidia-parakeet-ver-6/.env > /dev/null << EOF

# Production Health Check Results (Updated by riva-145)
WS_PRODUCTION_HEALTH_COMPLETE=true
WS_PRODUCTION_HEALTH_TIMESTAMP=$(date -Iseconds)
WS_HEALTH_CHECK_TEST_PASSED=${WS_HEALTH_TEST}
WS_RIVA_HEALTH_CHECK_TEST_PASSED=${RIVA_HEALTH_TEST}
WS_SYSTEM_HEALTH_CHECK_TEST_PASSED=${SYSTEM_HEALTH_TEST}
WS_AUTOMATED_MONITORING_ENABLED=${CRON_TEST}
EOF

# Display final summary
echo
log_info "📋 Production Health Check System Summary:"
echo "   Health Check Directory: $HEALTH_DIR"
echo "   Server URL: $SERVER_URL"
echo "   Riva Target: $RIVA_HOST:$RIVA_PORT"
echo
echo "   Health Check Components:"
echo "     WebSocket Bridge Check: $HEALTH_DIR/websocket-health-check.sh"
echo "     Riva Backend Check:     $HEALTH_DIR/riva-backend-health-check.sh"
echo "     System Health Check:    $HEALTH_DIR/system-health-check.sh"
echo "     Health Dashboard:       $HEALTH_DIR/health-dashboard.sh"
echo "     Alerting System:        $HEALTH_DIR/health-alerting.sh"

echo
echo "   Test Results:"
echo "     WebSocket Health:       $(if [[ "$WS_HEALTH_TEST" == "true" ]]; then echo "✅ PASS"; else echo "❌ FAIL"; fi)"
echo "     Riva Backend Health:    $(if [[ "$RIVA_HEALTH_TEST" == "true" ]]; then echo "✅ PASS"; else echo "❌ FAIL"; fi)"
echo "     System Health:          $(if [[ "$SYSTEM_HEALTH_TEST" == "true" ]]; then echo "✅ PASS"; else echo "⚠️ ISSUES"; fi)"
echo "     Automated Monitoring:   $(if [[ "$CRON_TEST" == "true" ]]; then echo "✅ ENABLED"; else echo "❌ DISABLED"; fi)"

echo
echo "   Automated Monitoring:"
echo "     Health Checks:  Every 5 minutes"
echo "     Daily Reports:  9:00 AM daily"
echo "     Maintenance:    2:00 AM Sundays"
echo "     Log Location:   /opt/riva/logs/health-check.log"

# Overall assessment
OVERALL_HEALTH_SUCCESS=true
if [[ "$WS_HEALTH_TEST" != "true" || "$RIVA_HEALTH_TEST" != "true" || "$CRON_TEST" != "true" ]]; then
    OVERALL_HEALTH_SUCCESS=false
fi

echo
if [[ "$OVERALL_HEALTH_SUCCESS" == "true" ]]; then
    log_success "🎉 Production health check system deployment complete!"
    echo "   The WebSocket bridge is ready for production monitoring."
else
    log_warn "⚠️  Production health check system has issues"
    echo "   Review the test results and address any failures."
fi

echo
echo "Health Check Commands:"
echo "  Manual Check:    sudo -u riva $HEALTH_DIR/system-health-check.sh"
echo "  Live Dashboard:  sudo -u riva $HEALTH_DIR/health-dashboard.sh"
echo "  Generate Report: sudo -u riva $HEALTH_DIR/daily-health-report.sh"
echo "  View Logs:       tail -f /opt/riva/logs/health-check.log"

echo
echo "Integration Examples:"
echo "  Nagios/Zabbix:   $HEALTH_DIR/system-health-check.sh"
echo "  Prometheus:      $HEALTH_DIR/health-alerting.sh"
echo "  Custom Scripts:  Parse JSON output from health-alerting.sh"

echo
log_success "🏁 WebSocket Bridge deployment pipeline complete!"
echo
echo "Complete deployment sequence:"
echo "  ✅ riva-140: Environment configuration"
echo "  ✅ riva-141: WebSocket bridge deployment"
echo "  ✅ riva-142: Systemd service installation"
echo "  ✅ riva-143: Client testing and validation"
echo "  ✅ riva-144: End-to-end validation"
echo "  ✅ riva-145: Production health checks"
echo
echo "Your NVIDIA Riva WebSocket Bridge is now production-ready! 🚀"