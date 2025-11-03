const std = @import("std");
const testing = std.testing;
const Lexer = @import("lexer").Lexer;
const TokenType = @import("lexer").TokenType;

test "simple string interpolation" {
    const allocator = testing.allocator;
    const source = "\"Hello {name}!\"";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    // Should get: StringInterpolationStart, Identifier, StringInterpolationEnd
    try testing.expectEqual(@as(usize, 4), tokens.items.len); // +1 for EOF
    try testing.expectEqual(TokenType.StringInterpolationStart, tokens.items[0].type);
    try testing.expectEqualStrings("\"Hello ", tokens.items[0].lexeme);

    try testing.expectEqual(TokenType.Identifier, tokens.items[1].type);
    try testing.expectEqualStrings("name", tokens.items[1].lexeme);

    try testing.expectEqual(TokenType.StringInterpolationEnd, tokens.items[2].type);
    try testing.expectEqualStrings("!\"", tokens.items[2].lexeme);
}

test "multiple interpolations" {
    const allocator = testing.allocator;
    const source = "\"Hello {first} {last}!\"";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    // Should get: StringInterpolationStart, first, StringInterpolationMid, last, StringInterpolationEnd
    try testing.expectEqual(@as(usize, 6), tokens.items.len); // +1 for EOF
    try testing.expectEqual(TokenType.StringInterpolationStart, tokens.items[0].type);
    try testing.expectEqual(TokenType.Identifier, tokens.items[1].type);
    try testing.expectEqual(TokenType.StringInterpolationMid, tokens.items[2].type);
    try testing.expectEqual(TokenType.Identifier, tokens.items[3].type);
    try testing.expectEqual(TokenType.StringInterpolationEnd, tokens.items[4].type);
}

test "interpolation with expression" {
    const allocator = testing.allocator;
    const source = "\"Result: {x + 1}\"";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    // Should get: StringInterpolationStart, x, +, 1, StringInterpolationEnd
    try testing.expectEqual(TokenType.StringInterpolationStart, tokens.items[0].type);
    try testing.expectEqual(TokenType.Identifier, tokens.items[1].type);
    try testing.expectEqual(TokenType.Plus, tokens.items[2].type);
    try testing.expectEqual(TokenType.Integer, tokens.items[3].type);
    try testing.expectEqual(TokenType.StringInterpolationEnd, tokens.items[4].type);
}

test "interpolation with function call" {
    const allocator = testing.allocator;
    const source = "\"Value: {foo(x)}\"";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    // Should get: StringInterpolationStart, foo, (, x, ), StringInterpolationEnd
    try testing.expectEqual(TokenType.StringInterpolationStart, tokens.items[0].type);
    try testing.expectEqual(TokenType.Identifier, tokens.items[1].type);
    try testing.expectEqual(TokenType.LeftParen, tokens.items[2].type);
    try testing.expectEqual(TokenType.Identifier, tokens.items[3].type);
    try testing.expectEqual(TokenType.RightParen, tokens.items[4].type);
    try testing.expectEqual(TokenType.StringInterpolationEnd, tokens.items[5].type);
}

test "interpolation with nested braces" {
    const allocator = testing.allocator;
    const source = "\"Result: {foo({bar})}\"";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    // Should handle nested braces correctly
    try testing.expectEqual(TokenType.StringInterpolationStart, tokens.items[0].type);
    try testing.expectEqual(TokenType.Identifier, tokens.items[1].type); // foo
    try testing.expectEqual(TokenType.LeftParen, tokens.items[2].type);
    try testing.expectEqual(TokenType.LeftBrace, tokens.items[3].type);
    try testing.expectEqual(TokenType.Identifier, tokens.items[4].type); // bar
    try testing.expectEqual(TokenType.RightBrace, tokens.items[5].type);
    try testing.expectEqual(TokenType.RightParen, tokens.items[6].type);
    try testing.expectEqual(TokenType.StringInterpolationEnd, tokens.items[7].type);
}

test "escaped brace in string" {
    const allocator = testing.allocator;
    const source = "\"Not interpolated: \\{value}\"";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    // Escaped brace should result in a simple string
    try testing.expectEqual(@as(usize, 2), tokens.items.len); // String + EOF
    try testing.expectEqual(TokenType.String, tokens.items[0].type);
}

test "empty interpolation parts" {
    const allocator = testing.allocator;
    const source = "\"{x}\"";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    // Should get: StringInterpolationStart (empty), x, StringInterpolationEnd (empty)
    try testing.expectEqual(TokenType.StringInterpolationStart, tokens.items[0].type);
    try testing.expectEqualStrings("\"", tokens.items[0].lexeme);
    try testing.expectEqual(TokenType.Identifier, tokens.items[1].type);
    try testing.expectEqual(TokenType.StringInterpolationEnd, tokens.items[2].type);
    try testing.expectEqualStrings("\"", tokens.items[2].lexeme);
}
