// Home Runtime — ported from Bun.
// Upstream:  packages/runtime/upstream/src/ast/op.zig
// Pinned SHA: fd0b6f1a271fca0b8124b69f230b100f4d636af6
//
// Renames applied (per packages/runtime/README.md naming convention):
//   - Dropped `@import("bun")` entirely (the only `bun.*` reference
//     upstream was `js_ast.AssignTarget`).
//   - `AssignTarget` lives upstream at `js_parser/js_parser.zig:54` (the
//     parser's own three-way enum). Until the JS parser lands, inline it
//     verbatim here so this file is self-contained.
//
// Operator metadata for the JS/TS parser+printer: unary/binary opcode
// enum, precedence levels, and the per-opcode string/level/keyword
// table. Pure data — no runtime allocations, no I/O.

pub const AssignTarget = enum(u2) {
    none = 0,
    replace = 1, // "a = b"
    update = 2, // "a += b"

    pub fn jsonStringify(self: *const @This(), writer: anytype) !void {
        return try writer.write(@tagName(self));
    }
};

// If you add a new token, remember to add it to "Table" too
pub const Code = enum {
    // Prefix
    un_pos, // +expr
    un_neg, // -expr
    un_cpl, // ~expr
    un_not, // !expr
    un_void,
    un_typeof,
    un_delete,

    // Prefix update
    un_pre_dec,
    un_pre_inc,

    // Postfix update
    un_post_dec,
    un_post_inc,

    /// Left-associative
    bin_add,
    /// Left-associative
    bin_sub,
    /// Left-associative
    bin_mul,
    /// Left-associative
    bin_div,
    /// Left-associative
    bin_rem,
    /// Left-associative
    bin_pow,
    /// Left-associative
    bin_lt,
    /// Left-associative
    bin_le,
    /// Left-associative
    bin_gt,
    /// Left-associative
    bin_ge,
    /// Left-associative
    bin_in,
    /// Left-associative
    bin_instanceof,
    /// Left-associative
    bin_shl,
    /// Left-associative
    bin_shr,
    /// Left-associative
    bin_u_shr,
    /// Left-associative
    bin_loose_eq,
    /// Left-associative
    bin_loose_ne,
    /// Left-associative
    bin_strict_eq,
    /// Left-associative
    bin_strict_ne,
    /// Left-associative
    bin_nullish_coalescing,
    /// Left-associative
    bin_logical_or,
    /// Left-associative
    bin_logical_and,
    /// Left-associative
    bin_bitwise_or,
    /// Left-associative
    bin_bitwise_and,
    /// Left-associative
    bin_bitwise_xor,

    /// Non-associative
    bin_comma,

    /// Right-associative
    bin_assign,
    /// Right-associative
    bin_add_assign,
    /// Right-associative
    bin_sub_assign,
    /// Right-associative
    bin_mul_assign,
    /// Right-associative
    bin_div_assign,
    /// Right-associative
    bin_rem_assign,
    /// Right-associative
    bin_pow_assign,
    /// Right-associative
    bin_shl_assign,
    /// Right-associative
    bin_shr_assign,
    /// Right-associative
    bin_u_shr_assign,
    /// Right-associative
    bin_bitwise_or_assign,
    /// Right-associative
    bin_bitwise_and_assign,
    /// Right-associative
    bin_bitwise_xor_assign,
    /// Right-associative
    bin_nullish_coalescing_assign,
    /// Right-associative
    bin_logical_or_assign,
    /// Right-associative
    bin_logical_and_assign,

    pub fn jsonStringify(self: @This(), writer: anytype) !void {
        return try writer.write(@tagName(self));
    }

    pub fn unaryAssignTarget(code: Op.Code) AssignTarget {
        if (@intFromEnum(code) >=
            @intFromEnum(Op.Code.un_pre_dec) and @intFromEnum(code) <=
            @intFromEnum(Op.Code.un_post_inc))
        {
            return AssignTarget.update;
        }

        return AssignTarget.none;
    }
    pub fn isLeftAssociative(code: Op.Code) bool {
        return @intFromEnum(code) >=
            @intFromEnum(Op.Code.bin_add) and
            @intFromEnum(code) < @intFromEnum(Op.Code.bin_comma) and code != .bin_pow;
    }
    pub fn isRightAssociative(code: Op.Code) bool {
        return @intFromEnum(code) >= @intFromEnum(Op.Code.bin_assign) or code == .bin_pow;
    }
    pub fn binaryAssignTarget(code: Op.Code) AssignTarget {
        if (code == .bin_assign) {
            return AssignTarget.replace;
        }

        if (@intFromEnum(code) > @intFromEnum(Op.Code.bin_assign)) {
            return AssignTarget.update;
        }

        return AssignTarget.none;
    }

    pub fn isPrefix(code: Op.Code) bool {
        return @intFromEnum(code) < @intFromEnum(Op.Code.un_post_dec);
    }
};

pub const Level = enum(u6) {
    lowest,
    comma,
    spread,
    yield,
    assign,
    conditional,
    nullish_coalescing,
    logical_or,
    logical_and,
    bitwise_or,
    bitwise_xor,
    bitwise_and,
    equals,
    compare,
    shift,
    add,
    multiply,
    exponentiation,
    prefix,
    postfix,
    new,
    call,
    member,

    pub inline fn lt(self: Level, b: Level) bool {
        return @intFromEnum(self) < @intFromEnum(b);
    }
    pub inline fn gt(self: Level, b: Level) bool {
        return @intFromEnum(self) > @intFromEnum(b);
    }
    pub inline fn gte(self: Level, b: Level) bool {
        return @intFromEnum(self) >= @intFromEnum(b);
    }
    pub inline fn lte(self: Level, b: Level) bool {
        return @intFromEnum(self) <= @intFromEnum(b);
    }
    pub inline fn eql(self: Level, b: Level) bool {
        return @intFromEnum(self) == @intFromEnum(b);
    }

    pub inline fn sub(self: Level, i: anytype) Level {
        return @as(Level, @enumFromInt(@intFromEnum(self) - i));
    }

    pub inline fn addF(self: Level, i: anytype) Level {
        return @as(Level, @enumFromInt(@intFromEnum(self) + i));
    }
};

pub const Op = @This();

text: string,
level: Level,
is_keyword: bool = false,

pub fn init(triple: anytype) Op {
    return Op{
        .text = triple.@"0",
        .level = triple.@"1",
        .is_keyword = triple.@"2",
    };
}

pub fn jsonStringify(self: *const @This(), writer: anytype) !void {
    return try writer.write(self.text);
}

pub const TableType: std.EnumArray(Op.Code, Op) = undefined;
pub const Table = brk: {
    var table = std.EnumArray(Op.Code, Op).initUndefined();

    // Prefix
    table.set(Op.Code.un_pos, Op.init(.{ "+", Level.prefix, false }));
    table.set(Op.Code.un_neg, Op.init(.{ "-", Level.prefix, false }));
    table.set(Op.Code.un_cpl, Op.init(.{ "~", Level.prefix, false }));
    table.set(Op.Code.un_not, Op.init(.{ "!", Level.prefix, false }));
    table.set(Op.Code.un_void, Op.init(.{ "void", Level.prefix, true }));
    table.set(Op.Code.un_typeof, Op.init(.{ "typeof", Level.prefix, true }));
    table.set(Op.Code.un_delete, Op.init(.{ "delete", Level.prefix, true }));

    // Prefix update
    table.set(Op.Code.un_pre_dec, Op.init(.{ "--", Level.prefix, false }));
    table.set(Op.Code.un_pre_inc, Op.init(.{ "++", Level.prefix, false }));

    // Postfix update
    table.set(Op.Code.un_post_dec, Op.init(.{ "--", Level.postfix, false }));
    table.set(Op.Code.un_post_inc, Op.init(.{ "++", Level.postfix, false }));

    // Left-associative
    table.set(Op.Code.bin_add, Op.init(.{ "+", Level.add, false }));
    table.set(Op.Code.bin_sub, Op.init(.{ "-", Level.add, false }));
    table.set(Op.Code.bin_mul, Op.init(.{ "*", Level.multiply, false }));
    table.set(Op.Code.bin_div, Op.init(.{ "/", Level.multiply, false }));
    table.set(Op.Code.bin_rem, Op.init(.{ "%", Level.multiply, false }));
    table.set(Op.Code.bin_pow, Op.init(.{ "**", Level.exponentiation, false }));
    table.set(Op.Code.bin_lt, Op.init(.{ "<", Level.compare, false }));
    table.set(Op.Code.bin_le, Op.init(.{ "<=", Level.compare, false }));
    table.set(Op.Code.bin_gt, Op.init(.{ ">", Level.compare, false }));
    table.set(Op.Code.bin_ge, Op.init(.{ ">=", Level.compare, false }));
    table.set(Op.Code.bin_in, Op.init(.{ "in", Level.compare, true }));
    table.set(Op.Code.bin_instanceof, Op.init(.{ "instanceof", Level.compare, true }));
    table.set(Op.Code.bin_shl, Op.init(.{ "<<", Level.shift, false }));
    table.set(Op.Code.bin_shr, Op.init(.{ ">>", Level.shift, false }));
    table.set(Op.Code.bin_u_shr, Op.init(.{ ">>>", Level.shift, false }));
    table.set(Op.Code.bin_loose_eq, Op.init(.{ "==", Level.equals, false }));
    table.set(Op.Code.bin_loose_ne, Op.init(.{ "!=", Level.equals, false }));
    table.set(Op.Code.bin_strict_eq, Op.init(.{ "===", Level.equals, false }));
    table.set(Op.Code.bin_strict_ne, Op.init(.{ "!==", Level.equals, false }));
    table.set(Op.Code.bin_nullish_coalescing, Op.init(.{ "??", Level.nullish_coalescing, false }));
    table.set(Op.Code.bin_logical_or, Op.init(.{ "||", Level.logical_or, false }));
    table.set(Op.Code.bin_logical_and, Op.init(.{ "&&", Level.logical_and, false }));
    table.set(Op.Code.bin_bitwise_or, Op.init(.{ "|", Level.bitwise_or, false }));
    table.set(Op.Code.bin_bitwise_and, Op.init(.{ "&", Level.bitwise_and, false }));
    table.set(Op.Code.bin_bitwise_xor, Op.init(.{ "^", Level.bitwise_xor, false }));

    // Non-associative
    table.set(Op.Code.bin_comma, Op.init(.{ ",", Level.comma, false }));

    // Right-associative
    table.set(Op.Code.bin_assign, Op.init(.{ "=", Level.assign, false }));
    table.set(Op.Code.bin_add_assign, Op.init(.{ "+=", Level.assign, false }));
    table.set(Op.Code.bin_sub_assign, Op.init(.{ "-=", Level.assign, false }));
    table.set(Op.Code.bin_mul_assign, Op.init(.{ "*=", Level.assign, false }));
    table.set(Op.Code.bin_div_assign, Op.init(.{ "/=", Level.assign, false }));
    table.set(Op.Code.bin_rem_assign, Op.init(.{ "%=", Level.assign, false }));
    table.set(Op.Code.bin_pow_assign, Op.init(.{ "**=", Level.assign, false }));
    table.set(Op.Code.bin_shl_assign, Op.init(.{ "<<=", Level.assign, false }));
    table.set(Op.Code.bin_shr_assign, Op.init(.{ ">>=", Level.assign, false }));
    table.set(Op.Code.bin_u_shr_assign, Op.init(.{ ">>>=", Level.assign, false }));
    table.set(Op.Code.bin_bitwise_or_assign, Op.init(.{ "|=", Level.assign, false }));
    table.set(Op.Code.bin_bitwise_and_assign, Op.init(.{ "&=", Level.assign, false }));
    table.set(Op.Code.bin_bitwise_xor_assign, Op.init(.{ "^=", Level.assign, false }));
    table.set(Op.Code.bin_nullish_coalescing_assign, Op.init(.{ "??=", Level.assign, false }));
    table.set(Op.Code.bin_logical_or_assign, Op.init(.{ "||=", Level.assign, false }));
    table.set(Op.Code.bin_logical_and_assign, Op.init(.{ "&&=", Level.assign, false }));

    break :brk table;
};

const string = []const u8;

const std = @import("std");

test "Op.Code precedence helpers classify prefix/postfix/binary" {
    try std.testing.expect(Op.Code.un_pos.isPrefix());
    try std.testing.expect(Op.Code.un_pre_inc.isPrefix());
    try std.testing.expect(!Op.Code.un_post_inc.isPrefix());
    try std.testing.expect(!Op.Code.bin_add.isPrefix());

    // Pre/post inc/dec are update targets; everything else unary is .none.
    try std.testing.expectEqual(AssignTarget.update, Op.Code.un_pre_dec.unaryAssignTarget());
    try std.testing.expectEqual(AssignTarget.update, Op.Code.un_post_inc.unaryAssignTarget());
    try std.testing.expectEqual(AssignTarget.none, Op.Code.un_pos.unaryAssignTarget());

    // Plain `=` is .replace, compound assigns are .update, comparisons .none.
    try std.testing.expectEqual(AssignTarget.replace, Op.Code.bin_assign.binaryAssignTarget());
    try std.testing.expectEqual(AssignTarget.update, Op.Code.bin_add_assign.binaryAssignTarget());
    try std.testing.expectEqual(AssignTarget.update, Op.Code.bin_logical_and_assign.binaryAssignTarget());
    try std.testing.expectEqual(AssignTarget.none, Op.Code.bin_add.binaryAssignTarget());

    // bin_pow is right-associative even though it sits in the
    // left-associative range; comma and assignment are not left-assoc.
    try std.testing.expect(Op.Code.bin_add.isLeftAssociative());
    try std.testing.expect(!Op.Code.bin_pow.isLeftAssociative());
    try std.testing.expect(!Op.Code.bin_comma.isLeftAssociative());
    try std.testing.expect(Op.Code.bin_pow.isRightAssociative());
    try std.testing.expect(Op.Code.bin_assign.isRightAssociative());
    try std.testing.expect(!Op.Code.bin_add.isRightAssociative());
}

test "Op.Table maps opcodes to text/level/is_keyword" {
    const add = Op.Table.get(Op.Code.bin_add);
    try std.testing.expectEqualStrings("+", add.text);
    try std.testing.expectEqual(Level.add, add.level);
    try std.testing.expect(!add.is_keyword);

    const typeof = Op.Table.get(Op.Code.un_typeof);
    try std.testing.expectEqualStrings("typeof", typeof.text);
    try std.testing.expectEqual(Level.prefix, typeof.level);
    try std.testing.expect(typeof.is_keyword);

    const pow = Op.Table.get(Op.Code.bin_pow);
    try std.testing.expectEqualStrings("**", pow.text);
    try std.testing.expectEqual(Level.exponentiation, pow.level);

    const nullish_assign = Op.Table.get(Op.Code.bin_nullish_coalescing_assign);
    try std.testing.expectEqualStrings("??=", nullish_assign.text);
    try std.testing.expectEqual(Level.assign, nullish_assign.level);
}

test "Level ordering helpers compare via @intFromEnum" {
    try std.testing.expect(Level.lowest.lt(Level.assign));
    try std.testing.expect(Level.member.gt(Level.call));
    try std.testing.expect(Level.assign.gte(Level.assign));
    try std.testing.expect(Level.assign.lte(Level.assign));
    try std.testing.expect(Level.add.eql(Level.add));
    try std.testing.expectEqual(Level.multiply, Level.add.addF(1));
    try std.testing.expectEqual(Level.add, Level.multiply.sub(1));
}
