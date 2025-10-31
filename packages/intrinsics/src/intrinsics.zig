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
pub const crypto = @import("crypto.zig");
pub const bmi = @import("bmi.zig");
pub const float = @import("float.zig");
pub const system = @import("system.zig");
pub const x86_simd = @import("x86_simd.zig");
pub const performance = @import("performance_counters.zig");
pub const arm64 = @import("arm64.zig");

// Re-export commonly used types
pub const AtomicValue = atomic.AtomicValue;
pub const AtomicOrdering = atomic.AtomicOrdering;
pub const CpuFeatures = cpu.CpuFeatures;
pub const MemoryOrder = memory.MemoryOrder;

// Re-export commonly used functions
pub const clz = bits.countLeadingZeros;
pub const ctz = bits.countTrailingZeros;
pub const popcount = bits.popCount;
pub const bswap = bits.byteSwap;
pub const bitreverse = bits.bitReverse;

test "intrinsics module imports" {
    _ = simd;
    _ = atomic;
    _ = cpu;
    _ = bits;
    _ = memory;
    _ = prefetch;
    _ = crypto;
    _ = bmi;
    _ = float;
    _ = system;
    _ = x86_simd;
    _ = performance;
    _ = arm64;
}
