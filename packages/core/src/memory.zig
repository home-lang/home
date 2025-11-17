// Home Language - Core Memory Module
// Advanced memory management for game engines

const std = @import("std");
const pool = @import("../../basics/src/memory/pool.zig");

pub const Allocator = std.mem.Allocator;
pub const ObjectPool = pool.ObjectPool;
pub const MemoryPool = pool.MemoryPool;
pub const TieredAllocator = pool.TieredAllocator;

/// Memory statistics
pub const MemoryStats = struct {
    total_allocated: usize,
    total_freed: usize,
    current_allocated: usize,
    peak_allocated: usize,
    allocation_count: u64,
    free_count: u64,

    pub fn init() MemoryStats {
        return .{
            .total_allocated = 0,
            .total_freed = 0,
            .current_allocated = 0,
            .peak_allocated = 0,
            .allocation_count = 0,
            .free_count = 0,
        };
    }
};

/// Tracking allocator wrapper
pub const TrackingAllocator = struct {
    backing_allocator: Allocator,
    stats: MemoryStats,

    pub fn init(backing_allocator: Allocator) TrackingAllocator {
        return .{
            .backing_allocator = backing_allocator,
            .stats = MemoryStats.init(),
        };
    }

    pub fn allocator(self: *TrackingAllocator) Allocator {
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
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing_allocator.rawAlloc(len, ptr_align, ret_addr);
        if (result) |ptr| {
            self.stats.total_allocated += len;
            self.stats.current_allocated += len;
            self.stats.allocation_count += 1;
            if (self.stats.current_allocated > self.stats.peak_allocated) {
                self.stats.peak_allocated = self.stats.current_allocated;
            }
        }
        return result;
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing_allocator.rawResize(buf, buf_align, new_len, ret_addr);
        if (result) {
            const old_len = buf.len;
            if (new_len > old_len) {
                const diff = new_len - old_len;
                self.stats.total_allocated += diff;
                self.stats.current_allocated += diff;
            } else {
                const diff = old_len - new_len;
                self.stats.total_freed += diff;
                self.stats.current_allocated -= diff;
                self.stats.free_count += 1;
            }
        }
        return result;
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        self.backing_allocator.rawFree(buf, buf_align, ret_addr);
        self.stats.total_freed += buf.len;
        self.stats.current_allocated -= buf.len;
        self.stats.free_count += 1;
    }

    pub fn getStats(self: *const TrackingAllocator) MemoryStats {
        return self.stats;
    }

    pub fn printStats(self: *const TrackingAllocator) void {
        std.debug.print("=== Memory Statistics ===\n", .{});
        std.debug.print("Total Allocated: {} bytes\n", .{self.stats.total_allocated});
        std.debug.print("Total Freed: {} bytes\n", .{self.stats.total_freed});
        std.debug.print("Currently Allocated: {} bytes\n", .{self.stats.current_allocated});
        std.debug.print("Peak Allocated: {} bytes\n", .{self.stats.peak_allocated});
        std.debug.print("Allocation Count: {}\n", .{self.stats.allocation_count});
        std.debug.print("Free Count: {}\n", .{self.stats.free_count});
    }
};

/// Copy memory
pub fn copy(dest: []u8, source: []const u8) void {
    @memcpy(dest[0..source.len], source);
}

/// Set memory to a value
pub fn set(dest: []u8, value: u8) void {
    @memset(dest, value);
}

/// Zero memory
pub fn zero(dest: []u8) void {
    @memset(dest, 0);
}

/// Compare memory
pub fn compare(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
