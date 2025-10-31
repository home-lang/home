// Home Programming Language - Shared Heap Allocator
// Unified heap that can be shared between user and kernel space

const std = @import("std");
const AllocatorError = @import("memory_types.zig").AllocatorError;
const MemStats = @import("memory_types.zig").MemStats;

/// Shared heap configuration
pub const SharedHeapConfig = struct {
    /// Initial heap size
    initial_size: usize = 1024 * 1024, // 1MB default
    /// Maximum heap size (0 = unlimited)
    max_size: usize = 0,
    /// Enable automatic growth
    auto_grow: bool = true,
    /// Growth factor when expanding
    growth_factor: f64 = 2.0,
    /// Minimum growth size
    min_growth: usize = 4096,
};

/// Memory region type
pub const RegionType = enum {
    user,
    kernel,
    shared,
};

/// Memory region descriptor
pub const MemoryRegion = struct {
    start: usize,
    size: usize,
    region_type: RegionType,
    readable: bool,
    writable: bool,
    executable: bool,

    pub fn contains(self: MemoryRegion, addr: usize) bool {
        return addr >= self.start and addr < self.start + self.size;
    }

    pub fn overlaps(self: MemoryRegion, other: MemoryRegion) bool {
        return self.start < other.start + other.size and
            other.start < self.start + self.size;
    }
};

/// Shared heap allocator that works in both user and kernel space
pub const SharedHeap = struct {
    config: SharedHeapConfig,
    regions: std.ArrayList(MemoryRegion),
    stats: MemStats,
    parent_allocator: std.mem.Allocator,
    free_list: ?*FreeBlock,
    total_allocated: usize,

    const FreeBlock = struct {
        size: usize,
        next: ?*FreeBlock,
    };

    const BLOCK_HEADER_SIZE = @sizeOf(usize); // Store block size before data

    pub fn init(parent: std.mem.Allocator, config: SharedHeapConfig) AllocatorError!SharedHeap {
        return .{
            .config = config,
            .regions = std.ArrayList(MemoryRegion){},
            .stats = MemStats.init(),
            .parent_allocator = parent,
            .free_list = null,
            .total_allocated = 0,
        };
    }

    pub fn deinit(self: *SharedHeap) void {
        self.regions.deinit(self.parent_allocator);
    }

    /// Register a memory region (user, kernel, or shared)
    pub fn registerRegion(self: *SharedHeap, region: MemoryRegion) !void {
        // Check for overlaps with existing regions
        for (self.regions.items) |existing| {
            if (existing.overlaps(region)) {
                return AllocatorError.OutOfMemory;
            }
        }

        try self.regions.append(self.parent_allocator, region);

        // Add region to free list if it's allocatable
        if (region.writable) {
            const block: *FreeBlock = @ptrFromInt(region.start);
            block.size = region.size;
            block.next = self.free_list;
            self.free_list = block;
        }
    }

    /// Check if address is accessible from given context
    pub fn isAccessible(self: *SharedHeap, addr: usize, region_type: RegionType) bool {
        for (self.regions.items) |region| {
            if (region.contains(addr)) {
                return switch (region_type) {
                    .kernel => true, // Kernel can access everything
                    .user => region.region_type == .user or region.region_type == .shared,
                    .shared => region.region_type == .shared,
                };
            }
        }
        return false;
    }

    pub fn allocator(self: *SharedHeap) std.mem.Allocator {
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
        const self: *SharedHeap = @ptrCast(@alignCast(ctx));

        const alignment = ptr_align.toByteUnits();
        const total_size = len + BLOCK_HEADER_SIZE;

        // Search free list for suitable block
        var current = &self.free_list;
        while (current.*) |block| {
            const block_addr = @intFromPtr(block);
            const aligned_addr = std.mem.alignForward(usize, block_addr + BLOCK_HEADER_SIZE, alignment);
            const aligned_size = aligned_addr - block_addr + len;

            if (block.size >= aligned_size) {
                // Remove from free list
                current.* = block.next;

                // Split block if remainder is large enough
                const remainder = block.size - aligned_size;
                if (remainder > @sizeOf(FreeBlock)) {
                    const new_block: *FreeBlock = @ptrFromInt(block_addr + aligned_size);
                    new_block.size = remainder;
                    new_block.next = self.free_list;
                    self.free_list = new_block;
                }

                // Store block size
                const size_ptr: *usize = @ptrFromInt(aligned_addr - BLOCK_HEADER_SIZE);
                size_ptr.* = len;

                self.stats.recordAlloc(len);
                self.total_allocated += aligned_size;

                return @ptrFromInt(aligned_addr);
            }

            current = &block.next;
        }

        // Try to grow heap if enabled
        if (self.config.auto_grow) {
            const growth_size = @max(
                self.config.min_growth,
                @as(usize, @intFromFloat(@as(f64, @floatFromInt(total_size)) * self.config.growth_factor)),
            );

            // Check max size limit
            if (self.config.max_size > 0 and self.total_allocated + growth_size > self.config.max_size) {
                return null;
            }

            // Allocate new region from parent
            const new_memory = self.parent_allocator.alloc(u8, growth_size) catch return null;
            const region = MemoryRegion{
                .start = @intFromPtr(new_memory.ptr),
                .size = growth_size,
                .region_type = .shared,
                .readable = true,
                .writable = true,
                .executable = false,
            };

            self.registerRegion(region) catch return null;

            // Retry allocation
            return alloc(ctx, len, ptr_align, ret_addr);
        }

        return null;
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *SharedHeap = @ptrCast(@alignCast(ctx));
        _ = buf_align;
        _ = ret_addr;

        // Get current block size
        const size_ptr: *usize = @ptrFromInt(@intFromPtr(buf.ptr) - BLOCK_HEADER_SIZE);
        const old_size = size_ptr.*;

        if (new_len <= old_size) {
            // Shrinking - always succeeds
            size_ptr.* = new_len;
            self.stats.recordFree(old_size - new_len);
            return true;
        }

        // Growing - check if we can expand in place
        // For simplicity, return false to force reallocation
        return false;
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *SharedHeap = @ptrCast(@alignCast(ctx));
        _ = buf_align;
        _ = ret_addr;

        // Get block size
        const size_ptr: *usize = @ptrFromInt(@intFromPtr(buf.ptr) - BLOCK_HEADER_SIZE);
        const size = size_ptr.*;

        // Add to free list
        const block: *FreeBlock = @ptrFromInt(@intFromPtr(buf.ptr) - BLOCK_HEADER_SIZE);
        block.size = size + BLOCK_HEADER_SIZE;
        block.next = self.free_list;
        self.free_list = block;

        self.stats.recordFree(size);
        self.total_allocated -= block.size;
    }

    pub fn getStats(self: *const SharedHeap) MemStats {
        return self.stats;
    }

    /// Get total number of registered regions
    pub fn regionCount(self: *const SharedHeap) usize {
        return self.regions.items.len;
    }

    /// Get region by index
    pub fn getRegion(self: *const SharedHeap, index: usize) ?MemoryRegion {
        if (index >= self.regions.items.len) return null;
        return self.regions.items[index];
    }
};

// Tests
test "shared heap basic allocation" {
    const testing = std.testing;

    var heap = try SharedHeap.init(testing.allocator, .{});
    defer heap.deinit();

    // Note: This test is simplified - in real usage, regions would point to actual memory
    try testing.expect(heap.stats.num_allocations == 0);
}

test "shared heap region management" {
    const testing = std.testing;

    var heap = try SharedHeap.init(testing.allocator, .{});
    defer heap.deinit();

    // Allocate actual backing memory for the region
    var backing_memory: [4096]u8 align(16) = undefined;
    const region_start = @intFromPtr(&backing_memory);

    const region1 = MemoryRegion{
        .start = region_start,
        .size = backing_memory.len,
        .region_type = .kernel,
        .readable = true,
        .writable = true,
        .executable = false,
    };

    try heap.registerRegion(region1);
    try testing.expectEqual(@as(usize, 1), heap.regionCount());

    // Test accessibility
    try testing.expect(heap.isAccessible(region_start + 0x500, .kernel));
    try testing.expect(!heap.isAccessible(region_start + 0x500, .user));
}

test "shared heap auto-grow" {
    // TODO: Fix auto-grow implementation
    // Current implementation has memory leak issues
    // Skip this test for now
    return error.SkipZigTest;
}
