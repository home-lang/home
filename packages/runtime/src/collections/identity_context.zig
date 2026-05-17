// Copied from bun/src/collections/identity_context.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: nothing to rewrite (no @import("bun") in upstream).

pub fn IdentityContext(comptime Key: type) type {
    return struct {
        pub fn hash(_: @This(), key: Key) u64 {
            return switch (comptime @typeInfo(Key)) {
                .@"enum" => @intFromEnum(key),
                .int => key,
                else => @compileError("unexpected identity context type"),
            };
        }

        pub fn eql(_: @This(), a: Key, b: Key) bool {
            return a == b;
        }
    };
}

/// When storing hashes as keys in a hash table, we don't want to hash the hashes or else we increase the chance of collisions. This is also marginally faster since it means hashing less stuff.
/// `ArrayIdentityContext` and `IdentityContext` are distinct because ArrayHashMap expects u32 hashes but HashMap expects u64 hashes.
pub const ArrayIdentityContext = struct {
    pub fn hash(_: @This(), key: u32) u32 {
        return key;
    }

    pub fn eql(_: @This(), a: u32, b: u32, _: usize) bool {
        return a == b;
    }

    pub const U64 = struct {
        pub fn hash(_: @This(), key: u64) u32 {
            return @truncate(key);
        }

        pub fn eql(_: @This(), a: u64, b: u64, _: usize) bool {
            return a == b;
        }
    };
};

test "IdentityContext hashes enums to their integer tag" {
    const std = @import("std");
    const E = enum(u8) { a = 1, b = 2, c = 3 };
    const ctx = IdentityContext(E){};
    try std.testing.expectEqual(@as(u64, 1), ctx.hash(E.a));
    try std.testing.expectEqual(@as(u64, 2), ctx.hash(E.b));
    try std.testing.expect(ctx.eql(E.a, E.a));
    try std.testing.expect(!ctx.eql(E.a, E.b));
}

test "ArrayIdentityContext returns the key unchanged" {
    const std = @import("std");
    const ctx = ArrayIdentityContext{};
    try std.testing.expectEqual(@as(u32, 42), ctx.hash(42));
    try std.testing.expect(ctx.eql(7, 7, 0));
    try std.testing.expect(!ctx.eql(7, 8, 0));
}

test "ArrayIdentityContext.U64 truncates 64-bit keys" {
    const std = @import("std");
    const ctx = ArrayIdentityContext.U64{};
    try std.testing.expectEqual(@as(u32, 0xdeadbeef), ctx.hash(0x1234_5678_dead_beef));
    try std.testing.expect(ctx.eql(0x1234, 0x1234, 0));
}
