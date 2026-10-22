//! Checked, allocation-free packed byte layouts. Names describe memory order,
//! not a platform FourCC. X is unused padding and always converts to opaque.
const std = @import("std");
pub const Layout = enum {
    rgb,
    bgr,
    rgbx,
    bgrx,
    rgba,
    bgra,
    argb,
    pub fn bytes(self: Layout) usize {
        return switch (self) {
            .rgb, .bgr => 3,
            else => 4,
        };
    }
    pub fn read(self: Layout, p: []const u8) [4]u8 {
        return switch (self) {
            .rgb, .rgbx => .{ p[0], p[1], p[2], 255 },
            .bgr, .bgrx => .{ p[2], p[1], p[0], 255 },
            .rgba => p[0..4].*,
            .bgra => .{ p[2], p[1], p[0], p[3] },
            .argb => .{ p[1], p[2], p[3], p[0] },
        };
    }
    pub fn write(self: Layout, p: []u8, rgba: [4]u8) void {
        switch (self) {
            .rgb, .rgbx, .rgba => @memcpy(p[0..3], rgba[0..3]),
            .bgr, .bgrx, .bgra => {
                p[0] = rgba[2];
                p[1] = rgba[1];
                p[2] = rgba[0];
            },
            .argb => {
                p[0] = rgba[3];
                @memcpy(p[1..4], rgba[0..3]);
            },
        }
        switch (self) {
            .rgbx, .bgrx => p[3] = 255,
            .rgba, .bgra => p[3] = rgba[3],
            else => {},
        }
    }
};
fn span(width: usize, height: usize, stride: usize, layout: Layout) !usize {
    if (width == 0 or height == 0) return error.InvalidGeometry;
    const row_bytes = std.math.mul(usize, width, layout.bytes()) catch return error.InvalidGeometry;
    if (stride < row_bytes) return error.InvalidGeometry;
    const last = std.math.mul(usize, height - 1, stride) catch return error.InvalidGeometry;
    return std.math.add(usize, last, row_bytes) catch return error.InvalidGeometry;
}
pub const View = struct {
    data: []const u8,
    width: usize,
    height: usize,
    stride: usize,
    layout: Layout,
    pub fn init(data: []const u8, width: usize, height: usize, stride: usize, layout: Layout) !View {
        const needed = try span(width, height, stride, layout);
        if (data.len < needed) return error.BufferTooSmall;
        return .{ .data = data[0..needed], .width = width, .height = height, .stride = stride, .layout = layout };
    }
    /// Preflight all geometry, lengths and overlap before any write. Destination
    /// row padding and suffix are untouched. Exact same view/layout is a no-op;
    /// all other overlap is rejected (including differently pitched views).
    pub fn convert(self: View, output: []u8, stride: usize, layout: Layout) !void {
        const source = try View.init(self.data, self.width, self.height, self.stride, self.layout);
        const needed = try span(self.width, self.height, stride, layout);
        if (output.len < needed) return error.BufferTooSmall;
        const dst = output[0..needed];
        const a = @intFromPtr(source.data.ptr);
        const b = @intFromPtr(dst.ptr);
        if (a == b and self.stride == stride and self.layout == layout) return;
        if ((a <= b and b - a < source.data.len) or (b < a and a - b < dst.len)) return error.Overlap;
        for (0..self.height) |y| {
            const src_row = source.data[y * self.stride ..][0 .. self.width * self.layout.bytes()];
            const dst_row = dst[y * stride ..][0 .. self.width * layout.bytes()];
            if (self.layout == layout and layout != .rgbx and layout != .bgrx) {
                @memcpy(dst_row, src_row);
            } else for (0..self.width) |x| layout.write(dst_row[x * layout.bytes() ..], self.layout.read(src_row[x * self.layout.bytes() ..]));
        }
    }
};
test "all packed layouts convert padded unaligned rows and preserve alpha or make X opaque" {
    const t = std.testing;
    const layouts = std.meta.tags(Layout);
    for (layouts) |src_layout| for (layouts) |dst_layout| {
        var src: [128]u8 = @splat(29);
        var dst: [128]u8 = @splat(73);
        const ss = src_layout.bytes() * 3 + 5;
        const ds = dst_layout.bytes() * 3 + 7;
        for (0..2) |y| for (0..3) |x| {
            const rgba = [4]u8{ @intCast(3 + x), @intCast(17 + y), @intCast(203 - x), @intCast(31 + x + y) };
            src_layout.write(src[1 + y * ss + x * src_layout.bytes() ..], rgba);
            if (src_layout == .rgbx or src_layout == .bgrx) src[1 + y * ss + x * 4 + 3] = 0;
        };
        const src_span = try span(3, 2, ss, src_layout);
        const view = try View.init(src[1..][0..src_span], 3, 2, ss, src_layout);
        try view.convert(dst[1..], ds, dst_layout);
        for (0..2) |y| for (0..3) |x| {
            const actual = dst_layout.read(dst[1 + y * ds + x * dst_layout.bytes() ..]);
            const alpha: u8 = if ((src_layout == .rgba or src_layout == .bgra or src_layout == .argb) and (dst_layout == .rgba or dst_layout == .bgra or dst_layout == .argb)) @intCast(31 + x + y) else 255;
            try t.expectEqual([4]u8{ @intCast(3 + x), @intCast(17 + y), @intCast(203 - x), alpha }, actual);
            if (dst_layout == .rgbx or dst_layout == .bgrx) try t.expectEqual(@as(u8, 255), dst[1 + y * ds + x * 4 + 3]);
        };
        try t.expectEqual(@as(u8, 73), dst[0]);
        for (1 + 3 * dst_layout.bytes()..1 + ds) |i| try t.expectEqual(@as(u8, 73), dst[i]);
        for (1 + try span(3, 2, ds, dst_layout)..dst.len) |i| try t.expectEqual(@as(u8, 73), dst[i]);
    };
}
test "invalid spans and all non-identity overlap fail before writing" {
    const t = std.testing;
    var bytes: [64]u8 = @splat(91);
    try t.expectError(error.InvalidGeometry, View.init(&bytes, 0, 1, 4, .rgbx));
    try t.expectError(error.InvalidGeometry, View.init(&bytes, 1, 0, 4, .rgbx));
    try t.expectError(error.InvalidGeometry, View.init(&bytes, 2, 1, 7, .rgbx));
    try t.expectError(error.InvalidGeometry, View.init(&bytes, std.math.maxInt(usize), 1, 4, .rgbx));
    try t.expectError(error.InvalidGeometry, View.init(&bytes, 1, 3, std.math.maxInt(usize), .rgbx));
    try t.expectError(error.BufferTooSmall, View.init(bytes[0..7], 1, 2, 4, .rgbx));
    const view = try View.init(bytes[16..24], 1, 2, 4, .rgbx);
    try t.expectError(error.BufferTooSmall, view.convert(bytes[0..5], 3, .rgb));
    try t.expectError(error.InvalidGeometry, view.convert(&bytes, 2, .rgb));
    try t.expectError(error.Overlap, view.convert(bytes[12..], 3, .rgb));
    try t.expectError(error.Overlap, view.convert(bytes[16..], 3, .rgb));
    try t.expectError(error.Overlap, view.convert(bytes[20..], 3, .rgb));
    try view.convert(bytes[16..24], 4, .rgbx);
    for (bytes) |value| try t.expectEqual(@as(u8, 91), value);
    try view.convert(bytes[0..], 3, .rgb);
    try view.convert(bytes[24..], 3, .rgb);
}
