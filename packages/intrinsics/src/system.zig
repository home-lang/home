// Home Programming Language - System Intrinsics
// Low-level system instructions and operations

const std = @import("std");
const builtin = @import("builtin");

// Trap/breakpoint
pub fn debugTrap() noreturn {
    @trap();
}

// Breakpoint for debugger
pub fn breakpoint() void {
    @breakpoint();
}

// Return address
pub fn returnAddress(level: u32) usize {
    _ = level; // Level is reserved for future use
    return @returnAddress();
}

// Frame address
pub fn frameAddress() usize {
    return @frameAddress();
}

// Compiler barrier - prevents reordering
pub fn compilerBarrier() void {
    asm volatile ("" ::: .{ .memory = true });
}

// Pause instruction for spin loops (x86 PAUSE, ARM YIELD)
pub fn pause() void {
    std.atomic.spinLoopHint();
}

// Serialize execution
pub fn serialize() void {
    switch (builtin.cpu.arch) {
        .x86_64, .x86 => {
            // MFENCE on x86
            asm volatile ("mfence" ::: .{ .memory = true });
        },
        .aarch64, .arm => {
            // DMB on ARM
            asm volatile ("dmb sy" ::: .{ .memory = true });
        },
        else => compilerBarrier(),
    }
}

// CPU ID and feature detection (x86)
pub const CpuId = struct {
    pub const Result = struct {
        eax: u32,
        ebx: u32,
        ecx: u32,
        edx: u32,
    };

    pub fn isAvailable() bool {
        return switch (builtin.cpu.arch) {
            .x86_64, .x86 => true,
            else => false,
        };
    }

    pub fn query(leaf: u32, subleaf: u32) Result {
        if (!isAvailable()) {
            return .{ .eax = 0, .ebx = 0, .ecx = 0, .edx = 0 };
        }

        switch (builtin.cpu.arch) {
            .x86_64, .x86 => {
                var eax: u32 = leaf;
                var ebx: u32 = 0;
                var ecx: u32 = subleaf;
                var edx: u32 = 0;

                asm volatile ("cpuid"
                    : [eax] "={eax}" (eax),
                      [ebx] "={ebx}" (ebx),
                      [ecx] "={ecx}" (ecx),
                      [edx] "={edx}" (edx),
                    : [eax_in] "{eax}" (eax),
                      [ecx_in] "{ecx}" (ecx),
                );

                return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
            },
            else => return .{ .eax = 0, .ebx = 0, .ecx = 0, .edx = 0 },
        }
    }

    pub fn getVendor() [12]u8 {
        const result = query(0, 0);
        var vendor: [12]u8 = undefined;

        std.mem.writeInt(u32, vendor[0..4], result.ebx, .little);
        std.mem.writeInt(u32, vendor[4..8], result.edx, .little);
        std.mem.writeInt(u32, vendor[8..12], result.ecx, .little);

        return vendor;
    }

    pub fn getFeatures() struct { ecx: u32, edx: u32 } {
        const result = query(1, 0);
        return .{ .ecx = result.ecx, .edx = result.edx };
    }
};

// Read Time Stamp Counter
pub fn readTSC() u64 {
    switch (builtin.cpu.arch) {
        .x86_64, .x86 => {
            var low: u32 = undefined;
            var high: u32 = undefined;

            asm volatile ("rdtsc"
                : [low] "={eax}" (low),
                  [high] "={edx}" (high),
            );

            return (@as(u64, high) << 32) | low;
        },
        .aarch64 => {
            var value: u64 = undefined;
            asm volatile ("mrs %[value], cntvct_el0"
                : [value] "=r" (value),
            );
            return value;
        },
        else => return 0,
    }
}

// Read Time Stamp Counter and Processor ID (x86 only)
pub fn readTSCP() struct { tsc: u64, aux: u32 } {
    switch (builtin.cpu.arch) {
        .x86_64, .x86 => {
            var low: u32 = undefined;
            var high: u32 = undefined;
            var aux: u32 = undefined;

            asm volatile ("rdtscp"
                : [low] "={eax}" (low),
                  [high] "={edx}" (high),
                  [aux] "={ecx}" (aux),
            );

            return .{
                .tsc = (@as(u64, high) << 32) | low,
                .aux = aux,
            };
        },
        else => return .{ .tsc = 0, .aux = 0 },
    }
}

// Cache line flush
pub fn cacheLineFlush(ptr: *const anyopaque) void {
    switch (builtin.cpu.arch) {
        .x86_64, .x86 => {
            asm volatile ("clflush (%[ptr])"
                :
                : [ptr] "r" (ptr),
                : .{ .memory = true }
            );
        },
        .aarch64, .arm => {
            asm volatile ("dc civac, %[ptr]"
                :
                : [ptr] "r" (ptr),
                : .{ .memory = true }
            );
        },
        else => {},
    }
}

// Cache line flush with writeback
pub fn cacheLineFlushOpt(ptr: *const anyopaque) void {
    switch (builtin.cpu.arch) {
        .x86_64, .x86 => {
            asm volatile ("clflushopt (%[ptr])"
                :
                : [ptr] "r" (ptr),
                : .{ .memory = true }
            );
        },
        else => cacheLineFlush(ptr),
    }
}

// Cache line write back
pub fn cacheLineWriteBack(ptr: *const anyopaque) void {
    switch (builtin.cpu.arch) {
        .x86_64, .x86 => {
            asm volatile ("clwb (%[ptr])"
                :
                : [ptr] "r" (ptr),
                : .{ .memory = true }
            );
        },
        .aarch64, .arm => {
            asm volatile ("dc cvac, %[ptr]"
                :
                : [ptr] "r" (ptr),
                : .{ .memory = true }
            );
        },
        else => {},
    }
}

// Invalidate TLB entry
pub fn invlpg(ptr: *const anyopaque) void {
    switch (builtin.cpu.arch) {
        .x86_64, .x86 => {
            asm volatile ("invlpg (%[ptr])"
                :
                : [ptr] "r" (ptr),
                : .{ .memory = true }
            );
        },
        .aarch64, .arm => {
            asm volatile ("tlbi vaae1, %[ptr]"
                :
                : [ptr] "r" (@intFromPtr(ptr)),
                : .{ .memory = true }
            );
        },
        else => {},
    }
}

// Wait for interrupt (power management)
pub fn waitForInterrupt() void {
    switch (builtin.cpu.arch) {
        .x86_64, .x86 => {
            asm volatile ("hlt");
        },
        .aarch64, .arm => {
            asm volatile ("wfi");
        },
        else => {},
    }
}

// Wait for event (ARM)
pub fn waitForEvent() void {
    switch (builtin.cpu.arch) {
        .aarch64, .arm => {
            asm volatile ("wfe");
        },
        else => pause(),
    }
}

// Send event (ARM)
pub fn sendEvent() void {
    switch (builtin.cpu.arch) {
        .aarch64, .arm => {
            asm volatile ("sev");
        },
        else => {},
    }
}

// Instruction synchronization barrier
pub fn isb() void {
    switch (builtin.cpu.arch) {
        .aarch64, .arm => {
            asm volatile ("isb" ::: .{ .memory = true });
        },
        else => compilerBarrier(),
    }
}

// Data synchronization barrier
pub fn dsb() void {
    switch (builtin.cpu.arch) {
        .aarch64, .arm => {
            asm volatile ("dsb sy" ::: .{ .memory = true });
        },
        .x86_64, .x86 => {
            asm volatile ("mfence" ::: .{ .memory = true });
        },
        else => compilerBarrier(),
    }
}

// Data memory barrier
pub fn dmb() void {
    switch (builtin.cpu.arch) {
        .aarch64, .arm => {
            asm volatile ("dmb sy" ::: .{ .memory = true });
        },
        else => compilerBarrier(),
    }
}

// System register access (ARM)
pub fn readSystemRegister(comptime reg: []const u8) u64 {
    if (builtin.cpu.arch != .aarch64) {
        @compileError("System register access only available on ARM64");
    }

    var value: u64 = undefined;
    asm volatile ("mrs %[value], " ++ reg
        : [value] "=r" (value),
    );
    return value;
}

pub fn writeSystemRegister(comptime reg: []const u8, value: u64) void {
    if (builtin.cpu.arch != .aarch64) {
        @compileError("System register access only available on ARM64");
    }

    asm volatile ("msr " ++ reg ++ ", %[value]"
        :
        : [value] "r" (value),
        : .{ .memory = true }
    );
}

// Model-specific register access (x86)
pub fn readMSR(msr: u32) u64 {
    if (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .x86) {
        @compileError("MSR access only available on x86/x86_64");
    }

    var low: u32 = undefined;
    var high: u32 = undefined;

    asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [msr] "{ecx}" (msr),
    );

    return (@as(u64, high) << 32) | low;
}

pub fn writeMSR(msr: u32, value: u64) void {
    if (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .x86) {
        @compileError("MSR access only available on x86/x86_64");
    }

    const low: u32 = @truncate(value);
    const high: u32 = @truncate(value >> 32);

    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [low] "{eax}" (low),
          [high] "{edx}" (high),
        : .{ .memory = true }
    );
}

test "system intrinsics" {
    // Test non-privileged operations
    pause();
    compilerBarrier();

    const addr = returnAddress(0);
    _ = addr;

    const frame = frameAddress();
    _ = frame;

    // Test TSC
    const tsc1 = readTSC();
    const tsc2 = readTSC();
    const testing = std.testing;
    try testing.expect(tsc2 >= tsc1);
}

test "cpuid" {
    // CPUID is only available on x86
    if (!CpuId.isAvailable()) {
        // On non-x86, verify the type exists and test passes
        const testing = std.testing;
        try testing.expect(@TypeOf(CpuId.isAvailable) != void);
        return;
    }

    const vendor = CpuId.getVendor();
    _ = vendor;

    const features = CpuId.getFeatures();
    _ = features;
}
