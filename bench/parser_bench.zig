const std = @import("std");
const home = @import("ion");
const Lexer = ion.lexer.Lexer;
const Parser = ion.parser.Parser;

const Timer = std.time.Timer;

fn benchmark(comptime name: []const u8, source: []const u8, iterations: usize, allocator: std.mem.Allocator) !void {
    var timer = try Timer.start();
    const start = timer.read();

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var lexer = Lexer.init(allocator, source);
        var tokens = try lexer.tokenize();
        defer tokens.deinit(allocator);

        var parser = try Parser.init(allocator, tokens.items);
        const program = try parser.parse();
        defer program.deinit(allocator);
    }

    const end = timer.read();
    const elapsed = end - start;
    const elapsed_ms = @as(f64, @floatFromInt(elapsed)) / 1_000_000.0;
    const per_iteration = elapsed_ms / @as(f64, @floatFromInt(iterations));

    std.debug.print("{s:<30} {d:>8} iterations in {d:>8.3}ms ({d:>8.6}ms per iteration)\n", .{
        name,
        iterations,
        elapsed_ms,
        per_iteration,
    });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Parser Benchmarks ===\n\n", .{});

    // Simple expression
    try benchmark(
        "Simple expression",
        "1 + 2 * 3",
        10000,
        allocator,
    );

    // Complex expression
    try benchmark(
        "Complex expression",
        "(x + y) * z >= 100 && a < b || c == d",
        10000,
        allocator,
    );

    // Function call
    try benchmark(
        "Function call",
        "add(1, 2, 3)",
        10000,
        allocator,
    );

    // Let declaration
    try benchmark(
        "Let declaration",
        "let mut x: int = 42",
        10000,
        allocator,
    );

    // If statement
    try benchmark(
        "If statement",
        "if x > 0 { return x } else { return 0 }",
        10000,
        allocator,
    );

    // Function declaration (simple)
    try benchmark(
        "Function (simple)",
        "fn main() { print(\"Hello\") }",
        10000,
        allocator,
    );

    // Function declaration (with params)
    try benchmark(
        "Function (with params)",
        "fn add(a: int, b: int) -> int { return a + b }",
        10000,
        allocator,
    );

    // Fibonacci function
    try benchmark(
        "Fibonacci function",
        \\fn fib(n: int) -> int {
        \\  if n <= 1 {
        \\    return n
        \\  }
        \\  return fib(n - 1) + fib(n - 2)
        \\}
    ,
        5000,
        allocator,
    );

    // Multiple statements
    try benchmark(
        "Multiple statements",
        \\let x = 10
        \\let y = 20
        \\let z = x + y
        \\return z
    ,
        10000,
        allocator,
    );

    // Larger program
    try benchmark(
        "Larger program",
        \\fn fib(n: int) -> int {
        \\  if n <= 1 {
        \\    return n
        \\  }
        \\  return fib(n - 1) + fib(n - 2)
        \\}
        \\
        \\fn main() {
        \\  let result = fib(10)
        \\  print("Fibonacci(10) = {result}")
        \\}
    ,
        5000,
        allocator,
    );

    std.debug.print("\n", .{});
}
