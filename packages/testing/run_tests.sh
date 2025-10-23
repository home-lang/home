#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo ""
echo "======================================================================"
echo "  ION MODERN TESTING FRAMEWORK - COMPREHENSIVE TEST SUITE"
echo "======================================================================"
echo ""

# Create output directory if it doesn't exist
mkdir -p zig-out/bin

# Track results
total_passed=0
total_failed=0
suite_count=0

# Function to run a test suite
run_test_suite() {
    local name=$1
    local file=$2

    echo ""
    echo -e "${BLUE}📦 Running Test Suite: $name${NC}"
    echo "----------------------------------------------------------------------"

    # Compile the test
    zig build-exe "$file" \
        --name "zig-out/bin/$name" \
        -I../.. \
        --main-pkg-path ../.. \
        2>&1

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Failed to compile $name${NC}"
        ((total_failed++))
        ((suite_count++))
        return 1
    fi

    # Run the test
    "./zig-out/bin/$name"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ $name: PASSED${NC}"
        ((total_passed++))
    else
        echo -e "${RED}❌ $name: FAILED${NC}"
        ((total_failed++))
    fi

    ((suite_count++))
}

# Run all test suites
run_test_suite "test_matchers" "tests/test_matchers.zig"
run_test_suite "test_framework" "tests/test_framework.zig"
run_test_suite "test_mocks" "tests/test_mocks.zig"
run_test_suite "test_snapshots" "tests/test_snapshots.zig"

# Print final summary
echo ""
echo "======================================================================"
echo "  FINAL RESULTS"
echo "======================================================================"
echo ""
echo "Test Suites: $suite_count total, $total_passed passed, $total_failed failed"
echo ""

if [ $total_failed -gt 0 ]; then
    echo -e "${RED}❌ TEST SUITE FAILED${NC}"
    echo ""
    echo "Some tests failed. Please review the output above."
    exit 1
else
    echo -e "${GREEN}✅ TEST SUITE PASSED${NC}"
    echo ""
    echo "All $total_passed test suites passed successfully!"
    exit 0
fi
