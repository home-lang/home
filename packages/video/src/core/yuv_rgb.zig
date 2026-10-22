//! Allocation-free RGB24/4:2:0 conversion over checked borrowed planes.
//! Matrix/range describe encoded R'G'B'/Y'CbCr values; no transfer/primaries transform.
//! Callers own synchronization. Validation completes before any destination write.
const std = @import("std");
pub const Matrix = enum { bt601, bt709, bt2020 };
pub const Range = enum { full, limited };
const scale: i64 = 65536;
fn fixed(value: f64) i64 {
    return @intFromFloat(@round(value * scale));
}
fn byte(value: i64) u8 {
    return @intCast(std.math.clamp(value, 0, 255));
}
pub const Conversion = struct {
    y_offset: i64,
    cy: i64,
    rv: i64,
    gu: i64,
    gv: i64,
    bu: i64,
    forward: [3][3]i64,
    pub fn init(matrix: Matrix, range: Range) Conversion {
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
        const kg = 1 - kr - kb;
        const yr: f64 = if (range == .limited) 219 else 255;
        const uv: f64 = if (range == .limited) 224 else 255;
        return .{
            .y_offset = if (range == .limited) 16 else 0,
            .cy = fixed(255 / yr),
            .rv = fixed(2 * (1 - kr) * 255 / uv),
            .gu = fixed(-2 * kb * (1 - kb) / kg * 255 / uv),
            .gv = fixed(-2 * kr * (1 - kr) / kg * 255 / uv),
            .bu = fixed(2 * (1 - kb) * 255 / uv),
            .forward = .{
                .{ fixed(kr * yr / 255), fixed(kg * yr / 255), fixed(kb * yr / 255) },
                .{ fixed(-kr / (2 * (1 - kb)) * uv / 255), fixed(-kg / (2 * (1 - kb)) * uv / 255), fixed(uv / 510) },
                .{ fixed(uv / 510), fixed(-kg / (2 * (1 - kr)) * uv / 255), fixed(-kb / (2 * (1 - kr)) * uv / 255) },
            },
        };
    }
    pub fn toRgb(self: Conversion, y: u8, u: u8, v: u8) [3]u8 {
        const l = self.cy * (@as(i64, y) - self.y_offset);
        const cb = @as(i64, u) - 128;
        const cr = @as(i64, v) - 128;
        return .{ byte((l + self.rv * cr + scale / 2) >> 16), byte((l + self.gu * cb + self.gv * cr + scale / 2) >> 16), byte((l + self.bu * cb + scale / 2) >> 16) };
    }
    fn component(self: Conversion, index: usize, rgb: [3]i64, count: i64) u8 {
        const m = self.forward[index];
        const offset: i64 = if (index == 0) self.y_offset else 128;
        return byte(@divFloor(m[0] * rgb[0] + m[1] * rgb[1] + m[2] * rgb[2] + @divTrunc(scale * count, 2), scale * count) + offset);
    }
    pub fn toYuv(self: Conversion, r: u8, g: u8, b: u8) [3]u8 {
        const rgb: [3]i64 = .{ r, g, b };
        return .{ self.component(0, rgb, 1), self.component(1, rgb, 1), self.component(2, rgb, 1) };
    }
};
fn validatePlane(length: usize, stride: u32, row: u64, height: u32) !void {
    if (height == 0 or row == 0 or stride < row) return error.InvalidGeometry;
    const need = @as(u64, stride) * (height - 1) + row;
    if (need > length) return error.BufferTooSmall;
}
pub const I420 = struct {
    width: u32,
    height: u32,
    planes: [3][]const u8,
    strides: [3]u32,
    /// Logical Y,U,V views. Step 2 permits borrowed interleaved chroma aliases.
    chroma_step: u32 = 1,
    pub fn semiPlanar(width: u32, height: u32, y: []const u8, y_stride: u32, uv: []const u8, uv_stride: u32, vu: bool) !I420 {
        if (width == 0 or height == 0 or (width | height) & 1 != 0) return error.InvalidGeometry;
        try validatePlane(uv.len, uv_stride, width, height / 2);
        const view = I420{ .width = width, .height = height, .planes = .{ y, uv[@intFromBool(vu)..], uv[@intFromBool(!vu)..] }, .strides = .{ y_stride, uv_stride, uv_stride }, .chroma_step = 2 };
        try view.validate();
        return view;
    }
    pub fn validate(self: I420) !void {
        if (self.width == 0 or self.height == 0 or (self.width | self.height) & 1 != 0 or (self.chroma_step != 1 and self.chroma_step != 2)) return error.InvalidGeometry;
        try validatePlane(self.planes[0].len, self.strides[0], self.width, self.height);
        for (1..3) |i| try validatePlane(self.planes[i].len, self.strides[i], (@as(u64, self.width / 2) - 1) * self.chroma_step + 1, self.height / 2);
    }
    /// Canonical tight Y,U,V output. Validates source, output and overlap before
    /// writing. Unused suffix is untouched; caller retains source ownership.
    pub fn copyI420(self: I420, output: []u8) !void {
        try self.validate();
        const pixels = std.math.mul(usize, self.width, self.height) catch return error.InvalidGeometry;
        const size = std.math.add(usize, pixels, pixels / 2) catch return error.InvalidGeometry;
        if (output.len < size) return error.BufferTooSmall;
        for (self.planes) |plane| try disjoint(plane, output[0..size]);
        for (0..3) |i| {
            const width = if (i == 0) self.width else self.width / 2;
            const height = if (i == 0) self.height else self.height / 2;
            const step = if (i == 0) 1 else self.chroma_step;
            const at: usize = if (i == 0) 0 else pixels + (i - 1) * pixels / 4;
            for (0..height) |y| {
                const row = output[at + y * width ..][0..width];
                if (step == 1) @memcpy(row, self.planes[i][y * self.strides[i] ..][0..width]) else for (0..width) |x| row[x] = self.planes[i][y * self.strides[i] + x * step];
            }
        }
    }
};
pub fn disjoint(source: []const u8, destination: []const u8) !void {
    if (source.len == 0 or destination.len == 0) return;
    const a = @intFromPtr(source.ptr);
    const b = @intFromPtr(destination.ptr);
    if ((a <= b and b - a < source.len) or (b < a and a - b < destination.len)) return error.Overlap;
}
pub fn decode420(src: I420, conversion: Conversion, out: []u8, stride: u32) !void {
    try src.validate();
    try validatePlane(out.len, stride, @as(u64, src.width) * 3, src.height);
    for (src.planes) |plane| try disjoint(plane, out);
    // One 4:2:0 chroma pair belongs to four luma samples. Compute its fixed-point
    // channel contributions once, preserving the existing rounding/clipping.
    for (0..src.height / 2) |cy| for (0..src.width / 2) |cx| {
        const cb = @as(i64, src.planes[1][cy * src.strides[1] + cx * src.chroma_step]) - 128;
        const cr = @as(i64, src.planes[2][cy * src.strides[2] + cx * src.chroma_step]) - 128;
        const chroma = [3]i64{ conversion.rv * cr, conversion.gu * cb + conversion.gv * cr, conversion.bu * cb };
        inline for (0..2) |dy| inline for (0..2) |dx| {
            const y = cy * 2 + dy;
            const x = cx * 2 + dx;
            const l = conversion.cy * (@as(i64, src.planes[0][y * src.strides[0] + x]) - conversion.y_offset);
            inline for (0..3) |channel| out[y * stride + x * 3 + channel] = byte((l + chroma[channel] + scale / 2) >> 16);
        };
    };
}
pub fn encode420(rgb: []const u8, width: u32, height: u32, stride: u32, planes: [3][]u8, strides: [3]u32, conversion: Conversion) !void {
    return encodeStrided420(rgb, width, height, stride, planes, strides, 1, conversion);
}
pub fn encodeSemi420(rgb: []const u8, width: u32, height: u32, stride: u32, planes: [2][]u8, strides: [2]u32, vu: bool, conversion: Conversion) !void {
    _ = try I420.semiPlanar(width, height, planes[0], strides[0], planes[1], strides[1], vu);
    try disjoint(planes[0], planes[1]);
    return encodeStrided420(rgb, width, height, stride, .{ planes[0], planes[1][@intFromBool(vu)..], planes[1][@intFromBool(!vu)..] }, .{ strides[0], strides[1], strides[1] }, 2, conversion);
}
fn encodeStrided420(rgb: []const u8, width: u32, height: u32, stride: u32, planes: [3][]u8, strides: [3]u32, step: u32, conversion: Conversion) !void {
    const view = I420{ .width = width, .height = height, .planes = .{ planes[0], planes[1], planes[2] }, .strides = strides, .chroma_step = step };
    try view.validate();
    try validatePlane(rgb.len, stride, @as(u64, width) * 3, height);
    for (planes, 0..) |plane, i| {
        try disjoint(rgb, plane);
        if (step == 1) for (planes[0..i]) |prior| try disjoint(prior, plane);
    }
    for (0..height / 2) |cy| for (0..width / 2) |cx| {
        var sum: [3]i64 = @splat(0);
        for (0..2) |dy| for (0..2) |dx| {
            const x = cx * 2 + dx;
            const y = cy * 2 + dy;
            const p = rgb[y * stride + x * 3 ..][0..3];
            planes[0][y * strides[0] + x] = conversion.component(0, .{ p[0], p[1], p[2] }, 1);
            for (0..3) |i| sum[i] += p[i];
        };
        planes[1][cy * strides[1] + cx * step] = conversion.component(1, sum, 4);
        planes[2][cy * strides[2] + cx * step] = conversion.component(2, sum, 4);
    };
}
test "independent full and studio range primaries and neutral endpoints" {
    const t = std.testing;
    const full = Conversion.init(.bt601, .full);
    const limited = Conversion.init(.bt601, .limited);
    try t.expectEqualSlices(u8, &.{ 254, 0, 0 }, &full.toRgb(76, 85, 255));
    try t.expectEqualSlices(u8, &.{ 254, 0, 0 }, &limited.toRgb(81, 90, 240));
    try t.expectEqualSlices(u8, &.{ 0, 255, 1 }, &limited.toRgb(145, 54, 34));
    for ([_]Matrix{ .bt601, .bt709, .bt2020 }) |matrix| for ([_]Range{ .full, .limited }) |range| {
        const c = Conversion.init(matrix, range);
        try t.expectEqualSlices(u8, &.{ 0, 0, 0 }, &c.toRgb(if (range == .full) 0 else 16, 128, 128));
        try t.expectEqualSlices(u8, &.{ 255, 255, 255 }, &c.toRgb(if (range == .full) 255 else 235, 128, 128));
        try t.expectEqualSlices(u8, &.{ if (range == .full) 0 else 16, 128, 128 }, &c.toYuv(0, 0, 0));
        const red = c.toRgb(switch (matrix) {
            .bt601 => 81,
            .bt709 => 63,
            .bt2020 => 74,
        }, switch (matrix) {
            .bt601 => 90,
            .bt709 => 102,
            .bt2020 => 97,
        }, 240);
        if (range == .limited) {
            const expected: [3]u8 = switch (matrix) {
                .bt601 => .{ 254, 0, 0 },
                .bt709 => .{ 255, 1, 0 },
                .bt2020 => .{ 255, 0, 1 },
            };
            try t.expectEqualSlices(u8, &expected, &red);
        }
    };
}
test "strided I420 averages all four samples, validates before writing, and preserves padding" {
    const t = std.testing;
    const rgb = [_]u8{ 255, 0, 0, 0, 255, 0, 99, 99, 0, 0, 255, 255, 255, 255 };
    var y: [6]u8 = @splat(77);
    var u: [2]u8 = @splat(77);
    var v: [2]u8 = @splat(77);
    const c = Conversion.init(.bt601, .limited);
    try encode420(&rgb, 2, 2, 8, .{ &y, &u, &v }, .{ 4, 2, 2 }, c);
    try t.expectEqualSlices(u8, &.{ 81, 145, 77, 77, 41, 235 }, &y);
    try t.expectEqualSlices(u8, &.{ 128, 77 }, &u);
    try t.expectEqualSlices(u8, &.{ 128, 77 }, &v);
    const src = I420{ .width = 2, .height = 2, .planes = .{ &y, &u, &v }, .strides = .{ 4, 2, 2 } };
    var decoded: [14]u8 = @splat(77);
    try decode420(src, c, &decoded, 8);
    try t.expectEqualSlices(u8, &.{ 76, 76, 76, 150, 150, 150, 77, 77, 29, 29, 29, 255, 255, 255 }, &decoded);
    const before = decoded;
    var bad = src;
    bad.planes[2] = &.{};
    try t.expectError(error.BufferTooSmall, decode420(bad, c, &decoded, 8));
    try t.expectEqualSlices(u8, &before, &decoded);
    const old = y;
    try t.expectError(error.BufferTooSmall, encode420(rgb[0..13], 2, 2, 8, .{ &y, &u, &v }, .{ 4, 2, 2 }, c));
    try t.expectEqualSlices(u8, &old, &y);
    try t.expectError(error.InvalidGeometry, decode420(.{ .width = 1, .height = 2, .planes = src.planes, .strides = src.strides }, c, &decoded, 8));
}

test "fixed point decoding agrees with independent floating reference within one code value" {
    for ([_]Matrix{ .bt601, .bt709, .bt2020 }) |matrix| for ([_]Range{ .full, .limited }) |range| {
        const c = Conversion.init(matrix, range);
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
        for ([_]u8{ 0, 16, 63, 128, 235, 255 }) |y| for ([_]u8{ 0, 16, 63, 128, 240, 255 }) |u| for ([_]u8{ 0, 16, 63, 128, 240, 255 }) |v| {
            const l = (@as(f64, @floatFromInt(y)) - @as(f64, if (range == .limited) 16 else 0)) / @as(f64, if (range == .limited) 219 else 255);
            const cb = (@as(f64, @floatFromInt(u)) - 128) / @as(f64, if (range == .limited) 224 else 255);
            const cr = (@as(f64, @floatFromInt(v)) - 128) / @as(f64, if (range == .limited) 224 else 255);
            const reference = [3]f64{ l + 2 * (1 - kr) * cr, l - 2 * kb * (1 - kb) / (1 - kr - kb) * cb - 2 * kr * (1 - kr) / (1 - kr - kb) * cr, l + 2 * (1 - kb) * cb };
            const actual = c.toRgb(y, u, v);
            for (reference, actual) |ref, value| {
                const expected: i32 = @intFromFloat(@round(std.math.clamp(ref * 255, 0, 255)));
                try std.testing.expect(@abs(@as(i32, value) - expected) <= 1);
            }
        };
    };
}

test "block decoding matches legacy per-pixel conversion exactly across all matrices and ranges" {
    var ys: [10]u8 = @splat(77);
    var us: [3]u8 = @splat(77);
    var vs: [3]u8 = @splat(77);
    const src = I420{ .width = 2, .height = 2, .planes = .{ &ys, &us, &vs }, .strides = .{ 6, 3, 3 } };
    var out: [18]u8 = @splat(99);
    for ([_]Matrix{ .bt601, .bt709, .bt2020 }) |matrix| for ([_]Range{ .full, .limited }) |range| {
        const c = Conversion.init(matrix, range);
        for (0..256) |sample| for ([_]u8{ 0, 16, 85, 128, 170, 240, 255 }) |u| for ([_]u8{ 0, 16, 85, 128, 170, 240, 255 }) |v| {
            ys[0] = @intCast(sample);
            ys[1] = @truncate(sample + 17);
            ys[6] = @truncate(sample + 101);
            ys[7] = @truncate(sample + 239);
            us[0] = u;
            vs[0] = v;
            try decode420(src, c, &out, 10);
            try std.testing.expectEqualSlices(u8, &c.toRgb(ys[0], u, v), out[0..3]);
            try std.testing.expectEqualSlices(u8, &c.toRgb(ys[1], u, v), out[3..6]);
            try std.testing.expectEqualSlices(u8, &c.toRgb(ys[6], u, v), out[10..13]);
            try std.testing.expectEqualSlices(u8, &c.toRgb(ys[7], u, v), out[13..16]);
            for (out[6..10]) |pad| try std.testing.expectEqual(@as(u8, 99), pad);
            for (out[16..]) |pad| try std.testing.expectEqual(@as(u8, 99), pad);
        };
    };
}

test "NV12 and NV21 encode average chroma and decode and pack like planar across matrices ranges and padding" {
    const t = std.testing;
    var rgb: [64]u8 = @splat(47);
    for (0..4) |y| for (0..4) |x| {
        rgb[y * 16 + x * 3 ..][0..3].* = .{ @intCast(x * 61), @intCast(y * 53), @intCast((x + y) * 31) };
    };
    for ([_]Matrix{ .bt601, .bt709, .bt2020 }) |matrix| for ([_]Range{ .full, .limited }) |range| for ([_]bool{ false, true }) |vu| {
        const conversion = Conversion.init(matrix, range);
        var y: [24]u8 = @splat(79);
        var u: [8]u8 = @splat(79);
        var v: [8]u8 = @splat(79);
        try encode420(rgb[0..60], 4, 4, 16, .{ &y, &u, &v }, .{ 6, 4, 4 }, conversion);
        const planar = I420{ .width = 4, .height = 4, .planes = .{ &y, &u, &v }, .strides = .{ 6, 4, 4 } };
        var sy: [24]u8 = @splat(79);
        var uv: [16]u8 = @splat(79);
        try encodeSemi420(rgb[0..60], 4, 4, 16, .{ sy[0..22], uv[0..12] }, .{ 6, 8 }, vu, conversion);
        const semi = try I420.semiPlanar(4, 4, sy[0..22], 6, uv[0..12], 8, vu);
        var a: [24]u8 = undefined;
        var b: [26]u8 = @splat(83);
        try planar.copyI420(&a);
        try semi.copyI420(&b);
        try t.expectEqualSlices(u8, &a, b[0..24]);
        try t.expectEqualSlices(u8, &.{ 83, 83 }, b[24..]);
        var ra: [64]u8 = @splat(91);
        var rb: [64]u8 = @splat(91);
        try decode420(planar, conversion, ra[0..60], 16);
        try decode420(semi, conversion, rb[0..60], 16);
        try t.expectEqualSlices(u8, &ra, &rb);
        try t.expectEqualSlices(u8, &y, &sy);
        for ([_]usize{ 4, 5, 6, 7, 12, 13, 14, 15 }) |i| try t.expectEqual(@as(u8, 79), uv[i]);
    };
}
test "semi-planar invalid tails step geometry overlap and output preserve every byte" {
    const t = std.testing;
    var y: [32]u8 = @splat(81);
    var uv: [16]u8 = @splat(90);
    var out: [64]u8 = @splat(73);
    try t.expectError(error.InvalidGeometry, I420.semiPlanar(3, 4, &y, 8, &uv, 8, false));
    try t.expectError(error.InvalidGeometry, I420.semiPlanar(4, 3, &y, 8, &uv, 8, false));
    try t.expectError(error.BufferTooSmall, I420.semiPlanar(4, 4, &y, 8, uv[0..11], 8, false));
    const view = try I420.semiPlanar(4, 4, &y, 8, &uv, 8, false);
    var bad = view;
    bad.chroma_step = 3;
    try t.expectError(error.InvalidGeometry, bad.copyI420(&out));
    bad = view;
    bad.planes[2] = uv[1..10];
    try t.expectError(error.BufferTooSmall, bad.copyI420(&out));
    try t.expectError(error.BufferTooSmall, view.copyI420(out[0..23]));
    try t.expectError(error.BufferTooSmall, decode420(view, Conversion.init(.bt601, .limited), out[0..47], 12));
    try t.expectError(error.Overlap, view.copyI420(&y));
    const rgb: [48]u8 = @splat(10);
    try t.expectError(error.BufferTooSmall, encodeSemi420(rgb[0..47], 4, 4, 12, .{ &y, &uv }, .{ 8, 8 }, false, Conversion.init(.bt601, .limited)));
    for (out) |value| try t.expectEqual(@as(u8, 73), value);
    for (y) |value| try t.expectEqual(@as(u8, 81), value);
    for (uv) |value| try t.expectEqual(@as(u8, 90), value);
}
