const std = @import("std");
const testing = std.testing;
const Lexer = @import("lexer").Lexer;
const TokenType = @import("lexer").TokenType;

test "raw string - basic" {
    const allocator = testing.allocator;
    const source = "r\"hello\"";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), tokens.items.len); // String + EOF
    try testing.expectEqual(TokenType.String, tokens.items[0].type);
    try testing.expectEqualStrings("r\"hello\"", tokens.items[0].lexeme);
}

test "raw string - with backslash" {
    const allocator = testing.allocator;
    const source = "r\"C:\\path\\to\\file\"";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(TokenType.String, tokens.items[0].type);
    try testing.expectEqualStrings("r\"C:\\path\\to\\file\"", tokens.items[0].lexeme);
}

test "raw string - with escape sequences (not processed)" {
    const allocator = testing.allocator;
    const source = "r\"\\n\\t\\r\"";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(TokenType.String, tokens.items[0].type);
    // Raw string should preserve literal backslashes
}

test "raw string with hash delimiter - basic" {
    const allocator = testing.allocator;
    const source = "r#\"hello\"#";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(TokenType.String, tokens.items[0].type);
    try testing.expectEqualStrings("r#\"hello\"#", tokens.items[0].lexeme);
}

test "raw string with hash - containing quotes" {
    const allocator = testing.allocator;
    const source = "r#\"String with \"quotes\" inside\"#";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(TokenType.String, tokens.items[0].type);
    try testing.expectEqualStrings("r#\"String with \"quotes\" inside\"#", tokens.items[0].lexeme);
}

test "raw string with multiple hashes" {
    const allocator = testing.allocator;
    const source = "r##\"hello\"##";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(TokenType.String, tokens.items[0].type);
    try testing.expectEqualStrings("r##\"hello\"##", tokens.items[0].lexeme);
}

test "raw string with hashes - containing single hash" {
    const allocator = testing.allocator;
    const source = "r##\"Text with # symbol\"##";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(TokenType.String, tokens.items[0].type);
}

test "raw string with hashes - containing quote and hash" {
    const allocator = testing.allocator;
    const source = "r##\"Quote: \" and hash: #\"##";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(TokenType.String, tokens.items[0].type);
}

test "raw string - multiline" {
    const allocator = testing.allocator;
    const source = "r\"line1\nline2\nline3\"";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(TokenType.String, tokens.items[0].type);
}

test "raw string with hash - multiline" {
    const allocator = testing.allocator;
    const source = "r#\"line1\nline2\nline3\"#";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(TokenType.String, tokens.items[0].type);
}

test "raw string - empty" {
    const allocator = testing.allocator;
    const source = "r\"\"";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(TokenType.String, tokens.items[0].type);
}

test "raw string with hash - empty" {
    const allocator = testing.allocator;
    const source = "r#\"\"#";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(TokenType.String, tokens.items[0].type);
}

test "raw string - regex pattern" {
    const allocator = testing.allocator;
    const source = "r\"^\\d{3}-\\d{2}-\\d{4}$\"";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(TokenType.String, tokens.items[0].type);
    // Should preserve regex special characters
}

test "raw string - JSON example" {
    const allocator = testing.allocator;
    const source = "r#\"{\"key\": \"value\"}\"#";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(TokenType.String, tokens.items[0].type);
}

test "multiple raw strings in sequence" {
    const allocator = testing.allocator;
    const source = "r\"first\" r#\"second\"# r##\"third\"##";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(@as(usize, 4), tokens.items.len); // 3 strings + EOF
    try testing.expectEqual(TokenType.String, tokens.items[0].type);
    try testing.expectEqual(TokenType.String, tokens.items[1].type);
    try testing.expectEqual(TokenType.String, tokens.items[2].type);
}

test "invalid raw string - mismatched hash count" {
    const allocator = testing.allocator;
    const source = "r##\"hello\"#";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    // Should be Invalid because closing delimiter doesn't match
    try testing.expectEqual(TokenType.Invalid, tokens.items[0].type);
}

test "invalid raw string - no opening quote" {
    const allocator = testing.allocator;
    const source = "r#hello\"#";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(TokenType.Invalid, tokens.items[0].type);
}

test "invalid raw string - unterminated" {
    const allocator = testing.allocator;
    const source = "r\"unterminated";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(TokenType.Invalid, tokens.items[0].type);
}

test "raw string vs regular string" {
    const allocator = testing.allocator;
    const source = "r\"\\n\" \"\\n\"";

    var lexer = Lexer.init(allocator, source);
    const tokens = try lexer.tokenize();
    defer tokens.deinit(allocator);

    try testing.expectEqual(@as(usize, 3), tokens.items.len); // 2 strings + EOF
    try testing.expectEqual(TokenType.String, tokens.items[0].type);
    try testing.expectEqual(TokenType.String, tokens.items[1].type);

    // First should be raw (preserves \\n), second should be regular (processes escape)
    try testing.expectEqualStrings("r\"\\n\"", tokens.items[0].lexeme);
    try testing.expectEqualStrings("\"\\n\"", tokens.items[1].lexeme);
}
