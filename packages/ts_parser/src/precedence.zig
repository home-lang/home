//! Pratt-parser operator precedence table for TS expressions.
//!
//! Per TS_PARITY_PLAN Phase 1.D. Mirrors ECMA-262 expression precedence
//! plus the TS-only `as`, `satisfies` operators.
//!
//! Higher number = higher binding. Right-associative operators are
//! handled by giving the right-recursive call `prec` rather than
//! `prec + 1` (i.e. they consume operators of equal precedence).

const std = @import("std");
const ts_lexer = @import("ts_lexer");
const TokenKind = ts_lexer.TokenKind;
const hir_mod = @import("hir");
const BinOp = hir_mod.BinOp;
const LogicalOp = hir_mod.LogicalOp;

pub const Prec = enum(u8) {
    none = 0,
    /// `,` operator — usually parsed at expression-statement boundary.
    comma = 1,
    /// `=`, `+=`, etc.
    assignment = 2,
    /// `?:` ternary.
    conditional = 3,
    /// `??` nullish coalescing.
    nullish = 4,
    /// `||` logical or.
    logical_or = 5,
    /// `&&` logical and.
    logical_and = 6,
    /// `|` bitwise or.
    bit_or = 7,
    /// `^` bitwise xor.
    bit_xor = 8,
    /// `&` bitwise and.
    bit_and = 9,
    /// `==`, `!=`, `===`, `!==`.
    equality = 10,
    /// `<`, `>`, `<=`, `>=`, `instanceof`, `in`, `as`, `satisfies`.
    relational = 11,
    /// Reserved historical slot; TS assertions use relational precedence.
    type_assertion = 12,
    /// `<<`, `>>`, `>>>`.
    shift = 13,
    /// `+`, `-`.
    additive = 14,
    /// `*`, `/`, `%`.
    multiplicative = 15,
    /// `**` (right-associative).
    exponentiation = 16,
    /// Unary prefix: `!`, `-`, `+`, `~`, `typeof`, `void`, `delete`.
    unary_prefix = 17,
    /// `++`, `--` postfix.
    postfix = 18,
    /// `f(...)`, `a[i]`, `a.b`, `a?.b`.
    call_or_member = 19,
    /// `new` without args, primary literals.
    primary = 20,
};

/// Look up the binary precedence of `tok` when it appears in an
/// infix position. `null` means "not a binary operator at this
/// precedence level."
pub fn binaryPrec(tok: TokenKind) ?Prec {
    return switch (tok) {
        .pipe_pipe => .logical_or,
        .ampersand_ampersand => .logical_and,
        // ES grammar puts CoalesceExpression at the same level as
        // LogicalORExpression so `a ?? b || c` parses left-to-right;
        // the mixed-operator syntax check then fires in
        // `reportMixedNullishLogical`. The `Prec.nullish = 4` slot is
        // preserved as a no-op for any historical callers.
        .question_question => .logical_or,
        .pipe => .bit_or,
        .caret => .bit_xor,
        .ampersand => .bit_and,
        .equal_equal, .bang_equal, .equal_equal_equal, .bang_equal_equal => .equality,
        .less_than, .less_than_equal, .greater_than, .greater_than_equal, .kw_instanceof, .kw_in, .kw_as, .kw_satisfies => .relational,
        .less_less, .greater_greater, .greater_greater_greater => .shift,
        .plus, .minus => .additive,
        .asterisk, .slash, .percent => .multiplicative,
        .asterisk_asterisk => .exponentiation,
        else => null,
    };
}

/// Map a token to a `BinOp`, when the token is a "plain" arithmetic
/// or bitwise operator (i.e. lowers into the HIR `binary_op` node).
/// Returns null for operators like `&&`, `||`, `??`, `as`, `satisfies`,
/// `instanceof` which use other HIR node kinds.
pub fn binOpOf(tok: TokenKind) ?BinOp {
    return switch (tok) {
        .plus => .add,
        .minus => .sub,
        .asterisk => .mul,
        .slash => .div,
        .percent => .mod,
        .asterisk_asterisk => .pow,
        .equal_equal => .eq,
        .bang_equal => .neq,
        .equal_equal_equal => .eq_strict,
        .bang_equal_equal => .neq_strict,
        .less_than => .lt,
        .less_than_equal => .le,
        .greater_than => .gt,
        .greater_than_equal => .ge,
        .ampersand => .bit_and,
        .pipe => .bit_or,
        .caret => .bit_xor,
        .less_less => .shl,
        .greater_greater => .shr,
        .greater_greater_greater => .shr_unsigned,
        .kw_instanceof => .instanceof,
        .kw_in => .in,
        else => null,
    };
}

pub fn logicalOpOf(tok: TokenKind) ?LogicalOp {
    return switch (tok) {
        .ampersand_ampersand => .@"and",
        .pipe_pipe => .@"or",
        .question_question => .nullish,
        else => null,
    };
}

/// Returns true if `prec` is right-associative (currently only `**`
/// and the assignment operators).
pub fn isRightAssociative(prec: Prec) bool {
    return prec == .exponentiation or prec == .assignment;
}

// =============================================================================
// Tests
// =============================================================================

const t = std.testing;

test "Prec: ordering matches expected hierarchy" {
    try t.expect(@intFromEnum(Prec.multiplicative) > @intFromEnum(Prec.additive));
    try t.expect(@intFromEnum(Prec.additive) > @intFromEnum(Prec.shift));
    try t.expect(@intFromEnum(Prec.shift) > @intFromEnum(Prec.relational));
    try t.expect(@intFromEnum(Prec.exponentiation) > @intFromEnum(Prec.multiplicative));
    try t.expect(@intFromEnum(Prec.unary_prefix) > @intFromEnum(Prec.exponentiation));
    try t.expect(@intFromEnum(Prec.call_or_member) > @intFromEnum(Prec.unary_prefix));
}

test "binaryPrec: arithmetic ops" {
    try t.expectEqual(@as(?Prec, .additive), binaryPrec(.plus));
    try t.expectEqual(@as(?Prec, .additive), binaryPrec(.minus));
    try t.expectEqual(@as(?Prec, .multiplicative), binaryPrec(.asterisk));
    try t.expectEqual(@as(?Prec, .multiplicative), binaryPrec(.slash));
    try t.expectEqual(@as(?Prec, .exponentiation), binaryPrec(.asterisk_asterisk));
}

test "binaryPrec: equality and relational" {
    try t.expectEqual(@as(?Prec, .equality), binaryPrec(.equal_equal_equal));
    try t.expectEqual(@as(?Prec, .equality), binaryPrec(.bang_equal_equal));
    try t.expectEqual(@as(?Prec, .relational), binaryPrec(.less_than));
    try t.expectEqual(@as(?Prec, .relational), binaryPrec(.kw_instanceof));
    try t.expectEqual(@as(?Prec, .relational), binaryPrec(.kw_in));
}

test "binaryPrec: TS-only as / satisfies" {
    try t.expectEqual(@as(?Prec, .relational), binaryPrec(.kw_as));
    try t.expectEqual(@as(?Prec, .relational), binaryPrec(.kw_satisfies));
}

test "binaryPrec: non-binary tokens are null" {
    try t.expectEqual(@as(?Prec, null), binaryPrec(.identifier));
    try t.expectEqual(@as(?Prec, null), binaryPrec(.semicolon));
    try t.expectEqual(@as(?Prec, null), binaryPrec(.eof));
}

test "binOpOf: round-trip for arithmetic" {
    try t.expectEqual(@as(?BinOp, .add), binOpOf(.plus));
    try t.expectEqual(@as(?BinOp, .sub), binOpOf(.minus));
    try t.expectEqual(@as(?BinOp, .mul), binOpOf(.asterisk));
    try t.expectEqual(@as(?BinOp, .pow), binOpOf(.asterisk_asterisk));
    try t.expectEqual(@as(?BinOp, .eq_strict), binOpOf(.equal_equal_equal));
    try t.expectEqual(@as(?BinOp, .neq_strict), binOpOf(.bang_equal_equal));
}

test "logicalOpOf: short-circuit family" {
    try t.expectEqual(@as(?LogicalOp, .@"and"), logicalOpOf(.ampersand_ampersand));
    try t.expectEqual(@as(?LogicalOp, .@"or"), logicalOpOf(.pipe_pipe));
    try t.expectEqual(@as(?LogicalOp, .nullish), logicalOpOf(.question_question));
    try t.expectEqual(@as(?LogicalOp, null), logicalOpOf(.plus));
}

test "isRightAssociative: ** and assignments" {
    try t.expect(isRightAssociative(.exponentiation));
    try t.expect(isRightAssociative(.assignment));
    try t.expect(!isRightAssociative(.additive));
    try t.expect(!isRightAssociative(.multiplicative));
}
