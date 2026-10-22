//! Checked I420 matrix/range remapping without an intermediate RGB image.
//! Primaries and transfer functions must already match; this transforms only
//! encoded Y'CbCr. Destination may not overlap source. Caller owns synchronization.
const std = @import("std");
const color = @import("yuv_rgb.zig");
const scale: i64 = 65536;
fn clamp(value: i64) u8 {
    return @intCast(std.math.clamp(value, 0, 255));
}
pub const Remap = struct {
    coefficients: [3][3]i64,
    source_offset: i64,
    target_offset: i64,
    same_matrix: bool,
    pub fn init(source: color.Matrix, source_range: color.Range, target: color.Matrix, target_range: color.Range) Remap {
        const src = color.Conversion.init(source, source_range);
        const dst = color.Conversion.init(target, target_range);
        const inverse = [3][3]i64{ .{ src.cy, 0, src.rv }, .{ src.cy, src.gu, src.gv }, .{ src.cy, src.bu, 0 } };
        var result = Remap{ .coefficients = undefined, .source_offset = src.y_offset, .target_offset = dst.y_offset, .same_matrix = source == target };
        for (0..3) |i| for (0..3) |j| {
            var sum: i64 = 0;
            for (0..3) |k| sum += dst.forward[i][k] * inverse[k][j];
            result.coefficients[i][j] = @divFloor(sum + scale / 2, scale);
        };
        // Chroma is independent of luma analytically. Avoid coefficient rounding
        // introducing a false dependency on a particular pixel in a 2x2 block.
        result.coefficients[1][0] = 0;
        result.coefficients[2][0] = 0;
        if (source == target) {
            const y_source: f64 = if (source_range == .full) 255 else 219;
            const y_target: f64 = if (target_range == .full) 255 else 219;
            const uv_source: f64 = if (source_range == .full) 255 else 224;
            const uv_target: f64 = if (target_range == .full) 255 else 224;
            const y_scale: i64 = @intFromFloat(@round(scale * y_target / y_source));
            const uv_scale: i64 = @intFromFloat(@round(scale * uv_target / uv_source));
            result.coefficients = .{ .{ y_scale, 0, 0 }, .{ 0, uv_scale, 0 }, .{ 0, 0, uv_scale } };
        }
        return result;
    }
    fn sample(self: Remap, index: usize, y: u8, u: u8, v: u8) u8 {
        const m = self.coefficients[index];
        const value = m[0] * (@as(i64, y) - self.source_offset) + m[1] * (@as(i64, u) - 128) + m[2] * (@as(i64, v) - 128);
        return clamp(((value + scale / 2) >> 16) + if (index == 0) self.target_offset else @as(i64, 128));
    }
    /// 4:2:2 luma uses each row's chroma. Output chroma averages the two source
    /// rows (round half up) before matrix/range remapping into I420.
    pub fn apply422(self: Remap, source: @import("packed_yuv422.zig").View, planes: [3][]u8, strides: [3]u32) !void {
        try source.validate();
        try (color.I420{ .width = source.width, .height = source.height, .planes = .{ planes[0], planes[1], planes[2] }, .strides = strides }).validate();
        for (planes, 0..) |destination, i| {
            try color.disjoint(source.data, destination);
            for (planes[0..i]) |prior| try color.disjoint(prior, destination);
        }
        for (0..source.height / 2) |cy| for (0..source.width / 2) |cx| {
            const top = source.pair(@intCast(cx), @intCast(cy * 2));
            const bottom = source.pair(@intCast(cx), @intCast(cy * 2 + 1));
            for ([2][4]u8{ top, bottom }, 0..) |p, dy| {
                inline for (0..2) |dx| planes[0][(cy * 2 + dy) * strides[0] + cx * 2 + dx] = self.sample(0, p[dx * 2], p[1], p[3]);
            }
            const u: u8 = @intCast((@as(u16, top[1]) + bottom[1] + 1) / 2);
            const v: u8 = @intCast((@as(u16, top[3]) + bottom[3] + 1) / 2);
            planes[1][cy * strides[1] + cx] = self.sample(1, 0, u, v);
            planes[2][cy * strides[2] + cx] = self.sample(2, 0, u, v);
        };
    }
    pub fn apply(self: Remap, source: color.I420, planes: [3][]u8, strides: [3]u32) !void {
        try source.validate();
        try (color.I420{ .width = source.width, .height = source.height, .planes = .{ planes[0], planes[1], planes[2] }, .strides = strides }).validate();
        for (planes, 0..) |destination, i| {
            for (source.planes) |src| try color.disjoint(src, destination);
            for (planes[0..i]) |prior| try color.disjoint(prior, destination);
        }
        if (self.same_matrix) {
            for (0..3) |i| {
                const width = if (i == 0) source.width else source.width / 2;
                const height = if (i == 0) source.height else source.height / 2;
                const coefficient = self.coefficients[i][i];
                const offset = if (i == 0) self.source_offset else @as(i64, 128);
                const target = if (i == 0) self.target_offset else @as(i64, 128);
                for (0..height) |y| for (0..width) |x| {
                    planes[i][y * strides[i] + x] = clamp(((coefficient * (@as(i64, source.planes[i][y * source.strides[i] + x * @as(u32, if (i == 0) 1 else source.chroma_step)]) - offset) + scale / 2) >> 16) + target);
                };
            }
            return;
        }
        for (0..source.height / 2) |cy| for (0..source.width / 2) |cx| {
            const u = source.planes[1][cy * source.strides[1] + cx * source.chroma_step];
            const v = source.planes[2][cy * source.strides[2] + cx * source.chroma_step];
            for (0..2) |dy| for (0..2) |dx| {
                const x = cx * 2 + dx;
                const y = cy * 2 + dy;
                planes[0][y * strides[0] + x] = self.sample(0, source.planes[0][y * source.strides[0] + x], u, v);
            };
            planes[1][cy * strides[1] + cx] = self.sample(1, 0, u, v);
            planes[2][cy * strides[2] + cx] = self.sample(2, 0, u, v);
        };
    }
};
test "full sYCC to studio preserves black, white and chroma without RGB clipping" {
    const src = color.I420{ .width = 2, .height = 2, .planes = .{ &.{ 0, 255, 76, 128 }, &.{85}, &.{255} }, .strides = .{ 2, 1, 1 } };
    var y: [6]u8 = @splat(77);
    var u: [2]u8 = @splat(77);
    var v: [2]u8 = @splat(77);
    const map = Remap.init(.bt601, .full, .bt601, .limited);
    try map.apply(src, .{ &y, &u, &v }, .{ 4, 2, 2 });
    try std.testing.expectEqualSlices(u8, &.{ 16, 235, 77, 77, 81, 126 }, &y);
    try std.testing.expectEqualSlices(u8, &.{ 90, 77 }, &u);
    try std.testing.expectEqualSlices(u8, &.{ 240, 77 }, &v);
    var bad = src;
    bad.planes[2] = &.{};
    const before = y;
    try std.testing.expectError(error.BufferTooSmall, map.apply(bad, .{ &y, &u, &v }, .{ 4, 2, 2 }));
    try std.testing.expectEqualSlices(u8, &before, &y);
}
test "identity preserves every code including studio footroom and headroom" {
    for ([_]color.Matrix{ .bt601, .bt709, .bt2020 }) |matrix| for ([_]color.Range{ .full, .limited }) |range| {
        const map = Remap.init(matrix, range, matrix, range);
        for (0..256) |i| {
            const value: u8 = @intCast(i);
            for (0..3) |component| try std.testing.expectEqual(value, map.sample(component, value, value, value));
        }
    };
}
test "matrix remap agrees with an independent unclipped floating reference" {
    for ([_]color.Matrix{ .bt601, .bt709, .bt2020 }) |source| for ([_]color.Matrix{ .bt601, .bt709, .bt2020 }) |target| for ([_]color.Range{ .full, .limited }) |range| {
        const map = Remap.init(source, range, target, .limited);
        const sk: [2]f64 = switch (source) {
            .bt601 => .{ 0.299, 0.114 },
            .bt709 => .{ 0.2126, 0.0722 },
            .bt2020 => .{ 0.2627, 0.0593 },
        };
        const tk: [2]f64 = switch (target) {
            .bt601 => .{ 0.299, 0.114 },
            .bt709 => .{ 0.2126, 0.0722 },
            .bt2020 => .{ 0.2627, 0.0593 },
        };
        for ([_]u8{ 0, 16, 76, 128, 235, 255 }) |y| for ([_]u8{ 0, 16, 85, 128, 240, 255 }) |u| for ([_]u8{ 0, 16, 90, 128, 240, 255 }) |v| {
            const l = (@as(f64, @floatFromInt(y)) - @as(f64, if (range == .full) 0 else 16)) / @as(f64, if (range == .full) 255 else 219);
            const cb = (@as(f64, @floatFromInt(u)) - 128) / @as(f64, if (range == .full) 255 else 224);
            const cr = (@as(f64, @floatFromInt(v)) - 128) / @as(f64, if (range == .full) 255 else 224);
            const r = l + 2 * (1 - sk[0]) * cr;
            const b = l + 2 * (1 - sk[1]) * cb;
            const g = l - 2 * sk[1] * (1 - sk[1]) / (1 - sk[0] - sk[1]) * cb - 2 * sk[0] * (1 - sk[0]) / (1 - sk[0] - sk[1]) * cr;
            const ty = tk[0] * r + (1 - tk[0] - tk[1]) * g + tk[1] * b;
            const expected = [3]f64{ 16 + 219 * ty, 128 + 224 * (b - ty) / (2 * (1 - tk[1])), 128 + 224 * (r - ty) / (2 * (1 - tk[0])) };
            for (expected, 0..) |e, i| {
                const rounded: i32 = @intFromFloat(@round(std.math.clamp(e, 0, 255)));
                try std.testing.expect(@abs(@as(i32, map.sample(i, y, u, v)) - rounded) <= 1);
            }
        };
    };
}

test "semi-planar remapping matches I420 for every source and target matrix and range" {
    const t = std.testing;
    const ys = [_]u8{ 0, 16, 76, 128, 235, 255, 51, 91, 2, 42, 82, 122, 162, 202, 222, 242 };
    const uv = [_]u8{ 0, 255, 85, 240, 240, 90, 128, 16 };
    const semi = try color.I420.semiPlanar(4, 4, &ys, 4, &uv, 4, false);
    var canonical: [24]u8 = undefined;
    try semi.copyI420(&canonical);
    const planar = color.I420{ .width = 4, .height = 4, .planes = .{ canonical[0..16], canonical[16..20], canonical[20..24] }, .strides = .{ 4, 2, 2 } };
    for ([_]color.Matrix{ .bt601, .bt709, .bt2020 }) |src| for ([_]color.Matrix{ .bt601, .bt709, .bt2020 }) |dst| for ([_]color.Range{ .full, .limited }) |sr| for ([_]color.Range{ .full, .limited }) |dr| {
        const map = Remap.init(src, sr, dst, dr);
        var a: [24]u8 = undefined;
        var b: [24]u8 = undefined;
        try map.apply(planar, .{ a[0..16], a[16..20], a[20..24] }, .{ 4, 2, 2 });
        try map.apply(semi, .{ b[0..16], b[16..20], b[20..24] }, .{ 4, 2, 2 });
        try t.expectEqualSlices(u8, &a, &b);
    };
    const map = Remap.init(.bt601, .full, .bt709, .limited);
    var out: [24]u8 = @splat(73);
    try t.expectError(error.Overlap, map.apply(planar, .{ out[0..16], out[16..20], out[16..20] }, .{ 4, 2, 2 }));
    for (out) |value| try t.expectEqual(@as(u8, 73), value);
    try t.expectError(error.Overlap, map.apply(planar, .{ canonical[0..16], out[16..20], out[20..24] }, .{ 4, 2, 2 }));
}

test "packed 422 remapping uses per-row luma chroma and vertical average with atomic odd-height rejection" {
    const t = std.testing;
    const packed422 = @import("packed_yuv422.zig");
    for (std.meta.tags(packed422.Layout)) |layout| {
        var bytes: [19]u8 = @splat(99);
        layout.write(bytes[0..], .{ 10, 0, 20, 255 });
        layout.write(bytes[4..], .{ 30, 80, 40, 160 });
        layout.write(bytes[11..], .{ 50, 255, 60, 0 });
        layout.write(bytes[15..], .{ 70, 101, 80, 121 });
        const view = try packed422.View.init(&bytes, 4, 2, 11, layout);
        var out: [12]u8 = @splat(73);
        try Remap.init(.bt601, .full, .bt601, .full).apply422(view, .{ out[0..8], out[8..10], out[10..12] }, .{ 4, 2, 2 });
        try t.expectEqualSlices(u8, &.{ 10, 20, 30, 40, 50, 60, 70, 80, 128, 91, 128, 141 }, &out);
        const top = try packed422.View.init(bytes[0..8], 4, 1, 8, layout);
        @memset(&out, 73);
        try t.expectError(error.InvalidGeometry, Remap.init(.bt601, .full, .bt709, .limited).apply422(top, .{ out[0..8], out[8..10], out[10..12] }, .{ 4, 2, 2 }));
        try t.expectError(error.Overlap, Remap.init(.bt601, .full, .bt709, .limited).apply422(view, .{ bytes[0..8], out[8..10], out[10..12] }, .{ 4, 2, 2 }));
        for (out) |value| try t.expectEqual(@as(u8, 73), value);
    }
}
