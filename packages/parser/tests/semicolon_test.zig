const std = @import("std");
const testing = std.testing;
const Parser = @import("parser").Parser;
const Lexer = @import("lexer").Lexer;

// Test optional semicolons - simple statements
test "optional semicolons - simple statements on separate lines" {
    const source =
        \\let x = 42
        \\let y = 100
        \\return x + y
    ;

    var lexer = try Lexer.init(testing.allocator, source);
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    defer testing.allocator.free(tokens);

    var parser = try Parser.init(testing.allocator, tokens);
    defer parser.deinit();

    const program = try parser.parse();
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), program.statements.len);
}

// Test with semicolons
test "optional semicolons - statements with semicolons" {
    const source =
        \\let x = 42;
        \\let y = 100;
        \\return x + y;
    ;

    var lexer = try Lexer.init(testing.allocator, source);
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    defer testing.allocator.free(tokens);

    var parser = try Parser.init(testing.allocator, tokens);
    defer parser.deinit();

    const program = try parser.parse();
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), program.statements.len);
}

// Test required semicolons - multiple statements on same line
test "required semicolons - multiple statements on same line" {
    const source = "let x = 5; let y = 10";

    var lexer = try Lexer.init(testing.allocator, source);
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    defer testing.allocator.free(tokens);

    var parser = try Parser.init(testing.allocator, tokens);
    defer parser.deinit();

    const program = try parser.parse();
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), program.statements.len);
}

// Test error - missing semicolon on same line
test "semicolon error - missing required semicolon" {
    const source = "let x = 5 let y = 10"; // Missing semicolon

    var lexer = try Lexer.init(testing.allocator, source);
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    defer testing.allocator.free(tokens);

    var parser = try Parser.init(testing.allocator, tokens);
    defer parser.deinit();

    const result = parser.parse();
    try testing.expectError(error.UnexpectedToken, result);
}

// Test semicolons before closing brace (optional)
test "optional semicolons - before closing brace" {
    const source =
        \\fn foo() {
        \\    let x = 42
        \\    return x
        \\}
    ;

    var lexer = try Lexer.init(testing.allocator, source);
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    defer testing.allocator.free(tokens);

    var parser = try Parser.init(testing.allocator, tokens);
    defer parser.deinit();

    const program = try parser.parse();
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), program.statements.len);
}

// Test mix of semicolons and newlines
test "optional semicolons - mixed usage" {
    const source =
        \\let x = 1
        \\let y = 2;
        \\let z = 3
    ;

    var lexer = try Lexer.init(testing.allocator, source);
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    defer testing.allocator.free(tokens);

    var parser = try Parser.init(testing.allocator, tokens);
    defer parser.deinit();

    const program = try parser.parse();
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), program.statements.len);
}

// Test return statement without semicolon
test "optional semicolons - return statement" {
    const source =
        \\fn add(a: int, b: int) -> int {
        \\    return a + b
        \\}
    ;

    var lexer = try Lexer.init(testing.allocator, source);
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    defer testing.allocator.free(tokens);

    var parser = try Parser.init(testing.allocator, tokens);
    defer parser.deinit();

    const program = try parser.parse();
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), program.statements.len);
}

// Test last statement in block without semicolon
test "optional semicolons - last statement in block" {
    const source =
        \\fn compute() -> int {
        \\    let x = 10
        \\    let y = 20
        \\    x + y
        \\}
    ;

    var lexer = try Lexer.init(testing.allocator, source);
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    defer testing.allocator.free(tokens);

    var parser = try Parser.init(testing.allocator, tokens);
    defer parser.deinit();

    const program = try parser.parse();
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), program.statements.len);
}

// Test complex nested blocks
test "optional semicolons - nested blocks" {
    const source =
        \\fn main() {
        \\    if true {
        \\        let x = 1
        \\        let y = 2
        \\    }
        \\    let z = 3
        \\}
    ;

    var lexer = try Lexer.init(testing.allocator, source);
    defer lexer.deinit();

    const tokens = try lexer.tokenize();
    defer testing.allocator.free(tokens);

    var parser = try Parser.init(testing.allocator, tokens);
    defer parser.deinit();

    const program = try parser.parse();
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), program.statements.len);
}
