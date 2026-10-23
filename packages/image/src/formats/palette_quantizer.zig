//! Bounded RGB8 median-cut palette preparation. Sparse images retain their
//! exact colors; larger color sets use a weighted 5-bit/channel histogram.
const std = @import("std");

pub const Quantizer = struct {
    allocator: std.mem.Allocator,
    palette: []u8 = &.{},
    palette_size: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Quantizer {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Quantizer) void {
        self.allocator.free(self.palette);
        self.palette = &.{};
        self.palette_size = 0;
    }
    /// Borrowed until successful replacement or deinit. Errors preserve the old
    /// palette. Input is consumed synchronously and is never mutated or retained.
    pub fn quantize(self: *Quantizer, rgb: []const u8, max_colors: usize) ![]u8 {
        if (max_colors == 0 or max_colors > 256) return error.InvalidColors;
        if (rgb.len == 0 or rgb.len % 3 != 0) return error.InvalidPixels;
        return self.quantizeSource(Packed{ .rgb = rgb, .len = rgb.len / 3 }, max_colors);
    }
    /// A checked source supplies len and synchronous pixel(index) !?[3]u8.
    /// null pixels do not consume palette entries (for one-bit transparency).
    /// An optional checkpoint() !void observes cancellation between phases.
    /// All skipped pixels produce an empty palette. Source ownership is borrowed;
    /// pixel values/count must remain stable throughout all preparation passes.
    pub fn quantizeSource(self: *Quantizer, source: anytype, max_colors: usize) ![]u8 {
        if (max_colors == 0 or max_colors > 256) return error.InvalidColors;
        if (source.len == 0) return error.InvalidPixels;
        if (source.len > std.math.maxInt(u32)) return error.ImageTooLarge;
        const replacement = try prepare(self.allocator, source, max_colors);
        const previous = self.palette;
        self.palette = replacement;
        self.palette_size = replacement.len / 3;
        self.allocator.free(previous);
        return replacement;
    }
    pub fn findNearestColor(self: *const Quantizer, r: u8, g: u8, b: u8) u8 {
        var best: u8 = 0;
        var distance: u32 = std.math.maxInt(u32);
        for (0..self.palette_size) |i| {
            const at = i * 3;
            const dr = @as(i32, r) - self.palette[at];
            const dg = @as(i32, g) - self.palette[at + 1];
            const db = @as(i32, b) - self.palette[at + 2];
            const next: u32 = @intCast(dr * dr + dg * dg + db * db);
            if (next < distance) {
                best = @intCast(i);
                if (next == 0) return best;
                distance = next;
            }
        }
        return best;
    }
};

const Packed = struct {
    rgb: []const u8,
    len: usize,
    pub fn pixel(self: Packed, index: usize) !?[3]u8 {
        return self.rgb[index * 3 ..][0..3].*;
    }
};
fn checkpoint(source: anytype) !void {
    const T = switch (@typeInfo(@TypeOf(source))) {
        .pointer => |p| p.child,
        else => @TypeOf(source),
    };
    if (@hasDecl(T, "checkpoint")) try source.checkpoint();
}

const Bin = struct {
    count: u32 = 0,
    key: u16 = 0,
    sums: [3]u64 = @splat(0),

    fn component(self: Bin, axis: u2) u8 {
        const shift: u4 = switch (axis) {
            0 => 10,
            1 => 5,
            else => 0,
        };
        return @intCast((self.key >> shift) & 31);
    }
    fn lessThan(axis: u2, a: Bin, b: Bin) bool {
        const av = a.component(axis);
        const bv = b.component(axis);
        return if (av == bv) a.key < b.key else av < bv;
    }
};
const Box = struct {
    bins: []Bin,
    weight: u64,
    axis: u2,
    range: u8,

    fn init(bins: []Bin) Box {
        var lo: [3]u8 = @splat(31);
        var hi: [3]u8 = @splat(0);
        var weight: u64 = 0;
        for (bins) |bin| {
            weight += bin.count;
            inline for (0..3) |axis| {
                const value = bin.component(axis);
                lo[axis] = @min(lo[axis], value);
                hi[axis] = @max(hi[axis], value);
            }
        }
        var axis: u2 = 0;
        for (1..3) |next| if (hi[next] - lo[next] > hi[axis] - lo[axis]) {
            axis = @intCast(next);
        };
        return .{ .bins = bins, .weight = weight, .axis = axis, .range = hi[axis] - lo[axis] };
    }
    fn split(self: Box) [2]Box {
        std.mem.sort(Bin, self.bins, self.axis, Bin.lessThan);
        var weight: u64 = 0;
        var cut: usize = 1;
        for (self.bins[0 .. self.bins.len - 1], 1..) |bin, at| {
            weight += bin.count;
            cut = at;
            if (weight >= (self.weight + 1) / 2) break;
        }
        return .{ init(self.bins[0..cut]), init(self.bins[cut..]) };
    }
};

fn prepare(allocator: std.mem.Allocator, source: anytype, max_colors: usize) ![]u8 {
    // Exact sparse path avoids histogram allocation and 5-bit collisions. The
    // open-addressed table is at most half full, so probing always terminates.
    var colors: [256][3]u8 = undefined;
    var slots: [512]u16 = @splat(0);
    var count: usize = 0;
    var at: usize = 0;
    try checkpoint(source);
    while (at < source.len) : (at += 1) {
        const color = try source.pixel(at) orelse continue;
        const key = @as(u32, color[0]) << 16 | @as(u32, color[1]) << 8 | color[2];
        var slot: usize = (key *% 0x9e3779b1) >> 23;
        while (slots[slot] != 0 and !std.mem.eql(u8, &colors[slots[slot] - 1], &color)) slot = (slot + 1) & 511;
        if (slots[slot] == 0) {
            if (count == max_colors) break;
            colors[count] = color;
            count += 1;
            slots[slot] = @intCast(count);
        }
    }
    try checkpoint(source);
    if (at == source.len) return allocator.dupe(u8, std.mem.sliceAsBytes(colors[0..count]));

    // Fixed histogram, independent of image size. Compact and sort occupied
    // bins in place; boxes only borrow disjoint slices of this single owner.
    const bins = try allocator.alloc(Bin, 32768);
    defer allocator.free(bins);
    @memset(bins, .{});
    at = 0;
    while (at < source.len) : (at += 1) {
        const color = try source.pixel(at) orelse continue;
        const key = @as(u16, color[0] >> 3) << 10 | @as(u16, color[1] >> 3) << 5 | color[2] >> 3;
        bins[key].count += 1;
        inline for (0..3) |channel| bins[key].sums[channel] += color[channel];
    }
    var used: usize = 0;
    for (bins, 0..) |bin, key| if (bin.count != 0) {
        bins[used] = bin;
        bins[used].key = @intCast(key);
        used += 1;
    };
    if (used == 0) return error.InvalidPixels;
    var boxes: [256]Box = undefined;
    boxes[0] = Box.init(bins[0..used]);
    count = 1;
    while (count < max_colors) {
        try checkpoint(source);
        var best: ?usize = null;
        var score: u64 = 0;
        for (boxes[0..count], 0..) |box, i| {
            const candidate = box.weight * box.range;
            if (box.bins.len > 1 and candidate > score) {
                best = i;
                score = candidate;
            }
        }
        const index = best orelse break;
        const halves = boxes[index].split();
        boxes[index] = halves[0];
        boxes[count] = halves[1];
        count += 1;
    }
    const palette = try allocator.alloc(u8, count * 3);
    for (boxes[0..count], 0..) |box, i| {
        var sums: [3]u64 = @splat(0);
        for (box.bins) |bin| inline for (0..3) |channel| {
            sums[channel] += bin.sums[channel];
        };
        inline for (0..3) |channel| palette[i * 3 + channel] = @intCast(sums[channel] / box.weight);
    }
    return palette;
}

test "sparse palettes preserve all exact hues including shared histogram bins" {
    const t = std.testing;
    var q = Quantizer.init(t.allocator);
    defer q.deinit();
    const pixels = [_]u8{ 255, 0, 0, 0, 255, 0, 0, 0, 255, 1, 2, 3, 2, 3, 4, 255, 0, 0 };
    const original = pixels;
    _ = try q.quantize(&pixels, 256);
    try t.expectEqual(@as(usize, 5), q.palette_size);
    var at: usize = 0;
    while (at < pixels.len) : (at += 3) {
        const index = @as(usize, q.findNearestColor(pixels[at], pixels[at + 1], pixels[at + 2])) * 3;
        try t.expectEqualSlices(u8, pixels[at..][0..3], q.palette[index..][0..3]);
    }
    try t.expectEqualSlices(u8, &original, &pixels);
}
test "histogram averages retain population weights and actual low channel bits" {
    const t = std.testing;
    var q = Quantizer.init(t.allocator);
    defer q.deinit();
    try t.expectEqualSlices(u8, &.{ 64, 2, 5 }, try q.quantize(&.{ 1, 2, 5, 1, 2, 5, 1, 2, 5, 255, 2, 5 }, 1));
    try t.expectEqualSlices(u8, &.{ 2, 3, 4 }, try q.quantize(&.{ 1, 2, 3, 3, 4, 5 }, 1));
}
test "uniform images need one exact color and only three allocated palette bytes" {
    const t = std.testing;
    const pixels = try t.allocator.alloc(u8, 1024 * 1024 * 3);
    defer t.allocator.free(pixels);
    @memset(pixels, 73);
    var scratch: [3]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&scratch);
    var q = Quantizer.init(fixed.allocator());
    defer q.deinit();
    try t.expectEqualSlices(u8, &.{ 73, 73, 73 }, try q.quantize(pixels, 256));
    try t.expectEqual(@as(usize, 1), q.palette_size);
}
test "dense RGB cube quantization bounds every decoded channel error" {
    const t = std.testing;
    var pixels: [512 * 3]u8 = undefined;
    for (0..8) |r| for (0..8) |g| for (0..8) |b| {
        const at = ((r * 8 + g) * 8 + b) * 3;
        pixels[at] = @intCast(r * 255 / 7);
        pixels[at + 1] = @intCast(g * 255 / 7);
        pixels[at + 2] = @intCast(b * 255 / 7);
    };
    var q = Quantizer.init(t.allocator);
    defer q.deinit();
    _ = try q.quantize(&pixels, 64);
    try t.expectEqual(@as(usize, 64), q.palette_size);
    var at: usize = 0;
    while (at < pixels.len) : (at += 3) {
        const index = @as(usize, q.findNearestColor(pixels[at], pixels[at + 1], pixels[at + 2])) * 3;
        for (0..3) |channel| {
            const delta = @as(i16, pixels[at + channel]) - q.palette[index + channel];
            try t.expect(@abs(delta) <= 19);
        }
    }
}
test "palette preparation uses constant bounded scratch for large dense input" {
    const t = std.testing;
    const pixels = try t.allocator.alloc(u8, 2 * 1024 * 1024 * 3);
    defer t.allocator.free(pixels);
    for (pixels, 0..) |*byte, i| byte.* = @truncate((i * 73) ^ (i >> 8) ^ (i >> 16));
    const scratch = try t.allocator.alloc(u8, 32768 * @sizeOf(Bin) + 4096);
    defer t.allocator.free(scratch);
    var fixed = std.heap.FixedBufferAllocator.init(scratch);
    var q = Quantizer.init(fixed.allocator());
    defer q.deinit();
    const palette = try q.quantize(pixels, 256);
    try t.expectEqual(@as(usize, 768), palette.len);
    // A second independent owner produces deterministic output.
    var other = Quantizer.init(t.allocator);
    defer other.deinit();
    try t.expectEqualSlices(u8, palette, try other.quantize(pixels, 256));
}
fn allocationFailures(allocator: std.mem.Allocator) !void {
    var q = Quantizer.init(allocator);
    defer q.deinit();
    const previous = try q.quantize(&.{ 1, 2, 3 }, 1);
    const pointer = previous.ptr;
    _ = q.quantize(&.{ 0, 0, 0, 255, 255, 255, 255, 0, 0 }, 2) catch |err| {
        try std.testing.expect(q.palette.ptr == pointer);
        try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, q.palette);
        return err;
    };
}
test "histogram and palette allocation failures preserve the previously published owner" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailures, .{});
}
test "borrowed sparse sources skip transparency and preserve the old palette on checkpoint failure" {
    const Source = struct {
        len: usize = 3,
        cancelled: bool = false,
        pub fn checkpoint(self: @This()) !void {
            if (self.cancelled) return error.Cancelled;
        }
        pub fn pixel(_: @This(), i: usize) !?[3]u8 {
            return if (i == 1) .{ 2, 3, 4 } else null;
        }
    };
    var q = Quantizer.init(std.testing.allocator);
    defer q.deinit();
    const palette = try q.quantizeSource(Source{}, 2);
    try std.testing.expectEqualSlices(u8, &.{ 2, 3, 4 }, palette);
    const address = palette.ptr;
    try std.testing.expectError(error.Cancelled, q.quantizeSource(Source{ .cancelled = true }, 2));
    try std.testing.expect(q.palette.ptr == address);
    try std.testing.expectEqualSlices(u8, &.{ 2, 3, 4 }, q.palette);
    const Empty = struct {
        len: usize = 3,
        pub fn pixel(_: @This(), _: usize) !?[3]u8 {
            return null;
        }
    };
    try std.testing.expectEqual(@as(usize, 0), (try q.quantizeSource(Empty{}, 2)).len);
    try std.testing.expectEqual(@as(usize, 0), q.palette_size);
}
