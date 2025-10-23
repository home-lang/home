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
    DotDot, // ..
    DotDotEqual, // ..=
    DotDotDot, // ...
    Semicolon, // ;
    Colon, // :
    Question, // ?
    QuestionDot, // ?.
    QuestionQuestion, // ??
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
    PipeGreater, // |>
    Caret, // ^
    LeftShift, // <<
    RightShift, // >>

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
    Case,
    Catch,
    Comptime,
    Const,
    Continue,
    Default,
    Defer,
    Do,
    Else,
    Finally,
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
    Switch,
    True,
    Try,
    Type,
    Union,
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
            .DotDot => "..",
            .DotDotEqual => "..=",
            .DotDotDot => "...",
            .Semicolon => ";",
            .Colon => ":",
            .Question => "?",
            .QuestionDot => "?.",
            .QuestionQuestion => "??",
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
            .PipeGreater => "|>",
            .Caret => "^",
            .LeftShift => "<<",
            .RightShift => ">>",
            .Identifier => "identifier",
            .String => "string",
            .Integer => "integer",
            .Float => "float",
            .And => "and",
            .Async => "async",
            .Await => "await",
            .Break => "break",
            .Case => "case",
            .Catch => "catch",
            .Comptime => "comptime",
            .Const => "const",
            .Continue => "continue",
            .Default => "default",
            .Defer => "defer",
            .Do => "do",
            .Else => "else",
            .Finally => "finally",
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
            .Switch => "switch",
            .True => "true",
            .Try => "try",
            .Type => "type",
            .Union => "union",
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
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("{s:<16} '{s}' ({d}:{d})", .{
            @tagName(self.type),
            self.lexeme,
            self.line,
            self.column,
        });
    }
};

/// Keyword map for O(1) lookup
pub const keywords = std.StaticStringMap(TokenType).initComptime(.{
    .{ "and", .And },
    .{ "async", .Async },
    .{ "await", .Await },
    .{ "break", .Break },
    .{ "case", .Case },
    .{ "catch", .Catch },
    .{ "comptime", .Comptime },
    .{ "const", .Const },
    .{ "continue", .Continue },
    .{ "default", .Default },
    .{ "defer", .Defer },
    .{ "do", .Do },
    .{ "else", .Else },
    .{ "finally", .Finally },
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
    .{ "switch", .Switch },
    .{ "true", .True },
    .{ "try", .Try },
    .{ "type", .Type },
    .{ "union", .Union },
    .{ "unsafe", .Unsafe },
    .{ "while", .While },
});
