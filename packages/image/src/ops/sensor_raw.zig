//! Checked borrowed sensor samples: Bayer/mono unpacked, CSI-2 and PiSP COMP1.
//! PiSP decoder adapted from raspberrypi/picamera2 request.py Helpers.decompress
//! at 5e2a35d3bb230825c98c56d98e01b41ddeb43e86. No Python dependency.
//! Other checked view/packing code: Home contributors (MIT).
// BSD 2-Clause License
//
// Copyright (c) 2021, Raspberry Pi
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice, this
//    list of conditions and the following disclaimer.
//
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
// FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
const std = @import("std");
pub const Pattern = enum {
    rggb,
    bggr,
    grbg,
    gbrg,
    mono,
    pub fn positions(self: Pattern) [4]u8 {
        return switch (self) {
            .rggb => .{ 0, 1, 2, 3 },
            .bggr => .{ 3, 2, 1, 0 },
            .grbg => .{ 1, 0, 3, 2 },
            .gbrg => .{ 2, 3, 0, 1 },
            .mono => @splat(0),
        };
    }
    pub fn cfa(self: Pattern) [4]u8 {
        std.debug.assert(self != .mono);
        const colors = [4]u8{ 0, 1, 1, 2 };
        var result: [4]u8 = undefined;
        for (self.positions(), 0..) |p, i| result[i] = colors[p];
        return result;
    }
    pub fn name(self: Pattern) []const u8 {
        return switch (self) {
            .rggb => "RGGB",
            .bggr => "BGGR",
            .grbg => "GRBG",
            .gbrg => "GBRG",
            .mono => "MONO",
        };
    }
};
pub const Format = struct {
    bits: u5,
    csi2_packed: bool = false,
    pattern: Pattern,
    pisp_comp1: bool = false,
    pub fn validate(self: Format) !void {
        if (self.bits != 8 and self.bits != 10 and self.bits != 12 and self.bits != 14 and self.bits != 16) return error.UnsupportedFormat;
        if (self.pisp_comp1 and (self.bits != 16 or self.csi2_packed)) return error.UnsupportedFormat;
        if (self.csi2_packed and (self.bits == 16 or (self.bits == 8 and self.pattern != .mono))) return error.UnsupportedFormat;
    }
    pub fn parse(name: []const u8) !Format {
        if (std.mem.endsWith(u8, name, "_PISP_COMP1")) {
            const prefix = name[0 .. name.len - 11];
            inline for (.{ Pattern.rggb, Pattern.bggr, Pattern.grbg, Pattern.gbrg, Pattern.mono }) |p| if (std.mem.eql(u8, prefix, p.name())) return .{ .bits = 16, .pattern = p, .pisp_comp1 = true };
            return error.UnsupportedFormat;
        }
        const mono = std.mem.startsWith(u8, name, "R") and !std.mem.startsWith(u8, name, "RG");
        const prefix: usize = if (mono) 1 else 5;
        if (name.len <= prefix or (!mono and name[0] != 'S')) return error.UnsupportedFormat;
        const pattern: Pattern = if (mono) .mono else if (std.mem.eql(u8, name[1..5], "RGGB")) .rggb else if (std.mem.eql(u8, name[1..5], "BGGR")) .bggr else if (std.mem.eql(u8, name[1..5], "GRBG")) .grbg else if (std.mem.eql(u8, name[1..5], "GBRG")) .gbrg else return error.UnsupportedFormat;
        const is_packed = std.mem.endsWith(u8, name, "_CSI2P");
        const end = if (is_packed) name.len - 6 else name.len;
        if (end <= prefix) return error.UnsupportedFormat;
        const depth = name[prefix..end];
        // Canonical names only, no signs, whitespace or leading zero aliases.
        if (depth.len == 0 or depth.len > 2 or depth[0] == '0') return error.UnsupportedFormat;
        for (depth) |v| if (v < '0' or v > '9') return error.UnsupportedFormat;
        const bits = std.fmt.parseInt(u5, depth, 10) catch return error.UnsupportedFormat;
        const result = Format{ .bits = bits, .csi2_packed = is_packed, .pattern = pattern };
        try result.validate();
        return result;
    }
    pub fn writeName(self: Format, out: []u8) ![]const u8 {
        try self.validate();
        if (self.pisp_comp1) return std.fmt.bufPrint(out, "{s}_PISP_COMP1", .{self.pattern.name()});
        return std.fmt.bufPrint(out, "{s}{s}{d}{s}", .{ if (self.pattern == .mono) "" else "S", if (self.pattern == .mono) "R" else self.pattern.name(), self.bits, if (self.csi2_packed) "_CSI2P" else "" });
    }
    pub fn rowBytes(self: Format, width: usize) !usize {
        try self.validate();
        if (width == 0) return error.InvalidGeometry;
        if (self.pisp_comp1) return std.math.mul(usize, (std.math.add(usize, width, 7) catch return error.InvalidGeometry) / 8, 8) catch error.InvalidGeometry;
        if (!self.csi2_packed or self.bits == 8) return std.math.mul(usize, width, if (self.bits == 8) 1 else 2) catch error.InvalidGeometry;
        const group: usize = if (self.bits == 12) 2 else 4;
        return std.math.mul(usize, (std.math.add(usize, width, group - 1) catch return error.InvalidGeometry) / group, if (self.bits == 10) 5 else if (self.bits == 12) 3 else 7) catch error.InvalidGeometry;
    }
    pub fn white(self: Format) u32 {
        std.debug.assert(self.bits > 0 and self.bits <= 16);
        return (@as(u32, 1) << self.bits) - 1;
    }
};
/// Driver-standard COMP1 reconstruction: interleaved four-pixel channel words.
/// The offset is fixed at 2048, matching the standard Raspberry Pi capture path.
pub fn decodeWord(word: u32) [4]u16 {
    const mode: i32 = @intCast(word & 3);
    var q: [4]i32 = undefined;
    var pix: [4]i32 = undefined;
    if (mode == 3) {
        const a: i32 = @intCast((word >> 2) & 32767);
        const b: i32 = @intCast((word >> 17) & 32767);
        q = .{ (a & 15) + 16 * @divTrunc(a >> 8, 11), @mod(a >> 4, 176), (b & 15) + 16 * @divTrunc(b >> 8, 11), @mod(b >> 4, 176) };
        for (q, 0..) |v, i| pix[i] = @max(256 * v, 512 * (v - 47));
    } else {
        const base: i32 = @intCast((word >> 2) & 511);
        const delta: i32 = @as(i32, @intCast((word >> 11) & 127)) - 64;
        q[1] = base;
        q[2] = delta + 448;
        if (mode * base < 768) {
            q[1] = @max(base, base - delta);
            q[2] = @max(base, base + delta);
        }
        const limit: i32 = @as(i32, 1536) >> @as(u5, @intCast(mode));
        q[0] = @min(limit, @max(0, q[1] - 64)) + @as(i32, @intCast((word >> 18) & 127));
        q[3] = @min(limit, @max(0, q[2] - 64)) + @as(i32, @intCast((word >> 25) & 127));
        for (q, 0..) |v, i| pix[i] = @max(@max(16 * v, 32 * (v - 160)), 64 * mode * v);
    }
    var result: [4]u16 = undefined;
    for (pix, 0..) |v, i| result[i] = @intCast(std.math.clamp(v + 2048, 0, 65535));
    return result;
}
/// Pack four mode-3 companding codes (0..175), not arbitrary lossless samples.
/// Used for deterministic input fixtures; this is not a general sensor encoder.
pub fn compandedWord(codes: [4]u8) !u32 {
    for (codes) |v| if (v > 175) return error.InvalidSample;
    const a: u32 = @as(u32, codes[0] % 16) + 16 * (@as(u32, codes[0] / 16) * 176 + codes[1]);
    const b: u32 = @as(u32, codes[2] % 16) + 16 * (@as(u32, codes[2] / 16) * 176 + codes[3]);
    return 3 | (a << 2) | (b << 17);
}
fn extent(height: usize, stride: usize, row: usize) !usize {
    if (height == 0 or stride < row) return error.InvalidGeometry;
    return std.math.add(usize, std.math.mul(usize, height - 1, stride) catch return error.InvalidGeometry, row) catch error.InvalidGeometry;
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
    format: Format,
    pub fn init(data: []const u8, width: usize, height: usize, stride: usize, format: Format) !View {
        const needed = try extent(height, stride, try format.rowBytes(width));
        if (data.len < needed) return error.BufferTooSmall;
        return .{ .data = data[0..needed], .width = width, .height = height, .stride = stride, .format = format };
    }
    fn value(self: View, x: usize, y: usize) u16 {
        const src = self.data[y * self.stride ..];
        const f = self.format;
        if (f.pisp_comp1) {
            const word = std.mem.readInt(u32, src[(x / 8) * 8 + (x % 2) * 4 ..][0..4], .little);
            return decodeWord(word)[(x % 8) / 2];
        }
        if (f.bits == 8) return src[x];
        if (!f.csi2_packed) return std.mem.readInt(u16, src[x * 2 ..][0..2], .little);
        const group: usize = if (f.bits == 12) 2 else 4;
        const size: usize = if (f.bits == 10) 5 else if (f.bits == 12) 3 else 7;
        const p = x % group;
        const base = x / group * size;
        const low_bits: usize = f.bits - 8;
        const shift = p * low_bits;
        const byte = base + group + shift / 8;
        var low: u16 = src[byte];
        if (shift % 8 + low_bits > 8) low |= @as(u16, src[byte + 1]) << 8;
        return (@as(u16, src[base + p]) << @intCast(low_bits)) | ((low >> @intCast(shift % 8)) & @as(u16, @intCast((@as(u32, 1) << @intCast(low_bits)) - 1)));
    }
    pub fn sample(self: View, x: usize, y: usize) !u16 {
        const checked = try View.init(self.data, self.width, self.height, self.stride, self.format);
        if (x >= self.width or y >= self.height) return error.InvalidGeometry;
        const v = checked.value(x, y);
        if (v > self.format.white()) return error.InvalidSample;
        return v;
    }
    fn checkSamples(self: View, start: usize, end: usize) !void {
        if (!self.format.csi2_packed and !self.format.pisp_comp1 and self.format.bits > 8 and self.format.bits < 16) for (start..end) |y| for (0..self.width) |x| {
            if (self.value(x, y) > self.format.white()) return error.InvalidSample;
        };
    }
    fn writeRow(self: View, y: usize, out: []u8) void {
        if (self.format.pisp_comp1) {
            const src = self.data[y * self.stride ..];
            for (0..(self.width + 7) / 8) |group| {
                const even = decodeWord(std.mem.readInt(u32, src[group * 8 ..][0..4], .little));
                const odd = decodeWord(std.mem.readInt(u32, src[group * 8 + 4 ..][0..4], .little));
                for (0..@min(8, self.width - group * 8)) |k| {
                    const v = if (k % 2 == 0) even[k / 2] else odd[k / 2];
                    std.mem.writeInt(u16, out[(group * 8 + k) * 2 ..][0..2], v, .little);
                }
            }
        } else if (!self.format.csi2_packed and self.format.bits == 16) {
            @memcpy(out[0 .. self.width * 2], self.data[y * self.stride ..][0 .. self.width * 2]);
        } else for (0..self.width) |x| std.mem.writeInt(u16, out[x * 2 ..][0..2], self.value(x, y), .little);
    }
    /// Complete preflight before any output byte changes. No scaling/demosaicing.
    pub fn copy16(self: View, out: []u8, stride: usize) !void {
        const checked = try View.init(self.data, self.width, self.height, self.stride, self.format);
        const row_bytes = std.math.mul(usize, self.width, 2) catch return error.InvalidGeometry;
        const needed = try extent(self.height, stride, row_bytes);
        if (out.len < needed) return error.BufferTooSmall;
        if (!self.format.pisp_comp1 and !self.format.csi2_packed and self.format.bits == 16 and self.data.ptr == out.ptr and self.stride == stride) return;
        try disjoint(checked.data, out[0..needed]);
        try checked.checkSamples(0, self.height);
        for (0..self.height) |y| checked.writeRow(y, out[y * stride ..]);
    }
    /// One active row as little-endian u16. Invalid samples cannot write a prefix.
    pub fn row(self: View, y: usize, out: []u8) !void {
        const checked = try View.init(self.data, self.width, self.height, self.stride, self.format);
        const row_bytes = std.math.mul(usize, self.width, 2) catch return error.InvalidGeometry;
        if (y >= self.height or out.len < row_bytes) return error.BufferTooSmall;
        try disjoint(checked.data, out[0..row_bytes]);
        try checked.checkSamples(y, y + 1);
        checked.writeRow(y, out);
    }
};
/// Exact CSI-2/unpacked fixture packing. Validates all samples before mutation.
pub fn packRow(format: Format, samples: []const u16, out: []u8) !void {
    const n = try format.rowBytes(samples.len);
    if (format.pisp_comp1) return error.UnsupportedFormat;
    if (out.len < n) return error.BufferTooSmall;
    try disjoint(std.mem.sliceAsBytes(samples), out[0..n]);
    for (samples) |v| if (v > format.white()) return error.InvalidSample;
    @memset(out[0..n], 0);
    for (samples, 0..) |v, x| {
        if (format.bits == 8) {
            out[x] = @intCast(v);
        } else if (!format.csi2_packed) {
            std.mem.writeInt(u16, out[x * 2 ..][0..2], v, .little);
        } else {
            const group: usize = if (format.bits == 12) 2 else 4;
            const size: usize = if (format.bits == 10) 5 else if (format.bits == 12) 3 else 7;
            const p = x % group;
            const base = x / group * size;
            const low_bits: usize = format.bits - 8;
            const shift = p * low_bits;
            out[base + p] = @intCast(v >> @intCast(low_bits));
            const low: u16 = (v & @as(u16, @intCast((@as(u32, 1) << @intCast(low_bits)) - 1))) << @intCast(shift % 8);
            out[base + group + shift / 8] |= @truncate(low);
            if (shift % 8 + low_bits > 8) out[base + group + shift / 8 + 1] |= @intCast(low >> 8);
        }
    }
}
test "sensor formats include all pinned Bayer mono CSI and COMP1 names without aliases" {
    const t = std.testing;
    for ([_]Pattern{ .rggb, .bggr, .grbg, .gbrg, .mono }) |p| {
        for ([_]u5{ 8, 10, 12, 14, 16 }) |bits| for ([_]bool{ false, true }) |is_packed| {
            const f = Format{ .bits = bits, .csi2_packed = is_packed, .pattern = p };
            if (is_packed and (bits == 16 or (bits == 8 and p != .mono))) continue;
            var buf: [32]u8 = undefined;
            try t.expectEqual(f, try Format.parse(try f.writeName(&buf)));
        };
        const f = Format{ .bits = 16, .pattern = p, .pisp_comp1 = true };
        var buf: [32]u8 = undefined;
        try t.expectEqual(f, try Format.parse(try f.writeName(&buf)));
    }
    for ([_][]const u8{ "R", "R00", "R+8", "R08", "R16_CSI2P", "SRGGB8_CSI2P", "SRGGB16_PISP_COMP1", "FOOO_PISP_COMP1", "RGGB_PISP_COMP2", "SRGGB12_CSI2Pjunk", "S", "", "R_CSI2P" }) |n| try t.expectError(error.UnsupportedFormat, Format.parse(n));
    try t.expectEqual([4]u8{ 2, 1, 1, 0 }, (try Format.parse("SBGGR12")).pattern.cfa());
}
test "sensor unpacked and CSI rows retain every depth including partial groups without final padding" {
    const t = std.testing;
    for ([_]u5{ 8, 10, 12, 14, 16 }) |bits| for ([_]bool{ false, true }) |is_packed| {
        if (is_packed and bits == 16) continue;
        const f = Format{ .bits = bits, .csi2_packed = is_packed, .pattern = .mono };
        for (1..12) |width| {
            var data: [256]u8 = @splat(79);
            var want: [12]u16 = undefined;
            var out: [128]u8 = @splat(73);
            const row_bytes = try f.rowBytes(width);
            const stride = row_bytes + 3;
            for (0..2) |y| {
                for (0..width) |x| want[x] = @intCast((x * 431 + y * 17 + 1) & f.white());
                try packRow(f, want[0..width], data[1 + y * stride ..]);
            }
            const view = try View.init(data[1 .. 1 + stride + row_bytes], width, 2, stride, f);
            try view.copy16(&out, width * 2 + 3);
            for (0..2) |y| for (0..width) |x| try t.expectEqual(@as(u16, @intCast((x * 431 + y * 17 + 1) & f.white())), std.mem.readInt(u16, out[y * (width * 2 + 3) + x * 2 ..][0..2], .little));
            try t.expectEqual(@as(u8, 73), out[width * 2]);
            try t.expectEqual(@as(u8, 73), out[(width * 2 + 3) + width * 2]);
        }
    };
}
test "COMP1 words match scalar upstream vectors and interleave channels across partial padded rows" {
    const t = std.testing;
    const vectors = @import("sensor_raw_vectors.zig").vectors;
    for (vectors) |v| try t.expectEqual(v.expected, decodeWord(v.word));
    for (1..18) |width| {
        const f = try Format.parse("MONO_PISP_COMP1");
        const n = try f.rowBytes(width);
        const stride = n + 3;
        var data: [80]u8 = @splat(79);
        var out: [96]u8 = @splat(73);
        for (0..2) |y| for (0..n / 4) |i| std.mem.writeInt(u32, data[1 + y * stride + i * 4 ..][0..4], vectors[(y * n / 4 + i) % vectors.len].word, .little);
        const v = try View.init(data[1 .. 1 + stride + n], width, 2, stride, f);
        try v.copy16(&out, width * 2 + 1);
        for (0..2) |y| for (0..width) |x| {
            const word = y * n / 4 + x / 8 * 2 + x % 2;
            try t.expectEqual(vectors[word % vectors.len].expected[(x % 8) / 2], std.mem.readInt(u16, out[y * (width * 2 + 1) + x * 2 ..][0..2], .little));
        };
        try t.expectEqual(@as(u8, 73), out[width * 2]);
    }
}
test "COMP1 companding fixture codes cover every legal pair including saturation" {
    const t = std.testing;
    for (0..176) |a| for (0..176) |b| {
        const word = try compandedWord(.{ @intCast(a), @intCast(b), @intCast(b), @intCast(a) });
        const values = decodeWord(word);
        const ac: i32 = @intCast(a);
        const bc: i32 = @intCast(b);
        const av: u16 = @intCast(@min(65535, @max(ac * 256, (ac - 47) * 512) + 2048));
        const bv: u16 = @intCast(@min(65535, @max(bc * 256, (bc - 47) * 512) + 2048));
        try t.expectEqual([4]u16{ av, bv, bv, av }, values);
    };
    try t.expectError(error.InvalidSample, compandedWord(.{ 176, 0, 0, 0 }));
}
test "raw view overflow truncation overlap and late invalid samples never change output" {
    const t = std.testing;
    const f = try Format.parse("R10");
    var data: [64]u8 = @splat(0);
    var out: [32]u8 = @splat(73);
    try t.expectError(error.InvalidGeometry, View.init(&data, 0, 1, 2, f));
    try t.expectError(error.InvalidGeometry, View.init(&data, std.math.maxInt(usize), 1, 2, f));
    try t.expectError(error.InvalidGeometry, View.init(&data, 2, 3, std.math.maxInt(usize), f));
    try t.expectError(error.BufferTooSmall, View.init(data[0..10], 2, 2, 7, f));
    const v = try View.init(data[1..12], 2, 2, 7, f);
    try t.expectError(error.BufferTooSmall, v.copy16(out[0..7], 4));
    try t.expectError(error.Overlap, v.copy16(data[0..], 4));
    std.mem.writeInt(u16, data[10..12], 1024, .little);
    try t.expectError(error.InvalidSample, v.copy16(&out, 4));
    try t.expectError(error.InvalidSample, v.row(1, &out));
    for (out) |b| try t.expectEqual(@as(u8, 73), b);
    try t.expectError(error.BufferTooSmall, v.row(2, &out));
    std.mem.writeInt(u16, data[10..12], 1, .little);
    const sixteen = try View.init(data[1..12], 2, 2, 7, try Format.parse("R16"));
    try sixteen.copy16(data[1..12], 7);
    try t.expectError(error.BufferTooSmall, View.init(data[0..7], 1, 1, 8, try Format.parse("MONO_PISP_COMP1")));
}
