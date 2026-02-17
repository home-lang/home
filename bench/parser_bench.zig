const std = @import("std");
const home = @import("home");
const Lexer = home.lexer.Lexer;
const Parser = home.parser.Parser;
const Io = std.Io;

fn benchmark(comptime name: []const u8, source: []const u8, iterations: usize, allocator: std.mem.Allocator, io: Io) !void {
    const start = Io.Clock.awake.now(io);

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var lexer = Lexer.init(allocator, source);
        var tokens = try lexer.tokenize();
        defer tokens.deinit(allocator);

        var parser = try Parser.init(allocator, tokens.items);
        const program = try parser.parse();
        defer program.deinit(allocator);
    }

    const end = Io.Clock.awake.now(io);
    const elapsed_ns: u64 = @intCast(start.durationTo(end).nanoseconds);
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const per_iteration = elapsed_ms / @as(f64, @floatFromInt(iterations));

    std.debug.print("{s:<30} {d:>8} iterations in {d:>8.3}ms ({d:>8.6}ms per iteration)\n", .{
        name,
        iterations,
        elapsed_ms,
        per_iteration,
    });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    std.debug.print("\n=== Parser Benchmarks ===\n\n", .{});

    // Simple expression
    try benchmark(
        "Simple expression",
        "1 + 2 * 3",
        10000,
        allocator,
        io,
    );

    // Complex expression
    try benchmark(
        "Complex expression",
        "(x + y) * z >= 100 && a < b || c == d",
        10000,
        allocator,
        io,
    );

    // Function call
    try benchmark(
        "Function call",
        "add(1, 2, 3)",
        10000,
        allocator,
        io,
    );

    // Let declaration
    try benchmark(
        "Let declaration",
        "let mut x: int = 42",
        10000,
        allocator,
        io,
    );

    // If statement
    try benchmark(
        "If statement",
        "if (x > 0) { return x } else { return 0 }",
        10000,
        allocator,
        io,
    );

    // Function declaration (simple)
    try benchmark(
        "Function (simple)",
        "fn main() { print(\"Hello\") }",
        10000,
        allocator,
        io,
    );

    // Function declaration (with params)
    try benchmark(
        "Function (with params)",
        "fn add(a: int, b: int) -> int { return a + b }",
        10000,
        allocator,
        io,
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
        io,
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
        io,
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
        io,
    );

    std.debug.print("\n", .{});
}
