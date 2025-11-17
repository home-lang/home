// Home Language - Memory Pool Allocator
// High-performance pooling for games and real-time applications
//
// Based on implementation from C&C Generals Zero Hour port

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Generic object pool with O(1) acquire/release
pub fn ObjectPool(comptime T: type) type {
    return struct {
        const Self = @This();

        objects: []T,
        free_list: []u32,
        free_count: u32,
        capacity: u32,
        allocator: Allocator,

        pub fn init(allocator: Allocator, capacity: u32) !Self {
            const objects = try allocator.alloc(T, capacity);
            const free_list = try allocator.alloc(u32, capacity);

            // Initialize free list
            for (free_list, 0..) |*slot, i| {
                slot.* = @intCast(i);
            }

            return Self{
                .objects = objects,
                .free_list = free_list,
                .free_count = capacity,
                .capacity = capacity,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.objects);
            self.allocator.free(self.free_list);
        }

        pub fn acquire(self: *Self) ?*T {
            if (self.free_count == 0) return null;

            self.free_count -= 1;
            const index = self.free_list[self.free_count];
            return &self.objects[index];
        }

        pub fn release(self: *Self, obj: *T) void {
            // Calculate index from pointer
            const obj_addr = @intFromPtr(obj);
            const base_addr = @intFromPtr(self.objects.ptr);
            const index = @divTrunc(obj_addr - base_addr, @sizeOf(T));

            if (index >= self.capacity) return; // Invalid object

            self.free_list[self.free_count] = @intCast(index);
            self.free_count += 1;
        }

        pub fn activeCount(self: *const Self) u32 {
            return self.capacity - self.free_count;
        }

        pub fn freeCount(self: *const Self) u32 {
            return self.free_count;
        }

        pub fn isFull(self: *const Self) bool {
            return self.free_count == 0;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.free_count == self.capacity;
        }
    };
}

/// Fixed-size block pool
pub const MemoryPool = struct {
    const PoolNode = struct {
        next: ?*PoolNode,
    };

    block_size: u32,
    block_count: u32,
    memory: []u8,
    free_list: ?*PoolNode,
    allocations: u32,
    allocator: Allocator,

    pub fn init(allocator: Allocator, block_size: u32, block_count: u32) !MemoryPool {
        // Ensure block size is at least pointer size
        const actual_block_size = @max(block_size, @sizeOf(PoolNode));
        const total_size = actual_block_size * block_count;

        const memory = try allocator.alloc(u8, total_size);

        // Initialize free list
        var pool = MemoryPool{
            .block_size = actual_block_size,
            .block_count = block_count,
            .memory = memory,
            .free_list = null,
            .allocations = 0,
            .allocator = allocator,
        };

        // Build free list
        var i: u32 = 0;
        while (i < block_count) : (i += 1) {
            const offset = i * actual_block_size;
            const node: *PoolNode = @ptrCast(@alignCast(memory[offset .. offset + @sizeOf(PoolNode)].ptr));
            node.next = pool.free_list;
            pool.free_list = node;
        }

        return pool;
    }

    pub fn deinit(self: *MemoryPool) void {
        self.allocator.free(self.memory);
    }

    pub fn alloc(self: *MemoryPool) ?*anyopaque {
        if (self.free_list == null) return null;

        const node = self.free_list.?;
        self.free_list = node.next;
        self.allocations += 1;

        return @ptrCast(node);
    }

    pub fn free(self: *MemoryPool, ptr: *anyopaque) void {
        const node: *PoolNode = @ptrCast(@alignCast(ptr));
        node.next = self.free_list;
        self.free_list = node;

        if (self.allocations > 0) {
            self.allocations -= 1;
        }
    }

    pub fn contains(self: *const MemoryPool, ptr: *const anyopaque) bool {
        const addr = @intFromPtr(ptr);
        const base = @intFromPtr(self.memory.ptr);
        const end = base + self.memory.len;
        return addr >= base and addr < end;
    }

    pub fn activeCount(self: *const MemoryPool) u32 {
        return self.allocations;
    }

    pub fn freeCount(self: *const MemoryPool) u32 {
        return self.block_count - self.allocations;
    }

    pub fn isFull(self: *const MemoryPool) bool {
        return self.free_list == null;
    }
};

/// Multi-tiered allocator (like in Generals)
pub const TieredAllocator = struct {
    small_pool: MemoryPool,   // 32 bytes
    medium_pool: MemoryPool,  // 128 bytes
    large_pool: MemoryPool,   // 512 bytes
    fallback_allocator: Allocator,

    // Statistics
    small_allocations: u64 = 0,
    medium_allocations: u64 = 0,
    large_allocations: u64 = 0,
    fallback_allocations: u64 = 0,
    peak_small: u32 = 0,
    peak_medium: u32 = 0,
    peak_large: u32 = 0,

    pub fn init(allocator: Allocator) !TieredAllocator {
        return TieredAllocator{
            .small_pool = try MemoryPool.init(allocator, 32, 1024),
            .medium_pool = try MemoryPool.init(allocator, 128, 512),
            .large_pool = try MemoryPool.init(allocator, 512, 256),
            .fallback_allocator = allocator,
        };
    }

    pub fn deinit(self: *TieredAllocator) void {
        self.small_pool.deinit();
        self.medium_pool.deinit();
        self.large_pool.deinit();
    }

    pub fn alloc(self: *TieredAllocator, size: usize) ?*anyopaque {
        if (size <= 32) {
            self.small_allocations += 1;
            self.peak_small = @max(self.peak_small, self.small_pool.activeCount());
            return self.small_pool.alloc();
        } else if (size <= 128) {
            self.medium_allocations += 1;
            self.peak_medium = @max(self.peak_medium, self.medium_pool.activeCount());
            return self.medium_pool.alloc();
        } else if (size <= 512) {
            self.large_allocations += 1;
            self.peak_large = @max(self.peak_large, self.large_pool.activeCount());
            return self.large_pool.alloc();
        } else {
            // Fall back to regular allocator for large allocations
            self.fallback_allocations += 1;
            const bytes = self.fallback_allocator.alloc(u8, size) catch return null;
            return @ptrCast(bytes.ptr);
        }
    }

    pub fn free(self: *TieredAllocator, ptr: *anyopaque, size: usize) void {
        if (size <= 32 and self.small_pool.contains(ptr)) {
            self.small_pool.free(ptr);
        } else if (size <= 128 and self.medium_pool.contains(ptr)) {
            self.medium_pool.free(ptr);
        } else if (size <= 512 and self.large_pool.contains(ptr)) {
            self.large_pool.free(ptr);
        } else {
            // Fallback allocator
            const slice: [*]u8 = @ptrCast(ptr);
            self.fallback_allocator.free(slice[0..size]);
        }
    }

    pub fn printStats(self: *const TieredAllocator) void {
        std.debug.print("=== Tiered Allocator Statistics ===\n", .{});
        std.debug.print("Small Pool (32B):\n", .{});
        std.debug.print("  Allocations: {d}\n", .{self.small_allocations});
        std.debug.print("  Active: {d} / {d}\n", .{self.small_pool.activeCount(), self.small_pool.block_count});
        std.debug.print("  Peak: {d}\n", .{self.peak_small});

        std.debug.print("Medium Pool (128B):\n", .{});
        std.debug.print("  Allocations: {d}\n", .{self.medium_allocations});
        std.debug.print("  Active: {d} / {d}\n", .{self.medium_pool.activeCount(), self.medium_pool.block_count});
        std.debug.print("  Peak: {d}\n", .{self.peak_medium});

        std.debug.print("Large Pool (512B):\n", .{});
        std.debug.print("  Allocations: {d}\n", .{self.large_allocations});
        std.debug.print("  Active: {d} / {d}\n", .{self.large_pool.activeCount(), self.large_pool.block_count});
        std.debug.print("  Peak: {d}\n", .{self.peak_large});

        std.debug.print("Fallback Allocations: {d}\n", .{self.fallback_allocations});
    }
};

// Tests
test "ObjectPool basic operations" {
    const allocator = std.testing.allocator;

    const TestStruct = struct {
        value: i32,
    };

    var pool = try ObjectPool(TestStruct).init(allocator, 10);
    defer pool.deinit();

    // Acquire and release
    const obj1 = pool.acquire() orelse return error.PoolExhausted;
    obj1.value = 42;
    try std.testing.expectEqual(@as(u32, 1), pool.activeCount());

    const obj2 = pool.acquire() orelse return error.PoolExhausted;
    obj2.value = 100;
    try std.testing.expectEqual(@as(u32, 2), pool.activeCount());

    pool.release(obj1);
    try std.testing.expectEqual(@as(u32, 1), pool.activeCount());

    pool.release(obj2);
    try std.testing.expectEqual(@as(u32, 0), pool.activeCount());
}

test "MemoryPool exhaustion" {
    const allocator = std.testing.allocator;

    var pool = try MemoryPool.init(allocator, 64, 5);
    defer pool.deinit();

    var ptrs: [5]*anyopaque = undefined;

    // Exhaust pool
    for (&ptrs) |*ptr| {
        ptr.* = pool.alloc() orelse return error.PoolExhausted;
    }

    // Should fail - pool exhausted
    try std.testing.expectEqual(@as(?*anyopaque, null), pool.alloc());

    // Free one and try again
    pool.free(ptrs[0]);
    const new_ptr = pool.alloc() orelse return error.PoolExhausted;
    try std.testing.expect(new_ptr != null);
}

test "TieredAllocator routing" {
    const allocator = std.testing.allocator;

    var tiered = try TieredAllocator.init(allocator);
    defer tiered.deinit();

    // Small allocation
    const small = tiered.alloc(16) orelse return error.AllocFailed;
    try std.testing.expectEqual(@as(u64, 1), tiered.small_allocations);
    tiered.free(small, 16);

    // Medium allocation
    const medium = tiered.alloc(100) orelse return error.AllocFailed;
    try std.testing.expectEqual(@as(u64, 1), tiered.medium_allocations);
    tiered.free(medium, 100);

    // Large allocation
    const large = tiered.alloc(400) orelse return error.AllocFailed;
    try std.testing.expectEqual(@as(u64, 1), tiered.large_allocations);
    tiered.free(large, 400);

    // Fallback allocation
    const huge = tiered.alloc(1024) orelse return error.AllocFailed;
    try std.testing.expectEqual(@as(u64, 1), tiered.fallback_allocations);
    tiered.free(huge, 1024);
}
