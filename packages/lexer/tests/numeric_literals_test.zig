const std = @import("std");
const testing = std.testing;
const Lexer = @import("lexer").Lexer;
const TokenType = @import("lexer").TokenType;

test "binary literals - basic" {
    const allocator = testing.allocator;
    const source = "0b1010";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), tokens.items.len); // Integer + EOF
    try testing.expectEqual(TokenType.Integer, tokens.items[0].type);
    try testing.expectEqualStrings("0b1010", tokens.items[0].lexeme);
}

test "binary literals - with underscores" {
    const allocator = testing.allocator;
    const source = "0b1010_1100";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(TokenType.Integer, tokens.items[0].type);
    try testing.expectEqualStrings("0b1010_1100", tokens.items[0].lexeme);
}

test "binary literals - all zeros" {
    const allocator = testing.allocator;
    const source = "0b0000";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(TokenType.Integer, tokens.items[0].type);
}

test "binary literals - all ones" {
    const allocator = testing.allocator;
    const source = "0b1111_1111";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(TokenType.Integer, tokens.items[0].type);
}

test "hexadecimal literals - basic" {
    const allocator = testing.allocator;
    const source = "0xFF";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(TokenType.Integer, tokens.items[0].type);
    try testing.expectEqualStrings("0xFF", tokens.items[0].lexeme);
}

test "hexadecimal literals - lowercase" {
    const allocator = testing.allocator;
    const source = "0xabcdef";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(TokenType.Integer, tokens.items[0].type);
    try testing.expectEqualStrings("0xabcdef", tokens.items[0].lexeme);
}

test "hexadecimal literals - uppercase" {
    const allocator = testing.allocator;
    const source = "0xABCDEF";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(TokenType.Integer, tokens.items[0].type);
}

test "hexadecimal literals - with underscores" {
    const allocator = testing.allocator;
    const source = "0xDEAD_BEEF";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(TokenType.Integer, tokens.items[0].type);
    try testing.expectEqualStrings("0xDEAD_BEEF", tokens.items[0].lexeme);
}

test "octal literals - basic" {
    const allocator = testing.allocator;
    const source = "0o755";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(TokenType.Integer, tokens.items[0].type);
    try testing.expectEqualStrings("0o755", tokens.items[0].lexeme);
}

test "octal literals - with underscores" {
    const allocator = testing.allocator;
    const source = "0o777_666";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(TokenType.Integer, tokens.items[0].type);
    try testing.expectEqualStrings("0o777_666", tokens.items[0].lexeme);
}

test "octal literals - all digits" {
    const allocator = testing.allocator;
    const source = "0o01234567";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(TokenType.Integer, tokens.items[0].type);
}

test "decimal with underscores" {
    const allocator = testing.allocator;
    const source = "1_000_000";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(TokenType.Integer, tokens.items[0].type);
    try testing.expectEqualStrings("1_000_000", tokens.items[0].lexeme);
}

test "decimal with multiple underscores" {
    const allocator = testing.allocator;
    const source = "123_456_789";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(TokenType.Integer, tokens.items[0].type);
}

test "float with underscores - integer part" {
    const allocator = testing.allocator;
    const source = "1_000.5";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(TokenType.Float, tokens.items[0].type);
    try testing.expectEqualStrings("1_000.5", tokens.items[0].lexeme);
}

test "float with underscores - fractional part" {
    const allocator = testing.allocator;
    const source = "3.141_592";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(TokenType.Float, tokens.items[0].type);
    try testing.expectEqualStrings("3.141_592", tokens.items[0].lexeme);
}

test "float with underscores - both parts" {
    const allocator = testing.allocator;
    const source = "1_234.567_89";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(TokenType.Float, tokens.items[0].type);
}

test "mixed numeric literals in expression" {
    const allocator = testing.allocator;
    const source = "0xFF + 0b1010 + 0o755 + 1_000";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    // Should get: hex, +, binary, +, octal, +, decimal, EOF
    try testing.expectEqual(TokenType.Integer, tokens.items[0].type);
    try testing.expectEqual(TokenType.Plus, tokens.items[1].type);
    try testing.expectEqual(TokenType.Integer, tokens.items[2].type);
    try testing.expectEqual(TokenType.Plus, tokens.items[3].type);
    try testing.expectEqual(TokenType.Integer, tokens.items[4].type);
    try testing.expectEqual(TokenType.Plus, tokens.items[5].type);
    try testing.expectEqual(TokenType.Integer, tokens.items[6].type);
}

test "invalid binary - no digits" {
    const allocator = testing.allocator;
    const source = "0b";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(TokenType.Invalid, tokens.items[0].type);
}

test "invalid hex - no digits" {
    const allocator = testing.allocator;
    const source = "0x";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(TokenType.Invalid, tokens.items[0].type);
}

test "invalid octal - no digits" {
    const allocator = testing.allocator;
    const source = "0o";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(TokenType.Invalid, tokens.items[0].type);
}
