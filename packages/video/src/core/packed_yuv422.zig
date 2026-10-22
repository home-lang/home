//! Checked packed 8-bit 4:2:2. Layout names describe byte order. No owner/allocator.
const std = @import("std");
const color = @import("yuv_rgb.zig");
const rgb = @import("packed_rgb.zig");
pub const Layout = enum {
    yuyv,
    yvyu,
    uyvy,
    vyuy,
    pub fn offsets(self: Layout) [4]usize {
        return switch (self) {
            .yuyv => .{ 0, 1, 2, 3 },
            .yvyu => .{ 0, 3, 2, 1 },
            .uyvy => .{ 1, 0, 3, 2 },
            .vyuy => .{ 1, 2, 3, 0 },
        };
    }
    /// Logical Y0,U,Y1,V for one horizontal pair.
    pub fn read(self: Layout, p: []const u8) [4]u8 {
        const o = self.offsets();
        return .{ p[o[0]], p[o[1]], p[o[2]], p[o[3]] };
    }
    pub fn write(self: Layout, p: []u8, value: [4]u8) void {
        const o = self.offsets();
        inline for (0..4) |i| p[o[i]] = value[i];
    }
};
fn span(width: u32, height: u32, stride: u32, bytes: usize) !usize {
    if (width == 0 or height == 0) return error.InvalidGeometry;
    const row = @as(u64, width) * bytes;
    if (stride < row) return error.InvalidGeometry;
    const required = @as(u64, stride) * (height - 1) + row;
    if (required > std.math.maxInt(usize)) return error.InvalidGeometry;
    return @intCast(required);
}
pub const View = struct {
    data: []const u8,
    width: u32,
    height: u32,
    stride: u32,
    layout: Layout,
    pub fn init(data: []const u8, width: u32, height: u32, stride: u32, layout: Layout) !View {
        if (width & 1 != 0) return error.InvalidGeometry;
        const needed = try span(width, height, stride, 2);
        if (data.len < needed) return error.BufferTooSmall;
        return .{ .data = data[0..needed], .width = width, .height = height, .stride = stride, .layout = layout };
    }
    pub fn validate(self: View) !void {
        _ = try View.init(self.data, self.width, self.height, self.stride, self.layout);
    }
    pub fn pair(self: View, x: u32, y: u32) [4]u8 {
        std.debug.assert(x < self.width / 2 and y < self.height);
        return self.layout.read(self.data[@as(usize, y) * self.stride + @as(usize, x) * 4 ..]);
    }
    pub fn copy(self: View, out: []u8, stride: u32, layout: Layout) !void {
        try self.validate();
        const target = try View.init(out, self.width, self.height, stride, layout);
        if (self.data.ptr == target.data.ptr and self.stride == stride and self.layout == layout) return;
        try color.disjoint(self.data, target.data);
        for (0..self.height) |y| for (0..self.width / 2) |x| layout.write(out[y * stride + x * 4 ..], self.pair(@intCast(x), @intCast(y)));
    }
    pub fn decodeRgb(self: View, conversion: color.Conversion, out: []u8, stride: u32) !void {
        return self.decode(conversion, out, stride, .rgb);
    }
    pub fn decode(self: View, conversion: color.Conversion, out: []u8, stride: u32, layout: rgb.Layout) !void {
        try self.validate();
        const needed = try span(self.width, self.height, stride, layout.bytes());
        if (out.len < needed) return error.BufferTooSmall;
        try color.disjoint(self.data, out[0..needed]);
        for (0..self.height) |y| for (0..self.width / 2) |x| {
            const p = self.pair(@intCast(x), @intCast(y));
            const cb = @as(i64, p[1]) - 128;
            const cr = @as(i64, p[3]) - 128;
            const chroma = [3]i64{ conversion.rv * cr, conversion.gu * cb + conversion.gv * cr, conversion.bu * cb };
            inline for (0..2) |dx| {
                const l = conversion.cy * (@as(i64, p[dx * 2]) - conversion.y_offset);
                var value: [4]u8 = .{ 0, 0, 0, 255 };
                inline for (0..3) |channel| value[channel] = @intCast(std.math.clamp((l + chroma[channel] + 32768) >> 16, 0, 255));
                layout.write(out[y * stride + (x * 2 + dx) * layout.bytes() ..], value);
            }
        };
    }
};
pub fn encodeRgb(source: rgb.View, out: []u8, stride: u32, layout: Layout, conversion: color.Conversion) !void {
    const checked = try rgb.View.init(source.data, source.width, source.height, source.stride, source.layout);
    if (source.width > std.math.maxInt(u32) or source.height > std.math.maxInt(u32)) return error.InvalidGeometry;
    const target = try View.init(out, @intCast(source.width), @intCast(source.height), stride, layout);
    try color.disjoint(checked.data, target.data);
    for (0..source.height) |y| for (0..source.width / 2) |x| {
        const first = source.layout.read(checked.data[y * source.stride + x * 2 * source.layout.bytes() ..]);
        const second = source.layout.read(checked.data[y * source.stride + (x * 2 + 1) * source.layout.bytes() ..]);
        const uv = conversion.chromaPair(first[0..3].*, second[0..3].*);
        layout.write(out[y * stride + x * 4 ..], .{ conversion.luma(first[0], first[1], first[2]), uv[0], conversion.luma(second[0], second[1], second[2]), uv[1] });
    };
}
test "packed layouts encode both RGB contributors and decode all matrices ranges with odd height padding and opaque alpha" {
    const t = std.testing;
    const source = [_]u8{ 255, 0, 0, 0, 255, 0, 99, 99, 99, 0, 0, 255, 255, 255, 255, 99, 99, 99, 20, 40, 60, 70, 90, 110 };
    const view = try rgb.View.init(&source, 2, 3, 9, .rgb);
    for (std.meta.tags(Layout)) |layout| for ([_]color.Matrix{ .bt601, .bt709, .bt2020 }) |matrix| for ([_]color.Range{ .full, .limited }) |range| {
        const conversion = color.Conversion.init(matrix, range);
        var encoded: [20]u8 = @splat(79);
        try encodeRgb(view, &encoded, 7, layout, conversion);
        const packed_view = try View.init(encoded[0..18], 2, 3, 7, layout);
        for (0..3) |y| {
            const first = view.layout.read(view.data[y * view.stride ..]);
            const second = view.layout.read(view.data[y * view.stride + 3 ..]);
            const pair = packed_view.pair(0, @intCast(y));
            try t.expectEqual(conversion.toYuv(first[0], first[1], first[2])[0], pair[0]);
            try t.expectEqual(conversion.toYuv(second[0], second[1], second[2])[0], pair[2]);
            // Independent floating chroma reference from averaged R'G'B'.
            const kr: f64 = switch (matrix) {
                .bt601 => 0.299,
                .bt709 => 0.2126,
                .bt2020 => 0.2627,
            };
            const kb: f64 = switch (matrix) {
                .bt601 => 0.114,
                .bt709 => 0.0722,
                .bt2020 => 0.0593,
            };
            const r = (@as(f64, @floatFromInt(first[0])) + @as(f64, @floatFromInt(second[0]))) / 2;
            const g = (@as(f64, @floatFromInt(first[1])) + @as(f64, @floatFromInt(second[1]))) / 2;
            const b = (@as(f64, @floatFromInt(first[2])) + @as(f64, @floatFromInt(second[2]))) / 2;
            const l = kr * r + (1 - kr - kb) * g + kb * b;
            const scale: f64 = if (range == .full) 255 else 224;
            const expected = [2]f64{ 128 + (b - l) * scale / (510 * (1 - kb)), 128 + (r - l) * scale / (510 * (1 - kr)) };
            for (expected, [_]u8{ pair[1], pair[3] }) |value, actual| try t.expect(@abs(@as(i32, actual) - @as(i32, @intFromFloat(@round(std.math.clamp(value, 0, 255))))) <= 1);
        }
        var decoded: [38]u8 = @splat(73);
        try packed_view.decode(conversion, &decoded, 13, .rgba);
        for (0..3) |y| inline for (0..2) |x| {
            const pair = packed_view.pair(0, @intCast(y));
            const expected = conversion.toRgb(pair[x * 2], pair[1], pair[3]);
            try t.expectEqualSlices(u8, &expected, decoded[y * 13 + x * 4 ..][0..3]);
            try t.expectEqual(@as(u8, 255), decoded[y * 13 + x * 4 + 3]);
        };
        for ([_]usize{ 4, 5, 6, 11, 12, 13, 18, 19 }) |i| try t.expectEqual(@as(u8, 79), encoded[i]);
        for (decoded[8..13]) |value| try t.expectEqual(@as(u8, 73), value);
    };
}
test "packed spans overflow odd width truncation and overlap fail before writes" {
    const t = std.testing;
    var source: [32]u8 = @splat(99);
    var out: [32]u8 = @splat(73);
    try t.expectError(error.InvalidGeometry, View.init(&source, 0, 2, 8, .yuyv));
    try t.expectError(error.InvalidGeometry, View.init(&source, 3, 2, 8, .yuyv));
    try t.expectError(error.InvalidGeometry, View.init(&source, 4, 2, 7, .yuyv));
    try t.expectError(error.InvalidGeometry, View.init(&source, std.math.maxInt(u32) - 1, 2, std.math.maxInt(u32), .yuyv));
    try t.expectError(error.BufferTooSmall, View.init(source[0..11], 2, 2, 8, .yuyv));
    const view = try View.init(source[0..12], 2, 2, 8, .yuyv);
    const conversion = color.Conversion.init(.bt601, .limited);
    try t.expectError(error.BufferTooSmall, view.decodeRgb(conversion, out[0..11], 6));
    try t.expectError(error.Overlap, view.decodeRgb(conversion, &source, 6));
    const rgb_view = try rgb.View.init(source[0..12], 2, 2, 6, .rgb);
    try t.expectError(error.BufferTooSmall, encodeRgb(rgb_view, out[0..7], 4, .uyvy, conversion));
    try t.expectError(error.Overlap, encodeRgb(rgb_view, &source, 4, .uyvy, conversion));
    for (out) |value| try t.expectEqual(@as(u8, 73), value);
    for (source) |value| try t.expectEqual(@as(u8, 99), value);
}
