// Home Programming Language - Timer Subsystem
// PIT, HPET, TSC, and timer management

const Basics = @import("basics");
const asm = @import("asm.zig");
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
        asm.outb(COMMAND, 0x36);

        // Set frequency divisor
        asm.outb(CHANNEL0, @truncate(divisor & 0xFF));
        asm.outb(CHANNEL0, @truncate((divisor >> 8) & 0xFF));
    }

    pub fn setFrequency(frequency: u32) void {
        init(frequency);
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

    pub fn init() Tsc {
        return .{
            .frequency_hz = calibrate(),
        };
    }

    pub fn read() u64 {
        return asm.rdtsc();
    }

    fn calibrate() u64 {
        // TODO: Calibrate TSC frequency using PIT or HPET
        // For now, return estimated value
        return 2_000_000_000; // 2 GHz estimate
    }

    pub fn toNanoseconds(self: *const Tsc, tsc_value: u64) u64 {
        return (tsc_value * 1_000_000_000) / self.frequency_hz;
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
