// Home Programming Language - BCM2835/BCM2711 System Timer Driver
// For Raspberry Pi 3/4

const std = @import("std");

// ============================================================================
// BCM System Timer Registers
// ============================================================================

pub const SystemTimerRegs = extern struct {
    control_status: u32, // Control/Status
    counter_lo: u32, // Counter lower 32 bits
    counter_hi: u32, // Counter upper 32 bits
    compare0: u32, // Compare 0
    compare1: u32, // Compare 1
    compare2: u32, // Compare 2
    compare3: u32, // Compare 3
};

// System Timer base addresses
pub const BCM2835_TIMER_BASE = 0x3F003000; // Raspberry Pi 3
pub const BCM2711_TIMER_BASE = 0xFE003000; // Raspberry Pi 4

// ============================================================================
// ARM Generic Timer Registers (Available in ARM64)
// ============================================================================

pub const ArmTimer = struct {
    /// Read the system counter frequency (Hz)
    pub fn getFrequency() u64 {
        var freq: u64 = undefined;
        asm volatile ("mrs %[freq], cntfrq_el0"
            : [freq] "=r" (freq),
        );
        return freq;
    }

    /// Read the physical counter value
    pub fn readCounter() u64 {
        var count: u64 = undefined;
        asm volatile ("mrs %[count], cntpct_el0"
            : [count] "=r" (count),
        );
        return count;
    }

    /// Read the virtual counter value
    pub fn readVirtualCounter() u64 {
        var count: u64 = undefined;
        asm volatile ("mrs %[count], cntvct_el0"
            : [count] "=r" (count),
        );
        return count;
    }

    /// Set physical timer compare value
    pub fn setPhysicalCompare(value: u64) void {
        asm volatile ("msr cntp_cval_el0, %[val]"
            :
            : [val] "r" (value),
        );
    }

    /// Set physical timer control
    pub fn setPhysicalControl(enable: bool, mask_irq: bool) void {
        var ctrl: u64 = 0;
        if (enable) ctrl |= 1 << 0; // ENABLE
        if (!mask_irq) ctrl |= 1 << 1; // IMASK (inverted)
        asm volatile ("msr cntp_ctl_el0, %[ctrl]"
            :
            : [ctrl] "r" (ctrl),
        );
    }

    /// Read physical timer control
    pub fn getPhysicalControl() u64 {
        var ctrl: u64 = undefined;
        asm volatile ("mrs %[ctrl], cntp_ctl_el0"
            : [ctrl] "=r" (ctrl),
        );
        return ctrl;
    }

    /// Check if physical timer interrupt is pending
    pub fn isPhysicalPending() bool {
        return (getPhysicalControl() & (1 << 2)) != 0;
    }

    /// Set virtual timer compare value
    pub fn setVirtualCompare(value: u64) void {
        asm volatile ("msr cntv_cval_el0, %[val]"
            :
            : [val] "r" (value),
        );
    }

    /// Set virtual timer control
    pub fn setVirtualControl(enable: bool, mask_irq: bool) void {
        var ctrl: u64 = 0;
        if (enable) ctrl |= 1 << 0; // ENABLE
        if (!mask_irq) ctrl |= 1 << 1; // IMASK (inverted)
        asm volatile ("msr cntv_ctl_el0, %[ctrl]"
            :
            : [ctrl] "r" (ctrl),
        );
    }

    /// Disable physical timer
    pub fn disablePhysical() void {
        setPhysicalControl(false, true);
    }

    /// Disable virtual timer
    pub fn disableVirtual() void {
        setVirtualControl(false, true);
    }
};

// ============================================================================
// BCM System Timer Driver
// ============================================================================

pub const SystemTimer = struct {
    regs: *volatile SystemTimerRegs,
    base_frequency: u64, // 1 MHz for BCM system timer

    pub fn init(base_addr: u64) SystemTimer {
        return .{
            .regs = @ptrFromInt(base_addr),
            .base_frequency = 1_000_000, // BCM system timer runs at 1 MHz
        };
    }

    /// Read 64-bit counter value
    pub fn readCounter(self: *SystemTimer) u64 {
        // Read high, then low, then high again to ensure consistency
        var hi1 = self.regs.counter_hi;
        var lo = self.regs.counter_lo;
        const hi2 = self.regs.counter_hi;

        // If high changed, re-read low
        if (hi1 != hi2) {
            lo = self.regs.counter_lo;
            hi1 = hi2;
        }

        return (@as(u64, hi1) << 32) | @as(u64, lo);
    }

    /// Set compare value for timer channel
    pub fn setCompare(self: *SystemTimer, channel: u2, value: u32) void {
        switch (channel) {
            0 => self.regs.compare0 = value,
            1 => self.regs.compare1 = value,
            2 => self.regs.compare2 = value,
            3 => self.regs.compare3 = value,
        }
    }

    /// Check if timer channel matched
    pub fn hasMatched(self: *SystemTimer, channel: u2) bool {
        return (self.regs.control_status & (@as(u32, 1) << channel)) != 0;
    }

    /// Clear timer channel match status
    pub fn clearMatch(self: *SystemTimer, channel: u2) void {
        self.regs.control_status = @as(u32, 1) << channel;
    }

    /// Get current time in microseconds
    pub fn getMicroseconds(self: *SystemTimer) u64 {
        return self.readCounter();
    }

    /// Get current time in milliseconds
    pub fn getMilliseconds(self: *SystemTimer) u64 {
        return self.readCounter() / 1000;
    }

    /// Get current time in seconds
    pub fn getSeconds(self: *SystemTimer) u64 {
        return self.readCounter() / 1_000_000;
    }

    /// Busy wait for microseconds
    pub fn delayMicroseconds(self: *SystemTimer, us: u64) void {
        const start = self.readCounter();
        while ((self.readCounter() - start) < us) {
            asm volatile ("nop");
        }
    }

    /// Busy wait for milliseconds
    pub fn delayMilliseconds(self: *SystemTimer, ms: u64) void {
        self.delayMicroseconds(ms * 1000);
    }

    /// Set up periodic timer interrupt
    pub fn setupPeriodicTimer(self: *SystemTimer, channel: u2, interval_us: u32) void {
        const current = @as(u32, @truncate(self.readCounter()));
        self.setCompare(channel, current + interval_us);
    }

    /// Acknowledge and reschedule periodic timer
    pub fn acknowledgePeriodicTimer(self: *SystemTimer, channel: u2, interval_us: u32) void {
        self.clearMatch(channel);
        const compare_value = switch (channel) {
            0 => self.regs.compare0,
            1 => self.regs.compare1,
            2 => self.regs.compare2,
            3 => self.regs.compare3,
        };
        self.setCompare(channel, compare_value + interval_us);
    }
};

// ============================================================================
// High-Level Timer Driver
// ============================================================================

pub const TimerDriver = struct {
    system_timer: SystemTimer,
    arm_timer_freq: u64,
    use_arm_timer: bool,

    pub fn init(base_addr: u64) TimerDriver {
        return .{
            .system_timer = SystemTimer.init(base_addr),
            .arm_timer_freq = ArmTimer.getFrequency(),
            .use_arm_timer = true, // Prefer ARM generic timer when available
        };
    }

    /// Get current timestamp in nanoseconds
    pub fn getNanoseconds(self: *TimerDriver) u64 {
        if (self.use_arm_timer) {
            const count = ArmTimer.readCounter();
            // Convert to nanoseconds: (count * 1_000_000_000) / frequency
            return (count * 1_000_000_000) / self.arm_timer_freq;
        } else {
            return self.system_timer.getMicroseconds() * 1000;
        }
    }

    /// Get current timestamp in microseconds
    pub fn getMicroseconds(self: *TimerDriver) u64 {
        if (self.use_arm_timer) {
            const count = ArmTimer.readCounter();
            return (count * 1_000_000) / self.arm_timer_freq;
        } else {
            return self.system_timer.getMicroseconds();
        }
    }

    /// Get current timestamp in milliseconds
    pub fn getMilliseconds(self: *TimerDriver) u64 {
        if (self.use_arm_timer) {
            const count = ArmTimer.readCounter();
            return (count * 1000) / self.arm_timer_freq;
        } else {
            return self.system_timer.getMilliseconds();
        }
    }

    /// Busy wait for microseconds
    pub fn delayMicroseconds(self: *TimerDriver, us: u64) void {
        if (self.use_arm_timer) {
            const ticks = (us * self.arm_timer_freq) / 1_000_000;
            const start = ArmTimer.readCounter();
            while ((ArmTimer.readCounter() - start) < ticks) {
                asm volatile ("nop");
            }
        } else {
            self.system_timer.delayMicroseconds(us);
        }
    }

    /// Busy wait for milliseconds
    pub fn delayMilliseconds(self: *TimerDriver, ms: u64) void {
        self.delayMicroseconds(ms * 1000);
    }

    /// Set up one-shot timer interrupt (ARM generic timer)
    pub fn setupOneShotTimer(self: *TimerDriver, delay_us: u64) void {
        const ticks = (delay_us * self.arm_timer_freq) / 1_000_000;
        const target = ArmTimer.readCounter() + ticks;
        ArmTimer.setPhysicalCompare(target);
        ArmTimer.setPhysicalControl(true, false); // Enable, don't mask IRQ
    }

    /// Set up periodic timer interrupt (ARM generic timer)
    pub fn setupPeriodicArmTimer(self: *TimerDriver, period_us: u64) void {
        const ticks = (period_us * self.arm_timer_freq) / 1_000_000;
        const target = ArmTimer.readCounter() + ticks;
        ArmTimer.setPhysicalCompare(target);
        ArmTimer.setPhysicalControl(true, false);
    }

    /// Acknowledge periodic ARM timer and reschedule
    pub fn acknowledgeArmTimer(self: *TimerDriver, period_us: u64) void {
        const ticks = (period_us * self.arm_timer_freq) / 1_000_000;
        const current_target = ArmTimer.readCounter();
        ArmTimer.setPhysicalCompare(current_target + ticks);
    }

    /// Disable ARM timer
    pub fn disableArmTimer(_: *TimerDriver) void {
        ArmTimer.disablePhysical();
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Initialize timer for Raspberry Pi 3
pub fn initRaspberryPi3() TimerDriver {
    return TimerDriver.init(BCM2835_TIMER_BASE);
}

/// Initialize timer for Raspberry Pi 4
pub fn initRaspberryPi4() TimerDriver {
    return TimerDriver.init(BCM2711_TIMER_BASE);
}

/// Calibrate busy wait loop
pub fn calibrateBusyWait(timer: *TimerDriver) u64 {
    const iterations = 1_000_000;
    const start = timer.getMicroseconds();

    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        asm volatile ("nop");
    }

    const elapsed = timer.getMicroseconds() - start;
    return iterations / elapsed; // iterations per microsecond
}

// ============================================================================
// Performance Measurement
// ============================================================================

pub const PerfCounter = struct {
    start_time: u64,
    timer: *TimerDriver,

    pub fn start(timer: *TimerDriver) PerfCounter {
        return .{
            .start_time = timer.getNanoseconds(),
            .timer = timer,
        };
    }

    pub fn elapsed(self: *PerfCounter) u64 {
        return self.timer.getNanoseconds() - self.start_time;
    }

    pub fn elapsedMicroseconds(self: *PerfCounter) u64 {
        return (self.timer.getNanoseconds() - self.start_time) / 1000;
    }

    pub fn elapsedMilliseconds(self: *PerfCounter) u64 {
        return (self.timer.getNanoseconds() - self.start_time) / 1_000_000;
    }

    pub fn reset(self: *PerfCounter) void {
        self.start_time = self.timer.getNanoseconds();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "System timer register layout" {
    try std.testing.expectEqual(@as(usize, 28), @sizeOf(SystemTimerRegs));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(SystemTimerRegs, "control_status"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(SystemTimerRegs, "counter_lo"));
}

test "ARM timer frequency" {
    const freq = ArmTimer.getFrequency();
    try std.testing.expect(freq > 0);
}

test "Timer addresses" {
    try std.testing.expectEqual(@as(u64, 0x3F003000), BCM2835_TIMER_BASE);
    try std.testing.expectEqual(@as(u64, 0xFE003000), BCM2711_TIMER_BASE);
}
