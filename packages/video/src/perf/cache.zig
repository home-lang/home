// Home Video Library - Caching and Memory Management
// Frame caching, memory pooling, and resource management

const std = @import("std");
const core = @import("../core.zig");

/// LRU (Least Recently Used) cache for video frames
pub const FrameCache = struct {
    cache: std.AutoHashMap(u64, CacheEntry),
    lru_list: std.DoublyLinkedList(u64),
    max_size: usize,
    current_size: usize,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    const Self = @This();

    const CacheEntry = struct {
        frame: *core.VideoFrame,
        size: usize,
        node: *std.DoublyLinkedList(u64).Node,
    };

    pub fn init(allocator: std.mem.Allocator, max_size: usize) Self {
        return .{
            .cache = std.AutoHashMap(u64, CacheEntry).init(allocator),
            .lru_list = .{},
            .max_size = max_size,
            .current_size = 0,
            .allocator = allocator,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.frame.deinit();
            self.allocator.destroy(entry.value_ptr.frame);
            self.allocator.destroy(entry.value_ptr.node);
        }

        self.cache.deinit();
    }

    pub fn get(self: *Self, key: u64) ?*core.VideoFrame {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.cache.get(key)) |entry| {
            // Move to front of LRU list
            self.lru_list.remove(entry.node);
            self.lru_list.prepend(entry.node);

            return entry.frame;
        }

        return null;
    }

    pub fn put(self: *Self, key: u64, frame: *core.VideoFrame) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const frame_size = frame.width * frame.height * 4; // Estimate

        // Evict if necessary
        while (self.current_size + frame_size > self.max_size and self.lru_list.last != null) {
            try self.evictLRU();
        }

        // Create new node
        const node = try self.allocator.create(std.DoublyLinkedList(u64).Node);
        node.* = .{ .data = key };

        // Clone frame
        const cloned_frame = try self.allocator.create(core.VideoFrame);
        cloned_frame.* = try frame.clone(self.allocator);

        // Add to cache and LRU list
        try self.cache.put(key, .{
            .frame = cloned_frame,
            .size = frame_size,
            .node = node,
        });

        self.lru_list.prepend(node);
        self.current_size += frame_size;
    }

    fn evictLRU(self: *Self) !void {
        if (self.lru_list.last) |node| {
            const key = node.data;

            if (self.cache.fetchRemove(key)) |kv| {
                kv.value.frame.deinit();
                self.allocator.destroy(kv.value.frame);
                self.current_size -= kv.value.size;

                self.lru_list.remove(node);
                self.allocator.destroy(node);
            }
        }
    }

    pub fn clear(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.frame.deinit();
            self.allocator.destroy(entry.value_ptr.frame);
            self.allocator.destroy(entry.value_ptr.node);
        }

        self.cache.clearRetainingCapacity();
        self.lru_list = .{};
        self.current_size = 0;
    }
};

/// Memory pool for video frames
pub const FramePool = struct {
    free_frames: std.ArrayList(*core.VideoFrame),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    frame_width: u32,
    frame_height: u32,
    frame_format: core.PixelFormat,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, format: core.PixelFormat, initial_size: usize) !Self {
        var pool = Self{
            .free_frames = std.ArrayList(*core.VideoFrame).init(allocator),
            .allocator = allocator,
            .mutex = .{},
            .frame_width = width,
            .frame_height = height,
            .frame_format = format,
        };

        // Pre-allocate frames
        for (0..initial_size) |_| {
            const frame = try allocator.create(core.VideoFrame);
            frame.* = try core.VideoFrame.init(allocator, width, height, format);
            try pool.free_frames.append(frame);
        }

        return pool;
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.free_frames.items) |frame| {
            frame.deinit();
            self.allocator.destroy(frame);
        }

        self.free_frames.deinit();
    }

    pub fn acquire(self: *Self) !*core.VideoFrame {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.free_frames.items.len > 0) {
            return self.free_frames.pop();
        }

        // Allocate new frame if pool is empty
        const frame = try self.allocator.create(core.VideoFrame);
        frame.* = try core.VideoFrame.init(self.allocator, self.frame_width, self.frame_height, self.frame_format);
        return frame;
    }

    pub fn release(self: *Self, frame: *core.VideoFrame) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Reset frame data
        for (frame.data, 0..) |plane, i| {
            if (plane.len > 0) {
                @memset(frame.data[i], 0);
            }
        }

        try self.free_frames.append(frame);
    }
};

/// Circular buffer for video streaming
pub const CircularFrameBuffer = struct {
    frames: []?*core.VideoFrame,
    read_index: std.atomic.Value(usize),
    write_index: std.atomic.Value(usize),
    capacity: usize,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
        const frames = try allocator.alloc(?*core.VideoFrame, capacity);
        @memset(frames, null);

        return .{
            .frames = frames,
            .read_index = std.atomic.Value(usize).init(0),
            .write_index = std.atomic.Value(usize).init(0),
            .capacity = capacity,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.frames) |maybe_frame| {
            if (maybe_frame) |frame| {
                frame.deinit();
                self.allocator.destroy(frame);
            }
        }

        self.allocator.free(self.frames);
    }

    pub fn write(self: *Self, frame: *core.VideoFrame) !bool {
        const write_idx = self.write_index.load(.acquire);
        const next_write = (write_idx + 1) % self.capacity;

        if (next_write == self.read_index.load(.acquire)) {
            return false; // Buffer full
        }

        // Clone frame
        const cloned = try self.allocator.create(core.VideoFrame);
        cloned.* = try frame.clone(self.allocator);

        // Free old frame if exists
        if (self.frames[write_idx]) |old_frame| {
            old_frame.deinit();
            self.allocator.destroy(old_frame);
        }

        self.frames[write_idx] = cloned;
        self.write_index.store(next_write, .release);

        return true;
    }

    pub fn read(self: *Self) ?*core.VideoFrame {
        const read_idx = self.read_index.load(.acquire);

        if (read_idx == self.write_index.load(.acquire)) {
            return null; // Buffer empty
        }

        const frame = self.frames[read_idx];
        self.frames[read_idx] = null;

        const next_read = (read_idx + 1) % self.capacity;
        self.read_index.store(next_read, .release);

        return frame;
    }

    pub fn peek(self: *Self) ?*core.VideoFrame {
        const read_idx = self.read_index.load(.acquire);

        if (read_idx == self.write_index.load(.acquire)) {
            return null;
        }

        return self.frames[read_idx];
    }
};

/// Memory allocator with buffer alignment for SIMD
pub const AlignedAllocator = struct {
    child_allocator: std.mem.Allocator,
    alignment: usize,

    const Self = @This();

    pub fn init(child_allocator: std.mem.Allocator, alignment: usize) Self {
        return .{
            .child_allocator = child_allocator,
            .alignment = alignment,
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

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = ret_addr;

        const actual_align = @max(@as(usize, @intCast(ptr_align)), self.alignment);

        return self.child_allocator.rawAlloc(len, @intCast(actual_align), ret_addr);
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.child_allocator.rawResize(buf, buf_align, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.child_allocator.rawFree(buf, buf_align, ret_addr);
    }
};

/// Resource limiter to prevent memory exhaustion
pub const ResourceLimiter = struct {
    max_memory: usize,
    current_memory: std.atomic.Value(usize),
    max_frames: usize,
    current_frames: std.atomic.Value(usize),

    const Self = @This();

    pub fn init(max_memory: usize, max_frames: usize) Self {
        return .{
            .max_memory = max_memory,
            .current_memory = std.atomic.Value(usize).init(0),
            .max_frames = max_frames,
            .current_frames = std.atomic.Value(usize).init(0),
        };
    }

    pub fn canAllocateFrame(self: *Self, frame_size: usize) bool {
        const current_mem = self.current_memory.load(.acquire);
        const current_frames = self.current_frames.load(.acquire);

        return (current_mem + frame_size <= self.max_memory) and
            (current_frames + 1 <= self.max_frames);
    }

    pub fn allocateFrame(self: *Self, frame_size: usize) !void {
        if (!self.canAllocateFrame(frame_size)) {
            return error.ResourceLimitExceeded;
        }

        _ = self.current_memory.fetchAdd(frame_size, .acq_rel);
        _ = self.current_frames.fetchAdd(1, .acq_rel);
    }

    pub fn releaseFrame(self: *Self, frame_size: usize) void {
        _ = self.current_memory.fetchSub(frame_size, .acq_rel);
        _ = self.current_frames.fetchSub(1, .acq_rel);
    }

    pub fn getCurrentMemory(self: *Self) usize {
        return self.current_memory.load(.acquire);
    }

    pub fn getCurrentFrames(self: *Self) usize {
        return self.current_frames.load(.acquire);
    }
};
