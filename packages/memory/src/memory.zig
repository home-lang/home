// Home Programming Language - Memory Allocators
// Comprehensive memory management system

const std = @import("std");
const memory_types = @import("memory_types.zig");

// Re-export threading primitives for synchronization
const threading = @import("threading");
pub const Mutex = threading.Mutex;
pub const RwLock = threading.RwLock;

// Allocator implementations
pub const Arena = @import("arena.zig").Arena;
pub const Pool = @import("pool.zig").Pool;
pub const GeneralPurpose = @import("gpa.zig").GeneralPurpose;
pub const Stack = @import("stack.zig").StackAllocator;
pub const ThreadSafe = @import("thread_safe.zig").ThreadSafeAllocator;

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
    _ = Pool;
    _ = GeneralPurpose;
    _ = Stack;
    _ = Mutex;
    _ = RwLock;
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
