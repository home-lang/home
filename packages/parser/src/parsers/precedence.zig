//! Operator-precedence table for the Pratt expression parser.
//!
//! Extracted from `parser.zig` per TS_PARITY_PLAN §0 Phase 0.7. This is
//! a pure lift-and-extract — `Precedence` is unchanged from its original
//! location; only the import surface and file location moved.
//!
//! The constants below name the 21 tiers in the Home / TS precedence
//! lattice; each corresponds to one set of left-associative operators
//! (or one right-associative block, like `Power`). Add new operators by
//! extending the corresponding tier in `fromToken`.

const std = @import("std");
const lexer_mod = @import("lexer");
const TokenType = lexer_mod.TokenType;

pub const Precedence = enum(u8) {
    None = 0,
    Assignment = 1, // =
    Ternary = 2, // ?:
    NullCoalesce = 3, // ??
    Or = 4, // ||
    And = 5, // &&
    BitOr = 6, // |
    BitXor = 7, // ^
    BitAnd = 8, // &
    Equality = 9, // == !=
    Comparison = 10, // < > <= >=
    TypeCast = 11, // as
    Range = 12, // .. ..=
    Pipe = 13, // |> (function pipeline)
    Shift = 14, // << >> (bitwise shifts)
    Term = 15, // + -
    Factor = 16, // * / % ~/
    Power = 17, // ** (exponentiation, right-associative)
    Unary = 18, // ! - ...
    Call = 20, // . () [] ?.
    Primary = 21,

    /// Get the precedence level for a given token type.
    ///
    /// Maps operator tokens to their precedence levels. Non-operator
    /// tokens return None precedence.
    pub fn fromToken(token_type: TokenType) Precedence {
        return switch (token_type) {
            .Equal, .PlusEqual, .MinusEqual, .StarEqual, .SlashEqual, .PercentEqual => .Assignment,
            .Question => .Ternary,
            .QuestionQuestion, .QuestionColon, .Else, .OrElse => .NullCoalesce,
            .QuestionBracket => .Call,
            .PipePipe, .Or => .Or,
            .AmpersandAmpersand, .And => .And,
            .Pipe => .BitOr,
            .PipeGreater => .Pipe,
            .Caret => .BitXor,
            .Ampersand => .BitAnd,
            .EqualEqual, .BangEqual => .Equality,
            .Less, .LessEqual, .Greater, .GreaterEqual, .Is => .Comparison,
            .As => .TypeCast,
            .DotDot, .DotDotEqual => .Range,
            .LeftShift, .RightShift => .Shift,
            .Plus, .Minus, .PlusBang, .MinusBang, .PlusQuestion, .MinusQuestion, .PlusPipe, .MinusPipe => .Term,
            .Star, .Slash, .Percent, .TildeSlash, .StarBang, .SlashBang, .StarQuestion, .SlashQuestion, .StarPipe => .Factor,
            .StarStar => .Power,
            .LeftParen, .LeftBracket, .Dot, .QuestionDot => .Call,
            else => .None,
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

const t = std.testing;

test "Precedence: enum tiers are stable and ordered" {
    try t.expectEqual(@as(u8, 0), @intFromEnum(Precedence.None));
    try t.expectEqual(@as(u8, 1), @intFromEnum(Precedence.Assignment));
    try t.expect(@intFromEnum(Precedence.Term) > @intFromEnum(Precedence.Equality));
    try t.expect(@intFromEnum(Precedence.Factor) > @intFromEnum(Precedence.Term));
    try t.expect(@intFromEnum(Precedence.Power) > @intFromEnum(Precedence.Factor));
    try t.expect(@intFromEnum(Precedence.Unary) > @intFromEnum(Precedence.Power));
    try t.expect(@intFromEnum(Precedence.Call) > @intFromEnum(Precedence.Unary));
    try t.expect(@intFromEnum(Precedence.Primary) > @intFromEnum(Precedence.Call));
}

test "Precedence.fromToken: arithmetic operators" {
    try t.expectEqual(Precedence.Term, Precedence.fromToken(.Plus));
    try t.expectEqual(Precedence.Term, Precedence.fromToken(.Minus));
    try t.expectEqual(Precedence.Factor, Precedence.fromToken(.Star));
    try t.expectEqual(Precedence.Factor, Precedence.fromToken(.Slash));
    try t.expectEqual(Precedence.Factor, Precedence.fromToken(.Percent));
    try t.expectEqual(Precedence.Power, Precedence.fromToken(.StarStar));
}

test "Precedence.fromToken: comparison and equality" {
    try t.expectEqual(Precedence.Equality, Precedence.fromToken(.EqualEqual));
    try t.expectEqual(Precedence.Equality, Precedence.fromToken(.BangEqual));
    try t.expectEqual(Precedence.Comparison, Precedence.fromToken(.Less));
    try t.expectEqual(Precedence.Comparison, Precedence.fromToken(.GreaterEqual));
    try t.expectEqual(Precedence.Comparison, Precedence.fromToken(.Is));
}

test "Precedence.fromToken: assignment" {
    try t.expectEqual(Precedence.Assignment, Precedence.fromToken(.Equal));
    try t.expectEqual(Precedence.Assignment, Precedence.fromToken(.PlusEqual));
    try t.expectEqual(Precedence.Assignment, Precedence.fromToken(.MinusEqual));
}

test "Precedence.fromToken: logical and bitwise" {
    try t.expectEqual(Precedence.Or, Precedence.fromToken(.PipePipe));
    try t.expectEqual(Precedence.And, Precedence.fromToken(.AmpersandAmpersand));
    try t.expectEqual(Precedence.BitOr, Precedence.fromToken(.Pipe));
    try t.expectEqual(Precedence.BitAnd, Precedence.fromToken(.Ampersand));
    try t.expectEqual(Precedence.BitXor, Precedence.fromToken(.Caret));
}

test "Precedence.fromToken: call/access tier" {
    try t.expectEqual(Precedence.Call, Precedence.fromToken(.LeftParen));
    try t.expectEqual(Precedence.Call, Precedence.fromToken(.LeftBracket));
    try t.expectEqual(Precedence.Call, Precedence.fromToken(.Dot));
    try t.expectEqual(Precedence.Call, Precedence.fromToken(.QuestionDot));
    try t.expectEqual(Precedence.Call, Precedence.fromToken(.QuestionBracket));
}

test "Precedence.fromToken: range and pipe" {
    try t.expectEqual(Precedence.Range, Precedence.fromToken(.DotDot));
    try t.expectEqual(Precedence.Range, Precedence.fromToken(.DotDotEqual));
    try t.expectEqual(Precedence.Pipe, Precedence.fromToken(.PipeGreater));
}

test "Precedence.fromToken: non-operator tokens return None" {
    try t.expectEqual(Precedence.None, Precedence.fromToken(.Identifier));
    try t.expectEqual(Precedence.None, Precedence.fromToken(.Integer));
    try t.expectEqual(Precedence.None, Precedence.fromToken(.Eof));
    try t.expectEqual(Precedence.None, Precedence.fromToken(.Semicolon));
}

test "Precedence.fromToken: power is above factor (right-associative tier)" {
    try t.expect(@intFromEnum(Precedence.fromToken(.StarStar)) >
        @intFromEnum(Precedence.fromToken(.Star)));
}
