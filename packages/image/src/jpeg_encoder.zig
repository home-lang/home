//! Home native baseline JPEG encoder. MIT; see NOTICE.
const std = @import("std");
const ZIGZAG = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};
const DEFAULT_LUMINANCE_QUANT = [64]u8{
    16, 11, 10, 16, 24,  40,  51,  61,
    12, 12, 14, 19, 26,  58,  60,  55,
    14, 13, 16, 24, 40,  57,  69,  56,
    14, 17, 22, 29, 51,  87,  80,  62,
    18, 22, 37, 56, 68,  109, 103, 77,
    24, 35, 55, 64, 81,  104, 113, 92,
    49, 64, 78, 87, 103, 121, 120, 101,
    72, 92, 95, 98, 112, 100, 103, 99,
};
const DEFAULT_CHROMINANCE_QUANT = [64]u8{
    17, 18, 24, 47, 99, 99, 99, 99,
    18, 21, 26, 66, 99, 99, 99, 99,
    24, 26, 56, 99, 99, 99, 99, 99,
    47, 66, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
};
const AC_VALUES = [_]u8{
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
    0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08, 0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0,
    0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
    0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
    0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
    0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5,
    0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
    0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
    0xF9, 0xFA,
};
const DC_COUNTS = [16]u8{ 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0 };
const AC_COUNTS = [16]u8{ 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 125 };
const DC_VALUES = [12]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
const Huffman = struct { codes: [256]u16 = @splat(0), lengths: [256]u5 = @splat(0) };
fn table(counts: [16]u8, values: []const u8) Huffman {
    var result: Huffman = .{};
    var code: u16 = 0;
    var n: usize = 0;
    for (counts, 0..) |num, i| {
        for (0..num) |_| {
            result.codes[values[n]] = code;
            result.lengths[values[n]] = @intCast(i + 1);
            code += 1;
            n += 1;
        }
        if (i < 15) code <<= 1;
    }
    return result;
}
const DC = table(DC_COUNTS, &DC_VALUES);
const AC = table(AC_COUNTS, &AC_VALUES);
const BASIS = @import("jpeg_dct.zig").BASIS;
pub const Encoder = struct {
    allocator: std.mem.Allocator,
    output: std.ArrayList(u8) = .empty,
    bits: u32 = 0,
    bit_count: u6 = 0,
    pub fn init(allocator: std.mem.Allocator) Encoder {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Encoder) void {
        self.output.deinit(self.allocator);
    }
    fn byte(self: *Encoder, v: u8) !void {
        try self.output.append(self.allocator, v);
    }
    fn bytes(self: *Encoder, v: []const u8) !void {
        try self.output.appendSlice(self.allocator, v);
    }
    fn word(self: *Encoder, v: u16) !void {
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, v, .big);
        try self.bytes(&b);
    }
    fn put(self: *Encoder, code: u16, len: u5) !void {
        self.bits = (self.bits << len) | code;
        self.bit_count += len;
        while (self.bit_count >= 8) {
            self.bit_count -= 8;
            const b: u8 = @truncate(self.bits >> @intCast(self.bit_count));
            try self.byte(b);
            if (b == 255) try self.byte(0);
        }
    }
    fn symbol(self: *Encoder, t: *const Huffman, v: u8) !void {
        if (t.lengths[v] == 0) return error.InvalidCoefficient;
        try self.put(t.codes[v], t.lengths[v]);
    }
    fn amplitude(self: *Encoder, v: i32) !u5 {
        _ = self;
        const magnitude: u32 = @intCast(@abs(v));
        return @intCast(if (magnitude == 0) 0 else 32 - @clz(magnitude));
    }
    fn value(self: *Encoder, v: i32, n: u5) !void {
        if (n == 0) return;
        const code: u16 = @intCast(if (v < 0) v + @as(i32, @intCast((@as(u32, 1) << n) - 1)) else v);
        try self.put(code, n);
    }
    fn block(self: *Encoder, input: [64]f32, quant: [64]u8, last_dc: *i32) !void {
        var intermediate: [8]@Vector(8, f32) = undefined;
        for (0..8) |y| {
            const line: @Vector(8, f32) = input[y * 8 ..][0..8].*;
            inline for (0..8) |u| intermediate[y][u] = @reduce(.Add, line * BASIS[u]);
        }
        var coefficients: [64]i32 = undefined;
        inline for (0..8) |u| {
            var col: @Vector(8, f32) = undefined;
            inline for (0..8) |y| col[y] = intermediate[y][u];
            for (0..8) |v| coefficients[v * 8 + u] = @intFromFloat(@round(@reduce(.Add, col * BASIS[v]) / @as(f32, @floatFromInt(quant[v * 8 + u]))));
        }
        const delta = coefficients[0] - last_dc.*;
        last_dc.* = coefficients[0];
        const dc_n = try self.amplitude(delta);
        try self.symbol(&DC, dc_n);
        try self.value(delta, dc_n);
        var run: u8 = 0;
        for (ZIGZAG[1..]) |index| {
            const v = coefficients[index];
            if (v == 0) {
                run += 1;
                continue;
            }
            while (run >= 16) {
                try self.symbol(&AC, 0xf0);
                run -= 16;
            }
            const n = try self.amplitude(v);
            if (n > 10) return error.InvalidCoefficient;
            try self.symbol(&AC, (run << 4) | @as(u8, n));
            try self.value(v, n);
            run = 0;
        }
        if (run != 0) try self.symbol(&AC, 0);
    }
    /// Borrowed output is valid until the next encode/deinit. RGB/RGBA/gray input
    /// can contain row padding. 4:4:4, baseline Huffman coding, edge replication.
    pub fn encode(self: *Encoder, data: []const u8, width: usize, height: usize, stride: usize, channels: u8, quality: u8) ![]const u8 {
        return self.encodeMetadata(data, width, height, stride, channels, quality, .{});
    }
    /// Complete owned JPEG; transfers encoder storage without a full-image dupe.
    /// The encoder remains reusable and retains no caller metadata pointers.
    pub fn encodeOwned(self: *Encoder, data: []const u8, width: usize, height: usize, stride: usize, channels: u8, quality: u8, metadata: @import("jpeg_metadata.zig").Metadata) ![]u8 {
        _ = try self.encodeMetadata(data, width, height, stride, channels, quality, metadata);
        return self.output.toOwnedSlice(self.allocator);
    }
    /// Metadata is checked before modifying reusable encoder state; it is written
    /// before scan data, with no post-encode image copy.
    pub fn encodeMetadata(self: *Encoder, data: []const u8, width: usize, height: usize, stride: usize, channels: u8, quality: u8, metadata: @import("jpeg_metadata.zig").Metadata) ![]const u8 {
        if (width == 0 or height == 0 or width > 65535 or height > 65535) return error.InvalidDimensions;
        if (channels != 1 and channels != 3 and channels != 4) return error.UnsupportedFormat;
        if (quality < 1 or quality > 100) return error.InvalidQuality;
        const row = std.math.mul(usize, width, channels) catch return error.InvalidDimensions;
        const needed = std.math.add(usize, std.math.mul(usize, height - 1, stride) catch return error.InvalidDimensions, row) catch return error.InvalidDimensions;
        if (stride < row or data.len < needed) return error.BufferTooSmall;
        const checked = try @import("jpeg_metadata.zig").check(metadata);
        if (checked.icc != null and channels == 1) return error.UnsupportedFormat;
        self.output.clearRetainingCapacity();
        self.bits = 0;
        self.bit_count = 0;
        const components: u8 = if (channels == 1) 1 else 3;
        var quant: [2][64]u8 = undefined;
        const scale: u32 = if (quality < 50) 5000 / @as(u32, quality) else 200 - @as(u32, quality) * 2;
        for ([2][64]u8{ DEFAULT_LUMINANCE_QUANT, DEFAULT_CHROMINANCE_QUANT }, 0..) |q, t| for (q, 0..) |v, i| {
            quant[t][i] = @intCast(std.math.clamp((@as(u32, v) * scale + 50) / 100, 1, 255));
        };
        try self.bytes(&.{ 255, 216, 255, 224, 0, 16, 'J', 'F', 'I', 'F', 0, 1, 1, 0, 0, 1, 0, 1, 0, 0 });
        try @import("jpeg_metadata.zig").appendChecked(self.allocator, &self.output, checked);
        for (0..2) |t| {
            try self.bytes(&.{ 255, 219, 0, 67 });
            try self.byte(@intCast(t));
            for (ZIGZAG) |i| try self.byte(quant[t][i]);
        }
        try self.bytes(&.{ 255, 192 });
        try self.word(8 + @as(u16, components) * 3);
        try self.byte(8);
        try self.word(@intCast(height));
        try self.word(@intCast(width));
        try self.byte(components);
        for (0..components) |i| {
            try self.byte(@intCast(i + 1));
            try self.byte(0x11);
            try self.byte(if (i == 0) 0 else 1);
        }
        try self.bytes(&.{ 255, 196, 0, 31, 0 });
        try self.bytes(&DC_COUNTS);
        try self.bytes(&DC_VALUES);
        try self.bytes(&.{ 255, 196, 0, 181, 0x10 });
        try self.bytes(&AC_COUNTS);
        try self.bytes(&AC_VALUES);
        try self.bytes(&.{ 255, 218 });
        try self.word(6 + @as(u16, components) * 2);
        try self.byte(components);
        for (0..components) |i| {
            try self.byte(@intCast(i + 1));
            try self.byte(0);
        }
        try self.bytes(&.{ 0, 63, 0 });
        var last_dc: [3]i32 = @splat(0);
        var by: usize = 0;
        while (by < height) : (by += 8) {
            var bx: usize = 0;
            while (bx < width) : (bx += 8) {
                var blocks: [3][64]f32 = undefined;
                for (0..8) |y| for (0..8) |x| {
                    const off = @min(by + y, height - 1) * stride + @min(bx + x, width - 1) * channels;
                    if (channels == 1) blocks[0][y * 8 + x] = @as(f32, @floatFromInt(data[off])) - 128 else {
                        const red: i32 = data[off];
                        const green: i32 = data[off + 1];
                        const blue: i32 = data[off + 2];
                        blocks[0][y * 8 + x] = @floatFromInt(((77 * red + 150 * green + 29 * blue) >> 8) - 128);
                        blocks[1][y * 8 + x] = @floatFromInt((-43 * red - 85 * green + 128 * blue) >> 8);
                        blocks[2][y * 8 + x] = @floatFromInt((128 * red - 107 * green - 21 * blue) >> 8);
                    }
                };
                for (0..components) |i| try self.block(blocks[i], quant[if (i == 0) 0 else 1], &last_dc[i]);
            }
        }
        if (self.bit_count > 0) {
            const pad: u5 = @intCast(8 - self.bit_count);
            try self.put(@intCast((@as(u16, 1) << @intCast(pad)) - 1), pad);
        }
        try self.bytes(&.{ 255, 217 });
        return self.output.items;
    }
};
test "baseline JPEG encodes real scan data and checks input" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    var pixels: [17 * 9 * 3]u8 = undefined;
    for (&pixels, 0..) |*v, i| v.* = @truncate(i * 17);
    const bytes = try enc.encode(&pixels, 17, 9, 17 * 3, 3, 90);
    try std.testing.expect(bytes.len > 400);
    try std.testing.expectEqualSlices(u8, &.{ 255, 217 }, bytes[bytes.len - 2 ..]);
    try std.testing.expectError(error.InvalidQuality, enc.encode(&pixels, 17, 9, 51, 3, 0));
    try std.testing.expectError(error.BufferTooSmall, enc.encode(&pixels, 17, 9, 52, 3, 90));
}

test "inline metadata preserves JPEG scans exactly and owned output survives encoder reuse" {
    const t = std.testing;
    var fields = @import("metadata/exif_builder.zig").Builder.init(t.allocator);
    defer fields.deinit();
    try fields.ascii(.image, 0x0110, "Inline model");
    const exif = try fields.finish(.{});
    defer t.allocator.free(exif);
    const profile = try @import("metadata/icc.zig").createSRGBProfile(t.allocator);
    defer t.allocator.free(profile);
    var encoder = Encoder.init(t.allocator);
    defer encoder.deinit();
    const pixels = "\x12\x34\x56";
    const plain = try encoder.encodeOwned(pixels, 1, 1, 3, 3, 98, .{});
    defer t.allocator.free(plain);
    const markers = try @import("jpeg_metadata.zig").encode(t.allocator, .{ .exif = exif, .icc = profile });
    defer t.allocator.free(markers);
    const with_metadata = try encoder.encodeOwned(pixels, 1, 1, 3, 3, 98, .{ .exif = exif, .icc = profile });
    defer t.allocator.free(with_metadata);
    try t.expectEqualSlices(u8, plain[0..20], with_metadata[0..20]);
    try t.expectEqualSlices(u8, markers, with_metadata[20..][0..markers.len]);
    try t.expectEqualSlices(u8, plain[20..], with_metadata[20 + markers.len ..]);
    const again = try encoder.encodeOwned(pixels, 1, 1, 3, 3, 98, .{});
    defer t.allocator.free(again);
    try t.expectEqualSlices(u8, plain, again);
    try t.expectEqualSlices(u8, "\xff\xd8", with_metadata[0..2]);
    try t.expectError(error.InvalidExif, encoder.encodeMetadata(pixels, 1, 1, 3, 3, 98, .{ .exif = "bad" }));
    try t.expectEqualSlices(u8, "\xff\xd8", with_metadata[0..2]);
}
fn metadataOwnership(allocator: std.mem.Allocator) !void {
    var encoder = Encoder.init(allocator);
    defer encoder.deinit();
    const exif = "II*\x00\x08\x00\x00\x00\x00\x00\x00\x00\x00\x00";
    const bytes = try encoder.encodeOwned("\x12\x34\x56", 1, 1, 3, 3, 90, .{ .exif = exif });
    defer allocator.free(bytes);
}
test "inline JPEG allocation failures clean up reusable encoder storage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, metadataOwnership, .{});
}
