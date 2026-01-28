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

        const adjusted_day: i16 = @as(i16, @intCast(day_of_year)) + jan1_offset;
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

// ============================================================================
// Edge Case Tests
// ============================================================================

// --- Instant Edge Cases ---

test "Instant: Unix epoch (zero)" {
    const epoch = Instant.fromEpochSeconds(0);
    try std.testing.expectEqual(@as(i128, 0), epoch.epoch_nanoseconds);
    try std.testing.expectEqual(@as(i64, 0), epoch.epochSeconds());
    try std.testing.expectEqual(@as(i64, 0), epoch.epochMilliseconds());
    try std.testing.expectEqual(@as(i64, 0), epoch.epochMicroseconds());
}

test "Instant: negative timestamps (before 1970)" {
    // One day before epoch
    const before_epoch = Instant.fromEpochSeconds(-86400);
    try std.testing.expectEqual(@as(i64, -86400), before_epoch.epochSeconds());

    // One year before epoch (1969)
    const year_before = Instant.fromEpochSeconds(-365 * 86400);
    try std.testing.expectEqual(@as(i64, -365 * 86400), year_before.epochSeconds());
}

test "Instant: nanosecond precision boundaries" {
    // 1 nanosecond
    const one_ns = Instant.fromEpochNanoseconds(1);
    try std.testing.expectEqual(@as(i128, 1), one_ns.epochNanoseconds());
    try std.testing.expectEqual(@as(i64, 0), one_ns.epochMicroseconds()); // Truncated

    // 999 nanoseconds (just under 1 microsecond)
    const under_us = Instant.fromEpochNanoseconds(999);
    try std.testing.expectEqual(@as(i64, 0), under_us.epochMicroseconds());

    // Exactly 1 microsecond
    const one_us = Instant.fromEpochMicroseconds(1);
    try std.testing.expectEqual(@as(i64, 1), one_us.epochMicroseconds());

    // 999,999 nanoseconds (just under 1 millisecond)
    const under_ms = Instant.fromEpochNanoseconds(999_999);
    try std.testing.expectEqual(@as(i64, 0), under_ms.epochMilliseconds());

    // Exactly 1 millisecond
    const one_ms = Instant.fromEpochMilliseconds(1);
    try std.testing.expectEqual(@as(i64, 1), one_ms.epochMilliseconds());
}

test "Instant: large timestamps (far future)" {
    // Year 3000 approximately (in seconds since epoch)
    const year_3000: i64 = 32503680000;
    const future = Instant.fromEpochSeconds(year_3000);
    try std.testing.expectEqual(year_3000, future.epochSeconds());
}

test "Instant: duration arithmetic" {
    const start = Instant.fromEpochSeconds(1000);
    const duration = Duration.fromSeconds(500);

    const later = start.add(duration);
    try std.testing.expectEqual(@as(i64, 1500), later.epochSeconds());

    const earlier = start.subtract(duration);
    try std.testing.expectEqual(@as(i64, 500), earlier.epochSeconds());
}

test "Instant: since and until" {
    const t1 = Instant.fromEpochSeconds(1000);
    const t2 = Instant.fromEpochSeconds(2000);

    const since = t2.since(t1);
    try std.testing.expectEqual(@as(i64, 1000), since.totalSeconds());

    const until = t1.until(t2);
    try std.testing.expectEqual(@as(i64, 1000), until.totalSeconds());
}

test "Instant: comparison" {
    const t1 = Instant.fromEpochSeconds(1000);
    const t2 = Instant.fromEpochSeconds(2000);
    const t3 = Instant.fromEpochSeconds(1000);

    try std.testing.expectEqual(std.math.Order.lt, t1.compare(t2));
    try std.testing.expectEqual(std.math.Order.gt, t2.compare(t1));
    try std.testing.expectEqual(std.math.Order.eq, t1.compare(t3));
    try std.testing.expect(t1.equals(t3));
    try std.testing.expect(!t1.equals(t2));
}

test "Instant: toString with milliseconds" {
    const allocator = std.testing.allocator;

    // With fractional seconds
    const instant_ms = Instant.fromEpochMilliseconds(1500); // 1.5 seconds
    const str_ms = try instant_ms.toString(allocator);
    defer allocator.free(str_ms);
    try std.testing.expectEqualStrings("1970-01-01T00:00:01.500Z", str_ms);
}

// --- PlainDate Edge Cases ---

test "PlainDate: leap year rules" {
    // Regular leap year (divisible by 4)
    const leap_2024 = try PlainDate.from(2024, 1, 1);
    try std.testing.expect(leap_2024.inLeapYear());

    // Century year not divisible by 400 (NOT a leap year)
    const not_leap_1900 = try PlainDate.from(1900, 1, 1);
    try std.testing.expect(!not_leap_1900.inLeapYear());

    // Century year divisible by 400 (IS a leap year)
    const leap_2000 = try PlainDate.from(2000, 1, 1);
    try std.testing.expect(leap_2000.inLeapYear());

    // Regular non-leap year
    const not_leap_2023 = try PlainDate.from(2023, 1, 1);
    try std.testing.expect(!not_leap_2023.inLeapYear());
}

test "PlainDate: February edge cases" {
    // Feb 29 in leap year - valid
    const feb29_leap = try PlainDate.from(2024, 2, 29);
    try std.testing.expectEqual(@as(u8, 29), feb29_leap.day);

    // Feb 29 in non-leap year - invalid
    try std.testing.expectError(error.InvalidDay, PlainDate.from(2023, 2, 29));

    // Feb 28 in non-leap year - valid
    const feb28 = try PlainDate.from(2023, 2, 28);
    try std.testing.expectEqual(@as(u8, 28), feb28.day);

    // Feb 30 - always invalid
    try std.testing.expectError(error.InvalidDay, PlainDate.from(2024, 2, 30));
}

test "PlainDate: month day boundaries" {
    // 31-day months
    _ = try PlainDate.from(2024, 1, 31); // January
    _ = try PlainDate.from(2024, 3, 31); // March
    _ = try PlainDate.from(2024, 5, 31); // May
    _ = try PlainDate.from(2024, 7, 31); // July
    _ = try PlainDate.from(2024, 8, 31); // August
    _ = try PlainDate.from(2024, 10, 31); // October
    _ = try PlainDate.from(2024, 12, 31); // December

    // 30-day months - day 31 invalid
    try std.testing.expectError(error.InvalidDay, PlainDate.from(2024, 4, 31)); // April
    try std.testing.expectError(error.InvalidDay, PlainDate.from(2024, 6, 31)); // June
    try std.testing.expectError(error.InvalidDay, PlainDate.from(2024, 9, 31)); // September
    try std.testing.expectError(error.InvalidDay, PlainDate.from(2024, 11, 31)); // November

    // 30-day months - day 30 valid
    _ = try PlainDate.from(2024, 4, 30);
    _ = try PlainDate.from(2024, 6, 30);
    _ = try PlainDate.from(2024, 9, 30);
    _ = try PlainDate.from(2024, 11, 30);
}

test "PlainDate: invalid month values" {
    try std.testing.expectError(error.InvalidMonth, PlainDate.from(2024, 0, 1));
    try std.testing.expectError(error.InvalidMonth, PlainDate.from(2024, 13, 1));
    try std.testing.expectError(error.InvalidMonth, PlainDate.from(2024, 255, 1));
}

test "PlainDate: invalid day values" {
    try std.testing.expectError(error.InvalidDay, PlainDate.from(2024, 1, 0));
    try std.testing.expectError(error.InvalidDay, PlainDate.from(2024, 1, 32));
}

test "PlainDate: day of week calculation" {
    // Known dates for verification
    // January 1, 2024 is Monday (1)
    const jan1_2024 = try PlainDate.from(2024, 1, 1);
    try std.testing.expectEqual(@as(u8, 1), jan1_2024.dayOfWeek());

    // June 15, 2024 is Saturday (6)
    const jun15_2024 = try PlainDate.from(2024, 6, 15);
    try std.testing.expectEqual(@as(u8, 6), jun15_2024.dayOfWeek());

    // December 25, 2024 is Wednesday (3)
    const dec25_2024 = try PlainDate.from(2024, 12, 25);
    try std.testing.expectEqual(@as(u8, 3), dec25_2024.dayOfWeek());

    // January 1, 1970 (Unix epoch) is Thursday (4)
    const epoch = try PlainDate.from(1970, 1, 1);
    try std.testing.expectEqual(@as(u8, 4), epoch.dayOfWeek());

    // Sunday should be 7
    const sunday = try PlainDate.from(2024, 1, 7);
    try std.testing.expectEqual(@as(u8, 7), sunday.dayOfWeek());
}

test "PlainDate: day of year calculation" {
    // January 1 is day 1
    const jan1 = try PlainDate.from(2024, 1, 1);
    try std.testing.expectEqual(@as(u16, 1), jan1.dayOfYear());

    // December 31 in leap year is day 366
    const dec31_leap = try PlainDate.from(2024, 12, 31);
    try std.testing.expectEqual(@as(u16, 366), dec31_leap.dayOfYear());

    // December 31 in non-leap year is day 365
    const dec31_non_leap = try PlainDate.from(2023, 12, 31);
    try std.testing.expectEqual(@as(u16, 365), dec31_non_leap.dayOfYear());

    // March 1 in leap year (after Feb 29) is day 61
    const mar1_leap = try PlainDate.from(2024, 3, 1);
    try std.testing.expectEqual(@as(u16, 61), mar1_leap.dayOfYear());

    // March 1 in non-leap year is day 60
    const mar1_non_leap = try PlainDate.from(2023, 3, 1);
    try std.testing.expectEqual(@as(u16, 60), mar1_non_leap.dayOfYear());
}

test "PlainDate: daysInMonth" {
    const jan = try PlainDate.from(2024, 1, 15);
    try std.testing.expectEqual(@as(u8, 31), jan.daysInMonth());

    const feb_leap = try PlainDate.from(2024, 2, 15);
    try std.testing.expectEqual(@as(u8, 29), feb_leap.daysInMonth());

    const feb_non_leap = try PlainDate.from(2023, 2, 15);
    try std.testing.expectEqual(@as(u8, 28), feb_non_leap.daysInMonth());

    const apr = try PlainDate.from(2024, 4, 15);
    try std.testing.expectEqual(@as(u8, 30), apr.daysInMonth());
}

test "PlainDate: daysInYear" {
    const leap = try PlainDate.from(2024, 6, 15);
    try std.testing.expectEqual(@as(u16, 366), leap.daysInYear());

    const non_leap = try PlainDate.from(2023, 6, 15);
    try std.testing.expectEqual(@as(u16, 365), non_leap.daysInYear());
}

test "PlainDate: addDays crossing month boundary" {
    // Jan 31 + 1 day = Feb 1
    const jan31 = try PlainDate.from(2024, 1, 31);
    const feb1 = try jan31.addDays(1);
    try std.testing.expectEqual(@as(u8, 2), feb1.month);
    try std.testing.expectEqual(@as(u8, 1), feb1.day);

    // Feb 28 + 1 day in leap year = Feb 29
    const feb28_leap = try PlainDate.from(2024, 2, 28);
    const feb29 = try feb28_leap.addDays(1);
    try std.testing.expectEqual(@as(u8, 2), feb29.month);
    try std.testing.expectEqual(@as(u8, 29), feb29.day);

    // Feb 28 + 1 day in non-leap year = Mar 1
    const feb28_non_leap = try PlainDate.from(2023, 2, 28);
    const mar1 = try feb28_non_leap.addDays(1);
    try std.testing.expectEqual(@as(u8, 3), mar1.month);
    try std.testing.expectEqual(@as(u8, 1), mar1.day);
}

test "PlainDate: addDays crossing year boundary" {
    // Dec 31 + 1 day = Jan 1 next year
    const dec31 = try PlainDate.from(2024, 12, 31);
    const jan1_next = try dec31.addDays(1);
    try std.testing.expectEqual(@as(i32, 2025), jan1_next.year);
    try std.testing.expectEqual(@as(u8, 1), jan1_next.month);
    try std.testing.expectEqual(@as(u8, 1), jan1_next.day);
}

test "PlainDate: addDays negative (going backwards)" {
    // Jan 1 - 1 day = Dec 31 previous year
    const jan1 = try PlainDate.from(2024, 1, 1);
    const dec31_prev = try jan1.addDays(-1);
    try std.testing.expectEqual(@as(i32, 2023), dec31_prev.year);
    try std.testing.expectEqual(@as(u8, 12), dec31_prev.month);
    try std.testing.expectEqual(@as(u8, 31), dec31_prev.day);

    // Mar 1 - 1 day in leap year = Feb 29
    const mar1_leap = try PlainDate.from(2024, 3, 1);
    const feb29_result = try mar1_leap.addDays(-1);
    try std.testing.expectEqual(@as(u8, 2), feb29_result.month);
    try std.testing.expectEqual(@as(u8, 29), feb29_result.day);
}

test "PlainDate: addMonths edge cases" {
    // Jan 31 + 1 month = Feb 29 (leap year, clamped)
    const jan31 = try PlainDate.from(2024, 1, 31);
    const feb_result = try jan31.addMonths(1);
    try std.testing.expectEqual(@as(u8, 2), feb_result.month);
    try std.testing.expectEqual(@as(u8, 29), feb_result.day); // Clamped to Feb 29

    // Jan 31 + 1 month in non-leap year = Feb 28 (clamped)
    const jan31_2023 = try PlainDate.from(2023, 1, 31);
    const feb_result_2023 = try jan31_2023.addMonths(1);
    try std.testing.expectEqual(@as(u8, 2), feb_result_2023.month);
    try std.testing.expectEqual(@as(u8, 28), feb_result_2023.day); // Clamped to Feb 28

    // Adding 12 months = same date next year
    const jun15 = try PlainDate.from(2024, 6, 15);
    const jun15_next = try jun15.addMonths(12);
    try std.testing.expectEqual(@as(i32, 2025), jun15_next.year);
    try std.testing.expectEqual(@as(u8, 6), jun15_next.month);
    try std.testing.expectEqual(@as(u8, 15), jun15_next.day);

    // Negative months
    const mar15 = try PlainDate.from(2024, 3, 15);
    const jan15 = try mar15.addMonths(-2);
    try std.testing.expectEqual(@as(u8, 1), jan15.month);
}

test "PlainDate: addYears edge cases" {
    // Feb 29 + 1 year = Feb 28 (non-leap year, clamped)
    const feb29 = try PlainDate.from(2024, 2, 29);
    const next_year = try feb29.addYears(1);
    try std.testing.expectEqual(@as(i32, 2025), next_year.year);
    try std.testing.expectEqual(@as(u8, 2), next_year.month);
    try std.testing.expectEqual(@as(u8, 28), next_year.day); // Clamped

    // Feb 29 + 4 years = Feb 29 (still leap year)
    const four_years = try feb29.addYears(4);
    try std.testing.expectEqual(@as(i32, 2028), four_years.year);
    try std.testing.expectEqual(@as(u8, 29), four_years.day);
}

test "PlainDate: comparison" {
    const d1 = try PlainDate.from(2024, 1, 1);
    const d2 = try PlainDate.from(2024, 1, 2);
    const d3 = try PlainDate.from(2024, 1, 1);

    try std.testing.expectEqual(std.math.Order.lt, d1.compare(d2));
    try std.testing.expectEqual(std.math.Order.gt, d2.compare(d1));
    try std.testing.expectEqual(std.math.Order.eq, d1.compare(d3));
    try std.testing.expect(d1.equals(d3));
    try std.testing.expect(!d1.equals(d2));
}

// --- PlainTime Edge Cases ---

test "PlainTime: midnight" {
    const midnight = try PlainTime.fromHMS(0, 0, 0);
    try std.testing.expectEqual(@as(u8, 0), midnight.hour);
    try std.testing.expectEqual(@as(u8, 0), midnight.minute);
    try std.testing.expectEqual(@as(u8, 0), midnight.second);
    try std.testing.expectEqual(@as(u64, 0), midnight.toNanoseconds());
}

test "PlainTime: just before midnight" {
    const before_midnight = try PlainTime.from(23, 59, 59, 999, 999, 999);
    try std.testing.expectEqual(@as(u8, 23), before_midnight.hour);
    try std.testing.expectEqual(@as(u8, 59), before_midnight.minute);
    try std.testing.expectEqual(@as(u8, 59), before_midnight.second);
    try std.testing.expectEqual(@as(u16, 999), before_midnight.millisecond);
    try std.testing.expectEqual(@as(u16, 999), before_midnight.microsecond);
    try std.testing.expectEqual(@as(u16, 999), before_midnight.nanosecond);
}

test "PlainTime: noon" {
    const noon = try PlainTime.fromHMS(12, 0, 0);
    try std.testing.expectEqual(@as(u8, 12), noon.hour);
    const expected_ns: u64 = 12 * 3600 * std.time.ns_per_s;
    try std.testing.expectEqual(expected_ns, noon.toNanoseconds());
}

test "PlainTime: invalid values" {
    try std.testing.expectError(error.InvalidHour, PlainTime.from(24, 0, 0, 0, 0, 0));
    try std.testing.expectError(error.InvalidMinute, PlainTime.from(0, 60, 0, 0, 0, 0));
    try std.testing.expectError(error.InvalidSecond, PlainTime.from(0, 0, 60, 0, 0, 0));
    try std.testing.expectError(error.InvalidMillisecond, PlainTime.from(0, 0, 0, 1000, 0, 0));
    try std.testing.expectError(error.InvalidMicrosecond, PlainTime.from(0, 0, 0, 0, 1000, 0));
    try std.testing.expectError(error.InvalidNanosecond, PlainTime.from(0, 0, 0, 0, 0, 1000));
}

test "PlainTime: subsecond precision" {
    // 1 millisecond
    const one_ms = try PlainTime.from(0, 0, 0, 1, 0, 0);
    try std.testing.expectEqual(@as(u64, std.time.ns_per_ms), one_ms.toNanoseconds());

    // 1 microsecond
    const one_us = try PlainTime.from(0, 0, 0, 0, 1, 0);
    try std.testing.expectEqual(@as(u64, std.time.ns_per_us), one_us.toNanoseconds());

    // 1 nanosecond
    const one_ns = try PlainTime.from(0, 0, 0, 0, 0, 1);
    try std.testing.expectEqual(@as(u64, 1), one_ns.toNanoseconds());
}

test "PlainTime: fromNanoseconds and toNanoseconds roundtrip" {
    const original = try PlainTime.from(14, 30, 45, 123, 456, 789);
    const ns = original.toNanoseconds();
    const reconstructed = PlainTime.fromNanoseconds(ns);

    try std.testing.expectEqual(original.hour, reconstructed.hour);
    try std.testing.expectEqual(original.minute, reconstructed.minute);
    try std.testing.expectEqual(original.second, reconstructed.second);
    try std.testing.expectEqual(original.millisecond, reconstructed.millisecond);
    try std.testing.expectEqual(original.microsecond, reconstructed.microsecond);
    try std.testing.expectEqual(original.nanosecond, reconstructed.nanosecond);
}

test "PlainTime: add wrapping at midnight" {
    const before_midnight = try PlainTime.fromHMS(23, 59, 59);
    const after_add = before_midnight.add(Duration.fromSeconds(2));

    // Should wrap to 00:00:01
    try std.testing.expectEqual(@as(u8, 0), after_add.hour);
    try std.testing.expectEqual(@as(u8, 0), after_add.minute);
    try std.testing.expectEqual(@as(u8, 1), after_add.second);
}

test "PlainTime: comparison" {
    const t1 = try PlainTime.fromHMS(10, 30, 0);
    const t2 = try PlainTime.fromHMS(10, 30, 1);
    const t3 = try PlainTime.fromHMS(10, 30, 0);

    try std.testing.expectEqual(std.math.Order.lt, t1.compare(t2));
    try std.testing.expectEqual(std.math.Order.gt, t2.compare(t1));
    try std.testing.expectEqual(std.math.Order.eq, t1.compare(t3));
    try std.testing.expect(t1.equals(t3));
}

test "PlainTime: toString formats" {
    const allocator = std.testing.allocator;

    // Without subseconds
    const time1 = try PlainTime.fromHMS(14, 30, 45);
    const str1 = try time1.toString(allocator);
    defer allocator.free(str1);
    try std.testing.expectEqualStrings("14:30:45", str1);

    // With milliseconds
    const time2 = try PlainTime.from(14, 30, 45, 123, 0, 0);
    const str2 = try time2.toString(allocator);
    defer allocator.free(str2);
    try std.testing.expectEqualStrings("14:30:45.123", str2);
}

// --- PlainDateTime Edge Cases ---

test "PlainDateTime: validation combines date and time" {
    // Valid combination
    const dt = try PlainDateTime.from(2024, 2, 29, 23, 59, 59, 999, 999, 999);
    try std.testing.expectEqual(@as(i32, 2024), dt.year);
    try std.testing.expectEqual(@as(u8, 23), dt.hour);

    // Invalid date
    try std.testing.expectError(error.InvalidDay, PlainDateTime.from(2023, 2, 29, 0, 0, 0, 0, 0, 0));

    // Invalid time
    try std.testing.expectError(error.InvalidHour, PlainDateTime.from(2024, 1, 1, 24, 0, 0, 0, 0, 0));
}

test "PlainDateTime: toPlainDate and toPlainTime" {
    const dt = try PlainDateTime.from(2024, 6, 15, 14, 30, 45, 123, 456, 789);

    const date = dt.toPlainDate();
    try std.testing.expectEqual(@as(i32, 2024), date.year);
    try std.testing.expectEqual(@as(u8, 6), date.month);
    try std.testing.expectEqual(@as(u8, 15), date.day);

    const time = dt.toPlainTime();
    try std.testing.expectEqual(@as(u8, 14), time.hour);
    try std.testing.expectEqual(@as(u8, 30), time.minute);
    try std.testing.expectEqual(@as(u8, 45), time.second);
}

test "PlainDateTime: fromDateAndTime" {
    const date = try PlainDate.from(2024, 6, 15);
    const time = try PlainTime.from(14, 30, 45, 123, 456, 789);
    const dt = PlainDateTime.fromDateAndTime(date, time);

    try std.testing.expectEqual(@as(i32, 2024), dt.year);
    try std.testing.expectEqual(@as(u8, 6), dt.month);
    try std.testing.expectEqual(@as(u8, 15), dt.day);
    try std.testing.expectEqual(@as(u8, 14), dt.hour);
    try std.testing.expectEqual(@as(u16, 123), dt.millisecond);
}

test "PlainDateTime: add crossing day boundary" {
    // 23:00 + 2 hours = next day 01:00
    const dt = try PlainDateTime.from(2024, 6, 15, 23, 0, 0, 0, 0, 0);
    const after = try dt.add(Duration.fromHours(2));

    try std.testing.expectEqual(@as(u8, 16), after.day);
    try std.testing.expectEqual(@as(u8, 1), after.hour);
}

test "PlainDateTime: add crossing month boundary" {
    // June 30 23:00 + 2 hours = July 1 01:00
    const dt = try PlainDateTime.from(2024, 6, 30, 23, 0, 0, 0, 0, 0);
    const after = try dt.add(Duration.fromHours(2));

    try std.testing.expectEqual(@as(u8, 7), after.month);
    try std.testing.expectEqual(@as(u8, 1), after.day);
    try std.testing.expectEqual(@as(u8, 1), after.hour);
}

test "PlainDateTime: add crossing year boundary" {
    // Dec 31 23:00 + 2 hours = Jan 1 next year 01:00
    const dt = try PlainDateTime.from(2024, 12, 31, 23, 0, 0, 0, 0, 0);
    const after = try dt.add(Duration.fromHours(2));

    try std.testing.expectEqual(@as(i32, 2025), after.year);
    try std.testing.expectEqual(@as(u8, 1), after.month);
    try std.testing.expectEqual(@as(u8, 1), after.day);
    try std.testing.expectEqual(@as(u8, 1), after.hour);
}

test "PlainDateTime: comparison" {
    const dt1 = try PlainDateTime.from(2024, 6, 15, 10, 0, 0, 0, 0, 0);
    const dt2 = try PlainDateTime.from(2024, 6, 15, 10, 0, 1, 0, 0, 0);
    const dt3 = try PlainDateTime.from(2024, 6, 16, 10, 0, 0, 0, 0, 0);

    try std.testing.expectEqual(std.math.Order.lt, dt1.compare(dt2));
    try std.testing.expectEqual(std.math.Order.lt, dt1.compare(dt3));
    try std.testing.expect(dt1.equals(dt1));
}

// --- ZonedDateTime Edge Cases ---

test "ZonedDateTime: different timezone offsets" {
    const instant = Instant.fromEpochSeconds(1718444400); // 2024-06-15 10:00:00 UTC

    const utc = instant.toZonedDateTimeISO("UTC");
    try std.testing.expectEqual(@as(i32, 0), utc.offset_seconds);

    const est = instant.toZonedDateTimeISO("America/New_York");
    try std.testing.expectEqual(TimeZone.EST, est.offset_seconds);

    const jst = instant.toZonedDateTimeISO("Asia/Tokyo");
    try std.testing.expectEqual(TimeZone.JST, jst.offset_seconds);
}

test "ZonedDateTime: half-hour timezone offset" {
    const instant = Instant.fromEpochSeconds(1718444400);
    const ist = instant.toZonedDateTimeISO("Asia/Kolkata");
    try std.testing.expectEqual(TimeZone.IST, ist.offset_seconds);
    try std.testing.expectEqual(@as(i32, 5 * 3600 + 30 * 60), ist.offset_seconds);
}

test "ZonedDateTime: unknown timezone defaults to UTC" {
    const instant = Instant.fromEpochSeconds(1718444400);
    const unknown = instant.toZonedDateTimeISO("Unknown/Timezone");
    try std.testing.expectEqual(@as(i32, 0), unknown.offset_seconds);
}

test "ZonedDateTime: timezone crossing date boundary" {
    // 2024-06-15 02:00:00 UTC
    const instant = Instant.fromEpochSeconds(1718416800);

    // In UTC, it's June 15
    const utc = instant.toZonedDateTimeISO("UTC");
    try std.testing.expectEqual(@as(u8, 15), utc.day);

    // In EST (UTC-5), it's still June 14 (21:00)
    const est = instant.toZonedDateTimeISO("America/New_York");
    try std.testing.expectEqual(@as(u8, 14), est.day);
    try std.testing.expectEqual(@as(u8, 21), est.hour);
}

test "ZonedDateTime: withTimeZone conversion" {
    const instant = Instant.fromEpochSeconds(1718444400);
    const utc = instant.toZonedDateTimeISO("UTC");

    // Convert to Tokyo time
    const tokyo = utc.withTimeZone("Asia/Tokyo");
    try std.testing.expectEqual(TimeZone.JST, tokyo.offset_seconds);

    // The instant should be the same
    const utc_instant = utc.toInstant();
    const tokyo_instant = tokyo.toInstant();
    try std.testing.expect(utc_instant.equals(tokyo_instant));
}

test "ZonedDateTime: toInstant roundtrip" {
    const original = Instant.fromEpochSeconds(1718444400);
    const zdt = original.toZonedDateTimeISO("America/New_York");
    const recovered = zdt.toInstant();

    try std.testing.expect(original.equals(recovered));
}

test "ZonedDateTime: offsetString format" {
    const allocator = std.testing.allocator;

    const instant = Instant.fromEpochSeconds(1718444400);

    // Positive offset
    const tokyo = instant.toZonedDateTimeISO("Asia/Tokyo");
    const tokyo_offset = try tokyo.offsetString(allocator);
    defer allocator.free(tokyo_offset);
    try std.testing.expectEqualStrings("+09:00", tokyo_offset);

    // Negative offset
    const ny = instant.toZonedDateTimeISO("America/New_York");
    const ny_offset = try ny.offsetString(allocator);
    defer allocator.free(ny_offset);
    try std.testing.expectEqualStrings("-05:00", ny_offset);

    // Half-hour offset
    const india = instant.toZonedDateTimeISO("Asia/Kolkata");
    const india_offset = try india.offsetString(allocator);
    defer allocator.free(india_offset);
    try std.testing.expectEqualStrings("+05:30", india_offset);

    // UTC (zero offset)
    const utc = instant.toZonedDateTimeISO("UTC");
    const utc_offset = try utc.offsetString(allocator);
    defer allocator.free(utc_offset);
    try std.testing.expectEqualStrings("+00:00", utc_offset);
}

// --- Duration Edge Cases ---

test "Duration: zero duration" {
    const zero = Duration.fromSeconds(0);
    try std.testing.expect(zero.isZero());
    try std.testing.expect(!zero.isNegative());
    try std.testing.expectEqual(@as(i64, 0), zero.totalSeconds());
}

test "Duration: negative duration" {
    const neg = Duration.fromSeconds(-100);
    try std.testing.expect(!neg.isZero());
    try std.testing.expect(neg.isNegative());
    try std.testing.expectEqual(@as(i64, -100), neg.totalSeconds());
}

test "Duration: negated" {
    const pos = Duration.fromSeconds(100);
    const neg = pos.negated();
    try std.testing.expectEqual(@as(i64, -100), neg.totalSeconds());

    const pos_again = neg.negated();
    try std.testing.expectEqual(@as(i64, 100), pos_again.totalSeconds());
}

test "Duration: abs" {
    const neg = Duration.fromSeconds(-100);
    const absolute = neg.abs();
    try std.testing.expectEqual(@as(i64, 100), absolute.totalSeconds());

    const pos = Duration.fromSeconds(100);
    const absolute_pos = pos.abs();
    try std.testing.expectEqual(@as(i64, 100), absolute_pos.totalSeconds());
}

test "Duration: unit conversions" {
    const one_week = Duration.fromWeeks(1);
    try std.testing.expectEqual(@as(i32, 7), one_week.totalDays());
    try std.testing.expectEqual(@as(i64, 168), one_week.totalHours());
    try std.testing.expectEqual(@as(i64, 10080), one_week.totalMinutes());
    try std.testing.expectEqual(@as(i64, 604800), one_week.totalSeconds());
}

test "Duration: add and subtract" {
    const d1 = Duration.fromHours(1);
    const d2 = Duration.fromMinutes(30);

    const sum = d1.add(d2);
    try std.testing.expectEqual(@as(i64, 90), sum.totalMinutes());

    const diff = d1.subtract(d2);
    try std.testing.expectEqual(@as(i64, 30), diff.totalMinutes());
}

test "Duration: comparison" {
    const d1 = Duration.fromSeconds(100);
    const d2 = Duration.fromSeconds(200);
    const d3 = Duration.fromSeconds(100);

    try std.testing.expectEqual(std.math.Order.lt, d1.compare(d2));
    try std.testing.expectEqual(std.math.Order.gt, d2.compare(d1));
    try std.testing.expectEqual(std.math.Order.eq, d1.compare(d3));
}

test "Duration: large values" {
    // 100 years in seconds
    const century: i64 = 100 * 365 * 24 * 3600;
    const d = Duration.fromSeconds(century);
    try std.testing.expectEqual(century, d.totalSeconds());
}

// --- TimeZone Edge Cases ---

test "TimeZone: all common timezone offsets" {
    try std.testing.expectEqual(@as(i32, 0), TimeZone.UTC);
    try std.testing.expectEqual(@as(i32, 0), TimeZone.GMT);
    try std.testing.expectEqual(@as(i32, -5 * 3600), TimeZone.EST);
    try std.testing.expectEqual(@as(i32, -4 * 3600), TimeZone.EDT);
    try std.testing.expectEqual(@as(i32, -8 * 3600), TimeZone.PST);
    try std.testing.expectEqual(@as(i32, -7 * 3600), TimeZone.PDT);
    try std.testing.expectEqual(@as(i32, 1 * 3600), TimeZone.CET);
    try std.testing.expectEqual(@as(i32, 2 * 3600), TimeZone.CEST);
    try std.testing.expectEqual(@as(i32, 9 * 3600), TimeZone.JST);
    try std.testing.expectEqual(@as(i32, 5 * 3600 + 30 * 60), TimeZone.IST);
    try std.testing.expectEqual(@as(i32, 10 * 3600), TimeZone.AEST);
    try std.testing.expectEqual(@as(i32, 11 * 3600), TimeZone.AEDT);
}

test "TimeZone: getOffset IANA names" {
    try std.testing.expectEqual(@as(i32, 0), TimeZone.getOffset("UTC"));
    try std.testing.expectEqual(@as(i32, 0), TimeZone.getOffset("Etc/UTC"));
    try std.testing.expectEqual(@as(i32, 0), TimeZone.getOffset("GMT"));
    try std.testing.expectEqual(TimeZone.EST, TimeZone.getOffset("America/New_York"));
    try std.testing.expectEqual(TimeZone.PST, TimeZone.getOffset("America/Los_Angeles"));
    try std.testing.expectEqual(TimeZone.CST, TimeZone.getOffset("America/Chicago"));
    try std.testing.expectEqual(TimeZone.MST, TimeZone.getOffset("America/Denver"));
    try std.testing.expectEqual(@as(i32, 0), TimeZone.getOffset("Europe/London"));
    try std.testing.expectEqual(TimeZone.CET, TimeZone.getOffset("Europe/Paris"));
    try std.testing.expectEqual(TimeZone.CET, TimeZone.getOffset("Europe/Berlin"));
    try std.testing.expectEqual(TimeZone.JST, TimeZone.getOffset("Asia/Tokyo"));
    try std.testing.expectEqual(TimeZone.IST, TimeZone.getOffset("Asia/Kolkata"));
    try std.testing.expectEqual(TimeZone.IST, TimeZone.getOffset("Asia/Calcutta"));
    try std.testing.expectEqual(@as(i32, 8 * 3600), TimeZone.getOffset("Asia/Shanghai"));
    try std.testing.expectEqual(@as(i32, 8 * 3600), TimeZone.getOffset("Asia/Hong_Kong"));
    try std.testing.expectEqual(@as(i32, 8 * 3600), TimeZone.getOffset("Asia/Singapore"));
    try std.testing.expectEqual(TimeZone.AEST, TimeZone.getOffset("Australia/Sydney"));
    try std.testing.expectEqual(TimeZone.AEST, TimeZone.getOffset("Australia/Melbourne"));
}

test "TimeZone: unknown timezone returns UTC" {
    try std.testing.expectEqual(@as(i32, 0), TimeZone.getOffset("Unknown/Place"));
    try std.testing.expectEqual(@as(i32, 0), TimeZone.getOffset(""));
    try std.testing.expectEqual(@as(i32, 0), TimeZone.getOffset("NotATimezone"));
}

// --- Now Edge Cases ---

test "Now: instant is monotonically increasing" {
    const t1 = Now.instant();
    const t2 = Now.instant();
    const t3 = Now.instant();

    // Each subsequent call should return equal or greater time
    try std.testing.expect(t2.compare(t1) != .lt);
    try std.testing.expect(t3.compare(t2) != .lt);
}

test "Now: timeZoneId returns non-empty string" {
    const tz = Now.timeZoneId();
    try std.testing.expect(tz.len > 0);
}

test "Now: all methods with explicit timezone" {
    const tz = "America/New_York";

    const zdt = Now.zonedDateTimeISO(tz);
    try std.testing.expectEqual(TimeZone.EST, zdt.offset_seconds);

    const date = Now.plainDateISO(tz);
    try std.testing.expect(date.year >= 2024);

    const time = Now.plainTimeISO(tz);
    try std.testing.expect(time.hour <= 23);

    const dt = Now.plainDateTimeISO(tz);
    try std.testing.expect(dt.year >= 2024);
}

test "Now: methods with null timezone use system default" {
    const zdt = Now.zonedDateTimeISO(null);
    const date = Now.plainDateISO(null);
    const time = Now.plainTimeISO(null);
    const dt = Now.plainDateTimeISO(null);

    // Just verify they don't crash and return valid data
    try std.testing.expect(date.year >= 2024);
    try std.testing.expect(time.hour <= 23);
    try std.testing.expect(dt.year >= 2024);
    try std.testing.expect(zdt.year >= 2024);
}

// --- toString Edge Cases ---

test "PlainDate toString: single digit padding" {
    const allocator = std.testing.allocator;

    const date = try PlainDate.from(2024, 1, 5);
    const str = try date.toString(allocator);
    defer allocator.free(str);
    try std.testing.expectEqualStrings("2024-01-05", str);
}

test "PlainDate toString: year padding" {
    const allocator = std.testing.allocator;

    // Year less than 1000
    const date = try PlainDate.from(500, 6, 15);
    const str = try date.toString(allocator);
    defer allocator.free(str);
    try std.testing.expectEqualStrings("0500-06-15", str);
}

test "PlainTime toString: single digit padding" {
    const allocator = std.testing.allocator;

    const time = try PlainTime.fromHMS(5, 3, 9);
    const str = try time.toString(allocator);
    defer allocator.free(str);
    try std.testing.expectEqualStrings("05:03:09", str);
}

test "PlainDateTime toString: full format" {
    const allocator = std.testing.allocator;

    const dt = try PlainDateTime.from(2024, 6, 15, 14, 30, 45, 0, 0, 0);
    const str = try dt.toString(allocator);
    defer allocator.free(str);
    try std.testing.expectEqualStrings("2024-06-15T14:30:45", str);
}

test "PlainDateTime toString: with milliseconds" {
    const allocator = std.testing.allocator;

    const dt = try PlainDateTime.from(2024, 6, 15, 14, 30, 45, 123, 0, 0);
    const str = try dt.toString(allocator);
    defer allocator.free(str);
    try std.testing.expectEqualStrings("2024-06-15T14:30:45.123", str);
}

test "ZonedDateTime toString: full format with timezone" {
    const allocator = std.testing.allocator;

    const instant = Instant.fromEpochSeconds(1718444400);
    const zdt = instant.toZonedDateTimeISO("America/New_York");
    const str = try zdt.toString(allocator);
    defer allocator.free(str);

    // Should contain the timezone in brackets
    try std.testing.expect(std.mem.indexOf(u8, str, "[America/New_York]") != null);
    try std.testing.expect(std.mem.indexOf(u8, str, "-05:00") != null);
}

// --- Epoch Conversion Edge Cases ---

test "epochToComponents: Unix epoch" {
    const components = epochToComponents(0);
    try std.testing.expectEqual(@as(u32, 1970), components.year);
    try std.testing.expectEqual(@as(u8, 1), components.month);
    try std.testing.expectEqual(@as(u8, 1), components.day);
    try std.testing.expectEqual(@as(u8, 0), components.hour);
    try std.testing.expectEqual(@as(u8, 0), components.minute);
    try std.testing.expectEqual(@as(u8, 0), components.second);
}

test "epochToComponents: known date" {
    // 2024-06-15 14:30:45 UTC
    const seconds: i64 = 1718461845;
    const components = epochToComponents(seconds);
    try std.testing.expectEqual(@as(u32, 2024), components.year);
    try std.testing.expectEqual(@as(u8, 6), components.month);
    try std.testing.expectEqual(@as(u8, 15), components.day);
    try std.testing.expectEqual(@as(u8, 14), components.hour);
    try std.testing.expectEqual(@as(u8, 30), components.minute);
    try std.testing.expectEqual(@as(u8, 45), components.second);
}

test "dateToDays and daysToDate roundtrip" {
    // Test various dates
    const test_dates = [_]struct { year: i32, month: u8, day: u8 }{
        .{ .year = 1970, .month = 1, .day = 1 },
        .{ .year = 2000, .month = 2, .day = 29 },
        .{ .year = 2024, .month = 12, .day = 31 },
        .{ .year = 1999, .month = 12, .day = 31 },
        .{ .year = 2100, .month = 6, .day = 15 },
    };

    for (test_dates) |td| {
        const days = dateToDays(td.year, td.month, td.day);
        const result = try daysToDate(days);
        try std.testing.expectEqual(td.year, result.year);
        try std.testing.expectEqual(td.month, result.month);
        try std.testing.expectEqual(td.day, result.day);
    }
}

// --- Additional Critical Edge Cases ---

test "PlainDate: first and last day of each month in leap year" {
    const allocator = std.testing.allocator;

    const months_days = [_]struct { month: u8, last_day: u8 }{
        .{ .month = 1, .last_day = 31 },
        .{ .month = 2, .last_day = 29 }, // Leap year
        .{ .month = 3, .last_day = 31 },
        .{ .month = 4, .last_day = 30 },
        .{ .month = 5, .last_day = 31 },
        .{ .month = 6, .last_day = 30 },
        .{ .month = 7, .last_day = 31 },
        .{ .month = 8, .last_day = 31 },
        .{ .month = 9, .last_day = 30 },
        .{ .month = 10, .last_day = 31 },
        .{ .month = 11, .last_day = 30 },
        .{ .month = 12, .last_day = 31 },
    };

    for (months_days) |md| {
        // First day should work
        const first = try PlainDate.from(2024, md.month, 1);
        try std.testing.expectEqual(@as(u8, 1), first.day);

        // Last day should work
        const last = try PlainDate.from(2024, md.month, md.last_day);
        try std.testing.expectEqual(md.last_day, last.day);

        // Day after last should fail
        if (md.last_day < 31) {
            try std.testing.expectError(error.InvalidDay, PlainDate.from(2024, md.month, md.last_day + 1));
        }
    }
    _ = allocator;
}

test "PlainDate: century leap year edge cases" {
    // 1900 is NOT a leap year (divisible by 100 but not 400)
    try std.testing.expectError(error.InvalidDay, PlainDate.from(1900, 2, 29));
    const feb28_1900 = try PlainDate.from(1900, 2, 28);
    try std.testing.expect(!feb28_1900.inLeapYear());

    // 2000 IS a leap year (divisible by 400)
    const feb29_2000 = try PlainDate.from(2000, 2, 29);
    try std.testing.expect(feb29_2000.inLeapYear());

    // 2100 will NOT be a leap year
    try std.testing.expectError(error.InvalidDay, PlainDate.from(2100, 2, 29));

    // 2400 WILL be a leap year
    const feb29_2400 = try PlainDate.from(2400, 2, 29);
    try std.testing.expect(feb29_2400.inLeapYear());
}

test "PlainDate: week of year edge cases" {
    // First week of year edge cases
    // Jan 1, 2024 is Monday - should be week 1
    const jan1_2024 = try PlainDate.from(2024, 1, 1);
    try std.testing.expectEqual(@as(u8, 1), jan1_2024.weekOfYear());

    // Jan 7, 2024 is Sunday - should still be week 1
    const jan7_2024 = try PlainDate.from(2024, 1, 7);
    try std.testing.expectEqual(@as(u8, 1), jan7_2024.weekOfYear());

    // Jan 8, 2024 is Monday - should be week 2
    const jan8_2024 = try PlainDate.from(2024, 1, 8);
    try std.testing.expectEqual(@as(u8, 2), jan8_2024.weekOfYear());
}

test "Instant: subsecond extraction in toString" {
    const allocator = std.testing.allocator;

    // Exactly on second boundary
    const on_second = Instant.fromEpochSeconds(1000);
    const str1 = try on_second.toString(allocator);
    defer allocator.free(str1);
    try std.testing.expect(std.mem.indexOf(u8, str1, ".") == null); // No decimal

    // With 1 millisecond
    const with_ms = Instant.fromEpochNanoseconds(1000 * std.time.ns_per_s + std.time.ns_per_ms);
    const str2 = try with_ms.toString(allocator);
    defer allocator.free(str2);
    try std.testing.expect(std.mem.indexOf(u8, str2, ".001") != null);

    // With 999 milliseconds
    const with_999ms = Instant.fromEpochNanoseconds(1000 * std.time.ns_per_s + 999 * std.time.ns_per_ms);
    const str3 = try with_999ms.toString(allocator);
    defer allocator.free(str3);
    try std.testing.expect(std.mem.indexOf(u8, str3, ".999") != null);
}

test "PlainDateTime: add with nanoseconds precision" {
    const dt = try PlainDateTime.from(2024, 6, 15, 12, 0, 0, 0, 0, 0);

    // Add exactly 1 nanosecond
    const after_1ns = try dt.add(Duration.fromNanoseconds(1));
    try std.testing.expectEqual(@as(u16, 0), after_1ns.millisecond);
    try std.testing.expectEqual(@as(u16, 0), after_1ns.microsecond);
    try std.testing.expectEqual(@as(u16, 1), after_1ns.nanosecond);

    // Add 1ms + 1us + 1ns
    const complex_add = try dt.add(Duration.fromNanoseconds(1_001_001));
    try std.testing.expectEqual(@as(u16, 1), complex_add.millisecond);
    try std.testing.expectEqual(@as(u16, 1), complex_add.microsecond);
    try std.testing.expectEqual(@as(u16, 1), complex_add.nanosecond);
}

test "Duration: mixed unit creation equivalence" {
    // 1 day = 24 hours = 1440 minutes = 86400 seconds
    const from_days = Duration.fromDays(1);
    const from_hours = Duration.fromHours(24);
    const from_minutes = Duration.fromMinutes(1440);
    const from_seconds = Duration.fromSeconds(86400);

    try std.testing.expectEqual(from_days.total_nanoseconds, from_hours.total_nanoseconds);
    try std.testing.expectEqual(from_days.total_nanoseconds, from_minutes.total_nanoseconds);
    try std.testing.expectEqual(from_days.total_nanoseconds, from_seconds.total_nanoseconds);
}

test "Instant: equality with different creation methods" {
    // Same moment created different ways
    const from_seconds = Instant.fromEpochSeconds(1000);
    const from_ms = Instant.fromEpochMilliseconds(1000000);
    const from_us = Instant.fromEpochMicroseconds(1000000000);
    const from_ns = Instant.fromEpochNanoseconds(1000000000000);

    try std.testing.expect(from_seconds.equals(from_ms));
    try std.testing.expect(from_seconds.equals(from_us));
    try std.testing.expect(from_seconds.equals(from_ns));
}

test "ZonedDateTime: extreme timezone offsets" {
    const instant = Instant.fromEpochSeconds(1718444400);

    // Test positive extreme (AEST +10:00)
    const aest = instant.toZonedDateTimeISO("Australia/Sydney");
    try std.testing.expectEqual(@as(i32, 10 * 3600), aest.offset_seconds);

    // Test negative extreme (PST -8:00)
    const pst = instant.toZonedDateTimeISO("America/Los_Angeles");
    try std.testing.expectEqual(@as(i32, -8 * 3600), pst.offset_seconds);
}

test "PlainDate: addMonths wrapping across year boundary" {
    // November + 3 months = February next year
    const nov = try PlainDate.from(2024, 11, 15);
    const feb = try nov.addMonths(3);
    try std.testing.expectEqual(@as(i32, 2025), feb.year);
    try std.testing.expectEqual(@as(u8, 2), feb.month);
    try std.testing.expectEqual(@as(u8, 15), feb.day);

    // March - 5 months = October previous year
    const mar = try PlainDate.from(2024, 3, 15);
    const oct = try mar.addMonths(-5);
    try std.testing.expectEqual(@as(i32, 2023), oct.year);
    try std.testing.expectEqual(@as(u8, 10), oct.month);
}

test "PlainTime: edge case at exactly midnight wrap" {
    // 23:59:59.999999999 + 1 nanosecond = 00:00:00.000000000
    const just_before = try PlainTime.from(23, 59, 59, 999, 999, 999);
    const just_after = just_before.add(Duration.fromNanoseconds(1));

    try std.testing.expectEqual(@as(u8, 0), just_after.hour);
    try std.testing.expectEqual(@as(u8, 0), just_after.minute);
    try std.testing.expectEqual(@as(u8, 0), just_after.second);
    try std.testing.expectEqual(@as(u16, 0), just_after.millisecond);
    try std.testing.expectEqual(@as(u16, 0), just_after.microsecond);
    try std.testing.expectEqual(@as(u16, 0), just_after.nanosecond);
}

test "Duration: nanosecond precision in conversion" {
    // 1 second + 1 nanosecond
    const d = Duration.fromNanoseconds(std.time.ns_per_s + 1);

    // totalSeconds should truncate
    try std.testing.expectEqual(@as(i64, 1), d.totalSeconds());

    // totalNanoseconds should preserve
    try std.testing.expectEqual(@as(i128, std.time.ns_per_s + 1), d.totalNanoseconds());
}

test "PlainDate: stress test with many consecutive days" {
    // Add 365 days one at a time and verify we end up at the right place
    var date = try PlainDate.from(2024, 1, 1);

    var i: u32 = 0;
    while (i < 365) : (i += 1) {
        date = try date.addDays(1);
    }

    // Should be Jan 1, 2025 (2024 is a leap year, so 366 days)
    try std.testing.expectEqual(@as(i32, 2024), date.year);
    try std.testing.expectEqual(@as(u8, 12), date.month);
    try std.testing.expectEqual(@as(u8, 31), date.day);

    // One more day gets us to 2025
    date = try date.addDays(1);
    try std.testing.expectEqual(@as(i32, 2025), date.year);
    try std.testing.expectEqual(@as(u8, 1), date.month);
    try std.testing.expectEqual(@as(u8, 1), date.day);
}

test "Now: instant epoch is reasonable" {
    const now = Now.instant();

    // Should be after 2024-01-01 (timestamp 1704067200)
    try std.testing.expect(now.epochSeconds() > 1704067200);

    // Should be before 2100-01-01 (timestamp 4102444800)
    try std.testing.expect(now.epochSeconds() < 4102444800);
}

test "PlainDateTime: millisecond precision preserved through conversions" {
    const original = try PlainDateTime.from(2024, 6, 15, 14, 30, 45, 123, 456, 789);

    // Convert to ZonedDateTime and back
    const zdt = original.toZonedDateTime("UTC");
    const back = zdt.toPlainDateTime();

    try std.testing.expectEqual(original.millisecond, back.millisecond);
    try std.testing.expectEqual(original.microsecond, back.microsecond);
    try std.testing.expectEqual(original.nanosecond, back.nanosecond);
}

test "ZonedDateTime: time component extraction with offset" {
    // Create a ZonedDateTime in a non-UTC timezone
    // Use a clean timestamp: 2024-06-15 10:00:00 UTC = 1718445600
    const instant = Instant.fromEpochSeconds(1718445600);

    // Verify UTC time is 10:00
    const utc = instant.toZonedDateTimeISO("UTC");
    try std.testing.expectEqual(@as(u8, 10), utc.hour);

    // In Tokyo (UTC+9), it should be 19:00 (10 + 9)
    const tokyo = instant.toZonedDateTimeISO("Asia/Tokyo");
    const time = tokyo.toPlainTime();
    try std.testing.expectEqual(@as(u8, 19), time.hour);

    // But the instant should convert back to same epoch
    const back_instant = tokyo.toInstant();
    try std.testing.expect(instant.equals(back_instant));
}
