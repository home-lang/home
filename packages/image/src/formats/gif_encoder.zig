//! Checked still GIF89a over borrowed raster rows. Home's bounded weighted
//! palette and dictionary LZW are reused; no full RGB/indexed copy is required.
const std = @import("std");
pub const raster = @import("raster_encoder.zig");
const Quantizer = @import("palette_quantizer.zig").Quantizer;
const Lzw = @import("gif_lzw.zig").Encoder;
pub const Options = struct {
    /// Includes the transparent entry when present; GIF tables need >=2 slots.
    max_colors: u16 = 256,
    /// Unassociated alpha's high byte below this value becomes transparent.
    /// Other pixels are opaque; GIF cannot retain partial alpha or 16-bit color.
    alpha_threshold: u8 = 128,
};

fn Reader(comptime Sink: type) type {
    return struct {
        view: raster.View,
        len: usize,
        threshold: u8,
        sink: Sink,
        pub fn checkpoint(self: @This()) !void {
            try raster.checkpoint(self.sink);
        }
        fn sample(self: @This(), index: usize, channel: usize) u8 {
            const v = self.view;
            const at = (index / v.width) * v.stride + ((index % v.width) * v.format.channels() + channel) * (v.bits / 8);
            return v.data[at + @as(usize, if (v.bits == 16 and v.endian == .little) 1 else 0)];
        }
        pub fn pixel(self: @This(), index: usize) !?[3]u8 {
            if (index % self.view.width == 0) try self.checkpoint();
            if (self.view.format == .rgba and self.sample(index, 3) < self.threshold) return null;
            const r = self.sample(index, 0);
            if (self.view.format == .gray) return .{ r, r, r };
            return .{ r, self.sample(index, 1), self.sample(index, 2) };
        }
        fn transparent(self: @This()) !bool {
            if (self.view.format != .rgba or self.threshold == 0) return false;
            for (0..self.len) |index| {
                if (index % self.view.width == 0) try self.checkpoint();
                if (self.sample(index, 3) < self.threshold) return true;
            }
            return false;
        }
    };
}
fn Blocks(comptime Sink: type) type {
    return struct {
        sink: Sink,
        bytes: [255]u8 = undefined,
        used: usize = 0,
        fn flush(self: *@This()) !void {
            if (self.used == 0) return;
            try self.sink.writeAll(&.{@as(u8, @intCast(self.used))});
            try self.sink.writeAll(self.bytes[0..self.used]);
            self.used = 0;
        }
        pub fn writeAll(self: *@This(), bytes: []const u8) !void {
            var at: usize = 0;
            while (at < bytes.len) {
                const size = @min(bytes.len - at, self.bytes.len - self.used);
                @memcpy(self.bytes[self.used..][0..size], bytes[at..][0..size]);
                self.used += size;
                at += size;
                if (self.used == self.bytes.len) try self.flush();
            }
        }
    };
}

/// Descriptors/options validate before any allocation or sink call. Streaming
/// errors can leave a prefix; the caller owns staging/rollback and serialization.
/// Optional synchronous sink checkpoints observe cancellation on each raster row
/// and palette phase, even if compression has not emitted an output block yet.
pub fn write(allocator: std.mem.Allocator, view: raster.View, options: Options, sink: anytype) !void {
    _ = try view.validate();
    if (view.width > 65535 or view.height > 65535) return error.InvalidGeometry;
    if (options.max_colors < 2 or options.max_colors > 256) return error.InvalidColors;
    const length = try std.math.mul(usize, view.width, view.height);
    const reader = Reader(@TypeOf(sink)){ .view = view, .len = length, .threshold = options.alpha_threshold, .sink = sink };
    try reader.checkpoint();
    const transparent = try reader.transparent();
    const offset: u8 = @intFromBool(transparent);
    var quantizer = Quantizer.init(allocator);
    defer quantizer.deinit();
    const palette = try quantizer.quantizeSource(reader, options.max_colors - offset);
    const colors = quantizer.palette_size + offset;
    var bits: u8 = 1;
    while ((@as(u16, 1) << @intCast(bits)) < colors) bits += 1;
    const row = try allocator.alloc(u8, view.width);
    defer allocator.free(row);
    try reader.checkpoint();
    var header: [13]u8 = undefined;
    @memcpy(header[0..6], "GIF89a");
    std.mem.writeInt(u16, header[6..8], @intCast(view.width), .little);
    std.mem.writeInt(u16, header[8..10], @intCast(view.height), .little);
    header[10] = 0xf0 | (bits - 1);
    header[11] = 0;
    header[12] = 0;
    try sink.writeAll(&header);
    if (transparent) try sink.writeAll(&.{ 0, 0, 0 });
    try sink.writeAll(palette);
    const entries = @as(usize, 1) << @intCast(bits);
    for (colors..entries) |_| try sink.writeAll(&.{ 0, 0, 0 });
    try sink.writeAll(&.{ 0x21, 0xf9, 4, offset, 0, 0, 0, 0 });
    var descriptor: [10]u8 = @splat(0);
    descriptor[0] = 0x2c;
    std.mem.writeInt(u16, descriptor[5..7], @intCast(view.width), .little);
    std.mem.writeInt(u16, descriptor[7..9], @intCast(view.height), .little);
    try sink.writeAll(&descriptor);
    const minimum = @max(bits, 2);
    try sink.writeAll(&.{minimum});
    var lzw = try Lzw.init(minimum);
    var blocks = Blocks(@TypeOf(sink)){ .sink = sink };
    for (0..view.height) |y| {
        try reader.checkpoint();
        for (row, 0..) |*index, x| {
            if (try reader.pixel(y * view.width + x)) |rgb| index.* = quantizer.findNearestColor(rgb[0], rgb[1], rgb[2]) + offset else index.* = 0;
        }
        try lzw.write(row, &blocks);
    }
    try reader.checkpoint();
    try lzw.finish(&blocks);
    try blocks.flush();
    try sink.writeAll(&.{ 0, 0x3b });
}
const Buffer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    pub fn writeAll(self: *Buffer, bytes: []const u8) !void {
        try self.bytes.appendSlice(self.allocator, bytes);
    }
};
pub fn encode(allocator: std.mem.Allocator, view: raster.View, options: Options) ![]u8 {
    var buffer = Buffer{ .allocator = allocator };
    errdefer buffer.bytes.deinit(allocator);
    try write(allocator, view, options, &buffer);
    return buffer.bytes.toOwnedSlice(allocator);
}

test "GIF preflight rejects geometry spans and palette limits before allocation or sink calls" {
    const Sink = struct {
        calls: usize = 0,
        pub fn writeAll(self: *@This(), _: []const u8) !void {
            self.calls += 1;
        }
        pub fn checkpoint(self: *@This()) !void {
            self.calls += 1;
        }
    };
    var sink = Sink{};
    const view = raster.View{ .data = &.{ 1, 2, 3 }, .width = 1, .height = 1, .stride = 3 };
    var invalid = view;
    invalid.data = &.{ 1, 2 };
    try std.testing.expectError(error.BufferTooSmall, write(std.testing.failing_allocator, invalid, .{}, &sink));
    invalid.width = 65536;
    try std.testing.expectError(error.InvalidGeometry, write(std.testing.failing_allocator, invalid, .{}, &sink));
    try std.testing.expectError(error.InvalidColors, write(std.testing.failing_allocator, view, .{ .max_colors = 1 }, &sink));
    try std.testing.expectEqual(@as(usize, 0), sink.calls);
}
test "GIF cancellation checkpoints interrupt palette and buffered compressed rows" {
    const Sink = struct {
        calls: usize = 0,
        limit: usize,
        writes: usize = 0,
        pub fn writeAll(self: *@This(), _: []const u8) !void {
            self.writes += 1;
        }
        pub fn checkpoint(self: *@This()) !void {
            self.calls += 1;
            if (self.calls == self.limit) return error.Cancelled;
        }
    };
    const pixels = try std.testing.allocator.alloc(u8, 20000 * 3);
    defer std.testing.allocator.free(pixels);
    @memset(pixels, 73);
    const view = raster.View{ .data = pixels, .width = 1, .height = 20000, .stride = 3 };
    var early = Sink{ .limit = 1 };
    try std.testing.expectError(error.Cancelled, write(std.testing.failing_allocator, view, .{}, &early));
    try std.testing.expectEqual(@as(usize, 0), early.writes);
    var palette = Sink{ .limit = 5000 };
    try std.testing.expectError(error.Cancelled, write(std.testing.allocator, view, .{}, &palette));
    try std.testing.expectEqual(@as(usize, 0), palette.writes);
    var compressed = Sink{ .limit = 25000 };
    try std.testing.expectError(error.Cancelled, write(std.testing.allocator, view, .{}, &compressed));
    try std.testing.expect(compressed.writes > 0);
    for (pixels) |byte| try std.testing.expectEqual(@as(u8, 73), byte);
}
fn allocationFailures(allocator: std.mem.Allocator) !void {
    const pixels = [_]u8{ 1, 2, 3, 255, 0, 0, 0, 0, 255 };
    const bytes = try encode(allocator, .{ .data = &pixels, .width = 3, .height = 1, .stride = 9 }, .{ .max_colors = 2 });
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("GIF89a", bytes[0..6]);
    try std.testing.expectEqual(@as(u8, 0x3b), bytes[bytes.len - 1]);
}
test "GIF owned output unwinds every palette row histogram and encoded allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailures, .{});
}
