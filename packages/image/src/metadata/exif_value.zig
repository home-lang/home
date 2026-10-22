//! Byte-order copying for already validated TIFF field payloads. Rational values
//! consist of two 32-bit words, not one 64-bit scalar. No allocation or pixels.
const std = @import("std");
pub fn copy(out: []u8, input: []const u8, kind: u16, source: std.builtin.Endian, target: std.builtin.Endian) void {
    const step: usize = switch (kind) {
        3, 8 => 2,
        4, 5, 9, 10, 11 => 4,
        12 => 8,
        else => 1,
    };
    std.debug.assert(out.len == input.len and input.len % step == 0);
    if (source == target or step == 1) {
        @memcpy(out, input);
        return;
    }
    var at: usize = 0;
    while (at < input.len) : (at += step) for (0..step) |i| {
        out[at + i] = input[at + step - 1 - i];
    };
}
test "rational scalar and opaque TIFF bytes preserve their units across byte orders" {
    const data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var out: [8]u8 = undefined;
    for ([_]u16{ 5, 10, 4, 9, 11 }) |kind| {
        copy(&out, &data, kind, .little, .big);
        try std.testing.expectEqualSlices(u8, &.{ 4, 3, 2, 1, 8, 7, 6, 5 }, &out);
    }
    copy(&out, &data, 12, .little, .big);
    try std.testing.expectEqualSlices(u8, &.{ 8, 7, 6, 5, 4, 3, 2, 1 }, &out);
    copy(&out, &data, 3, .little, .big);
    try std.testing.expectEqualSlices(u8, &.{ 2, 1, 4, 3, 6, 5, 8, 7 }, &out);
    copy(&out, &data, 7, .little, .big);
    try std.testing.expectEqualSlices(u8, &data, &out);
}
