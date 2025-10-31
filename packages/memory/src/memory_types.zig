// Home Programming Language - Memory Types
// Common types and errors for memory allocators

const std = @import("std");

// Allocator utilities
pub const AllocatorError = error{
    OutOfMemory,
    InvalidSize,
    InvalidAlignment,
    PoolExhausted,
    StackOverflow,
    DoubleFree,
    InvalidPointer,
};

// Memory statistics
pub const MemStats = struct {
    total_allocated: usize,
    total_freed: usize,
    current_usage: usize,
    peak_usage: usize,
    num_allocations: usize,
    num_frees: usize,

    pub fn init() MemStats {
        return .{
            .total_allocated = 0,
            .total_freed = 0,
            .current_usage = 0,
            .peak_usage = 0,
            .num_allocations = 0,
            .num_frees = 0,
        };
    }

    pub fn recordAlloc(self: *MemStats, size: usize) void {
        self.total_allocated += size;
        self.current_usage += size;
        self.num_allocations += 1;
        if (self.current_usage > self.peak_usage) {
            self.peak_usage = self.current_usage;
        }
    }

    pub fn recordFree(self: *MemStats, size: usize) void {
        self.total_freed += size;
        self.current_usage -= size;
        self.num_frees += 1;
    }
};
