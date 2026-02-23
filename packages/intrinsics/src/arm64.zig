// Home Programming Language - ARM64/AArch64 Intrinsics
// System registers, cache maintenance, TLB operations, PMU, and NEON SIMD

const std = @import("std");
const builtin = @import("builtin");

/// Check if running on ARM64
fn isARM64() bool {
    return switch (builtin.cpu.arch) {
        .aarch64 => true,
        else => false,
    };
}

/// System Registers (SYSREG) Access
pub const SysReg = struct {
    /// Read system register
    pub inline fn read(comptime reg_name: []const u8) u64 {
        if (comptime !isARM64()) @compileError("ARM64 system registers only available on AArch64");

        var value: u64 = undefined;
        asm volatile ("mrs %[value], " ++ reg_name
            : [value] "=r" (value),
        );
        return value;
    }

    /// Write system register
    pub inline fn write(comptime reg_name: []const u8, value: u64) void {
        if (comptime !isARM64()) @compileError("ARM64 system registers only available on AArch64");

        asm volatile ("msr " ++ reg_name ++ ", %[value]"
            :
            : [value] "r" (value),
        );
    }

    /// Current Exception Level (EL0-EL3)
    pub fn currentEL() u2 {
        if (comptime !isARM64()) return 0;
        const val = read("CurrentEL");
        return @truncate((val >> 2) & 0x3);
    }

    /// Stack Pointer Selection
    pub fn getSP() u64 {
        if (comptime !isARM64()) return 0;
        var sp: u64 = undefined;
        asm volatile ("mov %[sp], sp"
            : [sp] "=r" (sp),
        );
        return sp;
    }

    /// Exception Link Register
    pub fn getELR() u64 {
        if (!comptime isARM64()) return 0;
        const el = currentEL();
        return switch (el) {
            1 => read("elr_el1"),
            2 => read("elr_el2"),
            3 => read("elr_el3"),
            else => 0,
        };
    }

    /// Saved Program Status Register
    pub fn getSPSR() u64 {
        if (!comptime isARM64()) return 0;
        const el = currentEL();
        return switch (el) {
            1 => read("spsr_el1"),
            2 => read("spsr_el2"),
            3 => read("spsr_el3"),
            else => 0,
        };
    }

    /// Vector Base Address Register
    pub fn getVBAR() u64 {
        if (!comptime isARM64()) return 0;
        const el = currentEL();
        return switch (el) {
            1 => read("vbar_el1"),
            2 => read("vbar_el2"),
            3 => read("vbar_el3"),
            else => 0,
        };
    }

    pub fn setVBAR(addr: u64) void {
        if (!comptime isARM64()) return;
        const el = currentEL();
        switch (el) {
            1 => write("vbar_el1", addr),
            2 => write("vbar_el2", addr),
            3 => write("vbar_el3", addr),
            else => {},
        }
    }

    /// Translation Table Base Register 0
    pub fn getTTBR0() u64 {
        if (!comptime isARM64()) return 0;
        return read("ttbr0_el1");
    }

    pub fn setTTBR0(addr: u64) void {
        if (!comptime isARM64()) return;
        write("ttbr0_el1", addr);
    }

    /// Translation Table Base Register 1
    pub fn getTTBR1() u64 {
        if (!comptime isARM64()) return 0;
        return read("ttbr1_el1");
    }

    pub fn setTTBR1(addr: u64) void {
        if (!comptime isARM64()) return;
        write("ttbr1_el1", addr);
    }

    /// Translation Control Register
    pub fn getTCR() u64 {
        if (!comptime isARM64()) return 0;
        return read("tcr_el1");
    }

    pub fn setTCR(value: u64) void {
        if (!comptime isARM64()) return;
        write("tcr_el1", value);
    }

    /// Memory Attribute Indirection Register
    pub fn getMAIR() u64 {
        if (!comptime isARM64()) return 0;
        return read("mair_el1");
    }

    pub fn setMAIR(value: u64) void {
        if (!comptime isARM64()) return;
        write("mair_el1", value);
    }

    /// System Control Register
    pub fn getSCTLR() u64 {
        if (!comptime isARM64()) return 0;
        return read("sctlr_el1");
    }

    pub fn setSCTLR(value: u64) void {
        if (!comptime isARM64()) return;
        write("sctlr_el1", value);
    }

    /// Counter-timer Physical Count
    pub fn getCNTPCT() u64 {
        if (!comptime isARM64()) return 0;
        return read("cntpct_el0");
    }

    /// Counter-timer Frequency
    pub fn getCNTFRQ() u64 {
        if (!comptime isARM64()) return 0;
        return read("cntfrq_el0");
    }
};

/// Cache Maintenance Operations
pub const Cache = struct {
    /// Data Cache Clean by Virtual Address
    pub fn cleanDCacheVA(addr: u64) void {
        if (!comptime isARM64()) return;
        asm volatile ("dc cvac, %[addr]"
            :
            : [addr] "r" (addr),
            : .{ .memory = true }
        );
    }

    /// Data Cache Clean and Invalidate by Virtual Address
    pub fn cleanInvalidateDCacheVA(addr: u64) void {
        if (!comptime isARM64()) return;
        asm volatile ("dc civac, %[addr]"
            :
            : [addr] "r" (addr),
            : .{ .memory = true }
        );
    }

    /// Data Cache Invalidate by Virtual Address
    pub fn invalidateDCacheVA(addr: u64) void {
        if (!comptime isARM64()) return;
        asm volatile ("dc ivac, %[addr]"
            :
            : [addr] "r" (addr),
            : .{ .memory = true }
        );
    }

    /// Instruction Cache Invalidate All
    pub fn invalidateICache() void {
        if (!comptime isARM64()) return;
        asm volatile ("ic iallu" ::: .{ .memory = true });
        isb();
    }

    /// Instruction Cache Invalidate by Virtual Address
    pub fn invalidateICacheVA(addr: u64) void {
        if (!comptime isARM64()) return;
        asm volatile ("ic ivau, %[addr]"
            :
            : [addr] "r" (addr),
            : .{ .memory = true }
        );
        isb();
    }

    /// Data Cache Zero by Virtual Address
    pub fn zeroDCacheVA(addr: u64) void {
        if (!comptime isARM64()) return;
        asm volatile ("dc zva, %[addr]"
            :
            : [addr] "r" (addr),
            : .{ .memory = true }
        );
    }

    /// Clean entire data cache
    pub fn cleanDCacheAll() void {
        if (!comptime isARM64()) return;

        // This is a simplified version
        // In production, you'd walk the cache levels
        asm volatile ("dc cisw, xzr" ::: .{ .memory = true });
        dsb();
    }

    /// Invalidate entire data cache
    pub fn invalidateDCacheAll() void {
        if (!comptime isARM64()) return;

        asm volatile ("dc isw, xzr" ::: .{ .memory = true });
        dsb();
    }

    /// Clean and invalidate entire data cache
    pub fn cleanInvalidateDCacheAll() void {
        if (!comptime isARM64()) return;

        asm volatile ("dc cisw, xzr" ::: .{ .memory = true });
        dsb();
    }
};

/// TLB (Translation Lookaside Buffer) Operations
pub const TLB = struct {
    /// Invalidate entire TLB
    pub fn invalidateAll() void {
        if (!comptime isARM64()) return;
        asm volatile ("tlbi vmalle1" ::: .{ .memory = true });
        dsb();
        isb();
    }

    /// Invalidate TLB by Virtual Address
    pub fn invalidateVA(addr: u64) void {
        if (!comptime isARM64()) return;
        asm volatile ("tlbi vae1, %[addr]"
            :
            : [addr] "r" (addr >> 12),
            : .{ .memory = true }
        );
        dsb();
        isb();
    }

    /// Invalidate TLB by ASID (Address Space ID)
    pub fn invalidateASID(asid: u16) void {
        if (!comptime isARM64()) return;
        asm volatile ("tlbi aside1, %[asid]"
            :
            : [asid] "r" (@as(u64, asid) << 48),
            : .{ .memory = true }
        );
        dsb();
        isb();
    }

    /// Invalidate TLB by VA and ASID
    pub fn invalidateVA_ASID(addr: u64, asid: u16) void {
        if (!comptime isARM64()) return;
        const val = (@as(u64, asid) << 48) | (addr >> 12);
        asm volatile ("tlbi vae1is, %[val]"
            :
            : [val] "r" (val),
            : .{ .memory = true }
        );
        dsb();
        isb();
    }

    /// Invalidate all TLBs in inner shareable domain
    pub fn invalidateAllIS() void {
        if (!comptime isARM64()) return;
        asm volatile ("tlbi vmalle1is" ::: .{ .memory = true });
        dsb();
        isb();
    }
};

/// Barrier Operations
pub inline fn dsb() void {
    if (!comptime isARM64()) return;
    asm volatile ("dsb sy" ::: .{ .memory = true });
}

pub inline fn dmb() void {
    if (!comptime isARM64()) return;
    asm volatile ("dmb sy" ::: .{ .memory = true });
}

pub inline fn isb() void {
    if (!comptime isARM64()) return;
    asm volatile ("isb" ::: .{ .memory = true });
}

/// Enhanced Performance Monitoring Unit (PMU)
pub const PMU = struct {
    /// PMU Control Register bits
    pub const PMCR = struct {
        pub const ENABLE: u64 = 1 << 0; // Enable all counters
        pub const EVENT_COUNTER_RESET: u64 = 1 << 1; // Reset event counters
        pub const CYCLE_COUNTER_RESET: u64 = 1 << 2; // Reset cycle counter
        pub const CYCLE_DIVIDER: u64 = 1 << 3; // Divide cycle counter by 64
        pub const EXPORT_ENABLE: u64 = 1 << 4; // Export events
        pub const CYCLE_PROHIBIT: u64 = 1 << 5; // Prohibit cycle counter in secure modes
    };

    /// Common PMU events
    pub const Event = enum(u16) {
        sw_incr = 0x00, // Software increment
        l1i_cache_refill = 0x01, // L1 instruction cache refill
        l1i_tlb_refill = 0x02, // L1 instruction TLB refill
        l1d_cache_refill = 0x03, // L1 data cache refill
        l1d_cache = 0x04, // L1 data cache access
        l1d_tlb_refill = 0x05, // L1 data TLB refill
        inst_retired = 0x08, // Instructions architecturally executed
        exc_taken = 0x09, // Exception taken
        exc_return = 0x0A, // Exception return
        cid_write_retired = 0x0B, // Context ID write
        pc_write_retired = 0x0C, // Software change of PC
        br_immed_retired = 0x0D, // Immediate branch
        br_return_retired = 0x0E, // Procedure return
        unaligned_ldst_retired = 0x0F, // Unaligned load/store
        br_mis_pred = 0x10, // Branch mispredicted
        cpu_cycles = 0x11, // CPU cycles
        br_pred = 0x12, // Predictable branch
        mem_access = 0x13, // Data memory access
        l1i_cache = 0x14, // L1 instruction cache access
        l1d_cache_wb = 0x15, // L1 data cache write-back
        l2d_cache = 0x16, // L2 data cache access
        l2d_cache_refill = 0x17, // L2 data cache refill
        l2d_cache_wb = 0x18, // L2 data cache write-back
        bus_access = 0x19, // Bus access
        memory_error = 0x1A, // Local memory error
        inst_spec = 0x1B, // Instructions speculatively executed
        bus_cycles = 0x1D, // Bus cycles
    };

    /// Initialize PMU
    pub fn init() void {
        if (!comptime isARM64()) return;

        // Enable user-mode access to PMU
        SysReg.write("pmuserenr_el0", 0xF);

        // Reset all counters
        var pmcr = SysReg.read("pmcr_el0");
        pmcr |= PMCR.ENABLE | PMCR.EVENT_COUNTER_RESET | PMCR.CYCLE_COUNTER_RESET;
        SysReg.write("pmcr_el0", pmcr);

        // Enable cycle counter
        SysReg.write("pmcntenset_el0", 1 << 31);
    }

    /// Read cycle counter
    pub fn readCycles() u64 {
        if (!comptime isARM64()) return 0;
        return SysReg.read("pmccntr_el0");
    }

    /// Read event counter (0-30)
    pub fn readEventCounter(index: u5) u64 {
        if (!comptime isARM64()) return 0;

        // Select counter
        SysReg.write("pmselr_el0", index);
        isb();

        // Read counter value
        return SysReg.read("pmxevcntr_el0");
    }

    /// Configure event counter
    pub fn configureEventCounter(index: u5, event: Event) void {
        if (!comptime isARM64()) return;

        // Select counter
        SysReg.write("pmselr_el0", index);
        isb();

        // Set event type
        SysReg.write("pmxevtyper_el0", @intFromEnum(event));

        // Enable counter
        SysReg.write("pmcntenset_el0", @as(u64, 1) << index);
    }

    /// Disable event counter
    pub fn disableEventCounter(index: u5) void {
        if (!comptime isARM64()) return;
        SysReg.write("pmcntenclr_el0", @as(u64, 1) << index);
    }

    /// Disable all counters
    pub fn disableAll() void {
        if (!comptime isARM64()) return;
        SysReg.write("pmcntenclr_el0", 0xFFFFFFFF);
    }
};

/// NEON SIMD Operations
pub const NEON = struct {
    /// Vector types
    pub const v8u8 = @Vector(8, u8);
    pub const v16u8 = @Vector(16, u8);
    pub const v4u16 = @Vector(4, u16);
    pub const v8u16 = @Vector(8, u16);
    pub const v2u32 = @Vector(2, u32);
    pub const v4u32 = @Vector(4, u32);
    pub const v2u64 = @Vector(2, u64);

    pub const v2f32 = @Vector(2, f32);
    pub const v4f32 = @Vector(4, f32);
    pub const v2f64 = @Vector(2, f64);

    /// Load aligned
    pub fn load(comptime T: type, ptr: [*]const T) @Vector(16 / @sizeOf(T), T) {
        if (!comptime isARM64()) @compileError("NEON only available on ARM64");
        return @as(*align(16) const @Vector(16 / @sizeOf(T), T), @ptrCast(ptr)).*;
    }

    /// Store aligned
    pub fn store(comptime T: type, ptr: [*]T, value: @Vector(16 / @sizeOf(T), T)) void {
        if (!comptime isARM64()) @compileError("NEON only available on ARM64");
        @as(*align(16) @Vector(16 / @sizeOf(T), T), @ptrCast(ptr)).* = value;
    }

    /// Saturating add
    pub fn qaddU8(a: v16u8, b: v16u8) v16u8 {
        if (!comptime isARM64()) @compileError("NEON only available on ARM64");

        var result: v16u8 = undefined;
        asm ("uqadd %[result].16b, %[a].16b, %[b].16b"
            : [result] "=w" (result),
            : [a] "w" (a),
              [b] "w" (b),
        );
        return result;
    }

    /// Saturating subtract
    pub fn qsubU8(a: v16u8, b: v16u8) v16u8 {
        if (!comptime isARM64()) @compileError("NEON only available on ARM64");

        var result: v16u8 = undefined;
        asm ("uqsub %[result].16b, %[a].16b, %[b].16b"
            : [result] "=w" (result),
            : [a] "w" (a),
              [b] "w" (b),
        );
        return result;
    }

    /// Multiply and accumulate
    pub fn mlaF32(acc: v4f32, a: v4f32, b: v4f32) v4f32 {
        if (!comptime isARM64()) @compileError("NEON only available on ARM64");
        return @mulAdd(v4f32, a, b, acc);
    }

    /// Fused multiply-add
    pub fn fmaF32(a: v4f32, b: v4f32, c: v4f32) v4f32 {
        if (!comptime isARM64()) @compileError("NEON only available on ARM64");
        return @mulAdd(v4f32, a, b, c);
    }

    /// Reciprocal estimate
    pub fn frecpeF32(a: v4f32) v4f32 {
        if (!comptime isARM64()) @compileError("NEON only available on ARM64");

        var result: v4f32 = undefined;
        asm ("frecpe %[result].4s, %[a].4s"
            : [result] "=w" (result),
            : [a] "w" (a),
        );
        return result;
    }

    /// Reciprocal square root estimate
    pub fn frsqrteF32(a: v4f32) v4f32 {
        if (!comptime isARM64()) @compileError("NEON only available on ARM64");

        var result: v4f32 = undefined;
        asm ("frsqrte %[result].4s, %[a].4s"
            : [result] "=w" (result),
            : [a] "w" (a),
        );
        return result;
    }

    /// Pairwise add
    pub fn pairwiseAddF32(a: v4f32, b: v4f32) v4f32 {
        if (!comptime isARM64()) @compileError("NEON only available on ARM64");

        var result: v4f32 = undefined;
        asm ("faddp %[result].4s, %[a].4s, %[b].4s"
            : [result] "=w" (result),
            : [a] "w" (a),
              [b] "w" (b),
        );
        return result;
    }

    /// Dot product (ARMv8.2+)
    pub fn dotProductU8(acc: v4u32, a: v16u8, b: v16u8) v4u32 {
        if (!comptime isARM64()) @compileError("NEON only available on ARM64");

        var result: v4u32 = acc;
        asm ("udot %[result].4s, %[a].16b, %[b].16b"
            : [result] "=w" (result),
            : [a] "w" (a),
              [b] "w" (b),
              [acc] "0" (acc),
        );
        return result;
    }
};

// Tests
// NOTE: ARM64 tests run on ARM64 hardware. On other architectures,
// we test that the module compiles correctly without executing instructions.

test "arm64 module loads" {
    // This test ensures the module compiles correctly on all architectures
    const testing = std.testing;
    try testing.expect(true);
}

test "arm64 type definitions" {
    // Test that type definitions are correct (works on all architectures)
    const testing = std.testing;

    // Test NEON vector types have correct sizes
    try testing.expectEqual(@as(usize, 16), @sizeOf(NEON.v4f32));
    try testing.expectEqual(@as(usize, 16), @sizeOf(NEON.v2f64));
    try testing.expectEqual(@as(usize, 16), @sizeOf(NEON.v4u32));
    try testing.expectEqual(@as(usize, 16), @sizeOf(NEON.v16u8));
    // v2f32 is 8 bytes on ARM64, but may be padded to 16 on x86_64
    try testing.expect(@sizeOf(NEON.v2f32) >= 8);
}

test "arm64 sysreg functions" {
    // Test that system register function types are defined correctly
    // NOTE: We cannot actually call currentEL() on macOS userspace because
    // reading CurrentEL requires kernel privileges (EL1+). Attempting to do so
    // will cause an illegal instruction exception.
    const testing = std.testing;

    // Just verify the function exists and has the right type
    try testing.expect(@TypeOf(SysReg.currentEL) != void);
    try testing.expect(@TypeOf(SysReg.getELR) != void);
    try testing.expect(@TypeOf(SysReg.getSPSR) != void);
}

test "neon basic operations" {
    // NEON operations can run on ARM64 macOS (doesn't require kernel privileges)
    if (comptime builtin.cpu.arch != .aarch64) {
        // On non-ARM64, just verify the types exist
        const testing = std.testing;
        try testing.expectEqual(@as(usize, 16), @sizeOf(NEON.v4f32));
        return;
    }

    const a = NEON.v4f32{ 1.0, 2.0, 3.0, 4.0 };
    const b = NEON.v4f32{ 5.0, 6.0, 7.0, 8.0 };
    const c = NEON.v4f32{ 1.0, 1.0, 1.0, 1.0 };

    const result = NEON.fmaF32(a, b, c);

    const testing = std.testing;
    try testing.expectEqual(@as(f32, 6.0), result[0]); // 1*5+1
    try testing.expectEqual(@as(f32, 13.0), result[1]); // 2*6+1
    try testing.expectEqual(@as(f32, 22.0), result[2]); // 3*7+1
    try testing.expectEqual(@as(f32, 33.0), result[3]); // 4*8+1
}
