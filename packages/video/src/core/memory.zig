// Home Video Library - Memory Management
// Frame pools, reference counting, and efficient allocation

const std = @import("std");
const frame = @import("frame.zig");
const packet_mod = @import("packet.zig");

pub const VideoFrame = frame.VideoFrame;
pub const AudioFrame = frame.AudioFrame;
pub const Packet = packet_mod.Packet;

/// Reference-counted buffer
pub fn RefCountedBuffer(comptime T: type) type {
    return struct {
        data: []T,
        ref_count: std.atomic.Value(usize),
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, size: usize) !*Self {
            const self = try allocator.create(Self);
            const data = try allocator.alloc(T, size);

            self.* = .{
                .data = data,
                .ref_count = std.atomic.Value(usize).init(1),
                .allocator = allocator,
            };

            return self;
        }

        pub fn retain(self: *Self) void {
            _ = self.ref_count.fetchAdd(1, .monotonic);
        }

        pub fn release(self: *Self) void {
            const old_count = self.ref_count.fetchSub(1, .monotonic);
            if (old_count == 1) {
                // Last reference, free memory
                self.allocator.free(self.data);
                self.allocator.destroy(self);
            }
        }

        pub fn getRefCount(self: *const Self) usize {
            return self.ref_count.load(.monotonic);
        }
    };
}

/// Frame pool for efficient reuse
pub const VideoFramePool = struct {
    frames: std.ArrayList(*VideoFrame),
    width: u32,
    height: u32,
    format: frame.PixelFormat,
    allocator: std.mem.Allocator,
    max_frames: usize,
    allocated_frames: usize = 0,
    mutex: std.Thread.Mutex = .{},

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        width: u32,
        height: u32,
        format: frame.PixelFormat,
        max_frames: usize,
    ) Self {
        return .{
            .frames = std.ArrayList(*VideoFrame).init(allocator),
            .width = width,
            .height = height,
            .format = format,
            .allocator = allocator,
            .max_frames = max_frames,
        };
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.frames.items) |vf| {
            vf.deinit();
            self.allocator.destroy(vf);
        }
        self.frames.deinit();
    }

    /// Acquire a frame from the pool
    pub fn acquire(self: *Self) !*VideoFrame {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Try to reuse existing frame
        if (self.frames.popOrNull()) |vf| {
            // Reset frame properties
            vf.pts = frame.Timestamp.ZERO;
            vf.duration = frame.Duration.ZERO;
            vf.is_key_frame = false;
            vf.decode_order = 0;
            vf.display_order = 0;
            return vf;
        }

        // Allocate new frame if under limit
        if (self.allocated_frames < self.max_frames) {
            const vf = try self.allocator.create(VideoFrame);
            vf.* = try VideoFrame.init(
                self.allocator,
                self.width,
                self.height,
                self.format,
            );
            self.allocated_frames += 1;
            return vf;
        }

        return error.PoolExhausted;
    }

    /// Release a frame back to the pool
    pub fn release(self: *Self, vf: *VideoFrame) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Verify frame matches pool parameters
        if (vf.width != self.width or
            vf.height != self.height or
            vf.format != self.format)
        {
            return error.FrameMismatch;
        }

        try self.frames.append(vf);
    }

    /// Get pool statistics
    pub fn stats(self: *Self) PoolStats {
        self.mutex.lock();
        defer self.mutex.unlock();

        return .{
            .available = self.frames.items.len,
            .allocated = self.allocated_frames,
            .in_use = self.allocated_frames - self.frames.items.len,
        };
    }

    pub const PoolStats = struct {
        available: usize,
        allocated: usize,
        in_use: usize,
    };
};

/// Audio frame pool
pub const AudioFramePool = struct {
    frames: std.ArrayList(*AudioFrame),
    sample_rate: u32,
    channels: u8,
    num_samples: u32,
    format: frame.SampleFormat,
    allocator: std.mem.Allocator,
    max_frames: usize,
    allocated_frames: usize = 0,
    mutex: std.Thread.Mutex = .{},

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        sample_rate: u32,
        channels: u8,
        num_samples: u32,
        format: frame.SampleFormat,
        max_frames: usize,
    ) Self {
        return .{
            .frames = std.ArrayList(*AudioFrame).init(allocator),
            .sample_rate = sample_rate,
            .channels = channels,
            .num_samples = num_samples,
            .format = format,
            .allocator = allocator,
            .max_frames = max_frames,
        };
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.frames.items) |af| {
            af.deinit();
            self.allocator.destroy(af);
        }
        self.frames.deinit();
    }

    pub fn acquire(self: *Self) !*AudioFrame {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.frames.popOrNull()) |af| {
            af.pts = frame.Timestamp.ZERO;
            return af;
        }

        if (self.allocated_frames < self.max_frames) {
            const af = try self.allocator.create(AudioFrame);
            af.* = try AudioFrame.init(
                self.allocator,
                self.sample_rate,
                self.channels,
                self.num_samples,
                self.format,
            );
            self.allocated_frames += 1;
            return af;
        }

        return error.PoolExhausted;
    }

    pub fn release(self: *Self, af: *AudioFrame) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (af.sample_rate != self.sample_rate or
            af.channels != self.channels or
            af.format != self.format)
        {
            return error.FrameMismatch;
        }

        try self.frames.append(af);
    }
};

/// Packet pool
pub const PacketPool = struct {
    packets: std.ArrayList(*Packet),
    default_size: usize,
    allocator: std.mem.Allocator,
    max_packets: usize,
    allocated_packets: usize = 0,
    mutex: std.Thread.Mutex = .{},

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        default_size: usize,
        max_packets: usize,
    ) Self {
        return .{
            .packets = std.ArrayList(*Packet).init(allocator),
            .default_size = default_size,
            .allocator = allocator,
            .max_packets = max_packets,
        };
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.packets.items) |pkt| {
            pkt.deinit();
            self.allocator.destroy(pkt);
        }
        self.packets.deinit();
    }

    pub fn acquire(self: *Self, packet_type: packet_mod.PacketType) !*Packet {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.packets.popOrNull()) |pkt| {
            pkt.packet_type = packet_type;
            pkt.pts = frame.Timestamp.INVALID;
            pkt.dts = frame.Timestamp.INVALID;
            pkt.duration = frame.Duration.ZERO;
            pkt.flags = .{};
            pkt.sequence = 0;
            return pkt;
        }

        if (self.allocated_packets < self.max_packets) {
            const pkt = try self.allocator.create(Packet);
            pkt.* = try Packet.init(self.allocator, packet_type, self.default_size);
            self.allocated_packets += 1;
            return pkt;
        }

        return error.PoolExhausted;
    }

    pub fn release(self: *Self, pkt: *Packet) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.packets.append(pkt);
    }
};

/// Ring buffer for streaming
pub fn RingBuffer(comptime T: type) type {
    return struct {
        buffer: []T,
        read_pos: usize = 0,
        write_pos: usize = 0,
        count: usize = 0,
        allocator: std.mem.Allocator,
        mutex: std.Thread.Mutex = .{},
        not_empty: std.Thread.Condition = .{},
        not_full: std.Thread.Condition = .{},

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            const buffer = try allocator.alloc(T, capacity);
            return .{
                .buffer = buffer,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
        }

        pub fn push(self: *Self, item: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.count >= self.buffer.len) {
                self.not_full.wait(&self.mutex);
            }

            self.buffer[self.write_pos] = item;
            self.write_pos = (self.write_pos + 1) % self.buffer.len;
            self.count += 1;

            self.not_empty.signal();
        }

        pub fn tryPush(self: *Self, item: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.count >= self.buffer.len) {
                return error.BufferFull;
            }

            self.buffer[self.write_pos] = item;
            self.write_pos = (self.write_pos + 1) % self.buffer.len;
            self.count += 1;

            self.not_empty.signal();
        }

        pub fn pop(self: *Self) T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.count == 0) {
                self.not_empty.wait(&self.mutex);
            }

            const item = self.buffer[self.read_pos];
            self.read_pos = (self.read_pos + 1) % self.buffer.len;
            self.count -= 1;

            self.not_full.signal();
            return item;
        }

        pub fn tryPop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.count == 0) return null;

            const item = self.buffer[self.read_pos];
            self.read_pos = (self.read_pos + 1) % self.buffer.len;
            self.count -= 1;

            self.not_full.signal();
            return item;
        }

        pub fn len(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.count;
        }

        pub fn capacity(self: *const Self) usize {
            return self.buffer.len;
        }

        pub fn isEmpty(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.count == 0;
        }

        pub fn isFull(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.count >= self.buffer.len;
        }
    };
}

/// Tests
test "RefCountedBuffer" {
    const allocator = std.testing.allocator;

    var buf = try RefCountedBuffer(u8).init(allocator, 1024);
    try std.testing.expectEqual(@as(usize, 1), buf.getRefCount());

    buf.retain();
    try std.testing.expectEqual(@as(usize, 2), buf.getRefCount());

    buf.release();
    try std.testing.expectEqual(@as(usize, 1), buf.getRefCount());

    buf.release(); // Frees memory
}

test "VideoFramePool" {
    const allocator = std.testing.allocator;

    var pool = VideoFramePool.init(allocator, 1920, 1080, .yuv420p, 10);
    defer pool.deinit();

    const vf1 = try pool.acquire();
    const vf2 = try pool.acquire();

    try std.testing.expectEqual(@as(u32, 1920), vf1.width);
    try std.testing.expectEqual(@as(u32, 1080), vf1.height);

    try pool.release(vf1);
    try pool.release(vf2);

    const pool_stats = pool.stats();
    try std.testing.expectEqual(@as(usize, 2), pool_stats.available);
    try std.testing.expectEqual(@as(usize, 2), pool_stats.allocated);
    try std.testing.expectEqual(@as(usize, 0), pool_stats.in_use);
}

test "RingBuffer" {
    const allocator = std.testing.allocator;

    var ring = try RingBuffer(i32).init(allocator, 4);
    defer ring.deinit();

    try ring.tryPush(1);
    try ring.tryPush(2);
    try ring.tryPush(3);

    try std.testing.expectEqual(@as(usize, 3), ring.len());

    try std.testing.expectEqual(@as(i32, 1), ring.tryPop().?);
    try std.testing.expectEqual(@as(i32, 2), ring.tryPop().?);

    try std.testing.expectEqual(@as(usize, 1), ring.len());
}
