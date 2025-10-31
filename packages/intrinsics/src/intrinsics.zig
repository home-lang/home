// Home Programming Language - Hardware Intrinsics
// Low-level hardware operations and SIMD support

const std = @import("std");

// Intrinsic implementations
pub const simd = @import("simd.zig");
pub const atomic = @import("atomic.zig");
pub const cpu = @import("cpu.zig");
pub const bits = @import("bits.zig");
pub const memory = @import("memory_barriers.zig");
pub const prefetch = @import("prefetch.zig");

// Re-export commonly used types
pub const AtomicValue = atomic.AtomicValue;
pub const AtomicOrdering = atomic.AtomicOrdering;
pub const CpuFeatures = cpu.CpuFeatures;
pub const MemoryOrder = memory.MemoryOrder;

test "intrinsics module imports" {
    _ = simd;
    _ = atomic;
    _ = cpu;
    _ = bits;
    _ = memory;
    _ = prefetch;
}
