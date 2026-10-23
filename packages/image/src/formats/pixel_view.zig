//! Checked straight-alpha interleaved integer pixels. Native precision luma,
//! explicit high-byte reduction/byte replication and caller-owned copies.
const std = @import("std");
pub const Format = enum {
    gray,
    rgb,
    rgba,
    pub fn channels(self: Format) usize {
        return switch (self) {
            .gray => 1,
            .rgb => 3,
            .rgba => 4,
        };
    }
};
pub fn packedRow(width: u32, format: Format, bits: u8) !usize {
    if (width == 0 or width > std.math.maxInt(i32) or (bits != 8 and bits != 16)) return error.InvalidGeometry;
    return std.math.mul(usize, width, format.channels() * (bits / 8)) catch error.InvalidGeometry;
}
pub const View = struct {
    data: []const u8,
    width: u32,
    height: u32,
    stride: usize,
    format: Format = .rgb,
    bits: u8 = 8,
    endian: std.builtin.Endian = .little,

    pub fn validate(self: View) !usize {
        if (self.height == 0 or self.height > std.math.maxInt(i32)) return error.InvalidGeometry;
        const row_bytes = try packedRow(self.width, self.format, self.bits);
        if (self.stride < row_bytes) return error.InvalidGeometry;
        const last = std.math.mul(usize, self.height - 1, self.stride) catch return error.InvalidGeometry;
        const needed = std.math.add(usize, last, row_bytes) catch return error.InvalidGeometry;
        if (self.data.len < needed) return error.BufferTooSmall;
        return row_bytes;
    }
    pub fn row(self: View, y: usize, row_bytes: usize) []const u8 {
        return self.data[y * self.stride ..][0..row_bytes];
    }
    /// Call only on a validated view with coordinates inside its dimensions.
    /// Eight-bit samples expand by multiplication by 257; absent alpha is 65535.
    pub fn sample16(self: View, x: usize, y: usize) [4]u16 {
        std.debug.assert(x < self.width and y < self.height);
        const at = y * self.stride + x * self.format.channels() * (self.bits / 8);
        var values: [4]u16 = .{ 0, 0, 0, 65535 };
        for (0..self.format.channels()) |ch| values[ch] = if (self.bits == 8) @as(u16, self.data[at + ch]) * 257 else std.mem.readInt(u16, self.data[at + ch * 2 ..][0..2], self.endian);
        if (self.format == .gray) {
            values[1] = values[0];
            values[2] = values[0];
        }
        return values;
    }
    pub fn crop(self: View, x: u32, y: u32, width: u32, height: u32) !View {
        _ = try self.validate();
        if (width == 0 or height == 0 or x > self.width or y > self.height or width > self.width - x or height > self.height - y) return error.InvalidGeometry;
        const offset = @as(usize, y) * self.stride + @as(usize, x) * self.format.channels() * (self.bits / 8);
        var result = self;
        result.data = self.data[offset..];
        result.width = width;
        result.height = height;
        return result;
    }
    /// Reject overlap/truncation/options before the first destination write.
    /// Gray uses floor((299R+587G+114B)/1000) at source precision. No transfer,
    /// gamut or alpha compositing is performed. Dropping alpha is explicit.
    pub fn convert(self: View, output: []u8, stride: usize, format: Format, bits: u8, endian: std.builtin.Endian) !void {
        const source_row = try self.validate();
        const target = View{ .data = output, .width = self.width, .height = self.height, .stride = stride, .format = format, .bits = bits, .endian = endian };
        const target_row = try target.validate();
        const source_span = (@as(usize, self.height) - 1) * self.stride + source_row;
        const target_span = (@as(usize, self.height) - 1) * stride + target_row;
        const a = @intFromPtr(self.data.ptr);
        const b = @intFromPtr(output.ptr);
        const identical = self.format == format and self.bits == bits and (bits == 8 or self.endian == endian);
        if (a == b and self.stride == stride and identical) return;
        if ((a <= b and b - a < source_span) or (b < a and a - b < target_span)) return error.Overlap;
        if (identical) {
            for (0..self.height) |y| @memcpy(output[y * stride ..][0..target_row], self.row(y, source_row));
            return;
        }
        for (0..self.height) |y| for (0..self.width) |x| {
            var value = self.sample16(x, y);
            if (format == .gray) {
                const shift: u4 = if (self.bits == 8) 8 else 0;
                const gray = (@as(u32, value[0] >> shift) * 299 + @as(u32, value[1] >> shift) * 587 + @as(u32, value[2] >> shift) * 114) / 1000;
                value[0] = @intCast(if (self.bits == 8) gray * 257 else gray);
            }
            const at = y * stride + x * format.channels() * (bits / 8);
            for (0..format.channels()) |ch| {
                if (bits == 8) output[at + ch] = @intCast(value[ch] >> 8) else std.mem.writeInt(u16, output[at + ch * 2 ..][0..2], value[ch], endian);
            }
        };
    }
};
pub const Owned = struct {
    allocator: std.mem.Allocator,
    view: View,
    pub fn copy(allocator: std.mem.Allocator, source: View, format: Format, bits: u8, endian: std.builtin.Endian) !Owned {
        _ = try source.validate();
        const row = try packedRow(source.width, format, bits);
        const size = std.math.mul(usize, row, source.height) catch return error.InvalidGeometry;
        const data = try allocator.alloc(u8, size);
        errdefer allocator.free(data);
        try source.convert(data, row, format, bits, endian);
        return .{ .allocator = allocator, .view = .{ .data = data, .width = source.width, .height = source.height, .stride = row, .format = format, .bits = bits, .endian = endian } };
    }
    pub fn deinit(self: *Owned) void {
        self.allocator.free(self.view.data);
        self.view.data = &.{};
        self.view.width = 0;
        self.view.height = 0;
        self.view.stride = 0;
    }
};

test "pixel words endian conversion alpha and native precision gray preserve every low bit" {
    const t = std.testing;
    const values = [4]u16{ 0x1234, 0x8001, 0xfedc, 0x4567 };
    for ([_]std.builtin.Endian{ .little, .big }) |order| {
        var pixels: [18]u8 = @splat(99);
        for (values, 0..) |value, ch| std.mem.writeInt(u16, pixels[1 + ch * 2 ..][0..2], value, order);
        const source = View{ .data = pixels[1..9], .width = 1, .height = 1, .stride = 8, .format = .rgba, .bits = 16, .endian = order };
        _ = try source.validate();
        try t.expectEqual(values, source.sample16(0, 0));
        var out: [12]u8 = @splat(73);
        try source.convert(&out, 8, .rgba, 16, if (order == .little) .big else .little);
        const opposite = View{ .data = &out, .width = 1, .height = 1, .stride = 8, .format = .rgba, .bits = 16, .endian = if (order == .little) .big else .little };
        try t.expectEqual(values, opposite.sample16(0, 0));
        try source.convert(&out, 4, .rgba, 8, .little);
        try t.expectEqualSlices(u8, &.{ 0x12, 0x80, 0xfe, 0x45 }, out[0..4]);
        try source.convert(&out, 2, .gray, 16, .big);
        try t.expectEqual(@as(u16, @intCast((@as(u32, values[0]) * 299 + @as(u32, values[1]) * 587 + @as(u32, values[2]) * 114) / 1000)), std.mem.readInt(u16, out[0..2], .big));
    }
    const source = View{ .data = &.{ 1, 128, 255 }, .width = 1, .height = 1, .stride = 3 };
    var out: [8]u8 = undefined;
    try source.convert(&out, 8, .rgba, 16, .little);
    try t.expectEqualSlices(u8, &.{ 1, 1, 128, 128, 255, 255, 255, 255 }, &out);
}
test "pixel conversion validates both spans and overlap before mutating any output" {
    const t = std.testing;
    var pixels: [24]u8 = @splat(73);
    var out: [24]u8 = @splat(91);
    const source = View{ .data = pixels[2..15], .width = 2, .height = 2, .stride = 7 };
    try t.expectError(error.BufferTooSmall, source.convert(out[0..11], 6, .rgb, 8, .little));
    try t.expectError(error.InvalidGeometry, source.convert(&out, 6, .rgb, 12, .little));
    try t.expectError(error.Overlap, source.convert(pixels[0..], 6, .rgb, 8, .little));
    try t.expectError(error.Overlap, source.convert(pixels[7..], 6, .rgb, 8, .little));
    try t.expectError(error.InvalidGeometry, source.crop(1, 0, 2, 1));
    for (pixels) |byte| try t.expectEqual(@as(u8, 73), byte);
    for (out) |byte| try t.expectEqual(@as(u8, 91), byte);
    try source.convert(pixels[2..], 7, .rgb, 8, .little);
    try source.convert(&out, 8, .rgb, 8, .big);
    for (out[0..6]) |byte| try t.expectEqual(@as(u8, 73), byte);
    for (out[6..8]) |byte| try t.expectEqual(@as(u8, 91), byte);
    for (out[8..14]) |byte| try t.expectEqual(@as(u8, 73), byte);
    for (out[14..]) |byte| try t.expectEqual(@as(u8, 91), byte);
}
fn failures(a: std.mem.Allocator) !void {
    var source: [30]u8 = @splat(73);
    const view = View{ .data = &source, .width = 2, .height = 2, .stride = 14, .format = .rgba };
    var owned = try Owned.copy(a, try view.crop(1, 0, 1, 2), .rgba, 16, .big);
    defer owned.deinit();
    @memset(&source, 99);
    try std.testing.expectEqual(@as(usize, 16), owned.view.data.len);
    for (owned.view.data) |byte| try std.testing.expectEqual(@as(u8, 73), byte);
}
test "owned cropped pixels exclude padding retire sources and unwind allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, failures, .{});
}
