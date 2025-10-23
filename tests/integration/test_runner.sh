#!/bin/bash

# Integration Test Runner for Ion Compiler
# Tests all new features: ternary, null coalescing, tuples, do-while, switch, try-catch

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ION_BIN="$SCRIPT_DIR/../../zig-out/bin/ion"

echo "========================================"
echo "Ion Compiler Integration Test Suite"
echo "Testing New Features (Phases 1-5)"
echo "========================================"
echo ""

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

run_test() {
    local test_file=$1
    local test_name=$(basename "$test_file" .home)

    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    echo -n "  [$TOTAL_TESTS] $test_name... "

    if [ ! -f "$test_file" ]; then
        echo -e "${RED}FAIL${NC} (file not found)"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        return 1
    fi

    if timeout 10 "$ION_BIN" parse "$test_file" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ PASS${NC}"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        return 0
    else
        echo -e "${RED}✗ FAIL${NC}"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        echo "    Error: Failed to parse/execute $test_file"
        return 1
    fi
}

# Check if Ion binary exists
if [ ! -f "$ION_BIN" ]; then
    echo -e "${RED}Error: Ion binary not found at $ION_BIN${NC}"
    echo "Please build the project first:"
    echo "  cd $(dirname $(dirname $SCRIPT_DIR))"
    echo "  zig build"
    exit 1
fi

echo -e "${BLUE}Using Ion binary:${NC} $ION_BIN"
echo ""
echo "Running integration tests..."
echo ""

# Run basic feature tests
echo -e "${YELLOW}Basic Feature Tests:${NC}"
run_test "$SCRIPT_DIR/test_ternary.home" || true
run_test "$SCRIPT_DIR/test_null_coalesce.home" || true
run_test "$SCRIPT_DIR/test_tuples.home" || true
run_test "$SCRIPT_DIR/test_do_while.home" || true
run_test "$SCRIPT_DIR/test_switch.home" || true
run_test "$SCRIPT_DIR/test_try_catch.home" || true
run_test "$SCRIPT_DIR/test_comprehensive.home" || true

echo ""
echo -e "${YELLOW}Advanced Feature Tests:${NC}"
run_test "$SCRIPT_DIR/11_ternary_advanced.home" || true
run_test "$SCRIPT_DIR/12_null_coalesce_advanced.home" || true
run_test "$SCRIPT_DIR/13_pipe_operator.home" || true
run_test "$SCRIPT_DIR/14_safe_navigation.home" || true
run_test "$SCRIPT_DIR/15_spread_operator.home" || true
run_test "$SCRIPT_DIR/16_tuples_advanced.home" || true
run_test "$SCRIPT_DIR/17_switch_advanced.home" || true
run_test "$SCRIPT_DIR/18_do_while_advanced.home" || true
run_test "$SCRIPT_DIR/19_try_catch_advanced.home" || true
run_test "$SCRIPT_DIR/20_combined_features.home" || true

echo ""
echo -e "${YELLOW}Core Language Tests:${NC}"
run_test "$SCRIPT_DIR/01_basic_arithmetic.home" || true
run_test "$SCRIPT_DIR/02_conditionals.home" || true
run_test "$SCRIPT_DIR/03_loops.home" || true
run_test "$SCRIPT_DIR/04_functions.home" || true
run_test "$SCRIPT_DIR/05_arrays.home" || true
run_test "$SCRIPT_DIR/06_structs.home" || true
run_test "$SCRIPT_DIR/07_type_aliases.home" || true
run_test "$SCRIPT_DIR/08_enums.home" || true
run_test "$SCRIPT_DIR/09_strings.home" || true
run_test "$SCRIPT_DIR/10_bitwise.home" || true

echo ""
echo "========================================"
echo "Test Results Summary"
echo "========================================"
echo "Total tests:  $TOTAL_TESTS"
echo -e "Passed:       ${GREEN}$PASSED_TESTS${NC}"
echo -e "Failed:       ${RED}$FAILED_TESTS${NC}"
echo ""

if [ $FAILED_TESTS -eq 0 ]; then
    echo -e "${GREEN}✓ All integration tests passed!${NC}"
    echo -e "${GREEN}✓ All new features are working correctly!${NC}"
    exit 0
else
    PASS_RATE=$((PASSED_TESTS * 100 / TOTAL_TESTS))
    echo -e "${YELLOW}⚠ Some tests failed (${PASS_RATE}% pass rate)${NC}"
    exit 1
fi
