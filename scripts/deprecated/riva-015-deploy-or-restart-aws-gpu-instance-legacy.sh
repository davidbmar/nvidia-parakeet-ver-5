#!/bin/bash
# RIVA-015: Legacy Compatibility Wrapper
# Redirects to new GPU Instance Manager
# Version: 2.0.0 (Legacy Wrapper)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${YELLOW}⚠️  DEPRECATED: This script has been modernized${NC}"
echo "================================================"
echo ""
echo "The monolithic riva-015 script has been split into focused components:"
echo ""
echo -e "${CYAN}New Architecture:${NC}"
echo "  • 🎛️  riva-014-gpu-instance-manager.sh    - Smart orchestrator"
echo "  • 🚀 riva-015-deploy-gpu-instance.sh      - Deploy new instances"
echo "  • ▶️  riva-016-start-gpu-instance.sh       - Start stopped instances"
echo "  • ⏸️  riva-017-stop-gpu-instance.sh        - Stop running instances"
echo "  • 📊 riva-018-status-gpu-instance.sh      - Status reporting"
echo ""
echo -e "${GREEN}Benefits:${NC}"
echo "  • Better error handling and logging"
echo "  • Cost tracking and savings calculations"
echo "  • State persistence across operations"
echo "  • Health checks and validation"
echo "  • JSON structured logging for observability"
echo ""

# Determine best replacement action
ACTION="auto"

# Parse any arguments to determine intent
while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h)
            echo -e "${BLUE}Migration Guide:${NC}"
            echo ""
            echo "Old Usage → New Usage:"
            echo "  $0                                   → ./scripts/riva-014-gpu-instance-manager.sh --auto"
            echo "  $0 (deploy new)                      → ./scripts/riva-014-gpu-instance-manager.sh --deploy"
            echo "  $0 (restart stopped)                → ./scripts/riva-014-gpu-instance-manager.sh --start"
            echo "  Check status                         → ./scripts/riva-014-gpu-instance-manager.sh --status"
            echo "  Stop to save costs                   → ./scripts/riva-014-gpu-instance-manager.sh --stop"
            echo ""
            echo "Interactive Mode:"
            echo "  ./scripts/riva-014-gpu-instance-manager.sh"
            echo ""
            exit 0
            ;;
        *)
            # Pass through all arguments
            shift
            ;;
    esac
done

echo -e "${CYAN}Redirecting to new manager script...${NC}"
echo ""

# Add a small delay so users see the message
sleep 2

# Execute the new manager with auto mode
exec "$SCRIPT_DIR/riva-014-gpu-instance-manager.sh" --auto "$@"