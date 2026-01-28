const std = @import("std");
const builtin = @import("builtin");

/// JavaScript-compatible Temporal API for Home
/// Implements the TC39 Temporal proposal: https://tc39.es/proposal-temporal/
///
/// Temporal provides modern date/time handling with:
/// - Immutable date/time objects
/// - Explicit timezone handling
/// - Nanosecond precision
/// - ISO 8601 calendar support

// ============================================================================
// Internal time utilities for cross-platform wall-clock time
// ============================================================================

/// Get current wall-clock time in nanoseconds since Unix epoch
fn getWallClockNanoseconds() i128 {
    switch (builtin.os.tag) {
        .windows => {
            // Windows: use GetSystemTimePreciseAsFileTime
            const windows = std.os.windows;
            var ft: windows.FILETIME = undefined;
            windows.kernel32.GetSystemTimePreciseAsFileTime(&ft);
            // FILETIME is in 100-nanosecond intervals since January 1, 1601
            const ft_value = @as(u64, ft.dwHighDateTime) << 32 | ft.dwLowDateTime;
            // Convert to Unix epoch (difference is 116444736000000000 100-ns intervals)
            const unix_100ns = @as(i128, ft_value) - 116444736000000000;
            return unix_100ns * 100; // Convert to nanoseconds
        },
        .wasi => {
            var ns: std.os.wasi.timestamp_t = undefined;
            const rc = std.os.wasi.clock_time_get(.REALTIME, 1, &ns);
            if (rc != .SUCCESS) {
                // Fallback: return 0 (epoch)
                return 0;
            }
            return @as(i128, ns);
        },
        else => {
            // POSIX systems: use clock_gettime with REALTIME
            const ts = std.posix.clock_gettime(.REALTIME) catch {
                // Fallback: return 0 (epoch)
                return 0;
            };
            return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
        },
    }
}

// ============================================================================
// Temporal.Instant - A point on the timeline (nanoseconds since Unix epoch)
// ============================================================================

pub const Instant = struct {
    /// Nanoseconds since Unix epoch (1970-01-01T00:00:00Z)
    epoch_nanoseconds: i128,

    /// Create an Instant from nanoseconds since epoch
    pub fn fromEpochNanoseconds(ns: i128) Instant {
        return .{ .epoch_nanoseconds = ns };
    }

    /// Create an Instant from microseconds since epoch
    pub fn fromEpochMicroseconds(us: i64) Instant {
        return .{ .epoch_nanoseconds = @as(i128, us) * std.time.ns_per_us };
    }

    /// Create an Instant from milliseconds since epoch
    pub fn fromEpochMilliseconds(ms: i64) Instant {
        return .{ .epoch_nanoseconds = @as(i128, ms) * std.time.ns_per_ms };
    }

    /// Create an Instant from seconds since epoch
    pub fn fromEpochSeconds(s: i64) Instant {
        return .{ .epoch_nanoseconds = @as(i128, s) * std.time.ns_per_s };
    }

    /// Get epoch time in nanoseconds
    pub fn epochNanoseconds(self: Instant) i128 {
        return self.epoch_nanoseconds;
    }

    /// Get epoch time in microseconds (truncated)
    pub fn epochMicroseconds(self: Instant) i64 {
        return @intCast(@divTrunc(self.epoch_nanoseconds, std.time.ns_per_us));
    }

    /// Get epoch time in milliseconds (truncated)
    pub fn epochMilliseconds(self: Instant) i64 {
        return @intCast(@divTrunc(self.epoch_nanoseconds, std.time.ns_per_ms));
    }

    /// Get epoch time in seconds (truncated)
    pub fn epochSeconds(self: Instant) i64 {
        return @intCast(@divTrunc(self.epoch_nanoseconds, std.time.ns_per_s));
    }

    /// Add a duration to this instant
    pub fn add(self: Instant, duration: Duration) Instant {
        return .{
            .epoch_nanoseconds = self.epoch_nanoseconds + duration.total_nanoseconds,
        };
    }

    /// Subtract a duration from this instant
    pub fn subtract(self: Instant, duration: Duration) Instant {
        return .{
            .epoch_nanoseconds = self.epoch_nanoseconds - duration.total_nanoseconds,
        };
    }

    /// Get the duration between two instants
    pub fn since(self: Instant, other: Instant) Duration {
        return Duration.fromNanoseconds(self.epoch_nanoseconds - other.epoch_nanoseconds);
    }

    /// Get the duration until another instant
    pub fn until(self: Instant, other: Instant) Duration {
        return Duration.fromNanoseconds(other.epoch_nanoseconds - self.epoch_nanoseconds);
    }

    /// Compare two instants
    pub fn compare(self: Instant, other: Instant) std.math.Order {
        return std.math.order(self.epoch_nanoseconds, other.epoch_nanoseconds);
    }

    /// Check equality
    pub fn equals(self: Instant, other: Instant) bool {
        return self.epoch_nanoseconds == other.epoch_nanoseconds;
    }

    /// Convert to ZonedDateTime in the given time zone
    pub fn toZonedDateTimeISO(self: Instant, time_zone: []const u8) ZonedDateTime {
        const offset = TimeZone.getOffset(time_zone);
        return ZonedDateTime.fromInstant(self, time_zone, offset);
    }

    /// Format as ISO 8601 string (always UTC)
    pub fn toString(self: Instant, allocator: std.mem.Allocator) ![]u8 {
        const seconds = self.epochSeconds();
        const subsec_nanos: u32 = @intCast(@mod(self.epoch_nanoseconds, std.time.ns_per_s));

        const components = epochToComponents(seconds);

        if (subsec_nanos == 0) {
            return std.fmt.allocPrint(
                allocator,
                "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
                .{ components.year, components.month, components.day, components.hour, components.minute, components.second },
            );
        } else {
            // Include fractional seconds
            const millis = @divTrunc(subsec_nanos, std.time.ns_per_ms);
            return std.fmt.allocPrint(
                allocator,
                "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z",
                .{ components.year, components.month, components.day, components.hour, components.minute, components.second, millis },
            );
        }
    }
};

// ============================================================================
// Temporal.PlainDate - A calendar date without time or timezone
// ============================================================================

pub const PlainDate = struct {
    year: i32,
    month: u8, // 1-12
    day: u8, // 1-31

    /// Create a PlainDate from components
    pub fn from(year: i32, month: u8, day: u8) !PlainDate {
        if (month < 1 or month > 12) return error.InvalidMonth;
        const max_day = getDaysInMonth(@intCast(year), month);
        if (day < 1 or day > max_day) return error.InvalidDay;
        return .{ .year = year, .month = month, .day = day };
    }

    /// Get day of week (1 = Monday, 7 = Sunday) - ISO 8601
    pub fn dayOfWeek(self: PlainDate) u8 {
        // Zeller's congruence adapted for Monday = 1
        var y = self.year;
        var m = self.month;
        if (m < 3) {
            m += 12;
            y -= 1;
        }
        const q = self.day;
        const k: i32 = @mod(y, 100);
        const j: i32 = @divTrunc(y, 100);
        const h = @mod(q + @divTrunc(13 * (m + 1), 5) + k + @divTrunc(k, 4) + @divTrunc(j, 4) - 2 * j, 7);
        // Convert from Zeller (0=Sat) to ISO (1=Mon)
        const dow = @mod(h + 5, 7) + 1;
        return @intCast(dow);
    }

    /// Get day of year (1-366)
    pub fn dayOfYear(self: PlainDate) u16 {
        var day: u16 = self.day;
        var m: u8 = 1;
        while (m < self.month) : (m += 1) {
            day += getDaysInMonth(@intCast(self.year), m);
        }
        return day;
    }

    /// Get week of year (ISO 8601)
    pub fn weekOfYear(self: PlainDate) u8 {
        const jan1 = PlainDate{ .year = self.year, .month = 1, .day = 1 };
        const jan1_dow = jan1.dayOfWeek();

        // Days since start of year
        const day_of_year = self.dayOfYear();

        // ISO week starts on Monday
        // Week 1 is the week containing the first Thursday
        const jan1_offset: i16 = if (jan1_dow <= 4) @as(i16, 1) - @as(i16, jan1_dow) else @as(i16, 8) - @as(i16, jan1_dow);

        const adjusted_day = @as(i16, day_of_year) + jan1_offset;
        if (adjusted_day <= 0) {
            // Belongs to last week of previous year
            return 52;
        }

        const week = @divTrunc(adjusted_day - 1, 7) + 1;
        return @intCast(week);
    }

    /// Check if this is in a leap year
    pub fn inLeapYear(self: PlainDate) bool {
        return isLeapYear(@intCast(self.year));
    }

    /// Get number of days in the month
    pub fn daysInMonth(self: PlainDate) u8 {
        return getDaysInMonth(@intCast(self.year), self.month);
    }

    /// Get number of days in the year
    pub fn daysInYear(self: PlainDate) u16 {
        return if (self.inLeapYear()) 366 else 365;
    }

    /// Add duration to date
    pub fn add(self: PlainDate, duration: Duration) !PlainDate {
        const days_to_add = duration.totalDays();
        return self.addDays(days_to_add);
    }

    /// Add days to date
    pub fn addDays(self: PlainDate, days: i32) !PlainDate {
        // Convert to day number, add, convert back
        const current_days = dateToDays(self.year, self.month, self.day);
        const new_days = current_days + days;
        return daysToDate(new_days);
    }

    /// Add months to date
    pub fn addMonths(self: PlainDate, months: i32) !PlainDate {
        var new_month = @as(i32, self.month) + months;
        var new_year = self.year;

        while (new_month > 12) {
            new_month -= 12;
            new_year += 1;
        }
        while (new_month < 1) {
            new_month += 12;
            new_year -= 1;
        }

        const max_day = getDaysInMonth(@intCast(new_year), @intCast(new_month));
        const new_day = @min(self.day, max_day);

        return PlainDate{ .year = new_year, .month = @intCast(new_month), .day = new_day };
    }

    /// Add years to date
    pub fn addYears(self: PlainDate, years: i32) !PlainDate {
        const new_year = self.year + years;
        const max_day = getDaysInMonth(@intCast(new_year), self.month);
        const new_day = @min(self.day, max_day);

        return PlainDate{ .year = new_year, .month = self.month, .day = new_day };
    }

    /// Compare two dates
    pub fn compare(self: PlainDate, other: PlainDate) std.math.Order {
        if (self.year != other.year) return std.math.order(self.year, other.year);
        if (self.month != other.month) return std.math.order(self.month, other.month);
        return std.math.order(self.day, other.day);
    }

    /// Check equality
    pub fn equals(self: PlainDate, other: PlainDate) bool {
        return self.year == other.year and self.month == other.month and self.day == other.day;
    }

    /// Convert to PlainDateTime at midnight
    pub fn toPlainDateTime(self: PlainDate) PlainDateTime {
        return PlainDateTime{
            .year = self.year,
            .month = self.month,
            .day = self.day,
            .hour = 0,
            .minute = 0,
            .second = 0,
            .millisecond = 0,
            .microsecond = 0,
            .nanosecond = 0,
        };
    }

    /// Format as ISO 8601 string
    pub fn toString(self: PlainDate, allocator: std.mem.Allocator) ![]u8 {
        // Handle negative years (BCE dates) with explicit sign
        if (self.year < 0) {
            const abs_year: u32 = @intCast(-self.year);
            return std.fmt.allocPrint(
                allocator,
                "-{d:0>4}-{d:0>2}-{d:0>2}",
                .{ abs_year, self.month, self.day },
            );
        } else {
            const year: u32 = @intCast(self.year);
            return std.fmt.allocPrint(
                allocator,
                "{d:0>4}-{d:0>2}-{d:0>2}",
                .{ year, self.month, self.day },
            );
        }
    }
};

// ============================================================================
// Temporal.PlainTime - A wall-clock time without date or timezone
// ============================================================================

pub const PlainTime = struct {
    hour: u8, // 0-23
    minute: u8, // 0-59
    second: u8, // 0-59
    millisecond: u16, // 0-999
    microsecond: u16, // 0-999
    nanosecond: u16, // 0-999

    /// Create a PlainTime from components
    pub fn from(hour: u8, minute: u8, second: u8, millisecond: u16, microsecond: u16, nanosecond: u16) !PlainTime {
        if (hour > 23) return error.InvalidHour;
        if (minute > 59) return error.InvalidMinute;
        if (second > 59) return error.InvalidSecond;
        if (millisecond > 999) return error.InvalidMillisecond;
        if (microsecond > 999) return error.InvalidMicrosecond;
        if (nanosecond > 999) return error.InvalidNanosecond;
        return .{
            .hour = hour,
            .minute = minute,
            .second = second,
            .millisecond = millisecond,
            .microsecond = microsecond,
            .nanosecond = nanosecond,
        };
    }

    /// Create from hour:minute:second only
    pub fn fromHMS(hour: u8, minute: u8, second: u8) !PlainTime {
        return from(hour, minute, second, 0, 0, 0);
    }

    /// Get total nanoseconds since midnight
    pub fn toNanoseconds(self: PlainTime) u64 {
        const hours_ns = @as(u64, self.hour) * 3600 * std.time.ns_per_s;
        const mins_ns = @as(u64, self.minute) * 60 * std.time.ns_per_s;
        const secs_ns = @as(u64, self.second) * std.time.ns_per_s;
        const ms_ns = @as(u64, self.millisecond) * std.time.ns_per_ms;
        const us_ns = @as(u64, self.microsecond) * std.time.ns_per_us;
        return hours_ns + mins_ns + secs_ns + ms_ns + us_ns + self.nanosecond;
    }

    /// Create from nanoseconds since midnight
    pub fn fromNanoseconds(ns: u64) PlainTime {
        var remaining = ns;
        const hour: u8 = @intCast(@divTrunc(remaining, 3600 * std.time.ns_per_s));
        remaining = @mod(remaining, 3600 * std.time.ns_per_s);
        const minute: u8 = @intCast(@divTrunc(remaining, 60 * std.time.ns_per_s));
        remaining = @mod(remaining, 60 * std.time.ns_per_s);
        const second: u8 = @intCast(@divTrunc(remaining, std.time.ns_per_s));
        remaining = @mod(remaining, std.time.ns_per_s);
        const millisecond: u16 = @intCast(@divTrunc(remaining, std.time.ns_per_ms));
        remaining = @mod(remaining, std.time.ns_per_ms);
        const microsecond: u16 = @intCast(@divTrunc(remaining, std.time.ns_per_us));
        const nanosecond: u16 = @intCast(@mod(remaining, std.time.ns_per_us));

        return .{
            .hour = hour,
            .minute = minute,
            .second = second,
            .millisecond = millisecond,
            .microsecond = microsecond,
            .nanosecond = nanosecond,
        };
    }

    /// Add duration to time (wraps at midnight)
    pub fn add(self: PlainTime, duration: Duration) PlainTime {
        const current_ns = self.toNanoseconds();
        const duration_ns: u64 = @intCast(@mod(duration.total_nanoseconds, 24 * 3600 * std.time.ns_per_s));
        const new_ns = @mod(current_ns + duration_ns, 24 * 3600 * std.time.ns_per_s);
        return fromNanoseconds(new_ns);
    }

    /// Compare two times
    pub fn compare(self: PlainTime, other: PlainTime) std.math.Order {
        return std.math.order(self.toNanoseconds(), other.toNanoseconds());
    }

    /// Check equality
    pub fn equals(self: PlainTime, other: PlainTime) bool {
        return self.toNanoseconds() == other.toNanoseconds();
    }

    /// Format as ISO 8601 string
    pub fn toString(self: PlainTime, allocator: std.mem.Allocator) ![]u8 {
        const total_subsec = @as(u32, self.millisecond) * 1_000_000 +
            @as(u32, self.microsecond) * 1_000 +
            @as(u32, self.nanosecond);

        if (total_subsec == 0) {
            return std.fmt.allocPrint(
                allocator,
                "{d:0>2}:{d:0>2}:{d:0>2}",
                .{ self.hour, self.minute, self.second },
            );
        } else {
            return std.fmt.allocPrint(
                allocator,
                "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}",
                .{ self.hour, self.minute, self.second, self.millisecond },
            );
        }
    }
};

// ============================================================================
// Temporal.PlainDateTime - A date and time without timezone
// ============================================================================

pub const PlainDateTime = struct {
    year: i32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    millisecond: u16,
    microsecond: u16,
    nanosecond: u16,

    /// Create from components
    pub fn from(
        year: i32,
        month: u8,
        day: u8,
        hour: u8,
        minute: u8,
        second: u8,
        millisecond: u16,
        microsecond: u16,
        nanosecond: u16,
    ) !PlainDateTime {
        // Validate date
        _ = try PlainDate.from(year, month, day);
        // Validate time
        _ = try PlainTime.from(hour, minute, second, millisecond, microsecond, nanosecond);

        return .{
            .year = year,
            .month = month,
            .day = day,
            .hour = hour,
            .minute = minute,
            .second = second,
            .millisecond = millisecond,
            .microsecond = microsecond,
            .nanosecond = nanosecond,
        };
    }

    /// Create from PlainDate and PlainTime
    pub fn fromDateAndTime(date: PlainDate, time: PlainTime) PlainDateTime {
        return .{
            .year = date.year,
            .month = date.month,
            .day = date.day,
            .hour = time.hour,
            .minute = time.minute,
            .second = time.second,
            .millisecond = time.millisecond,
            .microsecond = time.microsecond,
            .nanosecond = time.nanosecond,
        };
    }

    /// Get the date part
    pub fn toPlainDate(self: PlainDateTime) PlainDate {
        return .{ .year = self.year, .month = self.month, .day = self.day };
    }

    /// Get the time part
    pub fn toPlainTime(self: PlainDateTime) PlainTime {
        return .{
            .hour = self.hour,
            .minute = self.minute,
            .second = self.second,
            .millisecond = self.millisecond,
            .microsecond = self.microsecond,
            .nanosecond = self.nanosecond,
        };
    }

    /// Add duration
    pub fn add(self: PlainDateTime, duration: Duration) !PlainDateTime {
        // Calculate total nanoseconds in the day
        const time_ns = self.toPlainTime().toNanoseconds();
        const duration_ns: i128 = duration.total_nanoseconds;

        // Handle positive and negative durations
        const total_ns = @as(i128, time_ns) + duration_ns;
        const ns_per_day: i128 = 24 * 3600 * std.time.ns_per_s;

        var days_delta: i32 = @intCast(@divFloor(total_ns, ns_per_day));
        var remaining_ns: u64 = @intCast(@mod(total_ns, ns_per_day));
        if (remaining_ns < 0) {
            remaining_ns += @intCast(ns_per_day);
            days_delta -= 1;
        }

        const new_date = try self.toPlainDate().addDays(days_delta);
        const new_time = PlainTime.fromNanoseconds(remaining_ns);

        return fromDateAndTime(new_date, new_time);
    }

    /// Compare two date-times
    pub fn compare(self: PlainDateTime, other: PlainDateTime) std.math.Order {
        const date_cmp = self.toPlainDate().compare(other.toPlainDate());
        if (date_cmp != .eq) return date_cmp;
        return self.toPlainTime().compare(other.toPlainTime());
    }

    /// Check equality
    pub fn equals(self: PlainDateTime, other: PlainDateTime) bool {
        return self.compare(other) == .eq;
    }

    /// Convert to ZonedDateTime in the given time zone
    pub fn toZonedDateTime(self: PlainDateTime, time_zone: []const u8) ZonedDateTime {
        const offset = TimeZone.getOffset(time_zone);
        return .{
            .year = self.year,
            .month = self.month,
            .day = self.day,
            .hour = self.hour,
            .minute = self.minute,
            .second = self.second,
            .millisecond = self.millisecond,
            .microsecond = self.microsecond,
            .nanosecond = self.nanosecond,
            .time_zone = time_zone,
            .offset_seconds = offset,
        };
    }

    /// Format as ISO 8601 string
    pub fn toString(self: PlainDateTime, allocator: std.mem.Allocator) ![]u8 {
        const total_subsec = @as(u32, self.millisecond) * 1_000_000 +
            @as(u32, self.microsecond) * 1_000 +
            @as(u32, self.nanosecond);

        // Handle negative years (BCE dates)
        if (self.year < 0) {
            const abs_year: u32 = @intCast(-self.year);
            if (total_subsec == 0) {
                return std.fmt.allocPrint(
                    allocator,
                    "-{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}",
                    .{ abs_year, self.month, self.day, self.hour, self.minute, self.second },
                );
            } else {
                return std.fmt.allocPrint(
                    allocator,
                    "-{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}",
                    .{ abs_year, self.month, self.day, self.hour, self.minute, self.second, self.millisecond },
                );
            }
        } else {
            const year: u32 = @intCast(self.year);
            if (total_subsec == 0) {
                return std.fmt.allocPrint(
                    allocator,
                    "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}",
                    .{ year, self.month, self.day, self.hour, self.minute, self.second },
                );
            } else {
                return std.fmt.allocPrint(
                    allocator,
                    "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}",
                    .{ year, self.month, self.day, self.hour, self.minute, self.second, self.millisecond },
                );
            }
        }
    }
};

// ============================================================================
// Temporal.ZonedDateTime - A date, time, and time zone
// ============================================================================

pub const ZonedDateTime = struct {
    year: i32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    millisecond: u16,
    microsecond: u16,
    nanosecond: u16,
    time_zone: []const u8,
    offset_seconds: i32,

    /// Create from an Instant in a specific time zone
    pub fn fromInstant(instant: Instant, time_zone: []const u8, offset_seconds: i32) ZonedDateTime {
        // Adjust for timezone offset
        const adjusted_seconds = instant.epochSeconds() + offset_seconds;
        const subsec_nanos: u32 = @intCast(@mod(instant.epoch_nanoseconds, std.time.ns_per_s));

        const components = epochToComponents(adjusted_seconds);

        const millisecond: u16 = @intCast(@divTrunc(subsec_nanos, std.time.ns_per_ms));
        const remaining_us = @mod(subsec_nanos, std.time.ns_per_ms);
        const microsecond: u16 = @intCast(@divTrunc(remaining_us, std.time.ns_per_us));
        const nanosecond: u16 = @intCast(@mod(remaining_us, std.time.ns_per_us));

        return .{
            .year = @intCast(components.year),
            .month = components.month,
            .day = components.day,
            .hour = components.hour,
            .minute = components.minute,
            .second = components.second,
            .millisecond = millisecond,
            .microsecond = microsecond,
            .nanosecond = nanosecond,
            .time_zone = time_zone,
            .offset_seconds = offset_seconds,
        };
    }

    /// Get the corresponding Instant
    pub fn toInstant(self: ZonedDateTime) Instant {
        const days = dateToDays(self.year, self.month, self.day);
        const day_seconds = @as(i64, self.hour) * 3600 + @as(i64, self.minute) * 60 + self.second;
        const total_seconds = @as(i64, days) * 86400 + day_seconds - self.offset_seconds;

        const subsec_ns = @as(i128, self.millisecond) * std.time.ns_per_ms +
            @as(i128, self.microsecond) * std.time.ns_per_us +
            self.nanosecond;

        return Instant{
            .epoch_nanoseconds = @as(i128, total_seconds) * std.time.ns_per_s + subsec_ns,
        };
    }

    /// Get the date part
    pub fn toPlainDate(self: ZonedDateTime) PlainDate {
        return .{ .year = self.year, .month = self.month, .day = self.day };
    }

    /// Get the time part
    pub fn toPlainTime(self: ZonedDateTime) PlainTime {
        return .{
            .hour = self.hour,
            .minute = self.minute,
            .second = self.second,
            .millisecond = self.millisecond,
            .microsecond = self.microsecond,
            .nanosecond = self.nanosecond,
        };
    }

    /// Get the date-time part (without timezone)
    pub fn toPlainDateTime(self: ZonedDateTime) PlainDateTime {
        return .{
            .year = self.year,
            .month = self.month,
            .day = self.day,
            .hour = self.hour,
            .minute = self.minute,
            .second = self.second,
            .millisecond = self.millisecond,
            .microsecond = self.microsecond,
            .nanosecond = self.nanosecond,
        };
    }

    /// Convert to a different time zone
    pub fn withTimeZone(self: ZonedDateTime, new_time_zone: []const u8) ZonedDateTime {
        const instant = self.toInstant();
        const new_offset = TimeZone.getOffset(new_time_zone);
        return fromInstant(instant, new_time_zone, new_offset);
    }

    /// Get offset as string (e.g., "+05:30" or "-08:00")
    pub fn offsetString(self: ZonedDateTime, allocator: std.mem.Allocator) ![]u8 {
        const sign: u8 = if (self.offset_seconds >= 0) '+' else '-';
        const abs_offset: u32 = @intCast(if (self.offset_seconds >= 0) self.offset_seconds else -self.offset_seconds);
        const hours = @divTrunc(abs_offset, 3600);
        const minutes = @divTrunc(@mod(abs_offset, 3600), 60);
        return std.fmt.allocPrint(allocator, "{c}{d:0>2}:{d:0>2}", .{ sign, hours, minutes });
    }

    /// Format as ISO 8601 string with timezone
    pub fn toString(self: ZonedDateTime, allocator: std.mem.Allocator) ![]u8 {
        const offset_str = try self.offsetString(allocator);
        defer allocator.free(offset_str);

        const total_subsec = @as(u32, self.millisecond) * 1_000_000 +
            @as(u32, self.microsecond) * 1_000 +
            @as(u32, self.nanosecond);

        // Handle negative years (BCE dates)
        if (self.year < 0) {
            const abs_year: u32 = @intCast(-self.year);
            if (total_subsec == 0) {
                return std.fmt.allocPrint(
                    allocator,
                    "-{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}{s}[{s}]",
                    .{ abs_year, self.month, self.day, self.hour, self.minute, self.second, offset_str, self.time_zone },
                );
            } else {
                return std.fmt.allocPrint(
                    allocator,
                    "-{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}{s}[{s}]",
                    .{ abs_year, self.month, self.day, self.hour, self.minute, self.second, self.millisecond, offset_str, self.time_zone },
                );
            }
        } else {
            const year: u32 = @intCast(self.year);
            if (total_subsec == 0) {
                return std.fmt.allocPrint(
                    allocator,
                    "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}{s}[{s}]",
                    .{ year, self.month, self.day, self.hour, self.minute, self.second, offset_str, self.time_zone },
                );
            } else {
                return std.fmt.allocPrint(
                    allocator,
                    "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}{s}[{s}]",
                    .{ year, self.month, self.day, self.hour, self.minute, self.second, self.millisecond, offset_str, self.time_zone },
                );
            }
        }
    }
};

// ============================================================================
// Temporal.Duration - A length of time
// ============================================================================

pub const Duration = struct {
    total_nanoseconds: i128,

    /// Create from nanoseconds
    pub fn fromNanoseconds(ns: i128) Duration {
        return .{ .total_nanoseconds = ns };
    }

    /// Create from microseconds
    pub fn fromMicroseconds(us: i64) Duration {
        return .{ .total_nanoseconds = @as(i128, us) * std.time.ns_per_us };
    }

    /// Create from milliseconds
    pub fn fromMilliseconds(ms: i64) Duration {
        return .{ .total_nanoseconds = @as(i128, ms) * std.time.ns_per_ms };
    }

    /// Create from seconds
    pub fn fromSeconds(s: i64) Duration {
        return .{ .total_nanoseconds = @as(i128, s) * std.time.ns_per_s };
    }

    /// Create from minutes
    pub fn fromMinutes(m: i64) Duration {
        return fromSeconds(m * 60);
    }

    /// Create from hours
    pub fn fromHours(h: i64) Duration {
        return fromSeconds(h * 3600);
    }

    /// Create from days
    pub fn fromDays(d: i64) Duration {
        return fromSeconds(d * 86400);
    }

    /// Create from weeks
    pub fn fromWeeks(w: i64) Duration {
        return fromDays(w * 7);
    }

    /// Get total nanoseconds
    pub fn totalNanoseconds(self: Duration) i128 {
        return self.total_nanoseconds;
    }

    /// Get total microseconds (truncated)
    pub fn totalMicroseconds(self: Duration) i64 {
        return @intCast(@divTrunc(self.total_nanoseconds, std.time.ns_per_us));
    }

    /// Get total milliseconds (truncated)
    pub fn totalMilliseconds(self: Duration) i64 {
        return @intCast(@divTrunc(self.total_nanoseconds, std.time.ns_per_ms));
    }

    /// Get total seconds (truncated)
    pub fn totalSeconds(self: Duration) i64 {
        return @intCast(@divTrunc(self.total_nanoseconds, std.time.ns_per_s));
    }

    /// Get total minutes (truncated)
    pub fn totalMinutes(self: Duration) i64 {
        return @intCast(@divTrunc(self.total_nanoseconds, 60 * std.time.ns_per_s));
    }

    /// Get total hours (truncated)
    pub fn totalHours(self: Duration) i64 {
        return @intCast(@divTrunc(self.total_nanoseconds, 3600 * std.time.ns_per_s));
    }

    /// Get total days (truncated)
    pub fn totalDays(self: Duration) i32 {
        return @intCast(@divTrunc(self.total_nanoseconds, 86400 * std.time.ns_per_s));
    }

    /// Add two durations
    pub fn add(self: Duration, other: Duration) Duration {
        return .{ .total_nanoseconds = self.total_nanoseconds + other.total_nanoseconds };
    }

    /// Subtract two durations
    pub fn subtract(self: Duration, other: Duration) Duration {
        return .{ .total_nanoseconds = self.total_nanoseconds - other.total_nanoseconds };
    }

    /// Negate duration
    pub fn negated(self: Duration) Duration {
        return .{ .total_nanoseconds = -self.total_nanoseconds };
    }

    /// Get absolute value
    pub fn abs(self: Duration) Duration {
        return .{
            .total_nanoseconds = if (self.total_nanoseconds < 0) -self.total_nanoseconds else self.total_nanoseconds,
        };
    }

    /// Check if zero
    pub fn isZero(self: Duration) bool {
        return self.total_nanoseconds == 0;
    }

    /// Check if negative
    pub fn isNegative(self: Duration) bool {
        return self.total_nanoseconds < 0;
    }

    /// Compare two durations
    pub fn compare(self: Duration, other: Duration) std.math.Order {
        return std.math.order(self.total_nanoseconds, other.total_nanoseconds);
    }
};

// ============================================================================
// Temporal.Now - Static methods for getting current time
// ============================================================================

pub const Now = struct {
    /// Private helper to get system time zone
    /// Returns the IANA time zone identifier for the system's current time zone.
    /// This is a best-effort implementation that tries multiple methods.
    fn getSystemTimeZone() []const u8 {
        // On POSIX systems, try to read /etc/localtime symlink or TZ env var
        // For now, return a reasonable default - a full implementation would
        // use platform-specific APIs or read system configuration

        // Try TZ environment variable first
        if (std.posix.getenv("TZ")) |tz| {
            if (tz.len > 0) {
                return tz;
            }
        }

        // Default to UTC if we can't determine the system timezone
        // A production implementation would use platform-specific APIs:
        // - macOS: CFTimeZoneCopySystem()
        // - Linux: /etc/localtime symlink target
        // - Windows: GetDynamicTimeZoneInformation()
        return "UTC";
    }

    /// Returns the current time as a Temporal.Instant object.
    /// The Instant represents an exact point on the timeline.
    pub fn instant() Instant {
        const ns = getWallClockNanoseconds();
        return Instant{ .epoch_nanoseconds = ns };
    }

    /// Returns the system's current time zone identifier.
    /// Returns an IANA time zone identifier string (e.g., "America/New_York").
    pub fn timeZoneId() []const u8 {
        return getSystemTimeZone();
    }

    /// Returns the current date and time as a Temporal.ZonedDateTime object,
    /// in the ISO 8601 calendar and the specified time zone.
    /// If no time zone is specified, uses the system time zone.
    pub fn zonedDateTimeISO(time_zone: ?[]const u8) ZonedDateTime {
        const tz = time_zone orelse getSystemTimeZone();
        return instant().toZonedDateTimeISO(tz);
    }

    /// Returns the current date as a Temporal.PlainDate object,
    /// in the ISO 8601 calendar and the specified time zone.
    /// If no time zone is specified, uses the system time zone.
    pub fn plainDateISO(time_zone: ?[]const u8) PlainDate {
        const zdt = zonedDateTimeISO(time_zone);
        return zdt.toPlainDate();
    }

    /// Returns the current time as a Temporal.PlainTime object,
    /// in the specified time zone.
    /// If no time zone is specified, uses the system time zone.
    pub fn plainTimeISO(time_zone: ?[]const u8) PlainTime {
        const zdt = zonedDateTimeISO(time_zone);
        return zdt.toPlainTime();
    }

    /// Returns the current date and time as a Temporal.PlainDateTime object,
    /// in the ISO 8601 calendar and the specified time zone.
    /// If no time zone is specified, uses the system time zone.
    pub fn plainDateTimeISO(time_zone: ?[]const u8) PlainDateTime {
        const zdt = zonedDateTimeISO(time_zone);
        return zdt.toPlainDateTime();
    }
};

// ============================================================================
// TimeZone utilities
// ============================================================================

pub const TimeZone = struct {
    /// Common timezone offsets (in seconds from UTC)
    pub const UTC: i32 = 0;
    pub const GMT: i32 = 0;
    pub const EST: i32 = -5 * 3600; // Eastern Standard Time
    pub const EDT: i32 = -4 * 3600; // Eastern Daylight Time
    pub const CST: i32 = -6 * 3600; // Central Standard Time
    pub const CDT: i32 = -5 * 3600; // Central Daylight Time
    pub const MST: i32 = -7 * 3600; // Mountain Standard Time
    pub const MDT: i32 = -6 * 3600; // Mountain Daylight Time
    pub const PST: i32 = -8 * 3600; // Pacific Standard Time
    pub const PDT: i32 = -7 * 3600; // Pacific Daylight Time
    pub const CET: i32 = 1 * 3600; // Central European Time
    pub const CEST: i32 = 2 * 3600; // Central European Summer Time
    pub const JST: i32 = 9 * 3600; // Japan Standard Time
    pub const IST: i32 = 5 * 3600 + 30 * 60; // India Standard Time
    pub const AEST: i32 = 10 * 3600; // Australian Eastern Standard Time
    pub const AEDT: i32 = 11 * 3600; // Australian Eastern Daylight Time

    /// Get offset in seconds for a timezone identifier
    /// This is a simplified implementation that handles common IANA timezone names
    /// A full implementation would use a timezone database (tzdata/zoneinfo)
    pub fn getOffset(tz_id: []const u8) i32 {
        // Handle common timezone abbreviations and IANA names
        if (std.mem.eql(u8, tz_id, "UTC") or std.mem.eql(u8, tz_id, "Etc/UTC")) return UTC;
        if (std.mem.eql(u8, tz_id, "GMT") or std.mem.eql(u8, tz_id, "Etc/GMT")) return GMT;

        // Americas
        if (std.mem.eql(u8, tz_id, "America/New_York")) return EST;
        if (std.mem.eql(u8, tz_id, "America/Chicago")) return CST;
        if (std.mem.eql(u8, tz_id, "America/Denver")) return MST;
        if (std.mem.eql(u8, tz_id, "America/Los_Angeles")) return PST;

        // Europe
        if (std.mem.eql(u8, tz_id, "Europe/London")) return UTC;
        if (std.mem.eql(u8, tz_id, "Europe/Paris")) return CET;
        if (std.mem.eql(u8, tz_id, "Europe/Berlin")) return CET;

        // Asia
        if (std.mem.eql(u8, tz_id, "Asia/Tokyo")) return JST;
        if (std.mem.eql(u8, tz_id, "Asia/Kolkata") or std.mem.eql(u8, tz_id, "Asia/Calcutta")) return IST;
        if (std.mem.eql(u8, tz_id, "Asia/Shanghai")) return 8 * 3600;
        if (std.mem.eql(u8, tz_id, "Asia/Hong_Kong")) return 8 * 3600;
        if (std.mem.eql(u8, tz_id, "Asia/Singapore")) return 8 * 3600;

        // Australia
        if (std.mem.eql(u8, tz_id, "Australia/Sydney")) return AEST;
        if (std.mem.eql(u8, tz_id, "Australia/Melbourne")) return AEST;

        // Default to UTC for unknown timezones
        return UTC;
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

const DateComponents = struct {
    year: u32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
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

/// Convert Unix timestamp (seconds) to date components
fn epochToComponents(epoch_seconds: i64) DateComponents {
    var remaining = epoch_seconds;
    if (remaining < 0) {
        // Handle negative timestamps (before 1970)
        remaining = 0; // Simplified: clamp to epoch
    }

    const days_since_epoch = @divTrunc(remaining, 86400);
    const seconds_in_day = @mod(remaining, 86400);

    const hour: u8 = @intCast(@divTrunc(seconds_in_day, 3600));
    const minute: u8 = @intCast(@divTrunc(@mod(seconds_in_day, 3600), 60));
    const second: u8 = @intCast(@mod(seconds_in_day, 60));

    // Calculate year, month, day from days since epoch
    var year: u32 = 1970;
    var remaining_days = days_since_epoch;

    // Fast path: approximate year
    const approx_years: i64 = @divTrunc(remaining_days * 400, 146097);
    if (approx_years > 0) {
        year += @intCast(approx_years - 1);
        remaining_days -= yearsToDays(@intCast(approx_years - 1));
    }

    // Fine-tune year
    while (remaining_days >= (if (isLeapYear(year)) @as(i64, 366) else @as(i64, 365))) {
        const days_in_year: i64 = if (isLeapYear(year)) 366 else 365;
        remaining_days -= days_in_year;
        year += 1;
    }

    // Calculate month and day
    var month: u8 = 1;
    while (month <= 12) {
        const days_in_month = getDaysInMonth(year, month);
        if (remaining_days < days_in_month) break;
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

/// Calculate days from a number of years since 1970
fn yearsToDays(years: u32) i64 {
    if (years == 0) return 0;

    var days: i64 = 0;
    var y: u32 = 1970;
    const target = 1970 + years;

    while (y < target) : (y += 1) {
        days += if (isLeapYear(y)) 366 else 365;
    }

    return days;
}

/// Convert date to days since Unix epoch
fn dateToDays(year: i32, month: u8, day: u8) i32 {
    var days: i32 = 0;

    // Days from years
    if (year >= 1970) {
        var y: u32 = 1970;
        while (y < @as(u32, @intCast(year))) : (y += 1) {
            days += if (isLeapYear(y)) 366 else 365;
        }
    } else {
        var y: u32 = @intCast(year);
        while (y < 1970) : (y += 1) {
            days -= if (isLeapYear(y)) 366 else 365;
        }
    }

    // Days from months
    var m: u8 = 1;
    while (m < month) : (m += 1) {
        days += getDaysInMonth(@intCast(year), m);
    }

    // Days in current month
    days += day - 1;

    return days;
}

/// Convert days since epoch to PlainDate
fn daysToDate(days: i32) !PlainDate {
    var remaining = days;
    var year: i32 = 1970;

    if (remaining >= 0) {
        while (true) {
            const days_in_year: i32 = if (isLeapYear(@intCast(year))) 366 else 365;
            if (remaining < days_in_year) break;
            remaining -= days_in_year;
            year += 1;
        }
    } else {
        while (remaining < 0) {
            year -= 1;
            const days_in_year: i32 = if (isLeapYear(@intCast(year))) 366 else 365;
            remaining += days_in_year;
        }
    }

    var month: u8 = 1;
    while (month <= 12) {
        const days_in_month = getDaysInMonth(@intCast(year), month);
        if (remaining < days_in_month) break;
        remaining -= days_in_month;
        month += 1;
    }

    const day: u8 = @intCast(remaining + 1);

    return PlainDate{ .year = year, .month = month, .day = day };
}

// ============================================================================
// Tests
// ============================================================================

test "Instant creation and conversion" {
    const instant = Instant.fromEpochSeconds(0);
    try std.testing.expectEqual(@as(i64, 0), instant.epochSeconds());
    try std.testing.expectEqual(@as(i64, 0), instant.epochMilliseconds());

    const instant2 = Instant.fromEpochMilliseconds(1000);
    try std.testing.expectEqual(@as(i64, 1), instant2.epochSeconds());
    try std.testing.expectEqual(@as(i64, 1000), instant2.epochMilliseconds());
}

test "Now.instant returns current time" {
    const before = getWallClockNanoseconds();
    const instant = Now.instant();
    const after = getWallClockNanoseconds();

    try std.testing.expect(instant.epoch_nanoseconds >= before);
    try std.testing.expect(instant.epoch_nanoseconds <= after);
}

test "PlainDate creation and validation" {
    const date = try PlainDate.from(2024, 2, 29);
    try std.testing.expectEqual(@as(i32, 2024), date.year);
    try std.testing.expectEqual(@as(u8, 2), date.month);
    try std.testing.expectEqual(@as(u8, 29), date.day);

    // Invalid date should fail
    try std.testing.expectError(error.InvalidDay, PlainDate.from(2023, 2, 29));
    try std.testing.expectError(error.InvalidMonth, PlainDate.from(2024, 13, 1));
}

test "PlainDate leap year" {
    const leap_date = try PlainDate.from(2024, 1, 1);
    try std.testing.expect(leap_date.inLeapYear());

    const non_leap_date = try PlainDate.from(2023, 1, 1);
    try std.testing.expect(!non_leap_date.inLeapYear());
}

test "PlainTime creation and conversion" {
    const time = try PlainTime.from(14, 30, 45, 123, 456, 789);
    try std.testing.expectEqual(@as(u8, 14), time.hour);
    try std.testing.expectEqual(@as(u8, 30), time.minute);
    try std.testing.expectEqual(@as(u8, 45), time.second);
    try std.testing.expectEqual(@as(u16, 123), time.millisecond);
}

test "PlainDateTime from date and time" {
    const date = try PlainDate.from(2024, 6, 15);
    const time = try PlainTime.fromHMS(10, 30, 0);
    const dt = PlainDateTime.fromDateAndTime(date, time);

    try std.testing.expectEqual(@as(i32, 2024), dt.year);
    try std.testing.expectEqual(@as(u8, 6), dt.month);
    try std.testing.expectEqual(@as(u8, 15), dt.day);
    try std.testing.expectEqual(@as(u8, 10), dt.hour);
    try std.testing.expectEqual(@as(u8, 30), dt.minute);
}

test "Duration arithmetic" {
    const d1 = Duration.fromSeconds(60);
    const d2 = Duration.fromMinutes(1);

    try std.testing.expectEqual(d1.total_nanoseconds, d2.total_nanoseconds);

    const sum = d1.add(d2);
    try std.testing.expectEqual(@as(i64, 120), sum.totalSeconds());
}

test "Now methods return valid data" {
    const date = Now.plainDateISO(null);
    try std.testing.expect(date.year >= 2024);
    try std.testing.expect(date.month >= 1 and date.month <= 12);
    try std.testing.expect(date.day >= 1 and date.day <= 31);

    const time = Now.plainTimeISO(null);
    try std.testing.expect(time.hour <= 23);
    try std.testing.expect(time.minute <= 59);
    try std.testing.expect(time.second <= 59);
}

test "ZonedDateTime with timezone" {
    const zdt = Now.zonedDateTimeISO("America/New_York");
    try std.testing.expect(zdt.offset_seconds == TimeZone.EST);

    const utc_zdt = Now.zonedDateTimeISO("UTC");
    try std.testing.expect(utc_zdt.offset_seconds == 0);
}

test "Instant toString" {
    const allocator = std.testing.allocator;
    const instant = Instant.fromEpochSeconds(0);
    const str = try instant.toString(allocator);
    defer allocator.free(str);

    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", str);
}

test "PlainDate toString" {
    const allocator = std.testing.allocator;
    const date = try PlainDate.from(2024, 6, 15);
    const str = try date.toString(allocator);
    defer allocator.free(str);

    try std.testing.expectEqualStrings("2024-06-15", str);
}
