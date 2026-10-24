//! Bounded APNG display canvas over checked Home integer rasters. Samples are
//! composited in their encoded space; no transfer/gamut conversion is implied.
//! One canvas and one restore canvas are allocated once. push/reset allocate
//! nothing, and invalid frames leave pixels and pending disposal unchanged.
const std = @import("std");
pub const pixel = @import("formats/pixel_view.zig");
pub const Control = struct { x: u32 = 0, y: u32 = 0, dispose: u8 = 0, blend: u8 = 0 };
const Pending = struct { control: Control, width: u32, height: u32 };
pub const Canvas = struct {
    allocator: std.mem.Allocator,
    pixels: []u8,
    restore: []u8,
    width: u32,
    height: u32,
    bits: u8,
    stride: usize,
    pending: ?Pending = null,

    pub fn requiredBytes(width: u32, height: u32, bits: u8) !usize {
        if (height == 0 or height > std.math.maxInt(i32)) return error.InvalidGeometry;
        const row = try pixel.packedRow(width, .rgba, bits);
        const size = try std.math.mul(usize, row, height);
        return std.math.mul(usize, size, 2);
    }
    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, bits: u8, maximum: usize) !Canvas {
        const required = try requiredBytes(width, height, bits);
        if (required > maximum) return error.WorkingLimit;
        const pixels = try allocator.alloc(u8, required / 2);
        errdefer allocator.free(pixels);
        const restore = try allocator.alloc(u8, required / 2);
        @memset(pixels, 0);
        // Restore is only read after a PREVIOUS frame saved its complete region.
        return .{ .allocator = allocator, .pixels = pixels, .restore = restore, .width = width, .height = height, .bits = bits, .stride = try pixel.packedRow(width, .rgba, bits) };
    }
    pub fn deinit(self: *Canvas) void {
        self.allocator.free(self.pixels);
        self.allocator.free(self.restore);
        self.* = undefined;
    }
    /// Borrowed until push/reset/deinit. Copy explicitly for an owned display frame.
    pub fn view(self: *const Canvas) pixel.View {
        return .{ .data = self.pixels, .width = self.width, .height = self.height, .stride = self.stride, .format = .rgba, .bits = self.bits };
    }
    pub fn reset(self: *Canvas) void {
        @memset(self.pixels, 0);
        self.pending = null;
    }
    pub fn push(self: *Canvas, source: pixel.View, control: Control) !void {
        const row = try source.validate();
        if (source.bits != self.bits or control.dispose > 2 or control.blend > 1 or control.x > self.width or control.y > self.height or source.width > self.width - control.x or source.height > self.height - control.y) return error.InvalidFrame;
        const span = (@as(usize, source.height) - 1) * source.stride + row;
        for ([_][]const u8{ self.pixels, self.restore }) |owned| {
            const a = @intFromPtr(source.data.ptr);
            const b = @intFromPtr(owned.ptr);
            if ((a <= b and b - a < span) or (b < a and a - b < owned.len)) return error.Overlap;
        }
        const first = self.pending == null;
        if (self.pending) |previous| self.dispose(previous);
        var actual = control;
        // PNG3: PREVIOUS on the first frame means BACKGROUND.
        if (first and actual.dispose == 2) actual.dispose = 1;
        const next = Pending{ .control = actual, .width = source.width, .height = source.height };
        if (actual.dispose == 2) self.region(next, .save);
        const bytes: usize = self.bits / 8;
        const shift: u4 = if (self.bits == 8) 8 else 0;
        for (0..source.height) |y| for (0..source.width) |x| {
            const at = (y + control.y) * self.stride + (x + control.x) * 4 * bytes;
            var value = source.sample16(x, y);
            for (&value) |*sample| sample.* >>= shift;
            if (control.blend == 1) {
                var dest: [4]u16 = undefined;
                for (&dest, 0..) |*sample, ch| sample.* = if (self.bits == 8) self.pixels[at + ch] else std.mem.readInt(u16, self.pixels[at + ch * 2 ..][0..2], .little);
                value = over(dest, value, if (self.bits == 8) 255 else 65535);
            }
            for (value, 0..) |sample, ch| {
                if (self.bits == 8) self.pixels[at + ch] = @intCast(sample) else std.mem.writeInt(u16, self.pixels[at + ch * 2 ..][0..2], sample, .little);
            }
        };
        self.pending = next;
    }
    fn dispose(self: *Canvas, previous: Pending) void {
        switch (previous.control.dispose) {
            1 => self.region(previous, .clear),
            2 => self.region(previous, .restore),
            else => {},
        }
    }
    fn region(self: *Canvas, frame: Pending, operation: enum { clear, save, restore }) void {
        const bytes: usize = 4 * @as(usize, self.bits / 8);
        for (0..frame.height) |y| {
            const at = (y + frame.control.y) * self.stride + frame.control.x * bytes;
            const dest = self.pixels[at..][0 .. frame.width * bytes];
            const saved = self.restore[at..][0 .. frame.width * bytes];
            switch (operation) {
                .clear => @memset(dest, 0),
                .save => @memcpy(saved, dest),
                .restore => @memcpy(dest, saved),
            }
        }
    }
};
/// Straight-alpha OVER, round-to-nearest with ties up, without intermediate
/// alpha rounding. u64 holds the worst-case 16-bit color*alpha*alpha sum.
fn over(dest: [4]u16, source: [4]u16, maximum: u64) [4]u16 {
    if (source[3] == 0) return dest;
    if (source[3] == maximum) return source;
    const sa: u64 = source[3];
    const remainder = @as(u64, dest[3]) * (maximum - sa);
    const alpha = sa * maximum + remainder;
    var result: [4]u16 = undefined;
    result[3] = @intCast((alpha + maximum / 2) / maximum);
    for (0..3) |ch| result[ch] = @intCast((@as(u64, source[ch]) * sa * maximum + @as(u64, dest[ch]) * remainder + alpha / 2) / alpha);
    return result;
}

test "APNG source over background previous and first previous use exact regions" {
    const t = std.testing;
    var canvas = try Canvas.init(t.allocator, 3, 1, 8, 24);
    defer canvas.deinit();
    const red = pixel.View{ .data = &.{ 255, 0, 0, 255 }, .width = 1, .height = 1, .stride = 4, .format = .rgba };
    const blue = pixel.View{ .data = &.{ 0, 0, 255, 128 }, .width = 1, .height = 1, .stride = 4, .format = .rgba };
    try canvas.push(red, .{ .dispose = 2 });
    try canvas.push(blue, .{ .x = 1, .dispose = 2 });
    try t.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 255, 128, 0, 0, 0, 0 }, canvas.pixels);
    try canvas.push(red, .{ .x = 2, .dispose = 1 });
    try t.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0, 255, 0, 0, 255 }, canvas.pixels);
    try canvas.push(red, .{});
    try canvas.push(blue, .{ .blend = 1, .dispose = 2 });
    try t.expectEqualSlices(u8, &.{ 127, 0, 128, 255 }, canvas.pixels[0..4]);
    try canvas.push(blue, .{ .x = 1 });
    try t.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, canvas.pixels[0..4]);
    canvas.reset();
    try t.expectEqualSlices(u8, &@as([12]u8, @splat(0)), canvas.pixels);
}
test "APNG native words respect endian stride gray RGB and transparent source replacement" {
    const t = std.testing;
    var canvas = try Canvas.init(t.allocator, 2, 2, 16, 64);
    defer canvas.deinit();
    const gray = pixel.View{ .data = &.{ 0x12, 0x34, 91, 92, 0xab, 0xcd }, .width = 1, .height = 2, .stride = 4, .format = .gray, .bits = 16, .endian = .big };
    try canvas.push(gray, .{ .x = 1 });
    try t.expectEqual([4]u16{ 0x1234, 0x1234, 0x1234, 65535 }, canvas.view().sample16(1, 0));
    try t.expectEqual([4]u16{ 0xabcd, 0xabcd, 0xabcd, 65535 }, canvas.view().sample16(1, 1));
    const transparent = pixel.View{ .data = &.{ 1, 0, 2, 0, 3, 0, 0, 0 }, .width = 1, .height = 1, .stride = 8, .format = .rgba, .bits = 16 };
    try canvas.push(transparent, .{ .x = 1, .blend = 1 });
    try t.expectEqual(@as(u16, 0x1234), canvas.view().sample16(1, 0)[0]);
    try canvas.push(transparent, .{ .x = 1 });
    try t.expectEqual([4]u16{ 1, 2, 3, 0 }, canvas.view().sample16(1, 0));
}
test "APNG integer straight alpha matches independent double precision equations" {
    const t = std.testing;
    var rng = std.Random.DefaultPrng.init(0xabcde);
    for ([_]u32{ 255, 65535 }) |maximum| for (0..5000) |_| {
        var source: [4]u16 = undefined;
        var dest: [4]u16 = undefined;
        for (&source, &dest) |*s, *d| {
            s.* = @intCast(rng.random().intRangeAtMost(u32, 0, maximum));
            d.* = @intCast(rng.random().intRangeAtMost(u32, 0, maximum));
        }
        const actual = over(dest, source, maximum);
        if (source[3] == 0) {
            try t.expectEqual(dest, actual);
            continue;
        }
        const m: f64 = @floatFromInt(maximum);
        const sa = @as(f64, @floatFromInt(source[3])) / m;
        const da = @as(f64, @floatFromInt(dest[3])) / m;
        const alpha = sa + da * (1 - sa);
        try t.expectApproxEqAbs(alpha * m, @as(f64, @floatFromInt(actual[3])), 0.500001);
        for (0..3) |ch| {
            const expected = (@as(f64, @floatFromInt(source[ch])) * sa + @as(f64, @floatFromInt(dest[ch])) * da * (1 - sa)) / alpha;
            try t.expectApproxEqAbs(expected, @as(f64, @floatFromInt(actual[ch])), 0.500001);
        }
    };
}
test "APNG bad frames cannot apply pending disposal or corrupt restore state" {
    const t = std.testing;
    var canvas = try Canvas.init(t.allocator, 1, 1, 8, 8);
    defer canvas.deinit();
    const source = pixel.View{ .data = &.{ 17, 18, 19 }, .width = 1, .height = 1, .stride = 3 };
    try canvas.push(source, .{ .dispose = 1 });
    for ([_]Control{ .{ .x = 1 }, .{ .y = 1 }, .{ .dispose = 3 }, .{ .blend = 2 } }) |bad| try t.expectError(error.InvalidFrame, canvas.push(source, bad));
    try t.expectError(error.Overlap, canvas.push(canvas.view(), .{}));
    var truncated = source;
    truncated.data = &.{ 1, 2 };
    try t.expectError(error.BufferTooSmall, canvas.push(truncated, .{}));
    try t.expectEqualSlices(u8, &.{ 17, 18, 19, 255 }, canvas.pixels);
    try canvas.push(source, .{});
    try t.expectEqualSlices(u8, &.{ 17, 18, 19, 255 }, canvas.pixels);
}
fn allocationCheck(a: std.mem.Allocator) !void {
    var canvas = try Canvas.init(a, 3, 2, 16, 96);
    defer canvas.deinit();
}
test "APNG canvas checks full two-buffer budget and unwinds every allocation failure" {
    const t = std.testing;
    try t.expectError(error.WorkingLimit, Canvas.init(t.allocator, 3, 2, 16, 95));
    try t.expectError(error.InvalidGeometry, Canvas.init(t.allocator, 0, 2, 16, 96));
    try t.expectError(error.InvalidGeometry, Canvas.init(t.allocator, 3, 0, 16, 96));
    try t.expectError(error.InvalidGeometry, Canvas.init(t.allocator, 3, 2, 12, 96));
    try t.checkAllAllocationFailures(t.allocator, allocationCheck, .{});
}
