//! Checked separable integer-raster resizing. Kernels derive from Home's image
//! resize operations; tables widen on reduction. Stored RGBA is straight alpha,
//! filtered RGBA is premultiplied. No transfer/gamut conversion is performed.
const std = @import("std");
pub const pixel = @import("pixel_view.zig");
pub const Algorithm = enum(u32) { nearest, bilinear, bicubic, lanczos2, lanczos3 };
pub const Limits = struct {
    max_output_bytes: usize = 256 * 1024 * 1024,
    max_work_bytes: usize = 64 * 1024 * 1024,
};
const Tap = struct { index: u32, weight: f64 };
const Span = struct { first: u32, end: u32, center: f64, scale: f64 };
const Axis = struct {
    offsets: []usize,
    taps: []Tap,
    largest: usize,
    fn deinit(self: Axis, a: std.mem.Allocator) void {
        a.free(self.offsets);
        a.free(self.taps);
    }
};
fn add(a: usize, b: usize) !usize {
    return std.math.add(usize, a, b) catch error.InvalidGeometry;
}
fn mul(a: usize, b: usize) !usize {
    return std.math.mul(usize, a, b) catch error.InvalidGeometry;
}
pub fn outputSize(source: pixel.View, width: u32, height: u32, limits: Limits) !usize {
    _ = try source.validate();
    if (height == 0 or height > std.math.maxInt(i32)) return error.InvalidGeometry;
    const size = try mul(try pixel.packedRow(width, source.format, source.bits), height);
    if (size > limits.max_output_bytes) return error.WorkLimit;
    return size;
}
fn support(algorithm: Algorithm) f64 {
    return switch (algorithm) {
        .nearest => 0.5,
        .bilinear => 1,
        .bicubic, .lanczos2 => 2,
        .lanczos3 => 3,
    };
}
fn weight(algorithm: Algorithm, x: f64) f64 {
    const ax = @abs(x);
    return switch (algorithm) {
        .nearest => unreachable,
        .bilinear => @max(0, 1 - ax),
        .bicubic => cubicWeight(ax),
        .lanczos2, .lanczos3 => blk: {
            const a = support(algorithm);
            if (ax >= a) break :blk 0;
            if (ax < 1e-12) break :blk 1;
            const px = std.math.pi * x;
            break :blk a * @sin(px) * @sin(px / a) / (px * px);
        },
    };
}
fn cubicWeight(x: f64) f64 {
    // Home's Mitchell-Netravali kernel (B=C=1/3), not Pillow's cubic kernel.
    const B = 1.0 / 3.0;
    const C = 1.0 / 3.0;
    if (x < 1) return ((12 - 9 * B - 6 * C) * x * x * x + (-18 + 12 * B + 6 * C) * x * x + (6 - 2 * B)) / 6;
    if (x < 2) return ((-B - 6 * C) * x * x * x + (6 * B + 30 * C) * x * x + (-12 * B - 48 * C) * x + (8 * B + 24 * C)) / 6;
    return 0;
}
fn span(source: u32, target: u32, at: usize, algorithm: Algorithm) Span {
    const ratio = @as(f64, @floatFromInt(source)) / @as(f64, @floatFromInt(target));
    const scale = @max(1, ratio);
    const center = (@as(f64, @floatFromInt(at)) + 0.5) * ratio - 0.5;
    const radius = support(algorithm) * scale;
    return .{
        .first = @intFromFloat(@max(0, @ceil(center - radius))),
        .end = @intFromFloat(@min(@as(f64, @floatFromInt(source)), @floor(center + radius) + 1)),
        .center = center,
        .scale = scale,
    };
}
fn axisBytes(source: u32, target: u32, algorithm: Algorithm) !struct { taps: usize, bytes: usize } {
    var count: usize = 0;
    for (0..target) |i| {
        const s = span(source, target, i, algorithm);
        count = try add(count, s.end - s.first);
    }
    return .{ .taps = count, .bytes = try add(try mul(try add(target, 1), @sizeOf(usize)), try mul(count, @sizeOf(Tap))) };
}
const Work = struct { x: usize, y: usize, samples: usize, base: usize, row_bytes: usize };
fn work(source: pixel.View, width: u32, height: u32, algorithm: Algorithm, limits: Limits) !Work {
    // Reject obviously oversized tables before scanning all target positions.
    const minimum_tables = try mul(try add(try add(width, height), 2), @sizeOf(usize) + @sizeOf(Tap));
    if (minimum_tables > limits.max_work_bytes) return error.WorkLimit;
    const xsize = try axisBytes(source.width, width, algorithm);
    const ysize = try axisBytes(source.height, height, algorithm);
    const tables = try add(xsize.bytes, ysize.bytes);
    const samples = try mul(width, source.format.channels());
    const row_bytes = try mul(samples, @sizeOf(f64));
    const base = try add(tables, row_bytes);
    if (base > limits.max_work_bytes or row_bytes > limits.max_work_bytes - base) return error.WorkLimit;
    return .{ .x = xsize.taps, .y = ysize.taps, .samples = samples, .base = base, .row_bytes = row_bytes };
}
/// Size query also preflights the bounded working heap without allocating it.
pub fn checkedSize(source: pixel.View, width: u32, height: u32, algorithm: Algorithm, limits: Limits) !usize {
    const size = try outputSize(source, width, height, limits);
    if (algorithm != .nearest and (width != source.width or height != source.height)) _ = try work(source, width, height, algorithm, limits);
    return size;
}
fn makeAxis(a: std.mem.Allocator, source: u32, target: u32, algorithm: Algorithm, count: usize) !Axis {
    const offsets = try a.alloc(usize, @as(usize, target) + 1);
    errdefer a.free(offsets);
    const taps = try a.alloc(Tap, count);
    errdefer a.free(taps);
    var at: usize = 0;
    var largest: usize = 0;
    for (0..target) |i| {
        offsets[i] = at;
        const s = span(source, target, i, algorithm);
        var total: f64 = 0;
        for (s.first..s.end) |j| {
            const w = weight(algorithm, (@as(f64, @floatFromInt(j)) - s.center) / s.scale);
            taps[at] = .{ .index = @intCast(j), .weight = w };
            total += w;
            at += 1;
        }
        if (!std.math.isFinite(total) or @abs(total) < 1e-12) return error.InvalidGeometry;
        for (taps[offsets[i]..at]) |*tap| tap.weight /= total;
        largest = @max(largest, at - offsets[i]);
    }
    offsets[target] = at;
    return .{ .offsets = offsets, .taps = taps, .largest = largest };
}
fn overlaps(source: pixel.View, out: []u8, stride: usize, width: u32, height: u32) bool {
    const a = @intFromPtr(source.data.ptr);
    const b = @intFromPtr(out.ptr);
    const source_span = (@as(usize, source.height) - 1) * source.stride + (pixel.packedRow(source.width, source.format, source.bits) catch unreachable);
    const target_span = (@as(usize, height) - 1) * stride + (pixel.packedRow(width, source.format, source.bits) catch unreachable);
    return (a <= b and b - a < source_span) or (b < a and a - b < target_span);
}
fn nearest(at: usize, source: u32, target: u32) usize {
    // Integer pixel-center mapping avoids float rounding at nearest boundaries.
    return @min(source - 1, ((@as(u64, @intCast(at)) * 2 + 1) * source) / (@as(u64, target) * 2));
}
fn horizontal(source: pixel.View, y: usize, xs: Axis, out: []f64) void {
    const channels = source.format.channels();
    for (0..xs.offsets.len - 1) |x| {
        const dest = out[x * channels ..][0..channels];
        @memset(dest, 0);
        for (xs.taps[xs.offsets[x]..xs.offsets[x + 1]]) |tap| {
            const values = source.sample16(tap.index, y);
            const alpha = if (channels == 4) @as(f64, @floatFromInt(values[3])) / 65535 else 1;
            for (dest, 0..) |*v, ch| v.* += @as(f64, @floatFromInt(values[ch])) * (if (channels == 4 and ch < 3) alpha else 1) * tap.weight;
        }
    }
}
/// Both spans, overlap, limits and every scratch allocation are checked before
/// any destination write. Padding is untouched. The input is borrowed only for
/// this call. Filtered results round once at native precision and saturate.
pub fn into(a: std.mem.Allocator, source: pixel.View, output: []u8, width: u32, height: u32, stride: usize, algorithm: Algorithm, limits: Limits) !void {
    _ = try outputSize(source, width, height, limits);
    const row = try pixel.packedRow(width, source.format, source.bits);
    const target = pixel.View{ .data = output, .width = width, .height = height, .stride = stride, .format = source.format, .bits = source.bits, .endian = source.endian };
    _ = try target.validate();
    if (width == source.width and height == source.height) return source.convert(output, stride, source.format, source.bits, source.endian);
    if (overlaps(source, output, stride, width, height)) return error.Overlap;
    const step = source.format.channels() * (source.bits / 8);
    if (algorithm == .nearest) {
        for (0..height) |y| for (0..width) |x| {
            const at = nearest(y, source.height, height) * source.stride + nearest(x, source.width, width) * step;
            @memcpy(output[y * stride + x * step ..][0..step], source.data[at..][0..step]);
        };
        return;
    }
    const layout = try work(source, width, height, algorithm, limits);
    const samples = layout.samples;
    const xs = try makeAxis(a, source.width, width, algorithm, layout.x);
    defer xs.deinit(a);
    const ys = try makeAxis(a, source.height, height, algorithm, layout.y);
    defer ys.deinit(a);
    // Bounded direct-mapped horizontal-row cache: no full floating-point image.
    const cache_rows = @min(64, ys.largest, (limits.max_work_bytes - layout.base) / layout.row_bytes);
    const cache = try a.alloc(f64, try mul(cache_rows, samples));
    defer a.free(cache);
    const sum = try a.alloc(f64, samples);
    defer a.free(sum);
    var keys: [64]i64 = @splat(-1);
    for (0..height) |y| {
        @memset(sum, 0);
        for (ys.taps[ys.offsets[y]..ys.offsets[y + 1]]) |tap| {
            const slot = tap.index % cache_rows;
            const values = cache[slot * samples ..][0..samples];
            if (keys[slot] != tap.index) {
                horizontal(source, tap.index, xs, values);
                keys[slot] = tap.index;
            }
            for (sum, values) |*v, h| v.* += h * tap.weight;
        }
        const channels = source.format.channels();
        for (0..width) |x| {
            const values = sum[x * channels ..][0..channels];
            const alpha = if (channels == 4) values[3] else 65535;
            for (values, 0..) |v, ch| {
                const native = if (channels == 4 and ch < 3) (if (alpha > 1e-12) v * 65535 / alpha else 0) else v;
                const value = std.math.clamp(native, 0, 65535);
                const at = y * stride + (x * channels + ch) * (source.bits / 8);
                if (source.bits == 8) output[at] = @intFromFloat(@floor(value / 257 + 0.5)) else std.mem.writeInt(u16, output[at..][0..2], @intFromFloat(@floor(value + 0.5)), source.endian);
            }
        }
        std.debug.assert(row <= stride);
    }
}
pub fn resize(a: std.mem.Allocator, source: pixel.View, width: u32, height: u32, algorithm: Algorithm, limits: Limits) !pixel.Owned {
    const size = try checkedSize(source, width, height, algorithm, limits);
    const data = try a.alloc(u8, size);
    errdefer a.free(data);
    const row = try pixel.packedRow(width, source.format, source.bits);
    try into(a, source, data, width, height, row, algorithm, limits);
    return .{ .allocator = a, .view = .{ .data = data, .width = width, .height = height, .stride = row, .format = source.format, .bits = source.bits, .endian = source.endian } };
}

test "resize pixel centers identity native words edge normalization and output padding" {
    const t = std.testing;
    for ([_]std.builtin.Endian{ .little, .big }) |endian| {
        var input: [7]u8 = @splat(91);
        std.mem.writeInt(u16, input[1..3], 12345, endian);
        std.mem.writeInt(u16, input[3..5], 54321, endian);
        const src = pixel.View{ .data = input[1..5], .width = 2, .height = 1, .stride = 4, .format = .gray, .bits = 16, .endian = endian };
        for (std.enums.values(Algorithm)) |algorithm| {
            var same = try resize(t.allocator, src, 2, 1, algorithm, .{});
            defer same.deinit();
            try t.expectEqualSlices(u8, input[1..5], same.view.data);
            var output: [18]u8 = @splat(73);
            try into(t.allocator, src, &output, 1, 2, 6, algorithm, .{});
            const expected: u16 = if (algorithm == .nearest) 54321 else 33333;
            try t.expectEqual(expected, std.mem.readInt(u16, output[0..2], endian));
            try t.expectEqual(expected, std.mem.readInt(u16, output[6..8], endian));
            for ([_]usize{ 2, 3, 4, 5, 8, 9, 17 }) |i| try t.expectEqual(@as(u8, 73), output[i]);
        }
    }
}
test "filtered straight alpha does not bleed hidden color and reduction sees the whole source" {
    const t = std.testing;
    const src = pixel.View{ .data = &.{ 255, 0, 0, 0, 0, 0, 255, 255 }, .width = 2, .height = 1, .stride = 8, .format = .rgba };
    for ([_]Algorithm{ .bilinear, .bicubic, .lanczos2, .lanczos3 }) |algorithm| {
        var out = try resize(t.allocator, src, 1, 1, algorithm, .{});
        defer out.deinit();
        try t.expectEqualSlices(u8, &.{ 0, 0, 255, 128 }, out.view.data);
        const gray = pixel.View{ .data = &.{ 255, 0, 0, 0, 0, 0, 0, 255 }, .width = 8, .height = 1, .stride = 8, .format = .gray };
        var reduced = try resize(t.allocator, gray, 1, 1, algorithm, .{});
        defer reduced.deinit();
        try t.expect(reduced.view.data[0] > 0);
    }
}
fn failed(a: std.mem.Allocator, output: []u8) !void {
    const source = pixel.View{ .data = &.{ 1, 9, 12, 18, 23, 98, 54, 230, 255 }, .width = 3, .height = 3, .stride = 3, .format = .gray };
    into(a, source, output, 2, 2, 3, .lanczos3, .{}) catch |err| {
        for (output) |v| try std.testing.expectEqual(@as(u8, 73), v);
        return err;
    };
    try std.testing.expectEqual(@as(u8, 73), output[2]);
    @memset(output, 73);
}
test "resize preflight and every allocation failure leave the destination untouched" {
    const t = std.testing;
    var source_data: [32]u8 = @splat(99);
    const src = pixel.View{ .data = &source_data, .width = 3, .height = 3, .stride = 3, .format = .gray };
    var output: [12]u8 = @splat(73);
    try t.expectError(error.Overlap, into(t.allocator, src, source_data[1..], 2, 2, 2, .nearest, .{}));
    try t.expectError(error.InvalidGeometry, into(t.allocator, src, &output, 0, 2, 2, .bilinear, .{}));
    try t.expectError(error.BufferTooSmall, into(t.allocator, src, output[0..3], 2, 2, 2, .bilinear, .{}));
    try t.expectError(error.WorkLimit, into(t.allocator, src, &output, 2, 2, 2, .bilinear, .{ .max_work_bytes = 0 }));
    try t.expectError(error.WorkLimit, resize(t.allocator, src, 5, 5, .nearest, .{ .max_output_bytes = 24 }));
    for (output) |v| try t.expectEqual(@as(u8, 73), v);
    try t.checkAllAllocationFailures(t.allocator, failed, .{&output});
}
