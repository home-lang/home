// Home Programming Language - Timer Subsystem
// PIT, HPET, TSC, and timer management

const Basics = @import("basics");
const assembly = @import("asm.zig");
const acpi = @import("acpi.zig");
const atomic = @import("atomic.zig");
const sync = @import("sync.zig");

// ============================================================================
// PIT (Programmable Interval Timer)
// ============================================================================

pub const Pit = struct {
    const CHANNEL0: u16 = 0x40;
    const COMMAND: u16 = 0x43;
    const FREQUENCY: u32 = 1193182; // Base frequency in Hz

    pub fn init(frequency: u32) void {
        const divisor: u16 = @intCast(FREQUENCY / frequency);

        // Command: Channel 0, lobyte/hibyte, rate generator
        assembly.outb(COMMAND, 0x36);

        // Set frequency divisor
        assembly.outb(CHANNEL0, @truncate(divisor & 0xFF));
        assembly.outb(CHANNEL0, @truncate((divisor >> 8) & 0xFF));
    }

    pub fn setFrequency(frequency: u32) void {
        Pit.init(frequency);
    }
};

// ============================================================================
// HPET (High Precision Event Timer)
// ============================================================================

pub const Hpet = struct {
    base_addr: u64,
    period_fs: u64, // Period in femtoseconds
    capable_64bit: bool,

    const GEN_CAP_REG: u64 = 0x00;
    const GEN_CONFIG_REG: u64 = 0x10;
    const MAIN_COUNTER_REG: u64 = 0xF0;

    pub fn init(base_addr: u64) !Hpet {
        const cap = readReg(base_addr, GEN_CAP_REG);

        return .{
            .base_addr = base_addr,
            .period_fs = cap >> 32,
            .capable_64bit = (cap & (1 << 13)) != 0,
        };
    }

    fn readReg(base: u64, offset: u64) u64 {
        const ptr: *volatile u64 = @ptrFromInt(base + offset);
        return ptr.*;
    }

    fn writeReg(base: u64, offset: u64, value: u64) void {
        const ptr: *volatile u64 = @ptrFromInt(base + offset);
        ptr.* = value;
    }

    pub fn enable(self: *const Hpet) void {
        var config = readReg(self.base_addr, GEN_CONFIG_REG);
        config |= 1; // Enable counter
        writeReg(self.base_addr, GEN_CONFIG_REG, config);
    }

    pub fn disable(self: *const Hpet) void {
        var config = readReg(self.base_addr, GEN_CONFIG_REG);
        config &= ~@as(u64, 1); // Disable counter
        writeReg(self.base_addr, GEN_CONFIG_REG, config);
    }

    pub fn readCounter(self: *const Hpet) u64 {
        return readReg(self.base_addr, MAIN_COUNTER_REG);
    }
};

// ============================================================================
// TSC (Time Stamp Counter)
// ============================================================================

pub const Tsc = struct {
    frequency_hz: u64,
    calibrated: bool,

    pub fn init() Tsc {
        return .{
            .frequency_hz = calibrate(),
            .calibrated = true,
        };
    }

    pub fn read() u64 {
        return assembly.rdtsc();
    }

    /// Calibrate TSC frequency using PIT
    /// Uses PIT channel 2 in one-shot mode for timing
    fn calibrate() u64 {
        // Method 1: Try to get TSC frequency from CPUID
        const cpuid_freq = getTscFrequencyFromCpuid();
        if (cpuid_freq != 0) {
            return cpuid_freq;
        }

        // Method 2: Calibrate using PIT
        return calibrateUsingPit();
    }

    /// Try to get TSC frequency directly from CPUID (Intel processors)
    fn getTscFrequencyFromCpuid() u64 {
        // CPUID leaf 0x15: TSC/Core Crystal Clock ratio
        // Only available on newer Intel processors
        const max_leaf = assembly.cpuid(0, 0).eax;

        if (max_leaf >= 0x15) {
            const cpuid15 = assembly.cpuid(0x15, 0);
            const denominator = cpuid15.eax;
            const numerator = cpuid15.ebx;
            const crystal_freq = cpuid15.ecx;

            if (denominator != 0 and numerator != 0) {
                if (crystal_freq != 0) {
                    // TSC freq = crystal_freq * numerator / denominator
                    return (@as(u64, crystal_freq) * @as(u64, numerator)) / @as(u64, denominator);
                }
            }
        }

        // CPUID leaf 0x16: Processor Frequency Information
        if (max_leaf >= 0x16) {
            const cpuid16 = assembly.cpuid(0x16, 0);
            const base_freq_mhz = cpuid16.eax & 0xFFFF;

            if (base_freq_mhz != 0) {
                return @as(u64, base_freq_mhz) * 1_000_000;
            }
        }

        return 0; // CPUID method not available
    }

    /// Calibrate TSC using PIT channel 2
    fn calibrateUsingPit() u64 {
        const PIT_CHANNEL2: u16 = 0x42;
        const PIT_COMMAND: u16 = 0x43;
        const PIT_GATE: u16 = 0x61;
        const PIT_FREQUENCY: u64 = 1193182;

        // Calibration period: 10ms (119318 PIT ticks at 1193182 Hz)
        const CALIBRATION_TICKS: u16 = 11932; // ~10ms

        // Save current gate value
        const old_gate = assembly.inb(PIT_GATE);

        // Disable speaker, enable PIT channel 2 gate
        assembly.outb(PIT_GATE, (old_gate & 0xFD) | 0x01);

        // Command: Channel 2, lobyte/hibyte, one-shot mode
        assembly.outb(PIT_COMMAND, 0xB0);

        // Set countdown value
        assembly.outb(PIT_CHANNEL2, @truncate(CALIBRATION_TICKS & 0xFF));
        assembly.outb(PIT_CHANNEL2, @truncate((CALIBRATION_TICKS >> 8) & 0xFF));

        // Reset channel 2 gate to start countdown
        assembly.outb(PIT_GATE, assembly.inb(PIT_GATE) & 0xFE);
        assembly.outb(PIT_GATE, assembly.inb(PIT_GATE) | 0x01);

        // Read TSC at start
        const tsc_start = assembly.rdtsc();

        // Wait for countdown to complete (gate output goes high)
        while ((assembly.inb(PIT_GATE) & 0x20) == 0) {
            assembly.pause();
        }

        // Read TSC at end
        const tsc_end = assembly.rdtsc();

        // Restore gate
        assembly.outb(PIT_GATE, old_gate);

        // Calculate TSC frequency
        const tsc_delta = tsc_end - tsc_start;
        const calibration_ns = (@as(u64, CALIBRATION_TICKS) * 1_000_000_000) / PIT_FREQUENCY;

        // TSC frequency = tsc_delta / (calibration_ns / 1e9)
        // = tsc_delta * 1e9 / calibration_ns
        const frequency = (tsc_delta * 1_000_000_000) / calibration_ns;

        // Round to nearest 100 MHz for cleaner value
        const rounded = ((frequency + 50_000_000) / 100_000_000) * 100_000_000;

        return if (rounded > 0) rounded else 2_000_000_000; // Fallback to 2 GHz
    }

    pub fn toNanoseconds(self: *const Tsc, tsc_value: u64) u64 {
        return (tsc_value * 1_000_000_000) / self.frequency_hz;
    }

    pub fn toMicroseconds(self: *const Tsc, tsc_value: u64) u64 {
        return (tsc_value * 1_000_000) / self.frequency_hz;
    }

    pub fn toMilliseconds(self: *const Tsc, tsc_value: u64) u64 {
        return (tsc_value * 1_000) / self.frequency_hz;
    }

    /// Get TSC ticks for a given nanosecond duration
    pub fn fromNanoseconds(self: *const Tsc, ns: u64) u64 {
        return (ns * self.frequency_hz) / 1_000_000_000;
    }
};

// ============================================================================
// Timer Manager
// ============================================================================

pub const TimerManager = struct {
    pit: Pit,
    hpet: ?Hpet,
    tsc: Tsc,
    ticks: atomic.AtomicU64,
    lock: sync.Spinlock,

    pub fn init() !TimerManager {
        var mgr = TimerManager{
            .pit = Pit{},
            .hpet = null,
            .tsc = Tsc.init(),
            .ticks = atomic.AtomicU64.init(0),
            .lock = sync.Spinlock.init(),
        };

        // Initialize PIT with 1000 Hz (1ms ticks)
        Pit.init(1000);

        // Try to initialize HPET if available
        if (acpi.getHpet()) |hpet_table| {
            mgr.hpet = try Hpet.init(hpet_table.address);
            if (mgr.hpet) |*hpet| {
                hpet.enable();
            }
        }

        return mgr;
    }

    pub fn tick(self: *TimerManager) void {
        _ = self.ticks.fetchAdd(1, .Monotonic);
    }

    pub fn getTicks(self: *const TimerManager) u64 {
        return self.ticks.load(.Monotonic);
    }

    pub fn getUptimeMs(self: *const TimerManager) u64 {
        return self.getTicks(); // 1 tick = 1ms
    }
};

var timer_manager: ?TimerManager = null;

pub fn init() !void {
    timer_manager = try TimerManager.init();
}

pub fn tick() void {
    if (timer_manager) |*mgr| {
        mgr.tick();
    }
}

pub fn getTicks() u64 {
    if (timer_manager) |*mgr| {
        return mgr.getTicks();
    }
    return 0;
}
