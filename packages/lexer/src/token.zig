const std = @import("std");

/// Enumeration of all token types recognized by the Ion lexer.
///
/// This enum represents every category of lexical token in the Ion language,
/// including operators, keywords, literals, and special symbols. Tokens are
/// the atomic units produced by lexical analysis and consumed by the parser.
///
/// Categories:
/// - Single-character tokens: Parentheses, braces, brackets, punctuation
/// - Multi-character operators: Arrows, ranges, compound assignments
/// - Literals: Identifiers, strings, integers, floats
/// - Keywords: Language reserved words (fn, let, if, etc.)
/// - Special: EOF (end of file), Invalid (lexical errors)
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

    /// Convert a TokenType to its string representation.
    ///
    /// Returns the canonical string form of this token type, which is either
    /// the literal symbol for operators/punctuation (e.g., "(", "->") or the
    /// lowercase keyword name for identifiers and keywords.
    ///
    /// Parameters:
    ///   - self: The token type to convert
    ///
    /// Returns: Static string representation of this token type
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

/// Represents a single token in the source code with location information.
///
/// A Token is the result of lexical analysis, containing:
/// - The token type (keyword, operator, literal, etc.)
/// - The original source text (lexeme)
/// - Source location for error reporting (line and column)
///
/// Tokens are immutable once created and form the input stream for the parser.
pub const Token = struct {
    /// The syntactic category of this token
    type: TokenType,
    /// The actual characters from source that form this token
    lexeme: []const u8,
    /// Line number in source (1-indexed)
    line: usize,
    /// Column number in source (1-indexed)
    column: usize,

    /// Create a new token with the specified attributes.
    ///
    /// Parameters:
    ///   - token_type: The type/category of this token
    ///   - lexeme: The source text for this token (must remain valid)
    ///   - line: Source line number (1-indexed)
    ///   - column: Source column number (1-indexed)
    ///
    /// Returns: Initialized Token struct
    pub fn init(token_type: TokenType, lexeme: []const u8, line: usize, column: usize) Token {
        return Token{
            .type = token_type,
            .lexeme = lexeme,
            .line = line,
            .column = column,
        };
    }

    /// Format this token for display (implements std.fmt formatting).
    ///
    /// Produces a human-readable representation showing the token type,
    /// lexeme, and source location. Format: "TokenType 'lexeme' (line:col)"
    ///
    /// This enables using tokens with std.fmt functions like print().
    ///
    /// Parameters:
    ///   - self: The token to format
    ///   - writer: Output writer to write formatted text to
    ///
    /// Example output: "Integer '123' (1:5)"
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

/// Compile-time hash map for efficient keyword recognition.
///
/// This static string map enables O(1) lookup to determine if an identifier
/// is a reserved keyword. It's initialized at compile-time for zero runtime
/// overhead. Used by the lexer to distinguish keywords from user identifiers.
///
/// All Ion language keywords are registered here, including control flow
/// (if, else, for), declarations (fn, let, const), and special forms
/// (async, await, match, comptime).
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
