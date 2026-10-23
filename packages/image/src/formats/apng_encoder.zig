//! Checked noninterlaced APNG over borrowed rasters. Reuses Home's PNG filters,
//! endian conversion and streaming zlib owner. No input or sink pointer survives.
const std = @import("std");
pub const raster = @import("raster_encoder.zig");
pub const Dispose = enum(u8) { none, background, previous };
pub const Blend = enum(u8) { source, over };
pub const Delay = struct {
    numerator: u16 = 0,
    denominator: u16 = 1000,

    /// Exact conversion, never silently clamps an unrepresentable duration.
    pub fn fromMilliseconds(ms: u32) !Delay {
        const divisor = std.math.gcd(ms, @as(u32, 1000));
        const num = ms / divisor;
        if (num > std.math.maxInt(u16)) return error.InvalidDelay;
        return .{ .numerator = @intCast(num), .denominator = @intCast(1000 / divisor) };
    }
};
pub const Frame = struct {
    view: raster.View,
    x: u32 = 0,
    y: u32 = 0,
    delay: Delay = .{},
    dispose: Dispose = .none,
    blend: Blend = .source,
};
pub const Animation = struct {
    width: u32,
    height: u32,
    frames: []const Frame,
    /// null includes frames[0] as the static PNG; it must cover the canvas.
    /// Otherwise this separate full-canvas static PNG is excluded from playback.
    default_image: ?raster.View = null,
    plays: u32 = 0,
    options: raster.PngOptions = .{},

    pub fn validate(self: Animation) !void {
        if (self.width == 0 or self.height == 0 or self.width > std.math.maxInt(i32) or self.height > std.math.maxInt(i32)) return error.InvalidGeometry;
        if (self.frames.len == 0 or self.frames.len > std.math.maxInt(u31) or self.plays > std.math.maxInt(u31)) return error.InvalidAnimation;
        try raster.checkPngOptions(self.options);
        const model = self.default_image orelse self.frames[0].view;
        if (model.width != self.width or model.height != self.height) return error.InvalidGeometry;
        _ = try model.validate();
        for (self.frames, 0..) |frame, i| {
            _ = try frame.view.validate();
            if (frame.view.format != model.format or frame.view.bits != model.bits) return error.IncompatibleFrame;
            if (frame.x > self.width or frame.y > self.height or frame.view.width > self.width - frame.x or frame.view.height > self.height - frame.y) return error.InvalidGeometry;
            if (i == 0 and self.default_image == null and (frame.x != 0 or frame.y != 0)) return error.InvalidGeometry;
        }
    }
};

const Sequence = struct {
    next: u64 = 0,
    fn take(self: *Sequence) ![4]u8 {
        if (self.next > std.math.maxInt(u31)) return error.SequenceOverflow;
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, @intCast(self.next), .big);
        self.next += 1;
        return bytes;
    }
};

/// All descriptors/spans are validated before allocation or the first sink call.
/// On sink/allocator/codec failure a streaming sink can contain a prefix; callers
/// own staging/rollback. The owned encode convenience publishes only on success.
pub fn write(allocator: std.mem.Allocator, animation: Animation, sink: anytype) !void {
    try animation.validate();
    try raster.checkpoint(sink);
    try raster.writePngHeader(sink, animation.default_image orelse animation.frames[0].view);
    var control: [8]u8 = undefined;
    std.mem.writeInt(u32, control[0..4], @intCast(animation.frames.len), .big);
    std.mem.writeInt(u32, control[4..8], animation.plays, .big);
    try raster.writePngChunk(sink, "acTL", &.{&control});
    var sequence = Sequence{};
    if (animation.default_image) |poster| {
        var compressed = ImageSink(@TypeOf(sink)){ .sink = sink, .sequence = null };
        try raster.writePngData(allocator, poster, animation.options, &compressed);
    }
    for (animation.frames, 0..) |frame, index| {
        var fc: [26]u8 = undefined;
        @memcpy(fc[0..4], &try sequence.take());
        std.mem.writeInt(u32, fc[4..8], frame.view.width, .big);
        std.mem.writeInt(u32, fc[8..12], frame.view.height, .big);
        std.mem.writeInt(u32, fc[12..16], frame.x, .big);
        std.mem.writeInt(u32, fc[16..20], frame.y, .big);
        std.mem.writeInt(u16, fc[20..22], frame.delay.numerator, .big);
        std.mem.writeInt(u16, fc[22..24], frame.delay.denominator, .big);
        fc[24] = @intFromEnum(frame.dispose);
        fc[25] = @intFromEnum(frame.blend);
        try raster.writePngChunk(sink, "fcTL", &.{&fc});
        var compressed = ImageSink(@TypeOf(sink)){ .sink = sink, .sequence = if (index == 0 and animation.default_image == null) null else &sequence };
        try raster.writePngData(allocator, frame.view, animation.options, &compressed);
    }
    try raster.writePngChunk(sink, "IEND", &.{});
}
fn ImageSink(comptime Sink: type) type {
    return struct {
        sink: Sink,
        sequence: ?*Sequence,
        pub fn checkpoint(self: *@This()) !void {
            try raster.checkpoint(self.sink);
        }
        pub fn writeAll(self: *@This(), bytes: []const u8) !void {
            if (bytes.len == 0) return;
            if (self.sequence) |seq| {
                const prefix = try seq.take();
                try raster.writePngChunk(self.sink, "fdAT", &.{ &prefix, bytes });
            } else try raster.writePngChunk(self.sink, "IDAT", &.{bytes});
        }
    };
}
const Buffer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    pub fn writeAll(self: *Buffer, bytes: []const u8) !void {
        try self.bytes.appendSlice(self.allocator, bytes);
    }
};
pub fn encode(allocator: std.mem.Allocator, animation: Animation) ![]u8 {
    var buffer = Buffer{ .allocator = allocator };
    errdefer buffer.bytes.deinit(allocator);
    try write(allocator, animation, &buffer);
    return buffer.bytes.toOwnedSlice(allocator);
}

const test_view = raster.View{ .data = &.{ 1, 2, 3, 4, 5, 6 }, .width = 2, .height = 1, .stride = 6 };
const RejectSink = struct {
    calls: usize = 0,
    pub fn writeAll(self: *RejectSink, _: []const u8) !void {
        self.calls += 1;
        return error.TestSinkFailed;
    }
};
test "APNG preflights every late frame, rectangle, format and option before writes or allocation" {
    const t = std.testing;
    var frames = [_]Frame{ .{ .view = test_view }, .{ .view = test_view } };
    var animation = Animation{ .width = 2, .height = 1, .frames = &frames };
    var sink = RejectSink{};
    frames[1].view.data = &.{1};
    try t.expectError(error.BufferTooSmall, write(t.failing_allocator, animation, &sink));
    frames[1].view = test_view;
    frames[1].x = std.math.maxInt(u32);
    try t.expectError(error.InvalidGeometry, write(t.failing_allocator, animation, &sink));
    frames[1].x = 1;
    try t.expectError(error.InvalidGeometry, write(t.failing_allocator, animation, &sink));
    frames[1].x = 0;
    frames[1].view.format = .gray;
    try t.expectError(error.IncompatibleFrame, write(t.failing_allocator, animation, &sink));
    frames[1].view = test_view;
    animation.options.compression = 10;
    try t.expectError(error.InvalidCompressionLevel, write(t.failing_allocator, animation, &sink));
    animation.options.compression = 1;
    animation.frames = &.{};
    try t.expectError(error.InvalidAnimation, write(t.failing_allocator, animation, &sink));
    animation.frames = &frames;
    animation.plays = std.math.maxInt(u32);
    try t.expectError(error.InvalidAnimation, write(t.failing_allocator, animation, &sink));
    try t.expectEqual(@as(usize, 0), sink.calls);
}
test "APNG exact delays preserve zero and large durations or reject without clamping" {
    const t = std.testing;
    try t.expectEqual(Delay{ .numerator = 0, .denominator = 1 }, try Delay.fromMilliseconds(0));
    try t.expectEqual(Delay{ .numerator = 8192, .denominator = 125 }, try Delay.fromMilliseconds(65536));
    try t.expectEqual(Delay{ .numerator = 65535, .denominator = 1 }, try Delay.fromMilliseconds(65535000));
    try t.expectError(error.InvalidDelay, Delay.fromMilliseconds(65537));
    try t.expectError(error.InvalidDelay, Delay.fromMilliseconds(std.math.maxInt(u32)));
}
test "APNG first animation frame must match canvas unless a separate poster is supplied" {
    const t = std.testing;
    const small = Frame{ .view = .{ .data = &.{ 7, 8, 9 }, .width = 1, .height = 1, .stride = 3 }, .x = 1 };
    var animation = Animation{ .width = 2, .height = 1, .frames = &.{small} };
    try t.expectError(error.InvalidGeometry, animation.validate());
    animation.default_image = test_view;
    try animation.validate();
    const bytes = try encode(t.allocator, animation);
    defer t.allocator.free(bytes);
    try t.expect(std.mem.indexOf(u8, bytes, "IDAT").? < std.mem.indexOf(u8, bytes, "fcTL").?);
    try t.expect(std.mem.indexOf(u8, bytes, "fdAT") != null);
}
test "APNG sequence numbers never wrap and sink failures propagate" {
    const t = std.testing;
    var sequence = Sequence{ .next = std.math.maxInt(u31) };
    try t.expectEqualSlices(u8, &.{ 0x7f, 0xff, 0xff, 0xff }, &try sequence.take());
    try t.expectError(error.SequenceOverflow, sequence.take());
    var sink = RejectSink{};
    try t.expectError(error.TestSinkFailed, write(t.allocator, .{ .width = 2, .height = 1, .frames = &.{.{ .view = test_view }} }, &sink));
    try t.expectEqual(@as(usize, 1), sink.calls);
}
fn allocationCase(a: std.mem.Allocator) !void {
    const small = Frame{ .view = .{ .data = &.{ 7, 8, 9 }, .width = 1, .height = 1, .stride = 3 }, .x = 1, .blend = .over, .dispose = .previous };
    const bytes = try encode(a, .{ .width = 2, .height = 1, .frames = &.{ .{ .view = test_view }, small } });
    defer a.free(bytes);
}
test "APNG allocations unwind all frames and chunks without publishing partial ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
test "APNG failures at every streaming write boundary clean up all frame owners" {
    const Sink = struct {
        calls: usize = 0,
        fail_at: usize = std.math.maxInt(usize),
        pub fn writeAll(self: *@This(), _: []const u8) !void {
            if (self.calls == self.fail_at) return error.InjectedSinkFailure;
            self.calls += 1;
        }
    };
    const animation = Animation{ .width = 2, .height = 1, .frames = &.{ .{ .view = test_view }, .{ .view = test_view } }, .default_image = test_view };
    var success = Sink{};
    try write(std.testing.allocator, animation, &success);
    for (0..success.calls) |index| {
        var failure = Sink{ .fail_at = index };
        try std.testing.expectError(error.InjectedSinkFailure, write(std.testing.allocator, animation, &failure));
        try std.testing.expectEqual(index, failure.calls);
    }
}
test "APNG streaming scratch allocations remain bounded independently of frame height" {
    const Sink = struct {
        pub fn writeAll(_: *@This(), _: []const u8) !void {}
    };
    const a = std.testing.allocator;
    const pixels = try a.alloc(u8, 3 * 20000);
    defer a.free(pixels);
    @memset(pixels, 71);
    const tall = raster.View{ .data = pixels, .width = 1, .height = 20000, .stride = 3 };
    // Bounded Zig scratch; zlib's native workspace is separately owned by C.
    var storage: [1024]u8 = undefined;
    var bounded = std.heap.FixedBufferAllocator.init(&storage);
    var sink = Sink{};
    try write(bounded.allocator(), .{ .width = 1, .height = 20000, .frames = &.{ .{ .view = tall }, .{ .view = tall } } }, &sink);
}

test "APNG checkpoints abort before allocation or within buffered rows and retain caller inputs" {
    const Sink = struct {
        calls: usize = 0,
        writes: usize = 0,
        stop: usize,
        pub fn checkpoint(self: *@This()) !void {
            if (self.calls == self.stop) return error.CaptureCancelled;
            self.calls += 1;
        }
        pub fn writeAll(self: *@This(), _: []const u8) !void {
            self.writes += 1;
        }
    };
    const a = std.testing.allocator;
    const pixels = try a.alloc(u8, 3 * 20000);
    defer a.free(pixels);
    @memset(pixels, 71);
    const tall = raster.View{ .data = pixels, .width = 1, .height = 20000, .stride = 3 };
    const animation = Animation{ .width = 1, .height = 20000, .frames = &.{ .{ .view = tall }, .{ .view = tall } } };
    var early = Sink{ .stop = 0 };
    try std.testing.expectError(error.CaptureCancelled, write(std.testing.failing_allocator, animation, &early));
    try std.testing.expectEqual(@as(usize, 0), early.writes);
    var middle = Sink{ .stop = 5000 };
    try std.testing.expectError(error.CaptureCancelled, write(a, animation, &middle));
    try std.testing.expectEqual(@as(usize, 5000), middle.calls);
    try std.testing.expect(middle.writes > 0);
    for (pixels) |value| try std.testing.expectEqual(@as(u8, 71), value);
}
