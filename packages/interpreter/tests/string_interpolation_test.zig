const std = @import("std");
const testing = std.testing;
const Interpreter = @import("interpreter").Interpreter;
const Parser = @import("parser").Parser;
const Lexer = @import("lexer").Lexer;
const ast = @import("ast");
const Value = @import("interpreter").Value;

fn evalSource(allocator: std.mem.Allocator, source: []const u8) !Value {
    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    var parser = Parser.init(allocator, tokens.items);
    defer parser.deinit();

    const program = try parser.parse();

    var interpreter = try Interpreter.init(allocator);
    defer interpreter.deinit();

    return try interpreter.interpret(program);
}

test "evaluate simple interpolated string" {
    const allocator = testing.allocator;
    const source =
        \\let name = "World"
        \\let greeting = "Hello {name}!"
        \\greeting
    ;

    const result = try evalSource(allocator, source);
    try testing.expectEqual(Value.String, @as(@TypeOf(result), result));
    try testing.expectEqualStrings("Hello World!", result.String);
}

test "evaluate multiple interpolations" {
    const allocator = testing.allocator;
    const source =
        \\let first = "John"
        \\let last = "Doe"
        \\let full = "Hello {first} {last}!"
        \\full
    ;

    const result = try evalSource(allocator, source);
    try testing.expectEqualStrings("Hello John Doe!", result.String);
}

test "evaluate interpolation with numbers" {
    const allocator = testing.allocator;
    const source =
        \\let x = 42
        \\let msg = "The answer is {x}"
        \\msg
    ;

    const result = try evalSource(allocator, source);
    try testing.expectEqualStrings("The answer is 42", result.String);
}

test "evaluate interpolation with expression" {
    const allocator = testing.allocator;
    const source =
        \\let x = 10
        \\let msg = "Result: {x + 5}"
        \\msg
    ;

    const result = try evalSource(allocator, source);
    try testing.expectEqualStrings("Result: 15", result.String);
}

test "evaluate interpolation with function call" {
    const allocator = testing.allocator;
    const source =
        \\fn double(x) { return x * 2 }
        \\let msg = "Double of 21 is {double(21)}"
        \\msg
    ;

    const result = try evalSource(allocator, source);
    try testing.expectEqualStrings("Double of 21 is 42", result.String);
}

test "evaluate interpolation with boolean" {
    const allocator = testing.allocator;
    const source =
        \\let flag = true
        \\let msg = "Flag is {flag}"
        \\msg
    ;

    const result = try evalSource(allocator, source);
    try testing.expectEqualStrings("Flag is true", result.String);
}

test "evaluate nested interpolations" {
    const allocator = testing.allocator;
    const source =
        \\let a = 1
        \\let b = 2
        \\let msg = "Sum: {a + b}, Product: {a * b}"
        \\msg
    ;

    const result = try evalSource(allocator, source);
    try testing.expectEqualStrings("Sum: 3, Product: 2", result.String);
}

test "evaluate empty string parts" {
    const allocator = testing.allocator;
    const source =
        \\let x = 42
        \\let msg = "{x}"
        \\msg
    ;

    const result = try evalSource(allocator, source);
    try testing.expectEqualStrings("42", result.String);
}
