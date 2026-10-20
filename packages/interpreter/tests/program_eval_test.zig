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

// Regression for the uninitialized expression-depth bug: `Interpreter.init`
// allocates with `allocator.create` (uninitialized memory) and sets fields
// individually, so the struct-field default never applied. The garbage value
// tripped the depth guard on the *first* expression, so
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
    // user-function call — all of which were unreachable while expression depth
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

test "eval: match statement range and or patterns" {
    try runProgram(
        \\fn classify(x: int): int {
        \\  match x {
        \\    0..=9 => return 1,
        \\    10..20 => return 2,
        \\    30 | 40 => return 3,
        \\    60 | 70..=75 => return 4,
        \\    50 => return 5,
        \\    n if n > 100 => return n,
        \\    _ => return 0,
        \\  }
        \\  return -1
        \\}
        \\
        \\fn main() {
        \\  assert(classify(0) == 1)
        \\  assert(classify(9) == 1)
        \\  assert(classify(10) == 2)
        \\  assert(classify(19) == 2)
        \\  assert(classify(20) == 0)
        \\  assert(classify(30) == 3)
        \\  assert(classify(40) == 3)
        \\  assert(classify(41) == 0)
        \\  assert(classify(60) == 4)
        \\  assert(classify(75) == 4)
        \\  assert(classify(76) == 0)
        \\  assert(classify(50) == 5)
        \\  assert(classify(101) == 101)
        \\  assert(classify(-1) == 0)
        \\}
    );
}

test "eval: failed or-pattern alternatives leave no bindings" {
    try runProgram(
        \\struct P {
        \\  a: int,
        \\  b: int,
        \\}
        \\
        \\fn after_failed_alternatives(p: P): int {
        \\  let x = 99
        \\  match p {
        \\    P { a: x, b: 0 } | P { a: x, b: 3 } => return -1,
        \\    _ => return x,
        \\  }
        \\  return -2
        \\}
        \\
        \\fn from_matching_alternative(p: P): int {
        \\  match p {
        \\    P { a: y, b: 0 } | P { a: y, b: 2 } => return y,
        \\    _ => return -1,
        \\  }
        \\  return -2
        \\}
        \\
        \\fn main() {
        \\  let p = P { a: 1, b: 2 }
        \\  assert(after_failed_alternatives(p) == 99)
        \\  assert(from_matching_alternative(p) == 1)
        \\}
    );
}

test "eval: finite recursive calls remain valid" {
    try runProgram(
        \\fn countdown(n: i32): i32 {
        \\  if n == 0 {
        \\    return 0
        \\  }
        \\  return countdown(n - 1)
        \\}
        \\fn main() {
        \\  print(countdown(8))
        \\}
    );
}

test "eval: runaway user recursion returns a runtime error" {
    try testing.expectError(error.RuntimeError, runProgram(
        \\fn recurse(n: i32): i32 {
        \\  return recurse(n + 1)
        \\}
        \\fn main() {
        \\  print(recurse(0))
        \\}
    ));
}
