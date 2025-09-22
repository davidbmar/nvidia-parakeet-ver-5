#!/bin/bash
# Test suite for riva-014-gpu-instance-manager.sh
# Validates argument handling and dry-run behavior

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RIVA_014="$SCRIPT_DIR/../../riva-014-gpu-instance-manager.sh"
TEST_INSTANCE_ID="i-1234567890abcdef0"
FAILED_TESTS=0
TOTAL_TESTS=0

# Test utilities
run_test() {
    local test_name="$1"
    local test_cmd="$2"
    local expected_pattern="$3"
    local should_contain="${4:-true}"

    echo -e "${BLUE}[TEST] $test_name${NC}"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    # Set up mock environment
    export MOCK_AWS=1
    export TEST_INSTANCE_ID="$TEST_INSTANCE_ID"
    export TEST_STATE="none"

    # Run the test and capture output
    local output
    local exit_code=0
    output=$(eval "$test_cmd" 2>&1) || exit_code=$?

    # Check if pattern matches
    local found=false
    if echo "$output" | grep -q "$expected_pattern"; then
        found=true
    fi

    # Evaluate result
    if [ "$should_contain" = "true" ] && [ "$found" = "true" ]; then
        echo -e "${GREEN}✅ PASS${NC}"
        return 0
    elif [ "$should_contain" = "false" ] && [ "$found" = "false" ]; then
        echo -e "${GREEN}✅ PASS${NC}"
        return 0
    else
        echo -e "${RED}❌ FAIL${NC}"
        echo "Expected pattern: $expected_pattern (should_contain: $should_contain)"
        echo "Output:"
        echo "$output"
        echo "Exit code: $exit_code"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        return 1
    fi
}

# Mock AWS functions for testing
setup_mocks() {
    # Create temporary mock functions file
    cat > /tmp/test-014-mocks.sh << 'EOF'
# Mock AWS and common functions for testing
get_instance_id() {
    if [ "${TEST_STATE:-}" = "none" ]; then
        echo ""
    else
        echo "${TEST_INSTANCE_ID:-i-1234567890abcdef0}"
    fi
}

get_instance_state() {
    echo "${TEST_STATE:-none}"
}

load_env_or_fail() {
    return 0
}

init_log() {
    return 0
}

json_log() {
    return 0
}

get_instance_hourly_rate() {
    echo "0.526"
}

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Mock AWS region
AWS_REGION="${AWS_REGION:-us-east-2}"
EOF

    # Modify riva-014 to include our mocks when MOCK_AWS=1
    if ! grep -q "MOCK_AWS" "$RIVA_014"; then
        # Add mock support after the common.sh source line
        sed -i '/source.*riva-099-common.sh/a\
# Mock support for testing\
if [ "${MOCK_AWS:-0}" = "1" ]; then\
    source /tmp/test-014-mocks.sh\
fi' "$RIVA_014"
    fi
}

# Test cases
test_deploy_no_instance_id() {
    export TEST_STATE="none"
    run_test "Deploy action should not contain --instance-id" \
        "'$RIVA_014' --deploy --dry-run" \
        "riva-015.*--instance-id" \
        "false"
}

test_start_with_instance_id() {
    export TEST_STATE="stopped"
    run_test "Start action should contain --instance-id" \
        "'$RIVA_014' --start --dry-run --instance-id $TEST_INSTANCE_ID" \
        "riva-016.*--instance-id.*$TEST_INSTANCE_ID" \
        "true"
}

test_status_with_instance_id() {
    export TEST_STATE="running"
    run_test "Status action should contain --instance-id" \
        "'$RIVA_014' --status --dry-run --instance-id $TEST_INSTANCE_ID" \
        "riva-018.*--instance-id.*$TEST_INSTANCE_ID" \
        "true"
}

test_wait_with_instance_id() {
    export TEST_STATE="pending"
    run_test "Wait action should include instance ID in status call" \
        "'$RIVA_014' --wait --dry-run --instance-id $TEST_INSTANCE_ID" \
        "riva-018.*--instance-id.*$TEST_INSTANCE_ID" \
        "true"
}

test_invalid_instance_id_rejection() {
    export TEST_STATE="running"
    run_test "Invalid instance ID should be rejected" \
        "'$RIVA_014' --start --instance-id invalid-id 2>&1" \
        "Instance ID required or invalid" \
        "true"
}

test_restart_dry_run() {
    export TEST_STATE="running"
    run_test "Restart should show both stop and start commands" \
        "'$RIVA_014' --restart --dry-run --instance-id $TEST_INSTANCE_ID" \
        "Would execute step 1.*riva-017.*--instance-id.*$TEST_INSTANCE_ID" \
        "true"
}

# Main test execution
main() {
    echo -e "${BLUE}🧪 RIVA-014 Test Suite${NC}"
    echo "=========================================="

    # Setup
    setup_mocks

    # Run tests
    test_deploy_no_instance_id
    test_start_with_instance_id
    test_status_with_instance_id
    test_wait_with_instance_id
    test_invalid_instance_id_rejection
    test_restart_dry_run

    # Results
    echo ""
    echo "=========================================="
    if [ "$FAILED_TESTS" -eq 0 ]; then
        echo -e "${GREEN}✅ All $TOTAL_TESTS tests passed!${NC}"
        exit 0
    else
        echo -e "${RED}❌ $FAILED_TESTS of $TOTAL_TESTS tests failed${NC}"
        exit 1
    fi
}

# Cleanup on exit
cleanup() {
    rm -f /tmp/test-014-mocks.sh
    # Remove mock support from riva-014 if we added it
    if grep -q "MOCK_AWS" "$RIVA_014"; then
        sed -i '/# Mock support for testing/,/^fi$/d' "$RIVA_014"
    fi
}
trap cleanup EXIT

main "$@"