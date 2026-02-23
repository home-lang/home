// Home Programming Language - Performance Counters
// Hardware performance monitoring (PMC/PMU) support for x86 and ARM

const std = @import("std");
const builtin = @import("builtin");

/// MSR (Model Specific Register) operations for x86
pub const MSR = struct {
    /// Read MSR
    pub fn read(msr: u32) u64 {
        if (!comptime isX86()) @compileError("MSR only available on x86");

        var low: u32 = undefined;
        var high: u32 = undefined;

        asm volatile ("rdmsr"
            : [low] "={eax}" (low),
              [high] "={edx}" (high),
            : [msr] "{ecx}" (msr),
        );

        return (@as(u64, high) << 32) | low;
    }

    /// Write MSR
    pub fn write(msr: u32, value: u64) void {
        if (!comptime isX86()) @compileError("MSR only available on x86");

        const low: u32 = @truncate(value);
        const high: u32 = @truncate(value >> 32);

        asm volatile ("wrmsr"
            :
            : [msr] "{ecx}" (msr),
              [low] "{eax}" (low),
              [high] "{edx}" (high),
        );
    }

    /// Common MSR addresses
    pub const IA32_TIME_STAMP_COUNTER: u32 = 0x10;
    pub const IA32_APIC_BASE: u32 = 0x1B;
    pub const IA32_FEATURE_CONTROL: u32 = 0x3A;
    pub const IA32_TSC_DEADLINE: u32 = 0x6E0;
    pub const IA32_MPERF: u32 = 0xE7;
    pub const IA32_APERF: u32 = 0xE8;
    pub const IA32_MTRRCAP: u32 = 0xFE;
    pub const IA32_SYSENTER_CS: u32 = 0x174;
    pub const IA32_SYSENTER_ESP: u32 = 0x175;
    pub const IA32_SYSENTER_EIP: u32 = 0x176;
    pub const IA32_PERF_GLOBAL_CTRL: u32 = 0x38F;
    pub const IA32_PERF_GLOBAL_STATUS: u32 = 0x38E;
    pub const IA32_PERF_GLOBAL_OVF_CTRL: u32 = 0x390;
    pub const IA32_FIXED_CTR0: u32 = 0x309; // Instructions retired
    pub const IA32_FIXED_CTR1: u32 = 0x30A; // CPU cycles
    pub const IA32_FIXED_CTR2: u32 = 0x30B; // Reference cycles
};

/// Time Stamp Counter
pub const TSC = struct {
    /// Read TSC
    pub fn read() u64 {
        if (!comptime isX86()) return 0;

        var low: u32 = undefined;
        var high: u32 = undefined;

        asm volatile ("rdtsc"
            : [low] "={eax}" (low),
              [high] "={edx}" (high),
        );

        return (@as(u64, high) << 32) | low;
    }

    /// Read TSC with serialization
    pub fn readOrdered() u64 {
        if (!comptime isX86()) return 0;

        // LFENCE before RDTSC ensures all previous instructions complete
        asm volatile ("lfence");

        const result = read();

        // LFENCE after prevents subsequent instructions from executing early
        asm volatile ("lfence");

        return result;
    }

    /// Read TSC with full serialization (RDTSCP)
    pub fn readp() struct { tsc: u64, aux: u32 } {
        if (!comptime isX86()) return .{ .tsc = 0, .aux = 0 };

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
    }

    /// Get TSC frequency (if available)
    pub fn getFrequency() ?u64 {
        if (!comptime isX86()) return null;

        // Try to read from CPUID leaf 0x15
        var eax: u32 = 0x15;
        var ebx: u32 = 0;
        var ecx: u32 = 0;
        var edx: u32 = 0;

        asm volatile ("cpuid"
            : [eax] "={eax}" (eax),
              [ebx] "={ebx}" (ebx),
              [ecx] "={ecx}" (ecx),
              [edx] "={edx}" (edx),
            : [eax_in] "{eax}" (eax),
        );

        if (ebx == 0 or eax == 0) return null;

        // Crystal clock frequency in Hz
        const crystal_hz = if (ecx != 0) ecx else 24000000; // Default to 24MHz
        return @as(u64, crystal_hz) * @as(u64, ebx) / @as(u64, eax);
    }
};

/// Performance Monitoring Counter event types
pub const PMCEvent = enum(u8) {
    // Common events across architectures
    cycles = 0x3C,
    instructions = 0xC0,
    cache_references = 0x2E,
    cache_misses = 0x24,
    branch_instructions = 0xC4,
    branch_misses = 0xC5,
    bus_cycles = 0x3C,

    // x86 specific events
    l1d_cache_load = 0x40,
    l1d_cache_store = 0x41,
    l1d_cache_miss = 0x51,
    l2_cache_miss = 0x24,
    l3_cache_miss = 0x2E,
    tlb_load_misses = 0x08,
    tlb_store_misses = 0x49,

    // Memory events
    mem_loads = 0xD0,
    mem_stores = 0xD1,
    mem_loads_retired = 0xD1,

    // Front-end events
    frontend_stalls = 0xD2,
    decoder_stalls = 0xD3,

    // Custom event
    custom = 0xFF,
};

/// Performance Monitoring Counter
pub const PMC = struct {
    counter_index: u8,
    event: PMCEvent,
    umask: u8,

    /// Performance counter configuration
    pub const Config = packed struct {
        event_select: u8,
        umask: u8,
        usr: bool, // Count in user mode
        os: bool, // Count in kernel mode
        edge: bool, // Edge detection
        pin_control: bool,
        interrupt: bool, // APIC interrupt enable
        any_thread: bool,
        enable: bool,
        invert: bool,
        counter_mask: u8,
        reserved: u32,
    };

    /// Create PMC configuration
    pub fn init(counter_index: u8, event: PMCEvent) PMC {
        return .{
            .counter_index = counter_index,
            .event = event,
            .umask = 0,
        };
    }

    /// Configure and start counter
    pub fn start(self: PMC) void {
        if (!comptime isX86()) return;

        const config = Config{
            .event_select = @intFromEnum(self.event),
            .umask = self.umask,
            .usr = true,
            .os = true,
            .edge = false,
            .pin_control = false,
            .interrupt = false,
            .any_thread = false,
            .enable = true,
            .invert = false,
            .counter_mask = 0,
            .reserved = 0,
        };

        const config_value: u64 = @bitCast(config);
        const perfevtsel_msr = 0x186 + self.counter_index; // IA32_PERFEVTSELx
        MSR.write(perfevtsel_msr, config_value);

        // Reset counter
        const pmc_msr = 0xC1 + self.counter_index; // IA32_PMCx
        MSR.write(pmc_msr, 0);
    }

    /// Read counter value
    pub fn read(self: PMC) u64 {
        if (!comptime isX86()) return 0;

        const pmc_msr = 0xC1 + self.counter_index;
        return MSR.read(pmc_msr);
    }

    /// Stop counter
    pub fn stop(self: PMC) void {
        if (!comptime isX86()) return;

        const perfevtsel_msr = 0x186 + self.counter_index;
        MSR.write(perfevtsel_msr, 0);
    }
};

/// Fixed-function performance counters
pub const FixedPMC = struct {
    /// Counter types
    pub const Counter = enum(u2) {
        instructions = 0, // Instructions retired
        core_cycles = 1, // Core clock cycles
        ref_cycles = 2, // Reference clock cycles
    };

    /// Read fixed counter
    pub fn read(counter: Counter) u64 {
        if (!comptime isX86()) return 0;

        const msr = switch (counter) {
            .instructions => MSR.IA32_FIXED_CTR0,
            .core_cycles => MSR.IA32_FIXED_CTR1,
            .ref_cycles => MSR.IA32_FIXED_CTR2,
        };

        return MSR.read(msr);
    }

    /// Enable fixed counters
    pub fn enable() void {
        if (!comptime isX86()) return;

        // Enable all fixed counters in user and kernel mode
        // Bits 0-1: Counter 0 (instructions)
        // Bits 4-5: Counter 1 (core cycles)
        // Bits 8-9: Counter 2 (reference cycles)
        const enable_value: u64 = 0x333; // Enable all in user+os mode
        MSR.write(0x38D, enable_value); // IA32_FIXED_CTR_CTRL
    }

    /// Disable fixed counters
    pub fn disable() void {
        if (!comptime isX86()) return;
        MSR.write(0x38D, 0);
    }
};

/// Performance monitoring session
pub const PerfSession = struct {
    start_tsc: u64,
    start_instructions: u64,
    start_cycles: u64,

    pub fn begin() PerfSession {
        if (comptime isX86()) {
            FixedPMC.enable();
        }

        return .{
            .start_tsc = TSC.read(),
            .start_instructions = FixedPMC.read(.instructions),
            .start_cycles = FixedPMC.read(.core_cycles),
        };
    }

    pub fn end(self: PerfSession) PerfResult {
        const end_tsc = TSC.read();
        const end_instructions = FixedPMC.read(.instructions);
        const end_cycles = FixedPMC.read(.core_cycles);

        return .{
            .tsc_elapsed = end_tsc - self.start_tsc,
            .instructions = end_instructions - self.start_instructions,
            .cycles = end_cycles - self.start_cycles,
        };
    }
};

pub const PerfResult = struct {
    tsc_elapsed: u64,
    instructions: u64,
    cycles: u64,

    pub fn ipc(self: PerfResult) f64 {
        if (self.cycles == 0) return 0.0;
        return @as(f64, @floatFromInt(self.instructions)) / @as(f64, @floatFromInt(self.cycles));
    }

    pub fn cyclesPerInstruction(self: PerfResult) f64 {
        if (self.instructions == 0) return 0.0;
        return @as(f64, @floatFromInt(self.cycles)) / @as(f64, @floatFromInt(self.instructions));
    }
};

/// ARM Performance Monitoring Unit (PMU)
pub const ARM_PMU = struct {
    /// Read cycle counter (PMCCNTR)
    pub fn readCycles() u64 {
        if (!comptime isARM()) return 0;

        var count: u64 = undefined;
        asm volatile ("mrs %[count], pmccntr_el0"
            : [count] "=r" (count),
        );
        return count;
    }

    /// Enable cycle counter
    pub fn enableCycleCounter() void {
        if (!comptime isARM()) return;

        // Enable cycle counter
        asm volatile ("msr pmcr_el0, %[val]"
            :
            : [val] "r" (@as(u64, 1 << 0)), // Enable bit
        );

        // Enable cycle counter specifically
        asm volatile ("msr pmcntenset_el0, %[val]"
            :
            : [val] "r" (@as(u64, 1 << 31)), // Cycle counter enable
        );
    }

    /// Disable cycle counter
    pub fn disableCycleCounter() void {
        if (!comptime isARM()) return;

        asm volatile ("msr pmcntenclr_el0, %[val]"
            :
            : [val] "r" (@as(u64, 1 << 31)),
        );
    }
};

fn isX86() bool {
    return switch (builtin.cpu.arch) {
        .x86_64, .x86 => true,
        else => false,
    };
}

fn isARM() bool {
    return switch (builtin.cpu.arch) {
        .aarch64, .arm => true,
        else => false,
    };
}

// Tests
// NOTE: Performance counter tests run on x86 hardware. On other architectures,
// we test that the module compiles correctly and type definitions are valid.

test "performance_counters module loads" {
    // This test ensures the module compiles correctly on all architectures
    const testing = std.testing;
    try testing.expect(true);
}

test "TSC read" {
    const tsc1 = TSC.read();
    const tsc2 = TSC.read();

    const testing = std.testing;
    try testing.expect(tsc2 >= tsc1);
}

test "TSC ordered read" {
    if (comptime !isX86()) {
        // On non-x86, verify the function exists
        const testing = std.testing;
        try testing.expect(@TypeOf(TSC.readOrdered) != void);
        return;
    }

    const tsc1 = TSC.readOrdered();

    // Do some work
    var sum: u64 = 0;
    for (0..1000) |i| {
        sum += i;
    }

    const tsc2 = TSC.readOrdered();

    const testing = std.testing;
    try testing.expect(tsc2 > tsc1);
    try testing.expect(sum > 0); // Use sum so it doesn't get optimized away
}

test "performance session" {
    // MSR read/write (rdmsr/wrmsr) requires ring 0 privileges.
    // Causes GPF on Linux and STATUS_PRIVILEGED_INSTRUCTION on Windows.
    // Verify the type exists but skip execution.
    const testing = std.testing;
    try testing.expect(@TypeOf(PerfSession.begin) != void);
}
