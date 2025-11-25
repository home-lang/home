// Home Video Library - Test Helpers
// Utilities for creating test data, mock objects, and assertions

const std = @import("std");
const core = @import("../core.zig");

/// Generate test video frame with pattern
pub const TestFrameGenerator = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Generate solid color frame
    pub fn solidColor(self: *Self, width: u32, height: u32, format: core.PixelFormat, color: u8) !*core.VideoFrame {
        const frame = try self.allocator.create(core.VideoFrame);
        frame.* = try core.VideoFrame.init(self.allocator, width, height, format);

        for (frame.data, 0..) |plane, i| {
            if (plane.len > 0) {
                @memset(frame.data[i], color);
            }
        }

        return frame;
    }

    /// Generate gradient frame (horizontal)
    pub fn horizontalGradient(self: *Self, width: u32, height: u32, format: core.PixelFormat) !*core.VideoFrame {
        const frame = try self.allocator.create(core.VideoFrame);
        frame.* = try core.VideoFrame.init(self.allocator, width, height, format);

        for (0..height) |y| {
            for (0..width) |x| {
                const value: u8 = @intCast((x * 255) / width);
                frame.data[0][y * width + x] = value;
            }
        }

        return frame;
    }

    /// Generate checkerboard pattern
    pub fn checkerboard(self: *Self, width: u32, height: u32, format: core.PixelFormat, square_size: u32) !*core.VideoFrame {
        const frame = try self.allocator.create(core.VideoFrame);
        frame.* = try core.VideoFrame.init(self.allocator, width, height, format);

        for (0..height) |y| {
            for (0..width) |x| {
                const is_black = ((x / square_size) + (y / square_size)) % 2 == 0;
                const value: u8 = if (is_black) 0 else 255;
                frame.data[0][y * width + x] = value;
            }
        }

        return frame;
    }

    /// Generate color bars (test pattern)
    pub fn colorBars(self: *Self, width: u32, height: u32) !*core.VideoFrame {
        const frame = try self.allocator.create(core.VideoFrame);
        frame.* = try core.VideoFrame.init(self.allocator, width, height, .rgb24);

        const bar_width = width / 7;
        const colors = [_][3]u8{
            .{ 255, 255, 255 }, // White
            .{ 255, 255, 0 }, // Yellow
            .{ 0, 255, 255 }, // Cyan
            .{ 0, 255, 0 }, // Green
            .{ 255, 0, 255 }, // Magenta
            .{ 255, 0, 0 }, // Red
            .{ 0, 0, 255 }, // Blue
        };

        for (0..height) |y| {
            for (0..width) |x| {
                const bar_index = @min(x / bar_width, 6);
                const pixel_idx = (y * width + x) * 3;

                frame.data[0][pixel_idx + 0] = colors[bar_index][0];
                frame.data[0][pixel_idx + 1] = colors[bar_index][1];
                frame.data[0][pixel_idx + 2] = colors[bar_index][2];
            }
        }

        return frame;
    }

    /// Generate noise frame
    pub fn noise(self: *Self, width: u32, height: u32, format: core.PixelFormat, seed: u64) !*core.VideoFrame {
        const frame = try self.allocator.create(core.VideoFrame);
        frame.* = try core.VideoFrame.init(self.allocator, width, height, format);

        var prng = std.rand.DefaultPrng.init(seed);
        const random = prng.random();

        for (frame.data[0]) |*pixel| {
            pixel.* = random.int(u8);
        }

        return frame;
    }
};

/// Generate test audio frames
pub const TestAudioGenerator = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Generate sine wave
    pub fn sineWave(self: *Self, sample_count: u32, sample_rate: u32, frequency: f32, amplitude: f32, channels: u16) !*core.AudioFrame {
        const frame = try self.allocator.create(core.AudioFrame);
        frame.* = try core.AudioFrame.init(self.allocator, sample_count, channels, sample_rate);

        const angular_freq = 2.0 * std.math.pi * frequency;

        for (0..sample_count) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sample_rate));
            const value = amplitude * @sin(angular_freq * t);

            for (0..channels) |ch| {
                frame.data[ch][i] = value;
            }
        }

        return frame;
    }

    /// Generate silence
    pub fn silence(self: *Self, sample_count: u32, sample_rate: u32, channels: u16) !*core.AudioFrame {
        const frame = try self.allocator.create(core.AudioFrame);
        frame.* = try core.AudioFrame.init(self.allocator, sample_count, channels, sample_rate);

        for (0..channels) |ch| {
            @memset(frame.data[ch], 0.0);
        }

        return frame;
    }

    /// Generate white noise
    pub fn whiteNoise(self: *Self, sample_count: u32, sample_rate: u32, channels: u16, seed: u64) !*core.AudioFrame {
        const frame = try self.allocator.create(core.AudioFrame);
        frame.* = try core.AudioFrame.init(self.allocator, sample_count, channels, sample_rate);

        var prng = std.rand.DefaultPrng.init(seed);
        const random = prng.random();

        for (0..channels) |ch| {
            for (0..sample_count) |i| {
                frame.data[ch][i] = (random.float(f32) * 2.0) - 1.0;
            }
        }

        return frame;
    }
};

/// Frame comparison utilities
pub const FrameComparison = struct {
    const Self = @This();

    pub fn areEqual(frame1: *const core.VideoFrame, frame2: *const core.VideoFrame) bool {
        if (frame1.width != frame2.width or frame1.height != frame2.height or frame1.format != frame2.format) {
            return false;
        }

        for (frame1.data, 0..) |plane1, i| {
            const plane2 = frame2.data[i];
            if (!std.mem.eql(u8, plane1, plane2)) {
                return false;
            }
        }

        return true;
    }

    pub fn calculateDifference(frame1: *const core.VideoFrame, frame2: *const core.VideoFrame) !f64 {
        if (frame1.width != frame2.width or frame1.height != frame2.height) {
            return error.FrameSizeMismatch;
        }

        const pixel_count = frame1.width * frame1.height;
        var sum_diff: u64 = 0;

        for (0..pixel_count) |i| {
            const diff = @abs(@as(i32, frame1.data[0][i]) - @as(i32, frame2.data[0][i]));
            sum_diff += @intCast(diff);
        }

        return @as(f64, @floatFromInt(sum_diff)) / @as(f64, @floatFromInt(pixel_count));
    }

    pub fn expectSimilar(frame1: *const core.VideoFrame, frame2: *const core.VideoFrame, max_diff: f64) !void {
        const diff = try calculateDifference(frame1, frame2);
        if (diff > max_diff) {
            std.debug.print("Frames differ by {d:.2}, expected max {d:.2}\n", .{ diff, max_diff });
            return error.FramesTooDifferent;
        }
    }
};

/// Performance benchmarking
pub const Benchmark = struct {
    name: []const u8,
    timer: std.time.Timer,
    iteration_count: usize,

    const Self = @This();

    pub fn start(name: []const u8) !Self {
        return .{
            .name = name,
            .timer = try std.time.Timer.start(),
            .iteration_count = 0,
        };
    }

    pub fn lap(self: *Self) void {
        self.iteration_count += 1;
    }

    pub fn finish(self: *Self) void {
        const elapsed = self.timer.read();
        const elapsed_ms = @as(f64, @floatFromInt(elapsed)) / 1_000_000.0;

        if (self.iteration_count > 0) {
            const per_iteration = elapsed_ms / @as(f64, @floatFromInt(self.iteration_count));
            std.debug.print("{s}: {d:.2}ms total, {d:.2}ms per iteration ({d} iterations)\n", .{
                self.name,
                elapsed_ms,
                per_iteration,
                self.iteration_count,
            });
        } else {
            std.debug.print("{s}: {d:.2}ms\n", .{ self.name, elapsed_ms });
        }
    }
};

/// Mock file I/O for testing
pub const MockFile = struct {
    data: std.ArrayList(u8),
    read_pos: usize,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .data = std.ArrayList(u8).init(allocator),
            .read_pos = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.data.deinit();
    }

    pub fn write(self: *Self, bytes: []const u8) !void {
        try self.data.appendSlice(bytes);
    }

    pub fn read(self: *Self, buffer: []u8) !usize {
        const available = self.data.items.len - self.read_pos;
        const to_read = @min(buffer.len, available);

        @memcpy(buffer[0..to_read], self.data.items[self.read_pos..][0..to_read]);
        self.read_pos += to_read;

        return to_read;
    }

    pub fn seek(self: *Self, pos: usize) void {
        self.read_pos = @min(pos, self.data.items.len);
    }

    pub fn reset(self: *Self) void {
        self.read_pos = 0;
    }

    pub fn getData(self: *const Self) []const u8 {
        return self.data.items;
    }
};

/// Test allocator wrapper with leak detection
pub const TestAllocator = struct {
    child_allocator: std.mem.Allocator,
    allocation_count: std.atomic.Value(usize),
    deallocation_count: std.atomic.Value(usize),

    const Self = @This();

    pub fn init(child_allocator: std.mem.Allocator) Self {
        return .{
            .child_allocator = child_allocator,
            .allocation_count = std.atomic.Value(usize).init(0),
            .deallocation_count = std.atomic.Value(usize).init(0),
        };
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
            },
        };
    }

    pub fn checkLeaks(self: *Self) bool {
        const allocs = self.allocation_count.load(.acquire);
        const deallocs = self.deallocation_count.load(.acquire);

        if (allocs != deallocs) {
            std.debug.print("Memory leak detected: {d} allocations, {d} deallocations\n", .{ allocs, deallocs });
            return true;
        }

        return false;
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = self.allocation_count.fetchAdd(1, .acq_rel);
        return self.child_allocator.rawAlloc(len, ptr_align, ret_addr);
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.child_allocator.rawResize(buf, buf_align, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = self.deallocation_count.fetchAdd(1, .acq_rel);
        self.child_allocator.rawFree(buf, buf_align, ret_addr);
    }
};
