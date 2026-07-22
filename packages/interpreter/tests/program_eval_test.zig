const std = @import("std");
const testing = std.testing;
const Interpreter = @import("interpreter").Interpreter;
const Parser = @import("parser").Parser;
const Lexer = @import("lexer").Lexer;

/// Lex + parse + interpret a full program, mapping the normal `error.Return`
/// from `main` to a clean success and surfacing any other interpreter error.
fn runProgram(source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lexer = Lexer.init(a, source);
    const tokens = try lexer.tokenize();

    var parser = try Parser.init(a, tokens.items);
    const program = try parser.parse();

    const interpreter = try Interpreter.init(testing.allocator, program);
    defer interpreter.deinit();

    interpreter.interpret() catch |err| {
        if (err == error.Return) return;
        return err;
    };
}

// Regression for the uninitialized `recursion_depth` bug: `Interpreter.init`
// allocates with `allocator.create` (uninitialized memory) and sets fields
// individually, so the `recursion_depth: u32 = 0` struct default never applied.
// The garbage value tripped MAX_RECURSION_DEPTH on the *first* expression, so
// no program could evaluate an expression (hello world included). Each of these
// evaluates at least one expression and must complete without a spurious
// "expression recursion depth exceeded" RuntimeError.

test "eval: print an integer literal" {
    try runProgram("fn main() { print(42) }");
}

test "eval: print a string literal (hello world)" {
    try runProgram(
        \\fn main() {
        \\  print("Hello, Home!")
        \\}
    );
}

test "eval: let-binding then use" {
    try runProgram(
        \\fn main() {
        \\  let x = 5
        \\  print(x)
        \\}
    );
}

test "eval: nested arithmetic expression" {
    try runProgram("fn main() { print((1 + 2) * 3 - 4) }");
}

test "eval: multiple statements and a returning function" {
    // Exercises several evaluateExpression entries across statements and a
    // user-function call — all of which were unreachable while recursion_depth
    // started as garbage.
    try runProgram(
        \\fn add(a: i32, b: i32): i32 {
        \\  return a + b
        \\}
        \\fn main() {
        \\  let a = 2
        \\  let b = 3
        \\  print(add(a, b))
        \\}
    );
}
