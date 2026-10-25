//! Checked straight-alpha source/source-over over borrowed integer rasters.
//! Blend encoded samples explicitly; no transfer or gamut conversion is implied.
//! One owned result or caller storage; no staging canvas or hidden allocation.
const std = @import("std");
pub const pixel = @import("pixel_view.zig");
pub const Blend = enum(u8) { over, source };
pub const Options = struct {
    x: i32 = 0,
    y: i32 = 0,
    blend: Blend = .over,
    opacity: u16 = 65535,
    /// Zero selects the greater input precision. Reduction keeps the high byte.
    bits: u8 = 0,
    endian: std.builtin.Endian = .little,
};
pub const Check = struct {
    context: ?*anyopaque = null,
    active: ?*const fn (?*anyopaque) bool = null,
    fn call(self: Check) !void {
        if (self.active) |f| if (!f(self.context)) return error.Cancelled;
    }
};
pub const Clip = struct { dx: usize, dy: usize, sx: usize, sy: usize, width: usize, height: usize };
pub const Plan = struct {
    width: u32,
    height: u32,
    bits: u8,
    endian: std.builtin.Endian,
    row_bytes: usize,
    bytes: usize,
    clip: Clip,
    pub fn init(base: pixel.View, overlay: pixel.View, options: Options, maximum: usize) !Plan {
        _ = try base.validate();
        _ = try overlay.validate();
        const bits = if (options.bits == 0) @max(base.bits, overlay.bits) else options.bits;
        const row = try pixel.packedRow(base.width, .rgba, bits);
        const bytes = std.math.mul(usize, row, base.height) catch return error.InvalidGeometry;
        if (bytes > maximum) return error.WorkingLimit;
        const dx: usize = @intCast(std.math.clamp(@as(i64, options.x), 0, base.width));
        const dy: usize = @intCast(std.math.clamp(@as(i64, options.y), 0, base.height));
        const sx: usize = @intCast(std.math.clamp(-@as(i64, options.x), 0, overlay.width));
        const sy: usize = @intCast(std.math.clamp(-@as(i64, options.y), 0, overlay.height));
        return .{ .width = base.width, .height = base.height, .bits = bits, .endian = options.endian, .row_bytes = row, .bytes = bytes, .clip = .{ .dx = dx, .dy = dy, .sx = sx, .sy = sy, .width = @min(base.width - dx, overlay.width - sx), .height = @min(base.height - dy, overlay.height - sy) } };
    }
};
/// Exact source-over with a 16-bit opacity multiplier and one final rounding.
/// Samples and alpha have the same precision; hidden destination RGB survives
/// a zero-coverage source. u64 holds even the worst-case u16 color numerator.
pub fn over(comptime T: type, dest: [4]T, source: [4]T, opacity: u16) [4]T {
    comptime std.debug.assert(T == u8 or T == u16);
    if (source[3] == 0 or opacity == 0) return dest;
    const m: u64 = std.math.maxInt(T);
    if (source[3] == m and opacity == 65535) return source;
    // Full-opacity APNG retains its original smaller integer weights.
    const denominator = if (opacity == 65535) m else m * 65535;
    const coverage = if (opacity == 65535) @as(u64, source[3]) else @as(u64, source[3]) * opacity;
    const sw = coverage * m;
    const dw = @as(u64, dest[3]) * (denominator - coverage);
    const alpha = sw + dw;
    var out: [4]T = undefined;
    out[3] = @intCast((alpha + denominator / 2) / denominator);
    for (0..3) |c| out[c] = @intCast((@as(u64, source[c]) * sw + @as(u64, dest[c]) * dw + alpha / 2) / alpha);
    return out;
}
fn blend(comptime T: type, dest: [4]T, source: [4]T, options: Options) [4]T {
    if (options.blend == .over) return over(T, dest, source, options.opacity);
    var result = source;
    result[3] = @intCast((@as(u64, source[3]) * options.opacity + 32767) / 65535);
    return result;
}
fn overlap(a: []const u8, b: []const u8) bool {
    const x = @intFromPtr(a.ptr);
    const y = @intFromPtr(b.ptr);
    return (x <= y and y - x < a.len) or (y < x and x - y < b.len);
}
/// Invalid input, limits, output spans or aliasing reject before any writes.
/// Cancellation can leave caller storage partial; owned users never publish it.
/// Both sources may alias each other, but neither may alias the destination.
pub fn into(base: pixel.View, overlay: pixel.View, options: Options, output: []u8, stride: usize, maximum: usize, check: Check) !void {
    const plan = try Plan.init(base, overlay, options, maximum);
    const target = pixel.View{ .data = output, .width = base.width, .height = base.height, .stride = stride, .format = .rgba, .bits = plan.bits, .endian = plan.endian };
    const row = try target.validate();
    const span = (@as(usize, target.height) - 1) * stride + row;
    for ([_]pixel.View{ base, overlay }) |source| {
        const source_row = try source.validate();
        const source_span = (@as(usize, source.height) - 1) * source.stride + source_row;
        if (overlap(source.data[0..source_span], output[0..span])) return error.Overlap;
    }
    const clip = plan.clip;
    for (0..base.height) |y| for (0..base.width) |x| {
        if (x & 1023 == 0) try check.call();
        var value = base.sample16(x, y);
        const covered = y >= clip.dy and y - clip.dy < clip.height and x >= clip.dx and x - clip.dx < clip.width;
        const source = if (covered) overlay.sample16(clip.sx + x - clip.dx, clip.sy + y - clip.dy) else value;
        if (plan.bits == 8) {
            var dest8: [4]u8 = undefined;
            var src8: [4]u8 = undefined;
            for (0..4) |c| {
                dest8[c] = @intCast(value[c] >> 8);
                src8[c] = @intCast(source[c] >> 8);
            }
            const result = if (covered) blend(u8, dest8, src8, options) else dest8;
            @memcpy(output[y * stride + x * 4 ..][0..4], &result);
        } else {
            if (covered) value = blend(u16, value, source, options);
            for (value, 0..) |v, c| std.mem.writeInt(u16, output[y * stride + x * 8 + c * 2 ..][0..2], v, plan.endian);
        }
    };
}
pub fn copied(allocator: std.mem.Allocator, base: pixel.View, overlay: pixel.View, options: Options, maximum: usize, check: Check) !pixel.Owned {
    const plan = try Plan.init(base, overlay, options, maximum);
    const data = try allocator.alloc(u8, plan.bytes);
    errdefer allocator.free(data);
    try into(base, overlay, options, data, plan.row_bytes, maximum, check);
    return .{ .allocator = allocator, .view = .{ .data = data, .width = plan.width, .height = plan.height, .stride = plan.row_bytes, .format = .rgba, .bits = plan.bits, .endian = plan.endian } };
}

// Independent exact rational Porter-Duff reference. Keep normalized fractions
// unexpanded rather than reusing the implementation's combined integer weights.
const Fraction = struct {
    n: u256,
    d: u256,
    fn plus(a: Fraction, b: Fraction) Fraction {
        return .{ .n = a.n * b.d + b.n * a.d, .d = a.d * b.d };
    }
    fn times(a: Fraction, b: Fraction) Fraction {
        return .{ .n = a.n * b.n, .d = a.d * b.d };
    }
    fn divided(a: Fraction, b: Fraction) Fraction {
        return .{ .n = a.n * b.d, .d = a.d * b.n };
    }
    fn complement(a: Fraction) Fraction {
        return .{ .n = a.d - a.n, .d = a.d };
    }
    fn quantize(a: Fraction, m: u256) u16 {
        return @intCast((a.n * m * 2 + a.d) / (2 * a.d));
    }
};
fn reference(comptime T: type, d: [4]T, s: [4]T, opacity: u16) [4]T {
    if (s[3] == 0 or opacity == 0) return d;
    const m = std.math.maxInt(T);
    const sa = (Fraction{ .n = s[3], .d = m }).times(.{ .n = opacity, .d = 65535 });
    const da = Fraction{ .n = d[3], .d = m };
    const weight = da.times(sa.complement());
    const alpha = sa.plus(weight);
    var out: [4]T = undefined;
    out[3] = @intCast(alpha.quantize(m));
    for (0..3) |c| out[c] = @intCast((Fraction{ .n = s[c], .d = m }).times(sa).plus((Fraction{ .n = d[c], .d = m }).times(weight)).divided(alpha).quantize(m));
    return out;
}
test "source-over matches independent exact fractions for every 8-bit alpha pair and native word opacity boundaries" {
    const t = std.testing;
    for (0..256) |sa| for (0..256) |da| {
        const s = [4]u8{ 255, 1, 91, @intCast(sa) };
        const d = [4]u8{ 3, 254, 177, @intCast(da) };
        try t.expectEqual(reference(u8, d, s, 65535), over(u8, d, s, 65535));
    };
    var seed: u64 = 0x92731;
    inline for (.{ u8, u16 }) |T| for (0..2048) |i| {
        var d: [4]T = undefined;
        var s: [4]T = undefined;
        for (0..4) |c| {
            seed = seed *% 6364136223846793005 +% 1;
            d[c] = @truncate(seed >> 32);
            seed = seed *% 6364136223846793005 +% 1;
            s[c] = @truncate(seed >> 32);
        }
        const opacity: u16 = switch (i % 7) {
            0 => 0,
            1 => 1,
            2 => 32767,
            3 => 32768,
            4 => 65534,
            5 => 65535,
            else => @truncate(seed),
        };
        try t.expectEqual(reference(T, d, s, opacity), over(T, d, s, opacity));
    };
}
test "clipping negative offsets mixed precision gray RGB and endian retain low bits and row padding" {
    const t = std.testing;
    const base = pixel.View{ .data = &.{ 10, 20, 30, 40 }, .width = 2, .height = 2, .stride = 2, .format = .gray };
    const source = pixel.View{ .data = &.{ 1, 2, 3, 255, 4, 5, 6, 255, 7, 8, 9, 255, 9, 8, 7, 255 }, .width = 2, .height = 2, .stride = 8, .format = .rgba };
    var out: [40]u8 = @splat(73);
    try into(base, source, .{ .x = -1, .y = -1, .bits = 16, .endian = .big }, &out, 20, 32, .{});
    const result = pixel.View{ .data = &out, .width = 2, .height = 2, .stride = 20, .format = .rgba, .bits = 16, .endian = .big };
    try t.expectEqual([4]u16{ 0x0909, 0x0808, 0x0707, 65535 }, result.sample16(0, 0));
    try t.expectEqual([4]u16{ 20 * 257, 20 * 257, 20 * 257, 65535 }, result.sample16(1, 0));
    for (out[16..20]) |v| try t.expectEqual(@as(u8, 73), v);
    for (out[36..]) |v| try t.expectEqual(@as(u8, 73), v);
    var word = [_]u8{ 0x12, 0x34, 0x80, 0x01, 0xfe, 0xdc };
    const rgb = pixel.View{ .data = &word, .width = 1, .height = 1, .stride = 6, .format = .rgb, .bits = 16, .endian = .big };
    var owned = try copied(t.allocator, base, rgb, .{}, 32, .{});
    defer owned.deinit();
    try t.expectEqual(@as(u8, 16), owned.view.bits);
    try t.expectEqual([4]u16{ 0x1234, 0x8001, 0xfedc, 65535 }, owned.view.sample16(0, 0));
    @memset(&word, 0);
    try t.expectEqual(@as(u16, 0x8001), owned.view.sample16(0, 0)[1]);
}
test "source replacement retains hidden RGB and multiplies alpha without intermediate rounding" {
    const t = std.testing;
    const base = pixel.View{ .data = &.{ 1, 2, 3, 4 }, .width = 1, .height = 1, .stride = 4, .format = .rgba };
    const source = pixel.View{ .data = &.{ 99, 45, 73, 128 }, .width = 1, .height = 1, .stride = 4, .format = .rgba };
    var out: [4]u8 = undefined;
    try into(base, source, .{ .blend = .source, .opacity = 32768 }, &out, 4, 4, .{});
    try t.expectEqualSlices(u8, &.{ 99, 45, 73, 64 }, &out);
    try into(base, source, .{ .blend = .source, .opacity = 0 }, &out, 4, 4, .{});
    try t.expectEqualSlices(u8, &.{ 99, 45, 73, 0 }, &out);
    inline for (.{ std.math.minInt(i32), std.math.maxInt(i32) }) |x| {
        try into(base, source, .{ .x = x, .y = x }, &out, 4, 4, .{});
        try t.expectEqualSlices(u8, base.data, &out);
    }
}
test "invalid late spans formats output overlap and limits preserve every destination byte" {
    const t = std.testing;
    var input: [32]u8 = @splat(91);
    var out: [32]u8 = @splat(73);
    const base = pixel.View{ .data = input[0..12], .width = 2, .height = 2, .stride = 6 };
    var source = base;
    source.data = input[0..11];
    try t.expectError(error.BufferTooSmall, into(base, source, .{}, &out, 8, 16, .{}));
    try t.expectError(error.BufferTooSmall, into(base, base, .{}, out[0..15], 8, 16, .{}));
    try t.expectError(error.InvalidGeometry, into(base, base, .{ .bits = 12 }, &out, 8, 32, .{}));
    try t.expectError(error.Overlap, into(base, base, .{}, input[1..], 8, 16, .{}));
    try t.expectError(error.WorkingLimit, into(base, base, .{}, &out, 8, 15, .{}));
    for (input) |v| try t.expectEqual(@as(u8, 91), v);
    for (out) |v| try t.expectEqual(@as(u8, 73), v);
}
fn failures(a: std.mem.Allocator) !void {
    const base = pixel.View{ .data = &.{ 17, 128, 255, 63 }, .width = 1, .height = 1, .stride = 4, .format = .rgba };
    var result = try copied(a, base, base, .{ .bits = 16, .opacity = 1 }, 8, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 8), result.view.data.len);
}
test "owned composites unwind every allocation failure and cancellation without publication" {
    const t = std.testing;
    try t.checkAllAllocationFailures(t.allocator, failures, .{});
    const base = pixel.View{ .data = &.{ 17, 128, 255, 63 }, .width = 1, .height = 1, .stride = 4, .format = .rgba };
    const Stop = struct {
        fn no(_: ?*anyopaque) bool {
            return false;
        }
    };
    try t.expectError(error.Cancelled, copied(t.allocator, base, base, .{}, 4, .{ .active = Stop.no }));
}
