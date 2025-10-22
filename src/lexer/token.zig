const std = @import("std");

/// Token types for the Ion language
pub const TokenType = enum {
    // Single-character tokens
    LeftParen, // (
    RightParen, // )
    LeftBrace, // {
    RightBrace, // }
    LeftBracket, // [
    RightBracket, // ]
    Comma, // ,
    Dot, // .
    Semicolon, // ;
    Colon, // :
    Question, // ?
    At, // @

    // One or two character tokens
    Plus, // +
    PlusEqual, // +=
    Minus, // -
    MinusEqual, // -=
    Arrow, // ->
    Star, // *
    StarEqual, // *=
    Slash, // /
    SlashEqual, // /=
    Percent, // %
    PercentEqual, // %=
    Bang, // !
    BangEqual, // !=
    Equal, // =
    EqualEqual, // ==
    Greater, // >
    GreaterEqual, // >=
    Less, // <
    LessEqual, // <=
    Ampersand, // &
    AmpersandAmpersand, // &&
    Pipe, // |
    PipePipe, // ||

    // Literals
    Identifier,
    String,
    Integer,
    Float,

    // Keywords
    And,
    Async,
    Await,
    Break,
    Comptime,
    Const,
    Continue,
    Else,
    Enum,
    False,
    Fn,
    For,
    If,
    Impl,
    Import,
    In,
    Let,
    Loop,
    Match,
    Mut,
    Or,
    Return,
    Struct,
    True,
    Type,
    Unsafe,
    While,

    // Special
    Eof,
    Invalid,

    pub fn toString(self: TokenType) []const u8 {
        return switch (self) {
            .LeftParen => "(",
            .RightParen => ")",
            .LeftBrace => "{",
            .RightBrace => "}",
            .LeftBracket => "[",
            .RightBracket => "]",
            .Comma => ",",
            .Dot => ".",
            .Semicolon => ";",
            .Colon => ":",
            .Question => "?",
            .At => "@",
            .Plus => "+",
            .PlusEqual => "+=",
            .Minus => "-",
            .MinusEqual => "-=",
            .Arrow => "->",
            .Star => "*",
            .StarEqual => "*=",
            .Slash => "/",
            .SlashEqual => "/=",
            .Percent => "%",
            .PercentEqual => "%=",
            .Bang => "!",
            .BangEqual => "!=",
            .Equal => "=",
            .EqualEqual => "==",
            .Greater => ">",
            .GreaterEqual => ">=",
            .Less => "<",
            .LessEqual => "<=",
            .Ampersand => "&",
            .AmpersandAmpersand => "&&",
            .Pipe => "|",
            .PipePipe => "||",
            .Identifier => "identifier",
            .String => "string",
            .Integer => "integer",
            .Float => "float",
            .And => "and",
            .Async => "async",
            .Await => "await",
            .Break => "break",
            .Comptime => "comptime",
            .Const => "const",
            .Continue => "continue",
            .Else => "else",
            .Enum => "enum",
            .False => "false",
            .Fn => "fn",
            .For => "for",
            .If => "if",
            .Impl => "impl",
            .Import => "import",
            .In => "in",
            .Let => "let",
            .Loop => "loop",
            .Match => "match",
            .Mut => "mut",
            .Or => "or",
            .Return => "return",
            .Struct => "struct",
            .True => "true",
            .Type => "type",
            .Unsafe => "unsafe",
            .While => "while",
            .Eof => "eof",
            .Invalid => "invalid",
        };
    }
};

/// Represents a single token in the source code
pub const Token = struct {
    type: TokenType,
    lexeme: []const u8,
    line: usize,
    column: usize,

    pub fn init(token_type: TokenType, lexeme: []const u8, line: usize, column: usize) Token {
        return Token{
            .type = token_type,
            .lexeme = lexeme,
            .line = line,
            .column = column,
        };
    }

    pub fn format(
        self: Token,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{s:<16} '{s}' ({d}:{d})", .{
            @tagName(self.type),
            self.lexeme,
            self.line,
            self.column,
        });
    }
};

/// Keyword map for O(1) lookup
pub const keywords = std.ComptimeStringMap(TokenType, .{
    .{ "and", .And },
    .{ "async", .Async },
    .{ "await", .Await },
    .{ "break", .Break },
    .{ "comptime", .Comptime },
    .{ "const", .Const },
    .{ "continue", .Continue },
    .{ "else", .Else },
    .{ "enum", .Enum },
    .{ "false", .False },
    .{ "fn", .Fn },
    .{ "for", .For },
    .{ "if", .If },
    .{ "impl", .Impl },
    .{ "import", .Import },
    .{ "in", .In },
    .{ "let", .Let },
    .{ "loop", .Loop },
    .{ "match", .Match },
    .{ "mut", .Mut },
    .{ "or", .Or },
    .{ "return", .Return },
    .{ "struct", .Struct },
    .{ "true", .True },
    .{ "type", .Type },
    .{ "unsafe", .Unsafe },
    .{ "while", .While },
});
