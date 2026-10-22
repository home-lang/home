//! Checked borrowed RGB/BGR words. Layout is memory order, independent of FourCC.
const std = @import("std");
pub const Layout = enum {
    rgb,
    bgr,
    pub fn read(self: Layout, p: []const u8, endian: std.builtin.Endian) [3]u16 {
        const values = [3]u16{ std.mem.readInt(u16, p[0..2], endian), std.mem.readInt(u16, p[2..4], endian), std.mem.readInt(u16, p[4..6], endian) };
        return if (self == .rgb) values else .{ values[2], values[1], values[0] };
    }
    pub fn write(self: Layout, p: []u8, endian: std.builtin.Endian, value: [3]u16) void {
        const v = if (self == .rgb) value else [3]u16{ value[2], value[1], value[0] };
        inline for (0..3) |i| std.mem.writeInt(u16, p[i * 2 ..][0..2], v[i], endian);
    }
};
fn span(width: usize, height: usize, stride: usize, bytes: usize) !usize {
    if (width == 0 or height == 0) return error.InvalidGeometry;
    const row = std.math.mul(usize, width, bytes) catch return error.InvalidGeometry;
    if (stride < row) return error.InvalidGeometry;
    const last = std.math.mul(usize, height - 1, stride) catch return error.InvalidGeometry;
    return std.math.add(usize, last, row) catch return error.InvalidGeometry;
}
fn disjoint(a: []const u8, b: []const u8) !void {
    const x = @intFromPtr(a.ptr);
    const y = @intFromPtr(b.ptr);
    if ((x <= y and y - x < a.len) or (y < x and x - y < b.len)) return error.Overlap;
}
pub const View = struct {
    data: []const u8,
    width: usize,
    height: usize,
    stride: usize,
    layout: Layout,
    endian: std.builtin.Endian = .little,
    pub fn init(data: []const u8, width: usize, height: usize, stride: usize, layout: Layout, endian: std.builtin.Endian) !View {
        const need = try span(width, height, stride, 6);
        if (data.len < need) return error.BufferTooSmall;
        return .{ .data = data[0..need], .width = width, .height = height, .stride = stride, .layout = layout, .endian = endian };
    }
    pub fn sample(self: View, x: usize, y: usize) [3]u16 {
        std.debug.assert(x < self.width and y < self.height);
        return self.layout.read(self.data[y * self.stride + x * 6 ..], self.endian);
    }
    /// Preserve every word, converting byte order/layout into independent rows.
    pub fn convert(self: View, out: []u8, stride: usize, layout: Layout, endian: std.builtin.Endian) !void {
        const checked = try View.init(self.data, self.width, self.height, self.stride, self.layout, self.endian);
        const need = try span(self.width, self.height, stride, 6);
        if (out.len < need) return error.BufferTooSmall;
        const dst = out[0..need];
        if (checked.data.ptr == dst.ptr and self.stride == stride and self.layout == layout and self.endian == endian) return;
        try disjoint(checked.data, dst);
        for (0..self.height) |y| {
            const row = dst[y * stride ..][0 .. self.width * 6];
            if (self.layout == layout and self.endian == endian) @memcpy(row, checked.data[y * self.stride ..][0 .. self.width * 6]) else for (0..self.width) |x| layout.write(row[x * 6 ..], endian, checked.sample(x, y));
        }
    }
    /// Explicit high-byte reduction to RGB8 (sample >> 8); no gamma conversion.
    pub fn toRgb8(self: View, out: []u8, stride: usize) !void {
        const checked = try View.init(self.data, self.width, self.height, self.stride, self.layout, self.endian);
        const need = try span(self.width, self.height, stride, 3);
        if (out.len < need) return error.BufferTooSmall;
        const dst = out[0..need];
        try disjoint(checked.data, dst);
        for (0..self.height) |y| for (0..self.width) |x| {
            const value = checked.sample(x, y);
            inline for (0..3) |c| dst[y * stride + x * 3 + c] = @intCast(value[c] >> 8);
        };
    }
};
test "RGB16 all endian/layout pairs retain low bits across unaligned padded rows and high-byte reduction" {
    const t = std.testing;
    const samples = [4][3]u16{ .{ 0, 1, 255 }, .{ 256, 257, 0x1234 }, .{ 0x8001, 0xfe01, 0xffff }, .{ 0x123, 0x2345, 0xabcd } };
    for ([_]Layout{ .rgb, .bgr }) |source_layout| for ([_]std.builtin.Endian{ .little, .big }) |source_endian| for ([_]Layout{ .rgb, .bgr }) |target_layout| for ([_]std.builtin.Endian{ .little, .big }) |target_endian| {
        var source: [32]u8 = @splat(79);
        var dest: [32]u8 = @splat(73);
        for (samples, 0..) |value, i| source_layout.write(source[1 + (i / 2) * 15 + (i % 2) * 6 ..], source_endian, value);
        const view = try View.init(source[1..28], 2, 2, 15, source_layout, source_endian);
        try view.convert(dest[1..], 17, target_layout, target_endian);
        for (samples, 0..) |expected, i| try t.expectEqual(expected, target_layout.read(dest[1 + (i / 2) * 17 + (i % 2) * 6 ..], target_endian));
        for (dest[13..18]) |value| try t.expectEqual(@as(u8, 73), value);
        for (dest[30..]) |value| try t.expectEqual(@as(u8, 73), value);
        var out: [16]u8 = @splat(91);
        try view.toRgb8(&out, 8);
        for (samples, 0..) |expected, i| inline for (0..3) |c| try t.expectEqual(@as(u8, @intCast(expected[c] >> 8)), out[(i / 2) * 8 + (i % 2) * 3 + c]);
        try t.expectEqual(@as(u8, 91), out[6]);
        try t.expectEqual(@as(u8, 91), out[14]);
    };
}
test "RGB16 invalid geometry span overflow truncation and overlap preserve output" {
    const t = std.testing;
    var bytes: [64]u8 = @splat(79);
    var out: [32]u8 = @splat(73);
    try t.expectError(error.InvalidGeometry, View.init(&bytes, 0, 2, 12, .rgb, .little));
    try t.expectError(error.InvalidGeometry, View.init(&bytes, 2, 2, 11, .rgb, .little));
    try t.expectError(error.InvalidGeometry, View.init(&bytes, std.math.maxInt(usize), 2, 12, .rgb, .little));
    try t.expectError(error.InvalidGeometry, View.init(&bytes, 2, 3, std.math.maxInt(usize), .rgb, .little));
    try t.expectError(error.BufferTooSmall, View.init(bytes[0..26], 2, 2, 15, .rgb, .little));
    const view = try View.init(bytes[8..35], 2, 2, 15, .rgb, .little);
    try t.expectError(error.BufferTooSmall, view.convert(out[0..23], 12, .rgb, .little));
    try t.expectError(error.BufferTooSmall, view.toRgb8(out[0..11], 6));
    try t.expectError(error.Overlap, view.convert(bytes[0..], 12, .bgr, .big));
    try t.expectError(error.Overlap, view.toRgb8(bytes[8..], 6));
    try view.convert(bytes[8..35], 15, .rgb, .little);
    for (bytes) |value| try t.expectEqual(@as(u8, 79), value);
    for (out) |value| try t.expectEqual(@as(u8, 73), value);
}
