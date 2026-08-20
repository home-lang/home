// Copied verbatim from bun/src/sql/shared/ColumnIdentifier.zig at
// upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../../cli/LICENSE.bun.md.
//
// JavaScriptCore treats numeric property names differently from string
// property names, so column names that parse as a plain decimal u32 are
// stored as `.index`; everything else becomes `.name` over an owned
// Data buffer (the wave-18 Data stub today). `.duplicate` is used by
// upstream to mark a column whose name collides with a sibling — Home
// keeps the field shape so callers can pattern-match without changes.
//
// No `@import("bun")` references. Verified phase12 smoke green.

pub const ColumnIdentifier = union(enum) {
    name: Data,
    index: u32,
    duplicate: void,

    pub fn init(name: Data) !@This() {
        if (switch (name.slice().len) {
            1..."4294967295".len => true,
            0 => return .{ .name = .{ .empty = {} } },
            else => false,
        }) might_be_int: {
            // use a u64 to avoid overflow
            var int: u64 = 0;
            for (name.slice()) |byte| {
                int = int * 10 + switch (byte) {
                    '0'...'9' => @as(u64, byte - '0'),
                    else => break :might_be_int,
                };
            }

            // JSC only supports indexed property names up to 2^32
            if (int < std.math.maxInt(u32))
                return .{ .index = @intCast(int) };
        }

        return .{ .name = .{ .owned = try name.toOwned() } };
    }

    pub fn deinit(this: *@This()) void {
        switch (this.*) {
            .name => |*name| name.deinit(),
            else => {},
        }
    }
};

test "ColumnIdentifier: empty Data yields empty name variant" {
    var ci: ColumnIdentifier = .{ .name = .{ .empty = {} } };
    defer ci.deinit();
    try std.testing.expect(ci == .name);
    try std.testing.expectEqualStrings("", ci.name.slice());
}

test "ColumnIdentifier: duplicate tag round-trips" {
    var ci: ColumnIdentifier = .{ .duplicate = {} };
    defer ci.deinit();
    try std.testing.expect(ci == .duplicate);
}

test "ColumnIdentifier: index variant carries u32 payload" {
    var ci: ColumnIdentifier = .{ .index = 42 };
    defer ci.deinit();
    try std.testing.expect(ci == .index);
    try std.testing.expectEqual(@as(u32, 42), ci.index);
}

test "ColumnIdentifier: digit separators stay named" {
    var ci = try ColumnIdentifier.init(.{ .temporary = "2024_01" });
    defer ci.deinit();

    try std.testing.expect(ci == .name);
    try std.testing.expectEqualStrings("2024_01", ci.name.slice());
}

test "ColumnIdentifier: only in-range plain decimals become indices" {
    var decimal = try ColumnIdentifier.init(.{ .temporary = "0008" });
    defer decimal.deinit();
    try std.testing.expect(decimal == .index);
    try std.testing.expectEqual(@as(u32, 8), decimal.index);

    var largest_index = try ColumnIdentifier.init(.{ .temporary = "4294967294" });
    defer largest_index.deinit();
    try std.testing.expect(largest_index == .index);
    try std.testing.expectEqual(std.math.maxInt(u32) - 1, largest_index.index);

    var outside_index_range = try ColumnIdentifier.init(.{ .temporary = "4294967295" });
    defer outside_index_range.deinit();
    try std.testing.expect(outside_index_range == .name);
    try std.testing.expectEqualStrings("4294967295", outside_index_range.name.slice());
}

const std = @import("std");
const Data = @import("./Data.zig").Data;
