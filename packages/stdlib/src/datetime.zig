const std = @import("std");

/// Date and time utilities for Ion
pub const DateTime = struct {
    timestamp: i64, // Unix timestamp in seconds
    nanoseconds: u32, // Nanoseconds component

    /// Get current date/time
    pub fn now() DateTime {
        const now_ns = std.time.nanoTimestamp();
        return .{
            .timestamp = @divTrunc(now_ns, std.time.ns_per_s),
            .nanoseconds = @intCast(@mod(now_ns, std.time.ns_per_s)),
        };
    }

    /// Create from Unix timestamp
    pub fn fromTimestamp(timestamp: i64) DateTime {
        return .{
            .timestamp = timestamp,
            .nanoseconds = 0,
        };
    }

    /// Create from components
    pub fn fromComponents(year: u32, month: u8, day: u8, hour: u8, minute: u8, second: u8) !DateTime {
        if (month < 1 or month > 12) return error.InvalidMonth;
        if (day < 1 or day > 31) return error.InvalidDay;
        if (hour > 23) return error.InvalidHour;
        if (minute > 59) return error.InvalidMinute;
        if (second > 59) return error.InvalidSecond;

        // Simplified Unix timestamp calculation (doesn't account for all edge cases)
        const days_since_epoch = calculateDaysSinceEpoch(year, month, day);
        const seconds_in_day = @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
        const timestamp = days_since_epoch * 86400 + seconds_in_day;

        return .{
            .timestamp = timestamp,
            .nanoseconds = 0,
        };
    }

    /// Add duration in seconds
    pub fn addSeconds(self: DateTime, seconds: i64) DateTime {
        return .{
            .timestamp = self.timestamp + seconds,
            .nanoseconds = self.nanoseconds,
        };
    }

    /// Add duration in minutes
    pub fn addMinutes(self: DateTime, minutes: i64) DateTime {
        return self.addSeconds(minutes * 60);
    }

    /// Add duration in hours
    pub fn addHours(self: DateTime, hours: i64) DateTime {
        return self.addSeconds(hours * 3600);
    }

    /// Add duration in days
    pub fn addDays(self: DateTime, days: i64) DateTime {
        return self.addSeconds(days * 86400);
    }

    /// Get difference in seconds
    pub fn diffSeconds(self: DateTime, other: DateTime) i64 {
        return self.timestamp - other.timestamp;
    }

    /// Get difference in minutes
    pub fn diffMinutes(self: DateTime, other: DateTime) i64 {
        return @divTrunc(self.diffSeconds(other), 60);
    }

    /// Get difference in hours
    pub fn diffHours(self: DateTime, other: DateTime) i64 {
        return @divTrunc(self.diffSeconds(other), 3600);
    }

    /// Get difference in days
    pub fn diffDays(self: DateTime, other: DateTime) i64 {
        return @divTrunc(self.diffSeconds(other), 86400);
    }

    /// Format as ISO 8601 string
    pub fn formatISO(self: DateTime, allocator: std.mem.Allocator) ![]u8 {
        const components = self.toComponents();
        return std.fmt.allocPrint(
            allocator,
            "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
            .{ components.year, components.month, components.day, components.hour, components.minute, components.second },
        );
    }

    /// Format with custom format string
    /// %Y - year (4 digits)
    /// %m - month (2 digits)
    /// %d - day (2 digits)
    /// %H - hour (2 digits)
    /// %M - minute (2 digits)
    /// %S - second (2 digits)
    pub fn format(self: DateTime, allocator: std.mem.Allocator, fmt: []const u8) ![]u8 {
        const components = self.toComponents();
        var result = std.ArrayList(u8).init(allocator);

        var i: usize = 0;
        while (i < fmt.len) {
            if (fmt[i] == '%' and i + 1 < fmt.len) {
                const specifier = fmt[i + 1];
                switch (specifier) {
                    'Y' => try result.writer().print("{d:0>4}", .{components.year}),
                    'm' => try result.writer().print("{d:0>2}", .{components.month}),
                    'd' => try result.writer().print("{d:0>2}", .{components.day}),
                    'H' => try result.writer().print("{d:0>2}", .{components.hour}),
                    'M' => try result.writer().print("{d:0>2}", .{components.minute}),
                    'S' => try result.writer().print("{d:0>2}", .{components.second}),
                    else => {
                        try result.append(fmt[i]);
                        try result.append(fmt[i + 1]);
                    },
                }
                i += 2;
            } else {
                try result.append(fmt[i]);
                i += 1;
            }
        }

        return result.toOwnedSlice();
    }

    /// Convert to components
    pub fn toComponents(self: DateTime) DateTimeComponents {
        // Convert Unix timestamp to date components
        // This is a simplified implementation
        const days_since_epoch = @divTrunc(self.timestamp, 86400);
        const seconds_in_day = @mod(self.timestamp, 86400);

        const hour: u8 = @intCast(@divTrunc(seconds_in_day, 3600));
        const minute: u8 = @intCast(@divTrunc(@mod(seconds_in_day, 3600), 60));
        const second: u8 = @intCast(@mod(seconds_in_day, 60));

        // Simplified calendar calculation (doesn't handle all edge cases perfectly)
        var year: u32 = 1970;
        var remaining_days = days_since_epoch;

        // Rough year calculation
        const years_passed = @divTrunc(remaining_days, 365);
        year += @intCast(years_passed);
        remaining_days -= years_passed * 365;
        remaining_days -= @divTrunc(years_passed, 4); // Account for leap years (simplified)

        // Ensure we don't go negative
        while (remaining_days < 0) {
            year -= 1;
            remaining_days += if (isLeapYear(year)) 365 + 1 else 365;
        }

        // Month and day calculation
        var month: u8 = 1;
        while (month <= 12) {
            const days_in_month = getDaysInMonth(year, month);
            if (remaining_days < days_in_month) {
                break;
            }
            remaining_days -= days_in_month;
            month += 1;
        }

        const day: u8 = @intCast(remaining_days + 1);

        return .{
            .year = year,
            .month = month,
            .day = day,
            .hour = hour,
            .minute = minute,
            .second = second,
        };
    }

    /// Compare two DateTimes
    pub fn compare(self: DateTime, other: DateTime) std.math.Order {
        if (self.timestamp < other.timestamp) return .lt;
        if (self.timestamp > other.timestamp) return .gt;
        if (self.nanoseconds < other.nanoseconds) return .lt;
        if (self.nanoseconds > other.nanoseconds) return .gt;
        return .eq;
    }

    /// Check if before another DateTime
    pub fn isBefore(self: DateTime, other: DateTime) bool {
        return self.compare(other) == .lt;
    }

    /// Check if after another DateTime
    pub fn isAfter(self: DateTime, other: DateTime) bool {
        return self.compare(other) == .gt;
    }
};

pub const DateTimeComponents = struct {
    year: u32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

/// Duration for time calculations
pub const Duration = struct {
    seconds: i64,
    nanoseconds: u32,

    pub fn fromSeconds(seconds: i64) Duration {
        return .{ .seconds = seconds, .nanoseconds = 0 };
    }

    pub fn fromMinutes(minutes: i64) Duration {
        return fromSeconds(minutes * 60);
    }

    pub fn fromHours(hours: i64) Duration {
        return fromSeconds(hours * 3600);
    }

    pub fn fromDays(days: i64) Duration {
        return fromSeconds(days * 86400);
    }

    pub fn fromMilliseconds(ms: i64) Duration {
        const seconds = @divTrunc(ms, 1000);
        const nanos = @mod(ms, 1000) * std.time.ns_per_ms;
        return .{ .seconds = seconds, .nanoseconds = @intCast(nanos) };
    }

    pub fn toSeconds(self: Duration) f64 {
        return @as(f64, @floatFromInt(self.seconds)) +
               @as(f64, @floatFromInt(self.nanoseconds)) / @as(f64, std.time.ns_per_s);
    }

    pub fn toMilliseconds(self: Duration) i64 {
        return self.seconds * 1000 + @divTrunc(self.nanoseconds, std.time.ns_per_ms);
    }

    pub fn add(self: Duration, other: Duration) Duration {
        var seconds = self.seconds + other.seconds;
        var nanoseconds = self.nanoseconds + other.nanoseconds;

        if (nanoseconds >= std.time.ns_per_s) {
            seconds += 1;
            nanoseconds -= std.time.ns_per_s;
        }

        return .{ .seconds = seconds, .nanoseconds = nanoseconds };
    }

    pub fn subtract(self: Duration, other: Duration) Duration {
        var seconds = self.seconds - other.seconds;
        var nanoseconds: i64 = @as(i64, self.nanoseconds) - @as(i64, other.nanoseconds);

        if (nanoseconds < 0) {
            seconds -= 1;
            nanoseconds += std.time.ns_per_s;
        }

        return .{ .seconds = seconds, .nanoseconds = @intCast(nanoseconds) };
    }
};

/// Timer for measuring elapsed time
pub const Timer = struct {
    start: i128,

    pub fn start() Timer {
        return .{ .start = std.time.nanoTimestamp() };
    }

    pub fn elapsed(self: Timer) Duration {
        const now = std.time.nanoTimestamp();
        const elapsed_ns = now - self.start;
        const seconds = @divTrunc(elapsed_ns, std.time.ns_per_s);
        const nanoseconds = @mod(elapsed_ns, std.time.ns_per_s);
        return .{
            .seconds = seconds,
            .nanoseconds = @intCast(nanoseconds),
        };
    }

    pub fn elapsedMillis(self: Timer) i64 {
        const now = std.time.nanoTimestamp();
        return @divTrunc(now - self.start, std.time.ns_per_ms);
    }

    pub fn reset(self: *Timer) void {
        self.start = std.time.nanoTimestamp();
    }
};

/// Check if a year is a leap year
fn isLeapYear(year: u32) bool {
    if (@mod(year, 400) == 0) return true;
    if (@mod(year, 100) == 0) return false;
    if (@mod(year, 4) == 0) return true;
    return false;
}

/// Get number of days in a month
fn getDaysInMonth(year: u32, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

/// Calculate days since Unix epoch (simplified)
fn calculateDaysSinceEpoch(year: u32, month: u8, day: u8) i64 {
    var days: i64 = 0;

    // Days from years
    var y: u32 = 1970;
    while (y < year) : (y += 1) {
        days += if (isLeapYear(y)) 366 else 365;
    }

    // Days from months
    var m: u8 = 1;
    while (m < month) : (m += 1) {
        days += getDaysInMonth(year, m);
    }

    // Days in current month
    days += day - 1;

    return days;
}

/// Sleep for a duration
pub fn sleep(duration: Duration) void {
    const ns = duration.seconds * std.time.ns_per_s + duration.nanoseconds;
    std.time.sleep(@intCast(ns));
}

/// Parse ISO 8601 date string (basic implementation)
pub fn parseISO(allocator: std.mem.Allocator, str: []const u8) !DateTime {
    _ = allocator;

    // Expected format: YYYY-MM-DDTHH:MM:SSZ
    if (str.len < 19) return error.InvalidFormat;

    const year = try std.fmt.parseInt(u32, str[0..4], 10);
    const month = try std.fmt.parseInt(u8, str[5..7], 10);
    const day = try std.fmt.parseInt(u8, str[8..10], 10);
    const hour = try std.fmt.parseInt(u8, str[11..13], 10);
    const minute = try std.fmt.parseInt(u8, str[14..16], 10);
    const second = try std.fmt.parseInt(u8, str[17..19], 10);

    return DateTime.fromComponents(year, month, day, hour, minute, second);
}

/// Common time zones (offset from UTC in seconds)
pub const TimeZone = struct {
    pub const UTC: i32 = 0;
    pub const EST: i32 = -5 * 3600; // UTC-5
    pub const PST: i32 = -8 * 3600; // UTC-8
    pub const CET: i32 = 1 * 3600; // UTC+1
    pub const JST: i32 = 9 * 3600; // UTC+9
};
