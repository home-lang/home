// Copied verbatim from bun/src/sql/mysql/protocol/EncodeInt.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.
//
// Wave-13 (2026-05-18) port. MySQL length-encoded integer codec. Only
// dependency is `home_rt.BoundedArray` (already-ported), so this file is
// a pure Tier-0 leaf — no JSC bridge.

// Length-encoded integer encoding/decoding
pub fn encodeLengthInt(value: u64) bun.BoundedArray(u8, 9) {
    var array: bun.BoundedArray(u8, 9) = .{};
    if (value < 0xfb) {
        array.len = 1;
        array.buffer[0] = @intCast(value);
    } else if (value < 0xffff) {
        array.len = 3;
        array.buffer[0] = 0xfc;
        array.buffer[1] = @intCast(value & 0xff);
        array.buffer[2] = @intCast((value >> 8) & 0xff);
    } else if (value < 0xffffff) {
        array.len = 4;
        array.buffer[0] = 0xfd;
        array.buffer[1] = @intCast(value & 0xff);
        array.buffer[2] = @intCast((value >> 8) & 0xff);
        array.buffer[3] = @intCast((value >> 16) & 0xff);
    } else {
        array.len = 9;
        array.buffer[0] = 0xfe;
        array.buffer[1] = @intCast(value & 0xff);
        array.buffer[2] = @intCast((value >> 8) & 0xff);
        array.buffer[3] = @intCast((value >> 16) & 0xff);
        array.buffer[4] = @intCast((value >> 24) & 0xff);
        array.buffer[5] = @intCast((value >> 32) & 0xff);
        array.buffer[6] = @intCast((value >> 40) & 0xff);
        array.buffer[7] = @intCast((value >> 48) & 0xff);
        array.buffer[8] = @intCast((value >> 56) & 0xff);
    }
    return array;
}

pub fn decodeLengthInt(bytes: []const u8) ?struct { value: u64, bytes_read: usize } {
    if (bytes.len == 0) return null;

    const first_byte = bytes[0];

    switch (first_byte) {
        0xfc => {
            if (bytes.len < 3) return null;
            return .{
                .value = @as(u64, bytes[1]) | (@as(u64, bytes[2]) << 8),
                .bytes_read = 3,
            };
        },
        0xfd => {
            if (bytes.len < 4) return null;
            return .{
                .value = @as(u64, bytes[1]) |
                    (@as(u64, bytes[2]) << 8) |
                    (@as(u64, bytes[3]) << 16),
                .bytes_read = 4,
            };
        },
        0xfe => {
            if (bytes.len < 9) return null;
            return .{
                .value = @as(u64, bytes[1]) |
                    (@as(u64, bytes[2]) << 8) |
                    (@as(u64, bytes[3]) << 16) |
                    (@as(u64, bytes[4]) << 24) |
                    (@as(u64, bytes[5]) << 32) |
                    (@as(u64, bytes[6]) << 40) |
                    (@as(u64, bytes[7]) << 48) |
                    (@as(u64, bytes[8]) << 56),
                .bytes_read = 9,
            };
        },
        else => return .{ .value = @byteSwap(first_byte), .bytes_read = 1 },
    }
}

const bun = @import("home");

test "EncodeInt: tiny values use the 1-byte encoding" {
    const std = @import("std");
    const a = encodeLengthInt(0);
    try std.testing.expectEqual(@as(usize, 1), a.len);
    try std.testing.expectEqual(@as(u8, 0), a.buffer[0]);

    const b = encodeLengthInt(0xfa);
    try std.testing.expectEqual(@as(usize, 1), b.len);
    try std.testing.expectEqual(@as(u8, 0xfa), b.buffer[0]);
}

test "EncodeInt: medium values use the 0xfc / 0xfd prefixes" {
    const std = @import("std");
    // 0xfb..0xfffe → 3-byte form with 0xfc prefix.
    const c = encodeLengthInt(0x1234);
    try std.testing.expectEqual(@as(usize, 3), c.len);
    try std.testing.expectEqual(@as(u8, 0xfc), c.buffer[0]);
    try std.testing.expectEqual(@as(u8, 0x34), c.buffer[1]);
    try std.testing.expectEqual(@as(u8, 0x12), c.buffer[2]);

    // 0xffff..0xfffffe → 4-byte form with 0xfd prefix.
    const d = encodeLengthInt(0x123456);
    try std.testing.expectEqual(@as(usize, 4), d.len);
    try std.testing.expectEqual(@as(u8, 0xfd), d.buffer[0]);
}

test "EncodeInt: decodeLengthInt round-trips 0xfc and 0xfd encodings" {
    const std = @import("std");
    const a = encodeLengthInt(0x1234);
    const ra = decodeLengthInt(a.buffer[0..a.len]).?;
    try std.testing.expectEqual(@as(u64, 0x1234), ra.value);
    try std.testing.expectEqual(@as(usize, 3), ra.bytes_read);

    const b = encodeLengthInt(0x123456);
    const rb = decodeLengthInt(b.buffer[0..b.len]).?;
    try std.testing.expectEqual(@as(u64, 0x123456), rb.value);
    try std.testing.expectEqual(@as(usize, 4), rb.bytes_read);
}

test "EncodeInt: decodeLengthInt returns null on short input" {
    const std = @import("std");
    try std.testing.expect(decodeLengthInt(&[_]u8{}) == null);
    // 0xfc prefix → expects 3 bytes total.
    try std.testing.expect(decodeLengthInt(&[_]u8{ 0xfc, 0x12 }) == null);
    // 0xfd prefix → expects 4 bytes total.
    try std.testing.expect(decodeLengthInt(&[_]u8{ 0xfd, 0x12, 0x34 }) == null);
}
