#!/bin/bash
# Integration test runner for Ion compiler
# Tests the complete pipeline: lex → parse → typecheck → interpret

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ION_BIN="$PROJECT_ROOT/zig-out/bin/ion"

# Counters
PASSED=0
FAILED=0
TOTAL=0

# Check if ion binary exists
if [ ! -f "$ION_BIN" ]; then
    echo -e "${RED}Error: ion binary not found at $ION_BIN${NC}"
    echo "Please run 'zig build' first"
    exit 1
fi

# Run a single test
run_test() {
    local test_file=$1
    local test_name=$(basename "$test_file" .ion)

    TOTAL=$((TOTAL + 1))

    echo -n "Testing $test_name... "

    # Run through complete pipeline
    if "$ION_BIN" run "$test_file" > /dev/null 2>&1; then
        echo -e "${GREEN}PASS${NC}"
        PASSED=$((PASSED + 1))
        return 0
    else
        echo -e "${RED}FAIL${NC}"
        FAILED=$((FAILED + 1))
        return 1
    fi
}

# Run all tests in the integration directory
echo "Running Ion Integration Tests"
echo "=============================="
echo ""

# Find all .ion test files
for test_file in "$SCRIPT_DIR"/*.ion; do
    if [ -f "$test_file" ]; then
        run_test "$test_file"
    fi
done

# Print summary
echo ""
echo "=============================="
echo "Test Summary:"
echo "  Total:  $TOTAL"
echo -e "  ${GREEN}Passed: $PASSED${NC}"
if [ $FAILED -gt 0 ]; then
    echo -e "  ${RED}Failed: $FAILED${NC}"
fi
echo ""

# Exit with appropriate code
if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed.${NC}"
    exit 1
fi
