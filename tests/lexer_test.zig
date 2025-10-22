const std = @import("std");
const testing = std.testing;
const Lexer = @import("../src/lexer/lexer.zig").Lexer;
const TokenType = @import("../src/lexer/token.zig").TokenType;

test "lexer: empty source" {
    var lexer = Lexer.init(testing.allocator, "");
    const tokens = try lexer.tokenize();
    defer tokens.deinit();

    try testing.expectEqual(@as(usize, 1), tokens.items.len);
    try testing.expectEqual(TokenType.Eof, tokens.items[0].type);
}

test "lexer: whitespace only" {
    var lexer = Lexer.init(testing.allocator, "   \n\t  \r\n  ");
    const tokens = try lexer.tokenize();
    defer tokens.deinit();

    try testing.expectEqual(@as(usize, 1), tokens.items.len);
    try testing.expectEqual(TokenType.Eof, tokens.items[0].type);
}

test "lexer: single-line comments" {
    var lexer = Lexer.init(testing.allocator, "// comment\nfoo // another comment\n// final comment");
    const tokens = try lexer.tokenize();
    defer tokens.deinit();

    try testing.expectEqual(@as(usize, 2), tokens.items.len); // foo + EOF
    try testing.expectEqual(TokenType.Identifier, tokens.items[0].type);
    try testing.expectEqualStrings("foo", tokens.items[0].lexeme);
}

test "lexer: all single-char tokens" {
    var lexer = Lexer.init(testing.allocator, "(){}[];,.:?@");
    const tokens = try lexer.tokenize();
    defer tokens.deinit();

    const expected = [_]TokenType{
        .LeftParen, .RightParen, .LeftBrace, .RightBrace,
        .LeftBracket, .RightBracket, .Semicolon, .Comma,
        .Dot, .Colon, .Question, .At,
    };

    try testing.expectEqual(expected.len + 1, tokens.items.len); // +1 for EOF
    for (expected, 0..) |expected_type, i| {
        try testing.expectEqual(expected_type, tokens.items[i].type);
    }
}

test "lexer: arithmetic operators" {
    var lexer = Lexer.init(testing.allocator, "+ - * / %");
    const tokens = try lexer.tokenize();
    defer tokens.deinit();

    try testing.expectEqual(TokenType.Plus, tokens.items[0].type);
    try testing.expectEqual(TokenType.Minus, tokens.items[1].type);
    try testing.expectEqual(TokenType.Star, tokens.items[2].type);
    try testing.expectEqual(TokenType.Slash, tokens.items[3].type);
    try testing.expectEqual(TokenType.Percent, tokens.items[4].type);
}

test "lexer: compound assignment operators" {
    var lexer = Lexer.init(testing.allocator, "+= -= *= /= %=");
    const tokens = try lexer.tokenize();
    defer tokens.deinit();

    try testing.expectEqual(TokenType.PlusEqual, tokens.items[0].type);
    try testing.expectEqual(TokenType.MinusEqual, tokens.items[1].type);
    try testing.expectEqual(TokenType.StarEqual, tokens.items[2].type);
    try testing.expectEqual(TokenType.SlashEqual, tokens.items[3].type);
    try testing.expectEqual(TokenType.PercentEqual, tokens.items[4].type);
}

test "lexer: comparison operators" {
    var lexer = Lexer.init(testing.allocator, "== != < <= > >=");
    const tokens = try lexer.tokenize();
    defer tokens.deinit();

    try testing.expectEqual(TokenType.EqualEqual, tokens.items[0].type);
    try testing.expectEqual(TokenType.BangEqual, tokens.items[1].type);
    try testing.expectEqual(TokenType.Less, tokens.items[2].type);
    try testing.expectEqual(TokenType.LessEqual, tokens.items[3].type);
    try testing.expectEqual(TokenType.Greater, tokens.items[4].type);
    try testing.expectEqual(TokenType.GreaterEqual, tokens.items[5].type);
}

test "lexer: logical operators" {
    var lexer = Lexer.init(testing.allocator, "&& || !");
    const tokens = try lexer.tokenize();
    defer tokens.deinit();

    try testing.expectEqual(TokenType.AmpersandAmpersand, tokens.items[0].type);
    try testing.expectEqual(TokenType.PipePipe, tokens.items[1].type);
    try testing.expectEqual(TokenType.Bang, tokens.items[2].type);
}

test "lexer: arrow operator" {
    var lexer = Lexer.init(testing.allocator, "->");
    const tokens = try lexer.tokenize();
    defer tokens.deinit();

    try testing.expectEqual(TokenType.Arrow, tokens.items[0].type);
    try testing.expectEqualStrings("->", tokens.items[0].lexeme);
}

test "lexer: integers" {
    var lexer = Lexer.init(testing.allocator, "0 123 456789");
    const tokens = try lexer.tokenize();
    defer tokens.deinit();

    try testing.expectEqual(TokenType.Integer, tokens.items[0].type);
    try testing.expectEqualStrings("0", tokens.items[0].lexeme);
    try testing.expectEqual(TokenType.Integer, tokens.items[1].type);
    try testing.expectEqualStrings("123", tokens.items[1].lexeme);
    try testing.expectEqual(TokenType.Integer, tokens.items[2].type);
    try testing.expectEqualStrings("456789", tokens.items[2].lexeme);
}

test "lexer: floats" {
    var lexer = Lexer.init(testing.allocator, "3.14 0.5 123.456");
    const tokens = try lexer.tokenize();
    defer tokens.deinit();

    try testing.expectEqual(TokenType.Float, tokens.items[0].type);
    try testing.expectEqualStrings("3.14", tokens.items[0].lexeme);
    try testing.expectEqual(TokenType.Float, tokens.items[1].type);
    try testing.expectEqualStrings("0.5", tokens.items[1].lexeme);
    try testing.expectEqual(TokenType.Float, tokens.items[2].type);
    try testing.expectEqualStrings("123.456", tokens.items[2].lexeme);
}

test "lexer: strings" {
    var lexer = Lexer.init(testing.allocator, "\"hello\" \"world\" \"foo bar\"");
    const tokens = try lexer.tokenize();
    defer tokens.deinit();

    try testing.expectEqual(TokenType.String, tokens.items[0].type);
    try testing.expectEqualStrings("\"hello\"", tokens.items[0].lexeme);
    try testing.expectEqual(TokenType.String, tokens.items[1].type);
    try testing.expectEqualStrings("\"world\"", tokens.items[1].lexeme);
    try testing.expectEqual(TokenType.String, tokens.items[2].type);
    try testing.expectEqualStrings("\"foo bar\"", tokens.items[2].lexeme);
}

test "lexer: multiline strings" {
    var lexer = Lexer.init(testing.allocator, "\"hello\nworld\"");
    const tokens = try lexer.tokenize();
    defer tokens.deinit();

    try testing.expectEqual(TokenType.String, tokens.items[0].type);
    try testing.expectEqual(@as(usize, 1), tokens.items[0].line);
}

test "lexer: identifiers" {
    var lexer = Lexer.init(testing.allocator, "foo bar _test variable123 _");
    const tokens = try lexer.tokenize();
    defer tokens.deinit();

    const expected = [_][]const u8{ "foo", "bar", "_test", "variable123", "_" };
    for (expected, 0..) |expected_id, i| {
        try testing.expectEqual(TokenType.Identifier, tokens.items[i].type);
        try testing.expectEqualStrings(expected_id, tokens.items[i].lexeme);
    }
}

test "lexer: keywords" {
    var lexer = Lexer.init(testing.allocator, "fn let const if else return struct enum match async await");
    const tokens = try lexer.tokenize();
    defer tokens.deinit();

    const expected = [_]TokenType{
        .Fn, .Let, .Const, .If, .Else, .Return, .Struct, .Enum, .Match, .Async, .Await,
    };

    for (expected, 0..) |expected_type, i| {
        try testing.expectEqual(expected_type, tokens.items[i].type);
    }
}

test "lexer: all keywords" {
    var lexer = Lexer.init(testing.allocator,
        \\and async await break comptime const continue else enum false
        \\fn for if impl import in let loop match mut or return struct
        \\true type unsafe while
    );
    const tokens = try lexer.tokenize();
    defer tokens.deinit();

    const expected = [_]TokenType{
        .And, .Async, .Await, .Break, .Comptime, .Const, .Continue, .Else, .Enum, .False,
        .Fn, .For, .If, .Impl, .Import, .In, .Let, .Loop, .Match, .Mut, .Or, .Return, .Struct,
        .True, .Type, .Unsafe, .While,
    };

    for (expected, 0..) |expected_type, i| {
        try testing.expectEqual(expected_type, tokens.items[i].type);
    }
}

test "lexer: line and column tracking" {
    var lexer = Lexer.init(testing.allocator, "foo\nbar\nbaz");
    const tokens = try lexer.tokenize();
    defer tokens.deinit();

    try testing.expectEqual(@as(usize, 1), tokens.items[0].line);
    try testing.expectEqual(@as(usize, 1), tokens.items[0].column);

    try testing.expectEqual(@as(usize, 2), tokens.items[1].line);
    try testing.expectEqual(@as(usize, 1), tokens.items[1].column);

    try testing.expectEqual(@as(usize, 3), tokens.items[2].line);
    try testing.expectEqual(@as(usize, 1), tokens.items[2].column);
}

test "lexer: function declaration" {
    var lexer = Lexer.init(testing.allocator, "fn main() {}");
    const tokens = try lexer.tokenize();
    defer tokens.deinit();

    try testing.expectEqual(TokenType.Fn, tokens.items[0].type);
    try testing.expectEqual(TokenType.Identifier, tokens.items[1].type);
    try testing.expectEqualStrings("main", tokens.items[1].lexeme);
    try testing.expectEqual(TokenType.LeftParen, tokens.items[2].type);
    try testing.expectEqual(TokenType.RightParen, tokens.items[3].type);
    try testing.expectEqual(TokenType.LeftBrace, tokens.items[4].type);
    try testing.expectEqual(TokenType.RightBrace, tokens.items[5].type);
}

test "lexer: let statement" {
    var lexer = Lexer.init(testing.allocator, "let x = 42");
    const tokens = try lexer.tokenize();
    defer tokens.deinit();

    try testing.expectEqual(TokenType.Let, tokens.items[0].type);
    try testing.expectEqual(TokenType.Identifier, tokens.items[1].type);
    try testing.expectEqualStrings("x", tokens.items[1].lexeme);
    try testing.expectEqual(TokenType.Equal, tokens.items[2].type);
    try testing.expectEqual(TokenType.Integer, tokens.items[3].type);
    try testing.expectEqualStrings("42", tokens.items[3].lexeme);
}

test "lexer: struct definition" {
    var lexer = Lexer.init(testing.allocator, "struct User { name: string }");
    const tokens = try lexer.tokenize();
    defer tokens.deinit();

    try testing.expectEqual(TokenType.Struct, tokens.items[0].type);
    try testing.expectEqual(TokenType.Identifier, tokens.items[1].type);
    try testing.expectEqualStrings("User", tokens.items[1].lexeme);
    try testing.expectEqual(TokenType.LeftBrace, tokens.items[2].type);
    try testing.expectEqual(TokenType.Identifier, tokens.items[3].type);
    try testing.expectEqualStrings("name", tokens.items[3].lexeme);
    try testing.expectEqual(TokenType.Colon, tokens.items[4].type);
}

test "lexer: if statement" {
    var lexer = Lexer.init(testing.allocator, "if x > 0 { return true }");
    const tokens = try lexer.tokenize();
    defer tokens.deinit();

    try testing.expectEqual(TokenType.If, tokens.items[0].type);
    try testing.expectEqual(TokenType.Identifier, tokens.items[1].type);
    try testing.expectEqual(TokenType.Greater, tokens.items[2].type);
    try testing.expectEqual(TokenType.Integer, tokens.items[3].type);
    try testing.expectEqual(TokenType.LeftBrace, tokens.items[4].type);
    try testing.expectEqual(TokenType.Return, tokens.items[5].type);
    try testing.expectEqual(TokenType.True, tokens.items[6].type);
    try testing.expectEqual(TokenType.RightBrace, tokens.items[7].type);
}

test "lexer: async function" {
    var lexer = Lexer.init(testing.allocator, "async fn fetch() -> User { await get_user() }");
    const tokens = try lexer.tokenize();
    defer tokens.deinit();

    try testing.expectEqual(TokenType.Async, tokens.items[0].type);
    try testing.expectEqual(TokenType.Fn, tokens.items[1].type);
    try testing.expectEqual(TokenType.Identifier, tokens.items[2].type);
    try testing.expectEqual(TokenType.LeftParen, tokens.items[3].type);
    try testing.expectEqual(TokenType.RightParen, tokens.items[4].type);
    try testing.expectEqual(TokenType.Arrow, tokens.items[5].type);
    try testing.expectEqual(TokenType.Identifier, tokens.items[6].type);
    try testing.expectEqual(TokenType.LeftBrace, tokens.items[7].type);
    try testing.expectEqual(TokenType.Await, tokens.items[8].type);
}

test "lexer: complex expression" {
    var lexer = Lexer.init(testing.allocator, "(x + y) * z >= 100 && active");
    const tokens = try lexer.tokenize();
    defer tokens.deinit();

    try testing.expectEqual(@as(usize, 12), tokens.items.len); // including EOF
    try testing.expectEqual(TokenType.LeftParen, tokens.items[0].type);
    try testing.expectEqual(TokenType.Identifier, tokens.items[1].type);
    try testing.expectEqual(TokenType.Plus, tokens.items[2].type);
    try testing.expectEqual(TokenType.Identifier, tokens.items[3].type);
    try testing.expectEqual(TokenType.RightParen, tokens.items[4].type);
    try testing.expectEqual(TokenType.Star, tokens.items[5].type);
    try testing.expectEqual(TokenType.Identifier, tokens.items[6].type);
    try testing.expectEqual(TokenType.GreaterEqual, tokens.items[7].type);
    try testing.expectEqual(TokenType.Integer, tokens.items[8].type);
    try testing.expectEqual(TokenType.AmpersandAmpersand, tokens.items[9].type);
    try testing.expectEqual(TokenType.Identifier, tokens.items[10].type);
}
