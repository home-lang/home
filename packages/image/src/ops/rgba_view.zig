//! Checked borrowed straight-alpha RGBA8 rows. No allocator, platform or renderer.
const std = @import("std");
pub const View = struct {
    data: []const u8,
    width: usize,
    height: usize,
    stride: usize,
    packed_size: usize,
    pub fn init(data: []const u8, width: usize, height: usize, stride: usize) !View {
        if (width == 0 or height == 0) return error.InvalidGeometry;
        const row_bytes = std.math.mul(usize, width, 4) catch return error.InvalidGeometry;
        if (stride < row_bytes) return error.InvalidGeometry;
        const before_last = std.math.mul(usize, height - 1, stride) catch return error.InvalidGeometry;
        const needed = std.math.add(usize, before_last, row_bytes) catch return error.InvalidGeometry;
        const compact_size = std.math.mul(usize, row_bytes, height) catch return error.InvalidGeometry;
        if (data.len < needed) return error.BufferTooSmall;
        return .{ .data = data[0..needed], .width = width, .height = height, .stride = stride, .packed_size = compact_size };
    }
    pub fn row(self: View, y: usize) []const u8 {
        std.debug.assert(y < self.height);
        return self.data[y * self.stride ..][0 .. self.width * 4];
    }
    /// Exact active bytes only. Reject overlap/truncation before any writes.
    pub fn copy(self: View, output: []u8) !void {
        if (output.len < self.packed_size) return error.BufferTooSmall;
        const dst = output[0..self.packed_size];
        const a = @intFromPtr(self.data.ptr);
        const b = @intFromPtr(dst.ptr);
        // Distance comparisons avoid pointer-end arithmetic overflow.
        if ((a <= b and b - a < self.data.len) or (b < a and a - b < dst.len)) return error.Overlap;
        for (0..self.height) |y| @memcpy(dst[y * self.width * 4 ..][0 .. self.width * 4], self.row(y));
    }
    /// Driver ARGB8888 is byte-ordered BGRA on little-endian scanout. Coverage
    /// keeps straight samples; premultiplication rounds (c*a+127)/255 exactly.
    /// Validate all source/destination spans and overlap before any write.
    pub fn toBgra(self: View, out: []u8, stride: usize, premultiply: bool) !void {
        const src = try View.init(self.data, self.width, self.height, self.stride);
        const dst = try View.init(out, self.width, self.height, stride);
        const a = @intFromPtr(src.data.ptr);
        const b = @intFromPtr(dst.data.ptr);
        if ((a <= b and b - a < src.data.len) or (b < a and a - b < dst.data.len)) return error.Overlap;
        for (0..src.height) |y| for (0..src.width) |x| {
            const at = y * src.stride + x * 4;
            const target = y * stride + x * 4;
            const alpha = src.data[at + 3];
            inline for (0..3) |ch| {
                const value = src.data[at + 2 - ch];
                out[target + ch] = if (premultiply) @intCast((@as(u16, value) * alpha + 127) / 255) else value;
            }
            out[target + 3] = alpha;
        };
    }
};
test "padded RGBA excludes padding and retains exact straight alpha" {
    const src = [_]u8{ 255, 1, 2, 0, 4, 5, 6, 128, 99, 99, 99, 99, 7, 8, 9, 255, 10, 11, 12, 1 };
    const view = try View.init(&src, 2, 2, 12);
    var out: [18]u8 = @splat(77);
    try view.copy(&out);
    try std.testing.expectEqualSlices(u8, &.{ 255, 1, 2, 0, 4, 5, 6, 128, 7, 8, 9, 255, 10, 11, 12, 1, 77, 77 }, &out);
    try std.testing.expectEqualSlices(u8, src[12..20], view.row(1));
}
test "invalid RGBA geometry overflow truncation and overlapping output do not write" {
    var bytes: [32]u8 = @splat(91);
    try std.testing.expectError(error.InvalidGeometry, View.init(&bytes, 0, 1, 4));
    try std.testing.expectError(error.InvalidGeometry, View.init(&bytes, 1, 0, 4));
    try std.testing.expectError(error.InvalidGeometry, View.init(&bytes, 2, 1, 7));
    try std.testing.expectError(error.InvalidGeometry, View.init(&bytes, std.math.maxInt(usize), 1, 4));
    try std.testing.expectError(error.InvalidGeometry, View.init(&bytes, 1, 3, std.math.maxInt(usize)));
    try std.testing.expectError(error.BufferTooSmall, View.init(bytes[0..7], 1, 2, 4));
    const view = try View.init(bytes[8..16], 1, 2, 4);
    try std.testing.expectError(error.BufferTooSmall, view.copy(bytes[0..7]));
    try std.testing.expectError(error.Overlap, view.copy(bytes[4..12]));
    try std.testing.expectError(error.Overlap, view.copy(bytes[8..16]));
    try std.testing.expectError(error.Overlap, view.copy(bytes[12..20]));
    for (bytes) |value| try std.testing.expectEqual(@as(u8, 91), value);
    try view.copy(bytes[0..8]);
    try view.copy(bytes[16..24]);
}

test "BGRA scanout conversion retains coverage alpha and rounds every premultiplied alpha" {
    const t = std.testing;
    for (0..256) |alpha| for ([_]bool{ false, true }) |premultiply| {
        const rgba = [8]u8{ 17, 129, 255, @intCast(alpha), 0, 255, 73, @intCast(alpha) };
        const view = try View.init(&rgba, 1, 2, 4);
        var out: [15]u8 = @splat(91);
        try view.toBgra(out[1..], 8, premultiply);
        for (0..2) |y| {
            inline for (0..3) |ch| {
                const value = rgba[y * 4 + 2 - ch];
                const expected: u8 = if (premultiply) @intCast((@as(u32, value) * alpha + 127) / 255) else value;
                try t.expectEqual(expected, out[1 + y * 8 + ch]);
            }
            try t.expectEqual(@as(u8, @intCast(alpha)), out[1 + y * 8 + 3]);
        }
        try t.expectEqual(@as(u8, 91), out[0]);
        try t.expectEqual(@as(u8, 91), out[5]);
        try t.expectEqual(@as(u8, 91), out[14]);
    };
}
test "BGRA rejects late truncation overlap and invalid stride without writes" {
    const t = std.testing;
    var source: [24]u8 = @splat(79);
    var out: [24]u8 = @splat(71);
    const view = try View.init(source[1..], 2, 2, 11);
    const before = out;
    try t.expectError(error.InvalidGeometry, view.toBgra(&out, 7, false));
    try t.expectError(error.BufferTooSmall, view.toBgra(out[0..18], 11, true));
    try t.expectError(error.Overlap, view.toBgra(source[1..], 11, false));
    try t.expectEqualSlices(u8, &before, &out);
}
