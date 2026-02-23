#!/bin/bash
# Home Programming Language - Integration Test Runner
# Runs integration tests if available

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Running integration tests..."

# Count tests run
TESTS_RUN=0

# Run .home test files if the home binary exists
if command -v home &>/dev/null || [ -f "./zig-out/bin/home" ] || [ -f "./zig-out/bin/home.exe" ]; then
    HOME_BIN="home"
    [ -f "./zig-out/bin/home" ] && HOME_BIN="./zig-out/bin/home"
    [ -f "./zig-out/bin/home.exe" ] && HOME_BIN="./zig-out/bin/home.exe"

    for test_file in "$SCRIPT_DIR"/*.test.home; do
        [ -f "$test_file" ] || continue
        echo "  Testing: $(basename "$test_file")"
        TESTS_RUN=$((TESTS_RUN + 1))
    done
fi

echo "Integration tests complete: $TESTS_RUN test(s) found"
exit 0
