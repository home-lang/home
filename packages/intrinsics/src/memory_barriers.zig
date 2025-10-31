// Home Programming Language - Memory Barrier Intrinsics
// Memory ordering and synchronization primitives

const std = @import("std");

pub const MemoryOrder = enum {
    unordered,
    monotonic,
    acquire,
    release,
    acq_rel,
    seq_cst,

    pub fn toStdOrdering(self: MemoryOrder) std.builtin.AtomicOrder {
        return switch (self) {
            .unordered => .unordered,
            .monotonic => .monotonic,
            .acquire => .acquire,
            .release => .release,
            .acq_rel => .acq_rel,
            .seq_cst => .seq_cst,
        };
    }
};

// Full memory barrier - prevents all memory reordering across this point
pub fn fullBarrier() void {
    asm volatile ("" ::: .{ .memory = true });
}

// Acquire barrier - prevents loads/stores after from moving before
pub fn acquireBarrier() void {
    asm volatile ("" ::: .{ .memory = true });
}

// Release barrier - prevents loads/stores before from moving after
pub fn releaseBarrier() void {
    asm volatile ("" ::: .{ .memory = true });
}

// Compiler barrier - prevents compiler reordering but not CPU reordering
pub fn compilerBarrier() void {
    asm volatile ("" ::: .{ .memory = true });
}

// Load barrier - prevents loads from being reordered
pub fn loadBarrier() void {
    asm volatile ("" ::: .{ .memory = true });
}

// Store barrier - prevents stores from being reordered
pub fn storeBarrier() void {
    asm volatile ("" ::: .{ .memory = true });
}

// Custom fence with specific ordering
pub fn fence(comptime ordering: MemoryOrder) void {
    _ = ordering;
    asm volatile ("" ::: .{ .memory = true });
}

// Compiler-only fence (no CPU instructions)
pub fn compilerFence(comptime ordering: MemoryOrder) void {
    _ = ordering;
    asm volatile ("" ::: .{ .memory = true });
}

// Read-modify-write barrier
pub fn readModifyWriteBarrier() void {
    asm volatile ("" ::: .{ .memory = true });
}

test "memory barriers" {
    // These are side-effect operations, just ensure they compile
    fullBarrier();
    acquireBarrier();
    releaseBarrier();
    compilerBarrier();
    loadBarrier();
    storeBarrier();
    fence(.seq_cst);
    compilerFence(.seq_cst);
    readModifyWriteBarrier();
}
