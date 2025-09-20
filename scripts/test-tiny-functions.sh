#!/bin/bash
#
# Quick Test Script for Tiny SSH Functions
# Tests the new architecture with real SSH calls
#

set -euo pipefail

# Load environment and common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/../.env" ]]; then
    source "$SCRIPT_DIR/../.env"
fi

# Extract RIVA version from server selection
RIVA_VERSION="${RIVA_SERVER_SELECTED#*speech-}"
RIVA_VERSION="${RIVA_VERSION%.tar.gz}"

source "${SCRIPT_DIR}/riva-common-functions.sh"
source "${SCRIPT_DIR}/riva-070-tiny-functions.sh"

echo "========================================="
echo "Testing Tiny SSH Functions"
echo "========================================="
echo ""

echo "Configuration:"
echo "  • Host: $RIVA_HOST"
echo "  • Version: $RIVA_VERSION"
echo "  • Model: $RIVA_MODEL_SELECTED"
echo ""

echo "Testing Step 1: Cache Check"
echo "----------------------------"
if cache_result=$(ssh_check_cache); then
    echo "✓ Cache check completed: $cache_result"
else
    echo "✗ Cache check failed"
    exit 1
fi

echo ""
echo "🎉 Tiny functions are working!"
echo ""
echo "Ready to run full workflow with:"
echo "  ./scripts/riva-070-tiny-functions.sh"