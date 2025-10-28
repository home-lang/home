const std = @import("std");
const Lexer = @import("lexer").Lexer;

fn benchmark(allocator: std.mem.Allocator, name: []const u8, source: []const u8, iterations: usize) !void {
    var timer = try std.time.Timer.start();

    var total_tokens: usize = 0;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var lexer = Lexer.init(allocator, source);
        var tokens = try lexer.tokenize();
        total_tokens = tokens.items.len;
        tokens.deinit(allocator);
    }

    const elapsed = timer.read();
    const avg_ns = elapsed / iterations;
    const avg_ms = @as(f64, @floatFromInt(avg_ns)) / 1_000_000.0;

    std.debug.print("{s:<30} {d:>10} iterations | {d:>8.3} ms avg | {d:>6} tokens\n", .{
        name,
        iterations,
        avg_ms,
        total_tokens,
    });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n{s}\n", .{"=" ** 80});
    std.debug.print("Home Lexer Benchmarks\n", .{});
    std.debug.print("{s}\n\n", .{"=" ** 80});

    // Benchmark 1: Hello World
    const hello_world =
        \\fn main() {
        \\  print("Hello, Home!")
        \\}
    ;
    try benchmark(allocator, "Hello World (4 LOC)", hello_world, 10000);

    // Benchmark 2: Fibonacci
    const fibonacci =
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
    ;
    try benchmark(allocator, "Fibonacci (11 LOC)", fibonacci, 5000);

    // Benchmark 3: Struct definition
    const struct_def =
        \\struct User {
        \\  name: string
        \\  email: string
        \\  age: int
        \\}
        \\
        \\fn main() {
        \\  let user = User {
        \\    name: "Alice",
        \\    email: "alice@example.com",
        \\    age: 30
        \\  }
        \\  print("User: {user.name}")
        \\}
    ;
    try benchmark(allocator, "Struct (13 LOC)", struct_def, 5000);

    // Benchmark 4: Large program (100 lines)
    var large_program = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
    defer large_program.deinit(allocator);

    var line_num: usize = 0;
    while (line_num < 100) : (line_num += 1) {
        try large_program.appendSlice(allocator, "let x");
        try large_program.writer(allocator).print("{d}", .{line_num});
        try large_program.appendSlice(allocator, " = ");
        try large_program.writer(allocator).print("{d}", .{line_num});
        try large_program.appendSlice(allocator, " + ");
        try large_program.writer(allocator).print("{d}", .{line_num + 1});
        try large_program.appendSlice(allocator, "\n");
    }

    try benchmark(allocator, "Large Program (100 LOC)", large_program.items, 1000);

    // Benchmark 5: Large program (1000 lines)
    var very_large_program = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
    defer very_large_program.deinit(allocator);

    line_num = 0;
    while (line_num < 1000) : (line_num += 1) {
        try very_large_program.appendSlice(allocator, "let variable");
        try very_large_program.writer(allocator).print("{d}", .{line_num});
        try very_large_program.appendSlice(allocator, " = calculate_value(");
        try very_large_program.writer(allocator).print("{d}", .{line_num});
        try very_large_program.appendSlice(allocator, ")\n");
    }

    try benchmark(allocator, "Very Large Program (1000 LOC)", very_large_program.items, 100);

    // Benchmark 6: Complex expressions
    const complex =
        \\let result = (x + y) * z >= 100 && active || (a != b && c == d)
        \\let value = some_function(arg1, arg2, arg3) + another_call()
        \\if condition1 && condition2 || condition3 {
        \\  do_something()
        \\}
    ;
    try benchmark(allocator, "Complex Expressions (4 LOC)", complex, 10000);

    std.debug.print("\n{s}\n", .{"=" ** 80});
    std.debug.print("Benchmark complete!\n", .{});
    std.debug.print("{s}\n\n", .{"=" ** 80});
}
