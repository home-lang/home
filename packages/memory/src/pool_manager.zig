// Home Programming Language - Automatic Memory Pool Manager
// Manages multiple pool allocators with automatic size selection

const std = @import("std");
const Pool = @import("pool.zig").Pool;
const AllocatorError = @import("memory_types.zig").AllocatorError;
const MemStats = @import("memory_types.zig").MemStats;

/// Pool configuration for a specific size class
pub const PoolConfig = struct {
    block_size: usize,
    initial_count: usize,
    max_count: usize = 0, // 0 = unlimited
};

/// Automatic pool manager that selects the best pool based on allocation size
pub const PoolManager = struct {
    pools: std.ArrayList(ManagedPool),
    parent_allocator: std.mem.Allocator,
    stats: MemStats,
    fallback_threshold: usize,

    const ManagedPool = struct {
        pool: Pool,
        config: PoolConfig,
        active_allocations: usize,
    };

    /// Default size classes for common allocation patterns
    pub const DEFAULT_SIZE_CLASSES = [_]PoolConfig{
        .{ .block_size = 16, .initial_count = 256, .max_count = 4096 },
        .{ .block_size = 32, .initial_count = 256, .max_count = 4096 },
        .{ .block_size = 64, .initial_count = 128, .max_count = 2048 },
        .{ .block_size = 128, .initial_count = 128, .max_count = 2048 },
        .{ .block_size = 256, .initial_count = 64, .max_count = 1024 },
        .{ .block_size = 512, .initial_count = 64, .max_count = 1024 },
        .{ .block_size = 1024, .initial_count = 32, .max_count = 512 },
        .{ .block_size = 2048, .initial_count = 16, .max_count = 256 },
        .{ .block_size = 4096, .initial_count = 16, .max_count = 256 },
    };

    pub fn init(parent: std.mem.Allocator) !PoolManager {
        return initWithConfigs(parent, &DEFAULT_SIZE_CLASSES);
    }

    pub fn initWithConfigs(parent: std.mem.Allocator, configs: []const PoolConfig) !PoolManager {
        var pools = try std.ArrayList(ManagedPool).initCapacity(parent, configs.len);
        errdefer pools.deinit(parent);

        // Create pools for each size class
        for (configs) |config| {
            const pool = try Pool.init(parent, config.block_size, config.initial_count);
            try pools.append(parent, .{
                .pool = pool,
                .config = config,
                .active_allocations = 0,
            });
        }

        // Set fallback threshold to largest pool size
        const fallback_threshold = if (configs.len > 0)
            configs[configs.len - 1].block_size
        else
            4096;

        return .{
            .pools = pools,
            .parent_allocator = parent,
            .stats = MemStats.init(),
            .fallback_threshold = fallback_threshold,
        };
    }

    pub fn deinit(self: *PoolManager) void {
        for (self.pools.items) |*managed| {
            managed.pool.deinit();
        }
        self.pools.deinit(self.parent_allocator);
    }

    pub fn allocator(self: *PoolManager) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
                .remap = std.mem.Allocator.noRemap,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *PoolManager = @ptrCast(@alignCast(ctx));

        // Find best fitting pool
        const pool_index = self.findPool(len);

        if (pool_index) |index| {
            const managed = &self.pools.items[index];

            // Try to allocate from pool
            const result = managed.pool.allocator().rawAlloc(len, ptr_align, @returnAddress());
            if (result) |ptr| {
                managed.active_allocations += 1;
                self.stats.recordAlloc(len);
                return ptr;
            }

            // Pool exhausted - try to grow if allowed
            if (managed.config.max_count == 0 or managed.pool.block_count < managed.config.max_count) {
                // Could implement pool growth here
                // For now, fall through to parent allocator
            }
        }

        // Use parent allocator for large allocations or when pools are exhausted
        const result = self.parent_allocator.rawAlloc(len, ptr_align, ret_addr) orelse return null;
        self.stats.recordAlloc(len);
        return result;
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *PoolManager = @ptrCast(@alignCast(ctx));

        // Check if allocation came from a pool
        const old_pool = self.findPoolForPointer(buf.ptr);
        const new_pool = self.findPool(new_len);

        // If same pool and new size fits, allow resize
        if (old_pool != null and old_pool.? == new_pool.? and new_len <= buf.len) {
            return true;
        }

        // Try parent allocator resize
        return self.parent_allocator.rawResize(buf, buf_align, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *PoolManager = @ptrCast(@alignCast(ctx));

        // Check if allocation came from a pool
        if (self.findPoolForPointer(buf.ptr)) |index| {
            const managed = &self.pools.items[index];
            managed.pool.allocator().rawFree(buf, buf_align, ret_addr);
            managed.active_allocations -= 1;
            self.stats.recordFree(buf.len);
        } else {
            // Free from parent allocator
            self.parent_allocator.rawFree(buf, buf_align, ret_addr);
            self.stats.recordFree(buf.len);
        }
    }

    /// Find the best pool for a given allocation size
    fn findPool(self: *PoolManager, size: usize) ?usize {
        if (size > self.fallback_threshold) return null;

        // Find smallest pool that can fit the allocation
        for (self.pools.items, 0..) |managed, i| {
            if (managed.pool.block_size >= size) {
                return i;
            }
        }

        return null;
    }

    /// Find which pool owns a given pointer
    fn findPoolForPointer(self: *PoolManager, ptr: *anyopaque) ?usize {
        const addr = @intFromPtr(ptr);

        for (self.pools.items, 0..) |managed, i| {
            const buffer_start = @intFromPtr(managed.pool.buffer.ptr);
            const buffer_end = buffer_start + managed.pool.buffer.len;

            if (addr >= buffer_start and addr < buffer_end) {
                return i;
            }
        }

        return null;
    }

    /// Get statistics for all pools
    pub fn getStats(self: *const PoolManager) MemStats {
        var total_stats = self.stats;

        for (self.pools.items) |managed| {
            const pool_stats = managed.pool.getStats();
            total_stats.total_allocated += pool_stats.total_allocated;
            total_stats.current_usage += pool_stats.current_usage;
            total_stats.peak_usage = @max(total_stats.peak_usage, pool_stats.peak_usage);
            total_stats.num_allocations += pool_stats.num_allocations;
            total_stats.num_frees += pool_stats.num_frees;
        }

        return total_stats;
    }

    /// Get pool utilization statistics
    pub const PoolUtilization = struct {
        block_size: usize,
        total_blocks: usize,
        active_allocations: usize,
        utilization_percent: f64,
    };

    pub fn getUtilization(self: *const PoolManager) !std.ArrayList(PoolUtilization) {
        var result = try std.ArrayList(PoolUtilization).initCapacity(self.parent_allocator, self.pools.items.len);
        errdefer result.deinit(self.parent_allocator);

        for (self.pools.items) |managed| {
            const utilization: f64 = if (managed.pool.block_count > 0)
                @as(f64, @floatFromInt(managed.active_allocations)) / @as(f64, @floatFromInt(managed.pool.block_count)) * 100.0
            else
                0.0;

            try result.append(self.parent_allocator, .{
                .block_size = managed.pool.block_size,
                .total_blocks = managed.pool.block_count,
                .active_allocations = managed.active_allocations,
                .utilization_percent = utilization,
            });
        }

        return result;
    }

    /// Add a new pool with custom configuration
    pub fn addPool(self: *PoolManager, config: PoolConfig) !void {
        const pool = try Pool.init(self.parent_allocator, config.block_size, config.initial_count);
        try self.pools.append(.{
            .pool = pool,
            .config = config,
            .active_allocations = 0,
        });

        // Update fallback threshold if needed
        if (config.block_size > self.fallback_threshold) {
            self.fallback_threshold = config.block_size;
        }
    }
};

// Tests
test "pool manager basic allocation" {
    const testing = std.testing;

    var manager = try PoolManager.init(testing.allocator);
    defer manager.deinit();

    const allocator = manager.allocator();

    // Allocate from different size classes
    const small = try allocator.alloc(u8, 16);
    defer allocator.free(small);

    const medium = try allocator.alloc(u8, 128);
    defer allocator.free(medium);

    const large = try allocator.alloc(u8, 1024);
    defer allocator.free(large);

    try testing.expectEqual(@as(usize, 16), small.len);
    try testing.expectEqual(@as(usize, 128), medium.len);
    try testing.expectEqual(@as(usize, 1024), large.len);
}

test "pool manager utilization tracking" {
    const testing = std.testing;

    var manager = try PoolManager.init(testing.allocator);
    defer manager.deinit();

    const allocator = manager.allocator();

    // Allocate some blocks
    const alloc1 = try allocator.alloc(u8, 32);
    const alloc2 = try allocator.alloc(u8, 32);
    _ = alloc2;

    var utilization = try manager.getUtilization();
    defer utilization.deinit(testing.allocator);

    // Check that we have utilization data
    try testing.expect(utilization.items.len > 0);

    // Free one allocation
    allocator.free(alloc1);
}

test "pool manager custom size classes" {
    const testing = std.testing;

    const custom_configs = [_]PoolConfig{
        .{ .block_size = 8, .initial_count = 100 },
        .{ .block_size = 16, .initial_count = 100 },
        .{ .block_size = 32, .initial_count = 50 },
    };

    var manager = try PoolManager.initWithConfigs(testing.allocator, &custom_configs);
    defer manager.deinit();

    const allocator = manager.allocator();

    // Should use 8-byte pool
    const tiny = try allocator.alloc(u8, 8);
    defer allocator.free(tiny);

    try testing.expectEqual(@as(usize, 8), tiny.len);
}
