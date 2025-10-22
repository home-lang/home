const std = @import("std");
pub const Token = @import("token.zig").Token;
pub const TokenType = @import("token.zig").TokenType;
const keywords = @import("token.zig").keywords;

/// Lexer for the Ion programming language
pub const Lexer = struct {
    source: []const u8,
    start: usize,
    current: usize,
    line: usize,
    column: usize,
    start_column: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Lexer {
        return Lexer{
            .source = source,
            .start = 0,
            .current = 0,
            .line = 1,
            .column = 1,
            .start_column = 1,
            .allocator = allocator,
        };
    }

    /// Check if we've reached the end of the source
    fn isAtEnd(self: *Lexer) bool {
        return self.current >= self.source.len;
    }

    /// Advance to the next character and return the current one
    fn advance(self: *Lexer) u8 {
        const c = self.source[self.current];
        self.current += 1;
        self.column += 1;
        return c;
    }

    /// Peek at the current character without advancing
    fn peek(self: *Lexer) u8 {
        if (self.isAtEnd()) return 0;
        return self.source[self.current];
    }

    /// Peek at the next character without advancing
    fn peekNext(self: *Lexer) u8 {
        if (self.current + 1 >= self.source.len) return 0;
        return self.source[self.current + 1];
    }

    /// Check if the next character matches the expected one and advance if so
    fn match(self: *Lexer, expected: u8) bool {
        if (self.isAtEnd()) return false;
        if (self.source[self.current] != expected) return false;
        self.current += 1;
        self.column += 1;
        return true;
    }

    /// Create a token from the current lexeme
    fn makeToken(self: *Lexer, token_type: TokenType) Token {
        const lexeme = self.source[self.start..self.current];
        return Token.init(token_type, lexeme, self.line, self.start_column);
    }

    /// Skip whitespace characters
    fn skipWhitespace(self: *Lexer) void {
        while (!self.isAtEnd()) {
            const c = self.peek();
            switch (c) {
                ' ', '\r', '\t' => {
                    _ = self.advance();
                },
                '\n' => {
                    self.line += 1;
                    self.column = 0;
                    _ = self.advance();
                },
                '/' => {
                    if (self.peekNext() == '/') {
                        // Skip single-line comment
                        while (self.peek() != '\n' and !self.isAtEnd()) {
                            _ = self.advance();
                        }
                    } else {
                        return;
                    }
                },
                else => return,
            }
        }
    }

    /// Lex a string literal
    fn string(self: *Lexer) Token {
        // Skip opening quote
        while (self.peek() != '"' and !self.isAtEnd()) {
            if (self.peek() == '\n') {
                self.line += 1;
                self.column = 0;
            }
            _ = self.advance();
        }

        if (self.isAtEnd()) {
            return self.makeToken(.Invalid);
        }

        // Consume closing quote
        _ = self.advance();

        return self.makeToken(.String);
    }

    /// Lex a number (integer or float)
    fn number(self: *Lexer) Token {
        while (std.ascii.isDigit(self.peek())) {
            _ = self.advance();
        }

        // Check for decimal point
        if (self.peek() == '.' and std.ascii.isDigit(self.peekNext())) {
            // Consume the '.'
            _ = self.advance();

            while (std.ascii.isDigit(self.peek())) {
                _ = self.advance();
            }

            return self.makeToken(.Float);
        }

        return self.makeToken(.Integer);
    }

    /// Lex an identifier or keyword
    fn identifier(self: *Lexer) Token {
        while (std.ascii.isAlphanumeric(self.peek()) or self.peek() == '_') {
            _ = self.advance();
        }

        const text = self.source[self.start..self.current];
        const token_type = keywords.get(text) orelse .Identifier;

        return self.makeToken(token_type);
    }

    /// Scan and return the next token
    pub fn scanToken(self: *Lexer) Token {
        self.skipWhitespace();

        self.start = self.current;
        self.start_column = self.column;

        if (self.isAtEnd()) {
            return self.makeToken(.Eof);
        }

        const c = self.advance();

        // Identifiers and keywords
        if (std.ascii.isAlphabetic(c) or c == '_') {
            return self.identifier();
        }

        // Numbers
        if (std.ascii.isDigit(c)) {
            return self.number();
        }

        // String literals
        if (c == '"') {
            return self.string();
        }

        // Operators and punctuation
        return switch (c) {
            '(' => self.makeToken(.LeftParen),
            ')' => self.makeToken(.RightParen),
            '{' => self.makeToken(.LeftBrace),
            '}' => self.makeToken(.RightBrace),
            '[' => self.makeToken(.LeftBracket),
            ']' => self.makeToken(.RightBracket),
            ',' => self.makeToken(.Comma),
            '.' => self.makeToken(.Dot),
            ';' => self.makeToken(.Semicolon),
            ':' => self.makeToken(.Colon),
            '?' => self.makeToken(.Question),
            '@' => self.makeToken(.At),
            '+' => if (self.match('=')) self.makeToken(.PlusEqual) else self.makeToken(.Plus),
            '-' => if (self.match('>')) self.makeToken(.Arrow) else if (self.match('=')) self.makeToken(.MinusEqual) else self.makeToken(.Minus),
            '*' => if (self.match('=')) self.makeToken(.StarEqual) else self.makeToken(.Star),
            '/' => if (self.match('=')) self.makeToken(.SlashEqual) else self.makeToken(.Slash),
            '%' => if (self.match('=')) self.makeToken(.PercentEqual) else self.makeToken(.Percent),
            '!' => if (self.match('=')) self.makeToken(.BangEqual) else self.makeToken(.Bang),
            '=' => if (self.match('=')) self.makeToken(.EqualEqual) else self.makeToken(.Equal),
            '>' => if (self.match('=')) self.makeToken(.GreaterEqual) else self.makeToken(.Greater),
            '<' => if (self.match('=')) self.makeToken(.LessEqual) else self.makeToken(.Less),
            '&' => if (self.match('&')) self.makeToken(.AmpersandAmpersand) else self.makeToken(.Ampersand),
            '|' => if (self.match('|')) self.makeToken(.PipePipe) else self.makeToken(.Pipe),
            else => self.makeToken(.Invalid),
        };
    }

    /// Tokenize the entire source and return all tokens
    pub fn tokenize(self: *Lexer) !std.ArrayList(Token) {
        var tokens = std.ArrayList(Token){ .items = &.{}, .capacity = 0 };

        while (true) {
            const token = self.scanToken();
            try tokens.append(self.allocator, token);
            if (token.type == .Eof) break;
        }

        return tokens;
    }
};

test "lexer: single tokens" {
    const testing = std.testing;
    var lexer = Lexer.init(testing.allocator, "(){}[];,.");
    var tokens = try lexer.tokenize();
    defer tokens.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 9), tokens.items.len); // 8 tokens + EOF
    try testing.expectEqual(TokenType.LeftParen, tokens.items[0].type);
    try testing.expectEqual(TokenType.RightParen, tokens.items[1].type);
    try testing.expectEqual(TokenType.LeftBrace, tokens.items[2].type);
    try testing.expectEqual(TokenType.RightBrace, tokens.items[3].type);
    try testing.expectEqual(TokenType.LeftBracket, tokens.items[4].type);
    try testing.expectEqual(TokenType.RightBracket, tokens.items[5].type);
    try testing.expectEqual(TokenType.Semicolon, tokens.items[6].type);
    try testing.expectEqual(TokenType.Comma, tokens.items[7].type);
    try testing.expectEqual(TokenType.Dot, tokens.items[8].type);
}

test "lexer: operators" {
    const testing = std.testing;
    var lexer = Lexer.init(testing.allocator, "+ += - -= -> * *= / /= == != < <= > >=");
    const tokens = try lexer.tokenize();
    defer tokens.deinit();

    try testing.expectEqual(TokenType.Plus, tokens.items[0].type);
    try testing.expectEqual(TokenType.PlusEqual, tokens.items[1].type);
    try testing.expectEqual(TokenType.Minus, tokens.items[2].type);
    try testing.expectEqual(TokenType.MinusEqual, tokens.items[3].type);
    try testing.expectEqual(TokenType.Arrow, tokens.items[4].type);
    try testing.expectEqual(TokenType.Star, tokens.items[5].type);
    try testing.expectEqual(TokenType.StarEqual, tokens.items[6].type);
}

test "lexer: integers" {
    const testing = std.testing;
    var lexer = Lexer.init(testing.allocator, "123 456 0");
    const tokens = try lexer.tokenize();
    defer tokens.deinit();

    try testing.expectEqual(TokenType.Integer, tokens.items[0].type);
    try testing.expectEqualStrings("123", tokens.items[0].lexeme);
    try testing.expectEqual(TokenType.Integer, tokens.items[1].type);
    try testing.expectEqualStrings("456", tokens.items[1].lexeme);
}

test "lexer: floats" {
    const testing = std.testing;
    var lexer = Lexer.init(testing.allocator, "3.14 0.5 99.99");
    const tokens = try lexer.tokenize();
    defer tokens.deinit();

    try testing.expectEqual(TokenType.Float, tokens.items[0].type);
    try testing.expectEqualStrings("3.14", tokens.items[0].lexeme);
    try testing.expectEqual(TokenType.Float, tokens.items[1].type);
    try testing.expectEqualStrings("0.5", tokens.items[1].lexeme);
}

test "lexer: strings" {
    const testing = std.testing;
    var lexer = Lexer.init(testing.allocator, "\"hello\" \"world\"");
    const tokens = try lexer.tokenize();
    defer tokens.deinit();

    try testing.expectEqual(TokenType.String, tokens.items[0].type);
    try testing.expectEqualStrings("\"hello\"", tokens.items[0].lexeme);
    try testing.expectEqual(TokenType.String, tokens.items[1].type);
    try testing.expectEqualStrings("\"world\"", tokens.items[1].lexeme);
}

test "lexer: identifiers" {
    const testing = std.testing;
    var lexer = Lexer.init(testing.allocator, "foo bar _test variable123");
    const tokens = try lexer.tokenize();
    defer tokens.deinit();

    try testing.expectEqual(TokenType.Identifier, tokens.items[0].type);
    try testing.expectEqualStrings("foo", tokens.items[0].lexeme);
    try testing.expectEqual(TokenType.Identifier, tokens.items[1].type);
    try testing.expectEqualStrings("bar", tokens.items[1].lexeme);
}

test "lexer: keywords" {
    const testing = std.testing;
    var lexer = Lexer.init(testing.allocator, "fn let const if else return");
    const tokens = try lexer.tokenize();
    defer tokens.deinit();

    try testing.expectEqual(TokenType.Fn, tokens.items[0].type);
    try testing.expectEqual(TokenType.Let, tokens.items[1].type);
    try testing.expectEqual(TokenType.Const, tokens.items[2].type);
    try testing.expectEqual(TokenType.If, tokens.items[3].type);
    try testing.expectEqual(TokenType.Else, tokens.items[4].type);
    try testing.expectEqual(TokenType.Return, tokens.items[5].type);
}

test "lexer: comments" {
    const testing = std.testing;
    var lexer = Lexer.init(testing.allocator, "foo // this is a comment\nbar");
    const tokens = try lexer.tokenize();
    defer tokens.deinit();

    try testing.expectEqual(@as(usize, 3), tokens.items.len); // foo, bar, EOF
    try testing.expectEqual(TokenType.Identifier, tokens.items[0].type);
    try testing.expectEqualStrings("foo", tokens.items[0].lexeme);
    try testing.expectEqual(TokenType.Identifier, tokens.items[1].type);
    try testing.expectEqualStrings("bar", tokens.items[1].lexeme);
}
