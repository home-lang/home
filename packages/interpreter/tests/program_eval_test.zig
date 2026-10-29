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

test "eval: deferred user function calls keep the pending return value" {
    try runProgram(
        \\struct Box {
        \\  v: int,
        \\}
        \\
        \\impl Box {
        \\  fn get(self): int {
        \\    defer cleanup()
        \\    return self.v
        \\  }
        \\}
        \\
        \\fn cleanup() {
        \\}
        \\
        \\fn direct(): int {
        \\  defer cleanup()
        \\  return 7
        \\}
        \\
        \\fn in_if(): int {
        \\  if true {
        \\    defer cleanup()
        \\    return 8
        \\  }
        \\  return 0
        \\}
        \\
        \\fn in_else(): int {
        \\  if false {
        \\    return 0
        \\  } else {
        \\    defer cleanup()
        \\    return 9
        \\  }
        \\  return 0
        \\}
        \\
        \\fn in_while(): int {
        \\  while true {
        \\    defer cleanup()
        \\    return 10
        \\  }
        \\  return 0
        \\}
        \\
        \\fn in_range_loop(): int {
        \\  for i in 0..3 {
        \\    defer cleanup()
        \\    return i + 11
        \\  }
        \\  return 0
        \\}
        \\
        \\fn in_array_loop(): int {
        \\  for x in [12] {
        \\    defer cleanup()
        \\    return x
        \\  }
        \\  return 0
        \\}
        \\
        \\fn in_block(): int {
        \\  {
        \\    defer cleanup()
        \\    return 13
        \\  }
        \\  return 0
        \\}
        \\
        \\fn main() {
        \\  let closure = fn(): int {
        \\    defer cleanup()
        \\    return 14
        \\  }
        \\  let box = Box { v: 15 }
        \\  assert(direct() == 7)
        \\  assert(in_if() == 8)
        \\  assert(in_else() == 9)
        \\  assert(in_while() == 10)
        \\  assert(in_range_loop() == 11)
        \\  assert(in_array_loop() == 12)
        \\  assert(in_block() == 13)
        \\  assert(closure() == 14)
        \\  assert(box.get() == 15)
        \\}
    );
}

test "eval: a value left behind by a call inside a defer does not replace the pending return" {
    try runProgram(
        \\fn noop() {
        \\}
        \\
        \\fn cleanup() {
        \\  let c = fn(): int {
        \\    return 99
        \\  }
        \\  c()
        \\  defer noop()
        \\}
        \\
        \\fn outer(): int {
        \\  defer cleanup()
        \\  return 7
        \\}
        \\
        \\fn main() {
        \\  assert(outer() == 7)
        \\}
    );
}

test "eval: a return inside a deferred block still sets the returned value" {
    try runProgram(
        \\fn final_return(): int {
        \\  defer {
        \\    return 5
        \\  }
        \\  return 7
        \\}
        \\
        \\fn earlier_return(): int {
        \\  defer {
        \\    return 6
        \\    0
        \\  }
        \\  return 7
        \\}
        \\
        \\fn main() {
        \\  assert(final_return() == 5)
        \\  assert(earlier_return() == 6)
        \\}
    );
}

test "eval: deferred calls run in reverse order before the return value is used" {
    try runProgram(
        \\fn inner(): int {
        \\  defer note(1)
        \\  return 99
        \\}
        \\
        \\let mut order = 0
        \\
        \\fn note(n: int) {
        \\  order = order * 10 + n
        \\}
        \\
        \\fn first() {
        \\  note(2)
        \\}
        \\
        \\fn second() {
        \\  assert(inner() == 99)
        \\  note(3)
        \\}
        \\
        \\fn outer(): int {
        \\  defer first()
        \\  defer second()
        \\  return 7
        \\}
        \\
        \\fn main() {
        \\  assert(outer() == 7)
        \\  assert(order == 132)
        \\}
    );
}
