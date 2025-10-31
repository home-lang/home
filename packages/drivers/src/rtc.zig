// Real-Time Clock (RTC) Driver
// Supports CMOS RTC (PC/AT compatible) and ARM PL031 RTC

const std = @import("std");
const builtin = @import("builtin");

/// RTC Time structure
pub const Time = struct {
    year: u16,
    month: u8, // 1-12
    day: u8, // 1-31
    hour: u8, // 0-23
    minute: u8, // 0-59
    second: u8, // 0-59
    weekday: u8, // 0-6 (Sunday=0)

    pub fn toUnixTimestamp(self: Time) i64 {
        // Calculate days since Unix epoch (1970-01-01)
        const days_since_epoch = self.daysSinceEpoch();
        const seconds_in_day: i64 = 86400;

        const timestamp = days_since_epoch * seconds_in_day +
            @as(i64, self.hour) * 3600 +
            @as(i64, self.minute) * 60 +
            @as(i64, self.second);

        return timestamp;
    }

    fn daysSinceEpoch(self: Time) i64 {
        var days: i64 = 0;

        // Days from years
        var year: i64 = 1970;
        while (year < self.year) : (year += 1) {
            days += if (isLeapYear(@intCast(year))) 366 else 365;
        }

        // Days from months
        const days_in_month = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        for (1..self.month) |month| {
            days += days_in_month[month - 1];
            if (month == 2 and isLeapYear(self.year)) {
                days += 1;
            }
        }

        // Days from day of month
        days += self.day - 1;

        return days;
    }

    fn isLeapYear(year: u16) bool {
        if (year % 400 == 0) return true;
        if (year % 100 == 0) return false;
        if (year % 4 == 0) return true;
        return false;
    }

    pub fn format(
        self: *const Time,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
            self.year,
            self.month,
            self.day,
            self.hour,
            self.minute,
            self.second,
        });
    }
};

/// CMOS RTC (PC/AT compatible)
pub const CMOS = struct {
    pub const ADDR_PORT: u16 = 0x70;
    pub const DATA_PORT: u16 = 0x71;

    pub const Register = enum(u8) {
        second = 0x00,
        minute = 0x02,
        hour = 0x04,
        weekday = 0x06,
        day = 0x07,
        month = 0x08,
        year = 0x09,
        century = 0x32,
        status_a = 0x0A,
        status_b = 0x0B,
        _,
    };

    pub const StatusB = struct {
        pub const HOUR_24: u8 = 1 << 1; // 24-hour mode
        pub const BINARY: u8 = 1 << 2; // Binary mode (not BCD)
        pub const UPDATE_INT: u8 = 1 << 4; // Update-ended interrupt
        pub const ALARM_INT: u8 = 1 << 5; // Alarm interrupt
        pub const PERIODIC_INT: u8 = 1 << 6; // Periodic interrupt
        pub const SET: u8 = 1 << 7; // Update in progress
    };

    pub const StatusA = struct {
        pub const UPDATE_IN_PROGRESS: u8 = 1 << 7;
    };

    /// Read CMOS register
    fn readRegister(reg: Register) u8 {
        // Disable NMI and select register
        outb(ADDR_PORT, 0x80 | @intFromEnum(reg));
        return inb(DATA_PORT);
    }

    /// Write CMOS register
    fn writeRegister(reg: Register, value: u8) void {
        outb(ADDR_PORT, 0x80 | @intFromEnum(reg));
        outb(DATA_PORT, value);
    }

    /// Wait for RTC update to complete
    fn waitForUpdate() void {
        var timeout: u32 = 1000000;
        while (timeout > 0) : (timeout -= 1) {
            if ((readRegister(.status_a) & StatusA.UPDATE_IN_PROGRESS) == 0) {
                return;
            }
        }
    }

    /// Convert BCD to binary
    fn bcdToBinary(bcd: u8) u8 {
        return (bcd & 0x0F) + ((bcd >> 4) * 10);
    }

    /// Convert binary to BCD
    fn binaryToBcd(binary: u8) u8 {
        return ((binary / 10) << 4) | (binary % 10);
    }

    /// Read current time from CMOS RTC
    pub fn readTime() Time {
        waitForUpdate();

        const status_b = readRegister(.status_b);
        const is_binary = (status_b & StatusB.BINARY) != 0;
        const is_24hour = (status_b & StatusB.HOUR_24) != 0;

        var second = readRegister(.second);
        var minute = readRegister(.minute);
        var hour = readRegister(.hour);
        const weekday = readRegister(.weekday);
        var day = readRegister(.day);
        var month = readRegister(.month);
        var year = readRegister(.year);
        const century = readRegister(.century);

        // Convert from BCD if necessary
        if (!is_binary) {
            second = bcdToBinary(second);
            minute = bcdToBinary(minute);
            hour = bcdToBinary(hour & 0x7F);
            day = bcdToBinary(day);
            month = bcdToBinary(month);
            year = bcdToBinary(year);
        }

        // Handle 12-hour format
        if (!is_24hour and (hour & 0x80) != 0) {
            hour = ((hour & 0x7F) + 12) % 24;
        }

        // Calculate full year
        const full_year = @as(u16, century) * 100 + year;

        return Time{
            .year = full_year,
            .month = month,
            .day = day,
            .hour = hour,
            .minute = minute,
            .second = second,
            .weekday = weekday - 1, // CMOS uses 1-7, we use 0-6
        };
    }

    /// Write time to CMOS RTC
    pub fn writeTime(time: Time) void {
        waitForUpdate();

        const status_b = readRegister(.status_b);
        const is_binary = (status_b & StatusB.BINARY) != 0;

        // Set the SET bit to stop updates
        writeRegister(.status_b, status_b | StatusB.SET);

        var second = time.second;
        var minute = time.minute;
        var hour = time.hour;
        var day = time.day;
        var month = time.month;
        var year = @as(u8, @intCast(time.year % 100));
        const century = @as(u8, @intCast(time.year / 100));

        // Convert to BCD if necessary
        if (!is_binary) {
            second = binaryToBcd(second);
            minute = binaryToBcd(minute);
            hour = binaryToBcd(hour);
            day = binaryToBcd(day);
            month = binaryToBcd(month);
            year = binaryToBcd(year);
        }

        writeRegister(.second, second);
        writeRegister(.minute, minute);
        writeRegister(.hour, hour);
        writeRegister(.weekday, time.weekday + 1);
        writeRegister(.day, day);
        writeRegister(.month, month);
        writeRegister(.year, year);
        writeRegister(.century, century);

        // Clear the SET bit to resume updates
        writeRegister(.status_b, status_b & ~StatusB.SET);
    }

    /// Enable RTC interrupts
    pub fn enableInterrupts(periodic: bool, alarm: bool, update: bool) void {
        var status_b = readRegister(.status_b);

        if (periodic) status_b |= StatusB.PERIODIC_INT;
        if (alarm) status_b |= StatusB.ALARM_INT;
        if (update) status_b |= StatusB.UPDATE_INT;

        writeRegister(.status_b, status_b);
    }

    /// Disable RTC interrupts
    pub fn disableInterrupts() void {
        var status_b = readRegister(.status_b);
        status_b &= ~(StatusB.PERIODIC_INT | StatusB.ALARM_INT | StatusB.UPDATE_INT);
        writeRegister(.status_b, status_b);
    }

    // Platform-specific I/O functions
    fn outb(port: u16, value: u8) void {
        if (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .x86) {
            asm volatile ("outb %[value], %[port]"
                :
                : [value] "{al}" (value),
                  [port] "N{dx}" (port),
            );
        }
    }

    fn inb(port: u16) u8 {
        if (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .x86) {
            return asm volatile ("inb %[port], %[result]"
                : [result] "={al}" (-> u8),
                : [port] "N{dx}" (port),
            );
        }
        return 0;
    }
};

/// ARM PL031 RTC
pub const PL031 = struct {
    pub const Registers = struct {
        pub const DR: u32 = 0x00; // Data Register
        pub const MR: u32 = 0x04; // Match Register
        pub const LR: u32 = 0x08; // Load Register
        pub const CR: u32 = 0x0C; // Control Register
        pub const IMSC: u32 = 0x10; // Interrupt Mask Set/Clear
        pub const RIS: u32 = 0x14; // Raw Interrupt Status
        pub const MIS: u32 = 0x18; // Masked Interrupt Status
        pub const ICR: u32 = 0x1C; // Interrupt Clear
    };

    base_address: usize,

    pub fn init(base_address: usize) PL031 {
        return .{ .base_address = base_address };
    }

    /// Read current time (seconds since epoch)
    pub fn readTimestamp(self: *const PL031) u32 {
        const addr = self.base_address + Registers.DR;
        return @as(*volatile u32, @ptrFromInt(addr)).*;
    }

    /// Write time (seconds since epoch)
    pub fn writeTimestamp(self: *const PL031, timestamp: u32) void {
        const addr = self.base_address + Registers.LR;
        @as(*volatile u32, @ptrFromInt(addr)).* = timestamp;
    }

    /// Read time as structured Time
    pub fn readTime(self: *const PL031) Time {
        const timestamp = self.readTimestamp();
        return timestampToTime(timestamp);
    }

    /// Write structured time
    pub fn writeTime(self: *const PL031, time: Time) void {
        const timestamp = @as(u32, @intCast(time.toUnixTimestamp()));
        self.writeTimestamp(timestamp);
    }

    /// Set alarm
    pub fn setAlarm(self: *const PL031, timestamp: u32) void {
        const addr = self.base_address + Registers.MR;
        @as(*volatile u32, @ptrFromInt(addr)).* = timestamp;
    }

    /// Enable interrupts
    pub fn enableInterrupts(self: *const PL031) void {
        const addr = self.base_address + Registers.IMSC;
        @as(*volatile u32, @ptrFromInt(addr)).* = 1;
    }

    /// Disable interrupts
    pub fn disableInterrupts(self: *const PL031) void {
        const addr = self.base_address + Registers.IMSC;
        @as(*volatile u32, @ptrFromInt(addr)).* = 0;
    }

    /// Clear interrupt
    pub fn clearInterrupt(self: *const PL031) void {
        const addr = self.base_address + Registers.ICR;
        @as(*volatile u32, @ptrFromInt(addr)).* = 1;
    }

    /// Convert Unix timestamp to Time structure
    fn timestampToTime(timestamp: u32) Time {
        const seconds_per_day: u32 = 86400;
        const seconds_per_hour: u32 = 3600;
        const seconds_per_minute: u32 = 60;

        var remaining = timestamp;

        // Calculate year
        var year: u16 = 1970;
        while (true) {
            const days_in_year: u32 = if (Time.isLeapYear(year)) 366 else 365;
            const seconds_in_year = days_in_year * seconds_per_day;

            if (remaining < seconds_in_year) break;

            remaining -= seconds_in_year;
            year += 1;
        }

        // Calculate month and day
        const days_in_month = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        var month: u8 = 1;
        var day: u8 = 1;

        var days_remaining = remaining / seconds_per_day;
        remaining %= seconds_per_day;

        for (days_in_month, 1..) |days, m| {
            var month_days = days;
            if (m == 2 and Time.isLeapYear(year)) {
                month_days += 1;
            }

            if (days_remaining < month_days) {
                month = @intCast(m);
                day = @intCast(days_remaining + 1);
                break;
            }

            days_remaining -= month_days;
        }

        // Calculate hour, minute, second
        const hour = @as(u8, @intCast(remaining / seconds_per_hour));
        remaining %= seconds_per_hour;

        const minute = @as(u8, @intCast(remaining / seconds_per_minute));
        const second = @as(u8, @intCast(remaining % seconds_per_minute));

        // Calculate day of week (Zeller's congruence would go here)
        const weekday: u8 = 0; // Simplified

        return Time{
            .year = year,
            .month = month,
            .day = day,
            .hour = hour,
            .minute = minute,
            .second = second,
            .weekday = weekday,
        };
    }
};

/// Generic RTC interface
pub const RTC = union(enum) {
    cmos: void,
    pl031: PL031,

    pub fn readTime(self: RTC) Time {
        return switch (self) {
            .cmos => CMOS.readTime(),
            .pl031 => |rtc| rtc.readTime(),
        };
    }

    pub fn writeTime(self: RTC, time: Time) void {
        switch (self) {
            .cmos => CMOS.writeTime(time),
            .pl031 => |rtc| rtc.writeTime(time),
        }
    }

    pub fn initCMOS() RTC {
        return .{ .cmos = {} };
    }

    pub fn initPL031(base_address: usize) RTC {
        return .{ .pl031 = PL031.init(base_address) };
    }
};

test "time to unix timestamp" {
    const testing = std.testing;

    const time = Time{
        .year = 2024,
        .month = 1,
        .day = 1,
        .hour = 0,
        .minute = 0,
        .second = 0,
        .weekday = 1,
    };

    const timestamp = time.toUnixTimestamp();
    try testing.expect(timestamp > 0);
}

test "leap year" {
    const testing = std.testing;

    try testing.expect(Time.isLeapYear(2000));
    try testing.expect(Time.isLeapYear(2024));
    try testing.expect(!Time.isLeapYear(1900));
    try testing.expect(!Time.isLeapYear(2023));
}

test "BCD conversion" {
    const testing = std.testing;

    try testing.expectEqual(@as(u8, 59), CMOS.bcdToBinary(0x59));
    try testing.expectEqual(@as(u8, 23), CMOS.bcdToBinary(0x23));
    try testing.expectEqual(@as(u8, 0x59), CMOS.binaryToBcd(59));
    try testing.expectEqual(@as(u8, 0x23), CMOS.binaryToBcd(23));
}
