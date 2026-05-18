// Copied from bun/src/jsc/ZigStackFramePosition.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Upstream stores `line: bun.Ordinal` / `column: bun.Ordinal` where
// `bun.Ordinal = bun.OrdinalT(c_int)` and represents an
// ABI-equivalent-of-`WTF::OrdinalNumber` enum. Until the full `bun.OrdinalT`
// generic lands in `home_rt`, we inline a Home-side copy of the same enum so
// this file's struct layout matches WebKit byte-for-byte. The Ordinal API
// surface is kept identical (start/invalid sentinels, fromZeroBased,
// fromOneBased, zeroBased, oneBased, add, addScalar, isValid) so the eventual
// re-export from `home_rt` is a drop-in.

const std = @import("std");

/// ABI-equivalent of `WTF::OrdinalNumber` — see WTF/wtf/text/OrdinalNumber.h
/// for the canonical zero-based-with-sentinel layout. Mirrors the
/// upstream `bun.Ordinal` type one-to-one until the generic re-export lands.
pub const Ordinal = enum(c_int) {
    invalid = -1,
    start = 0,
    _,

    pub inline fn fromZeroBased(int: c_int) Ordinal {
        std.debug.assert(int >= 0);
        return @enumFromInt(int);
    }

    pub inline fn fromOneBased(int: c_int) Ordinal {
        std.debug.assert(int > 0);
        return @enumFromInt(int - 1);
    }

    pub inline fn zeroBased(ord: Ordinal) c_int {
        return @intFromEnum(ord);
    }

    pub inline fn oneBased(ord: Ordinal) c_int {
        return @intFromEnum(ord) + 1;
    }

    pub inline fn add(ord: Ordinal, b: Ordinal) Ordinal {
        return fromZeroBased(ord.zeroBased() + b.zeroBased());
    }

    pub inline fn addScalar(ord: Ordinal, inc: c_int) Ordinal {
        return fromZeroBased(ord.zeroBased() + inc);
    }

    pub inline fn isValid(ord: Ordinal) bool {
        return ord.zeroBased() >= 0;
    }
};

/// Represents a position in source code with line and column information
pub const ZigStackFramePosition = extern struct {
    line: Ordinal,
    column: Ordinal,
    /// -1 if not present
    line_start_byte: c_int,

    pub const invalid = ZigStackFramePosition{
        .line = .invalid,
        .column = .invalid,
        .line_start_byte = -1,
    };

    pub fn isInvalid(this: *const ZigStackFramePosition) bool {
        return std.mem.eql(u8, std.mem.asBytes(this), std.mem.asBytes(&invalid));
    }

    pub fn decode(reader: anytype) !@This() {
        return .{
            .line = Ordinal.fromZeroBased(try reader.readValue(i32)),
            .column = Ordinal.fromZeroBased(try reader.readValue(i32)),
            .line_start_byte = -1,
        };
    }

    pub fn encode(this: *const @This(), writer: anytype) anyerror!void {
        try writer.writeInt(this.line.zeroBased());
        try writer.writeInt(this.column.zeroBased());
    }
};

test "Ordinal.start and Ordinal.invalid are pinned" {
    try std.testing.expectEqual(@as(c_int, 0), Ordinal.start.zeroBased());
    try std.testing.expectEqual(@as(c_int, 1), Ordinal.start.oneBased());
    try std.testing.expectEqual(@as(c_int, -1), Ordinal.invalid.zeroBased());
    try std.testing.expect(!Ordinal.invalid.isValid());
    try std.testing.expect(Ordinal.start.isValid());
}

test "Ordinal.fromOneBased decrements" {
    try std.testing.expectEqual(@as(c_int, 0), Ordinal.fromOneBased(1).zeroBased());
    try std.testing.expectEqual(@as(c_int, 4), Ordinal.fromOneBased(5).zeroBased());
}

test "Ordinal.add composes zero-based offsets" {
    const a = Ordinal.fromZeroBased(3);
    const b = Ordinal.fromZeroBased(4);
    try std.testing.expectEqual(@as(c_int, 7), a.add(b).zeroBased());
    try std.testing.expectEqual(@as(c_int, 10), a.addScalar(7).zeroBased());
}

test "ZigStackFramePosition.invalid round-trips through isInvalid" {
    const p = ZigStackFramePosition.invalid;
    try std.testing.expect(p.isInvalid());
    const valid = ZigStackFramePosition{
        .line = Ordinal.fromZeroBased(0),
        .column = Ordinal.fromZeroBased(0),
        .line_start_byte = 0,
    };
    try std.testing.expect(!valid.isInvalid());
}
