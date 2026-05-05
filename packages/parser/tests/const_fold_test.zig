//! Tests for the early integer constant-folder added to Parser.binary().
//!
//! `Parser.foldIntegerBinary` is a pure function that takes two AST nodes and a
//! binary op and returns either the folded i128 result or null. We exercise it
//! directly so we don't have to spin up a full lexer/parser pipeline (which
//! has a heavier dependency graph).

const std = @import("std");
const ast = @import("ast");
const Parser = @import("parser").Parser;

const dummy_loc = ast.SourceLocation{ .line = 1, .column = 1 };

fn intLit(value: i128) ast.Expr {
    return .{ .IntegerLiteral = ast.IntegerLiteral.init(value, dummy_loc) };
}

fn fold(op: ast.BinaryOp, a: i128, b: i128) ?i128 {
    var l = intLit(a);
    var r = intLit(b);
    return Parser.foldIntegerBinary(op, &l, &r);
}

test "const fold: addition" {
    try std.testing.expectEqual(@as(?i128, 5), fold(.Add, 2, 3));
    try std.testing.expectEqual(@as(?i128, 0), fold(.Add, -7, 7));
}

test "const fold: subtraction" {
    try std.testing.expectEqual(@as(?i128, 1), fold(.Sub, 4, 3));
    try std.testing.expectEqual(@as(?i128, -3), fold(.Sub, 4, 7));
}

test "const fold: multiplication" {
    try std.testing.expectEqual(@as(?i128, 86400), fold(.Mul, 60 * 60, 24));
}

test "const fold: division truncates" {
    try std.testing.expectEqual(@as(?i128, 3), fold(.Div, 10, 3));
    try std.testing.expectEqual(@as(?i128, -3), fold(.Div, -10, 3));
}

test "const fold: division by zero refuses to fold" {
    try std.testing.expectEqual(@as(?i128, null), fold(.Div, 10, 0));
    try std.testing.expectEqual(@as(?i128, null), fold(.Mod, 10, 0));
}

test "const fold: addition overflow refuses to fold" {
    const max = std.math.maxInt(i128);
    try std.testing.expectEqual(@as(?i128, null), fold(.Add, max, 1));
    try std.testing.expectEqual(@as(?i128, null), fold(.Sub, std.math.minInt(i128), 1));
    try std.testing.expectEqual(@as(?i128, null), fold(.Mul, max, 2));
}

test "const fold: bitwise ops" {
    try std.testing.expectEqual(@as(?i128, 0x0F), fold(.BitAnd, 0xFF, 0x0F));
    try std.testing.expectEqual(@as(?i128, 0xFF), fold(.BitOr, 0xF0, 0x0F));
    try std.testing.expectEqual(@as(?i128, 0xFF), fold(.BitXor, 0xF0, 0x0F));
}

test "const fold: shifts" {
    try std.testing.expectEqual(@as(?i128, 8), fold(.LeftShift, 1, 3));
    try std.testing.expectEqual(@as(?i128, 1), fold(.RightShift, 8, 3));
    // Negative or out-of-range shift refuses to fold (UB in target).
    try std.testing.expectEqual(@as(?i128, null), fold(.LeftShift, 1, -1));
    try std.testing.expectEqual(@as(?i128, null), fold(.LeftShift, 1, 64));
}

test "const fold: comparison ops do not fold (returns null)" {
    // Comparisons aren't in the integer-fold path; they should fall through.
    try std.testing.expectEqual(@as(?i128, null), fold(.Equal, 1, 1));
    try std.testing.expectEqual(@as(?i128, null), fold(.Less, 1, 2));
}

test "const fold: non-int operand returns null" {
    var float_lit = ast.Expr{ .FloatLiteral = ast.FloatLiteral.init(1.5, dummy_loc) };
    var int_lit = intLit(2);
    try std.testing.expectEqual(@as(?i128, null), Parser.foldIntegerBinary(.Add, &float_lit, &int_lit));
    try std.testing.expectEqual(@as(?i128, null), Parser.foldIntegerBinary(.Add, &int_lit, &float_lit));
}
