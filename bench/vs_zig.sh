#!/usr/bin/env bash

# Benchmark Home vs Zig
# Compares compilation time and runtime performance

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "🏃 Home vs Zig Benchmark Suite"
echo "================================"
echo ""

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Create benchmark programs
mkdir -p "$SCRIPT_DIR/programs"

# 1. Hello World
cat > "$SCRIPT_DIR/programs/hello.home" << 'EOF'
fn main() {
    print("Hello, World!")
}
EOF

cat > "$SCRIPT_DIR/programs/hello.zig" << 'EOF'
const std = @import("std");
pub fn main() void {
    std.debug.print("Hello, World!\n", .{});
}
EOF

# 2. Fibonacci (recursive)
cat > "$SCRIPT_DIR/programs/fib_recursive.home" << 'EOF'
fn fib(n: int) -> int {
    if n <= 1 {
        return n
    }
    return fib(n - 1) + fib(n - 2)
}

fn main() {
    let result = fib(30)
    print(result)
}
EOF

cat > "$SCRIPT_DIR/programs/fib_recursive.zig" << 'EOF'
const std = @import("std");

fn fib(n: i64) i64 {
    if (n <= 1) return n;
    return fib(n - 1) + fib(n - 2);
}

pub fn main() void {
    const result = fib(30);
    std.debug.print("{d}\n", .{result});
}
EOF

# 3. Fibonacci (iterative)
cat > "$SCRIPT_DIR/programs/fib_iterative.home" << 'EOF'
fn fib(n: int) -> int {
    if n <= 1 {
        return n
    }

    let mut a = 0
    let mut b = 1
    let mut i = 2

    while i <= n {
        let tmp = a + b
        a = b
        b = tmp
        i = i + 1
    }

    return b
}

fn main() {
    let result = fib(10000)
    print(result)
}
EOF

cat > "$SCRIPT_DIR/programs/fib_iterative.zig" << 'EOF'
const std = @import("std");

fn fib(n: i64) i64 {
    if (n <= 1) return n;

    var a: i64 = 0;
    var b: i64 = 1;
    var i: i64 = 2;

    while (i <= n) : (i += 1) {
        const tmp = a + b;
        a = b;
        b = tmp;
    }

    return b;
}

pub fn main() void {
    const result = fib(10000);
    std.debug.print("{d}\n", .{result});
}
EOF

# 4. String manipulation
cat > "$SCRIPT_DIR/programs/strings.home" << 'EOF'
fn main() {
    let s1 = "Hello"
    let s2 = "World"
    print(s1)
    print(s2)
}
EOF

cat > "$SCRIPT_DIR/programs/strings.zig" << 'EOF'
const std = @import("std");

pub fn main() void {
    const s1 = "Hello";
    const s2 = "World";
    std.debug.print("{s}\n", .{s1});
    std.debug.print("{s}\n", .{s2});
}
EOF

# 5. Array operations
cat > "$SCRIPT_DIR/programs/arrays.home" << 'EOF'
fn sum(arr: [5]int) -> int {
    let mut total = 0
    let mut i = 0
    while i < 5 {
        total = total + arr[i]
        i = i + 1
    }
    return total
}

fn main() {
    let numbers = [1, 2, 3, 4, 5]
    let result = sum(numbers)
    print(result)
}
EOF

cat > "$SCRIPT_DIR/programs/arrays.zig" << 'EOF'
const std = @import("std");

fn sum(arr: [5]i64) i64 {
    var total: i64 = 0;
    for (arr) |n| {
        total += n;
    }
    return total;
}

pub fn main() void {
    const numbers = [_]i64{1, 2, 3, 4, 5};
    const result = sum(numbers);
    std.debug.print("{d}\n", .{result});
}
EOF

echo "📝 Benchmark Programs Created"
echo ""

# Compilation Time Benchmarks
echo "${BLUE}═══════════════════════════════════════${NC}"
echo "${BLUE}  Compilation Time Benchmarks${NC}"
echo "${BLUE}═══════════════════════════════════════${NC}"
echo ""

PROGRAMS=("hello" "fib_recursive" "fib_iterative" "strings" "arrays")

echo "| Program | Home (ms) | Zig (ms) | Speedup |"
echo "|---------|----------|----------|---------|"

for prog in "${PROGRAMS[@]}"; do
    # Home compilation time
    ION_TIME=$(hyperfine --warmup 3 --runs 10 \
        "$PROJECT_ROOT/zig-out/bin/ion build $SCRIPT_DIR/programs/${prog}.home -o /tmp/ion_${prog}" \
        --style none --export-json /tmp/ion_bench.json 2>/dev/null | \
        jq -r '.results[0].mean * 1000' || echo "N/A")

    # Zig compilation time
    ZIG_TIME=$(hyperfine --warmup 3 --runs 10 \
        "zig build-exe $SCRIPT_DIR/programs/${prog}.zig -femit-bin=/tmp/zig_${prog} -O ReleaseFast" \
        --style none --export-json /tmp/zig_bench.json 2>/dev/null | \
        jq -r '.results[0].mean * 1000' || echo "N/A")

    if [ "$ION_TIME" != "N/A" ] && [ "$ZIG_TIME" != "N/A" ]; then
        SPEEDUP=$(echo "scale=2; $ZIG_TIME / $ION_TIME" | bc)
        printf "| %-11s | %8.2f | %8.2f | %6.2fx |\n" "$prog" "$ION_TIME" "$ZIG_TIME" "$SPEEDUP"
    else
        printf "| %-11s | %8s | %8s | %7s |\n" "$prog" "$ION_TIME" "$ZIG_TIME" "N/A"
    fi
done

echo ""
echo "${BLUE}═══════════════════════════════════════${NC}"
echo "${BLUE}  Runtime Performance Benchmarks${NC}"
echo "${BLUE}═══════════════════════════════════════${NC}"
echo ""

echo "| Program | Home (µs) | Zig (µs) | Ratio |"
echo "|---------|----------|----------|-------|"

for prog in "${PROGRAMS[@]}"; do
    # Build first
    "$PROJECT_ROOT/zig-out/bin/ion" build "$SCRIPT_DIR/programs/${prog}.home" -o "/tmp/ion_${prog}" 2>/dev/null || true
    zig build-exe "$SCRIPT_DIR/programs/${prog}.zig" -femit-bin="/tmp/zig_${prog}" -O ReleaseFast 2>/dev/null || true

    # Home runtime
    if [ -f "/tmp/ion_${prog}" ]; then
        ION_RUNTIME=$(hyperfine --warmup 5 --runs 20 \
            "/tmp/ion_${prog}" \
            --style none --export-json /tmp/ion_runtime.json 2>/dev/null | \
            jq -r '.results[0].mean * 1000000' || echo "N/A")
    else
        ION_RUNTIME="N/A"
    fi

    # Zig runtime
    if [ -f "/tmp/zig_${prog}" ]; then
        ZIG_RUNTIME=$(hyperfine --warmup 5 --runs 20 \
            "/tmp/zig_${prog}" \
            --style none --export-json /tmp/zig_runtime.json 2>/dev/null | \
            jq -r '.results[0].mean * 1000000' || echo "N/A")
    else
        ZIG_RUNTIME="N/A"
    fi

    if [ "$ION_RUNTIME" != "N/A" ] && [ "$ZIG_RUNTIME" != "N/A" ]; then
        RATIO=$(echo "scale=2; $ION_RUNTIME / $ZIG_RUNTIME" | bc)
        printf "| %-11s | %8.2f | %8.2f | %5.2fx |\n" "$prog" "$ION_RUNTIME" "$ZIG_RUNTIME" "$RATIO"
    else
        printf "| %-11s | %8s | %8s | %5s |\n" "$prog" "$ION_RUNTIME" "$ZIG_RUNTIME" "N/A"
    fi
done

echo ""
echo "${GREEN}✅ Benchmark Complete!${NC}"
echo ""
echo "${YELLOW}Note: Requires hyperfine and jq to be installed${NC}"
echo "${YELLOW}  Install with: brew install hyperfine jq (macOS)${NC}"
echo ""
