// Home Runtime - ported from Bun.
// Upstream:  /Users/chrisbreuer/Code/bun/src/ast/known_global.zig
// Pinned SHA: fd0b6f1a271fca0b8124b69f230b100f4d636af6
//
// Pure-data subset only. Upstream also defines
// `KnownGlobal.minifyGlobalConstructor`, but that routine rewrites `E.New`
// into Expr nodes and depends on `logger`, `Symbol`, `E`, and parser prefill
// state. It should re-attach when the wider Expr/Symbol AST graph lands. The
// enum-name map is local here so the leaf can be tested without importing all
// of `home_rt`.

pub const KnownGlobal = enum {
    WeakSet,
    WeakMap,
    Date,
    Set,
    Map,
    Headers,
    Response,
    TextEncoder,
    TextDecoder,
    Error,
    TypeError,
    SyntaxError,
    RangeError,
    ReferenceError,
    EvalError,
    URIError,
    AggregateError,
    Array,
    Object,
    Function,
    RegExp,

    pub const map = ComptimeEnumMap(KnownGlobal);
};

const std = @import("std");

fn ComptimeEnumMap(comptime T: type) type {
    @setEvalBranchQuota(50_000);
    const values = std.enums.values(T);
    const entries = comptime brk: {
        var result: [values.len]struct { [:0]const u8, T } = undefined;
        for (values, &result) |value, *entry| {
            entry.* = .{ @tagName(value), value };
        }
        break :brk result;
    };

    return struct {
        pub fn get(input: []const u8) ?T {
            inline for (entries) |entry| {
                if (std.mem.eql(u8, entry.@"0", input)) return entry.@"1";
            }
            return null;
        }
    };
}

test "KnownGlobal.map resolves constructor names" {
    try std.testing.expectEqual(KnownGlobal.Array, KnownGlobal.map.get("Array").?);
    try std.testing.expectEqual(KnownGlobal.WeakMap, KnownGlobal.map.get("WeakMap").?);
    try std.testing.expectEqual(KnownGlobal.TextDecoder, KnownGlobal.map.get("TextDecoder").?);
    try std.testing.expect(KnownGlobal.map.get("Promise") == null);
}
