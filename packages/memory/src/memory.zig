// Home Programming Language - Memory Allocators
// Comprehensive memory management system

const std = @import("std");
const memory_types = @import("memory_types.zig");

// Re-export threading primitives for synchronization (when available)
// In standalone tests, these won't be available but aren't needed
const has_threading = @import("builtin").is_test == false;
pub const Mutex = if (has_threading) @import("threading").Mutex else void;
pub const RwLock = if (has_threading) @import("threading").RwLock else void;

// Allocator implementations
pub const Arena = @import("arena.zig").Arena;
pub const ArenaConfig = @import("arena.zig").ArenaConfig;
pub const Pool = @import("pool.zig").Pool;
pub const PoolManager = @import("pool_manager.zig").PoolManager;
pub const PoolConfig = @import("pool_manager.zig").PoolConfig;
pub const GeneralPurpose = @import("gpa.zig").GeneralPurpose;
pub const Stack = @import("stack.zig").StackAllocator;
pub const ThreadSafe = @import("thread_safe.zig").ThreadSafeAllocator;
pub const SharedHeap = @import("shared_heap.zig").SharedHeap;
pub const SharedHeapConfig = @import("shared_heap.zig").SharedHeapConfig;
pub const MemoryRegion = @import("shared_heap.zig").MemoryRegion;
pub const RegionType = @import("shared_heap.zig").RegionType;
pub const KernelHeap = @import("kernel_heap.zig").KernelHeap;
pub const KernelHeapConfig = @import("kernel_heap.zig").KernelHeapConfig;

// Re-export memory types
pub const AllocatorError = memory_types.AllocatorError;
pub const MemStats = memory_types.MemStats;

// Allocator interface wrapper
pub const Allocator = std.mem.Allocator;

// Helper functions
pub fn alignForward(ptr: usize, alignment: usize) usize {
    const mask = alignment - 1;
    return (ptr + mask) & ~mask;
}

pub fn isAligned(ptr: usize, alignment: usize) bool {
    return ptr & (alignment - 1) == 0;
}

pub fn isPowerOfTwo(n: usize) bool {
    return n > 0 and (n & (n - 1)) == 0;
}

test "memory module imports" {
    _ = Arena;
    _ = ArenaConfig;
    _ = Pool;
    _ = PoolManager;
    _ = PoolConfig;
    _ = GeneralPurpose;
    _ = Stack;
    _ = SharedHeap;
    _ = SharedHeapConfig;
    _ = MemoryRegion;
    _ = RegionType;
    _ = KernelHeap;
    _ = KernelHeapConfig;
}

test "align forward" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 16), alignForward(15, 16));
    try testing.expectEqual(@as(usize, 16), alignForward(16, 16));
    try testing.expectEqual(@as(usize, 32), alignForward(17, 16));
}

test "memory stats" {
    var stats = MemStats.init();
    stats.recordAlloc(100);
    stats.recordAlloc(200);

    const testing = std.testing;
    try testing.expectEqual(@as(usize, 300), stats.total_allocated);
    try testing.expectEqual(@as(usize, 300), stats.current_usage);
    try testing.expectEqual(@as(usize, 2), stats.num_allocations);

    stats.recordFree(100);
    try testing.expectEqual(@as(usize, 200), stats.current_usage);
}
