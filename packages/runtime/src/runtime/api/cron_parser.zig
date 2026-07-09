// Copied from bun/src/runtime/api/cron_parser.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Rewrites:
//   - @import("bun")                              → @import("home")
//   - bun.strings.{indexOfChar,eql}               → home_rt.strings.*
//   - bun.ComptimeStringMap                       → home_rt.ComptimeStringMap
//   - bun.assert / bun.debugAssert                → home_rt.assert
//
// Local helpers (not yet in home_rt.strings):
//   - `trimAsciiWhitespace`             — substitute for `bun.strings.trim(s, " \t")`
//   - `eqlCaseInsensitiveAscii`         — substitute for
//     `bun.strings.eqlCaseInsensitiveASCIIICheckLength`
//   - `getNamedValueCaseInsensitiveAscii(M)` — substitute for
//     `M.getASCIIICaseInsensitive(str)` on a `ComptimeStringMap(u7)`. Performs an
//     in-place ASCII lower-case on the input into a 16-byte stack buffer and
//     does a normal `get()`. The longest cron name is `wednesday` (9 chars),
//     well inside the buffer.
//
// Stubs (re-attach in Phase 12.2 when home_rt.jsc grows the
// JSGlobalObject date helpers):
//   - `jsc.JSGlobalObject` is modelled as an opaque type with two
//     extern entry points (`msToGregorianDateTimeUTC` /
//     `gregorianDateTimeToMSUTC`). `CronExpression.next()` is preserved
//     verbatim against this shape.
//   - `bun.JSError` → `error{JSError}` (single-variant set, matches the
//     existing local-stub convention in `home_rt/jsc/JSArray.zig`).
//
// All field-parsing logic is pure Zig and exercised by tests.

/// Cron expression parser and next-occurrence calculator.
///
/// Parses standard 5-field cron expressions (minute hour day month weekday)
/// into a bitset representation, and computes the next matching UTC time.
///
/// Supports:
///   - Wildcards: *
///   - Lists: 1,3,5
///   - Ranges: 1-5
///   - Steps: */15, 1-30/2
///   - Named days: SUN-SAT, Sun-Sat, Sunday-Saturday (case-insensitive)
///   - Named months: JAN-DEC, Jan-Dec, January-December (case-insensitive)
///   - Sunday as 7: weekday field accepts 7 as alias for 0
///   - Nicknames: @yearly, @annually, @monthly, @weekly, @daily, @midnight, @hourly
pub const CronExpression = struct {
    minutes: u64, // bits 0-59
    hours: u32, // bits 0-23
    days: u32, // bits 1-31
    months: u16, // bits 1-12
    weekdays: u8, // bits 0-6 (0=Sunday)
    days_is_wildcard: bool, // true if day-of-month field was *
    weekdays_is_wildcard: bool, // true if weekday field was *

    pub const Error = error{
        InvalidField,
        InvalidStep,
        InvalidRange,
        InvalidNumber,
        TooManyFields,
        TooFewFields,
    };

    pub fn errorMessage(e: Error) []const u8 {
        return switch (e) {
            error.TooFewFields => "Invalid cron expression: expected 5 space-separated fields (minute hour day month weekday)",
            error.TooManyFields => "Invalid cron expression: too many fields. Bun.cron uses 5 fields (minute hour day month weekday) — seconds are not supported",
            error.InvalidStep => "Invalid cron expression: step value must be a positive integer",
            error.InvalidRange => "Invalid cron expression: range must be ascending (use 'a,b' or 'a-max,0-b' for wrap-around)",
            error.InvalidNumber => "Invalid cron expression: value out of range for field",
            error.InvalidField => "Invalid cron expression: unrecognized field syntax",
        };
    }

    /// Parse a 5-field cron expression or predefined nickname into a CronExpression.
    pub fn parse(input: []const u8) Error!CronExpression {
        const expr = trimAsciiWhitespace(input);

        // Check for predefined nicknames
        if (expr.len > 0 and expr[0] == '@') {
            return parseNickname(expr) orelse error.InvalidField;
        }

        var count: usize = 0;
        var fields: [5][]const u8 = undefined;
        var iter = std.mem.tokenizeAny(u8, expr, " \t");
        while (iter.next()) |field| {
            if (count >= 5) return error.TooManyFields;
            fields[count] = field;
            count += 1;
        }
        if (count != 5) return error.TooFewFields;

        return .{
            .minutes = try parseField(u64, fields[0], 0, 59, .none),
            .hours = try parseField(u32, fields[1], 0, 23, .none),
            .days = try parseField(u32, fields[2], 1, 31, .none),
            .months = try parseField(u16, fields[3], 1, 12, .month),
            .weekdays = try parseField(u8, fields[4], 0, 7, .weekday),
            .days_is_wildcard = home_rt.strings.eql(fields[2], "*"),
            .weekdays_is_wildcard = home_rt.strings.eql(fields[4], "*"),
        };
    }

    /// Validate a cron expression string without allocating.
    pub fn validate(expr: []const u8) bool {
        _ = parse(expr) catch return false;
        return true;
    }

    /// Format the expression as a normalized numeric "M H D Mo W" string
    /// suitable for crontab. Returns the written slice of `buf`.
    pub fn formatNumeric(self: CronExpression, buf: *[512]u8) []const u8 {
        var w = std.Io.Writer.fixed(buf);
        formatBitfield(&w, u64, self.minutes, 0, 59);
        w.writeByte(' ') catch unreachable;
        formatBitfield(&w, u32, self.hours, 0, 23);
        w.writeByte(' ') catch unreachable;
        formatBitfield(&w, u32, self.days, 1, 31);
        w.writeByte(' ') catch unreachable;
        formatBitfield(&w, u16, self.months, 1, 12);
        w.writeByte(' ') catch unreachable;
        formatBitfield(&w, u8, self.weekdays, 0, 6);
        return w.buffered();
    }

    /// Compute the next UTC time (in ms since epoch) that matches this
    /// expression, strictly after `from_ms`. Returns null if no match found
    /// within 8 years.
    pub fn next(self: CronExpression, globalObject: *jsc.JSGlobalObject, from_ms: f64) JSError!?f64 {
        var dt = globalObject.msToGregorianDateTimeUTC(from_ms);
        const start_year = dt.year;
        dt.minute += 1;
        dt.second = 0;

        while (dt.year - start_year <= 8) {
            // Normalize overflow + recompute weekday via a UTC round-trip.
            dt = globalObject.msToGregorianDateTimeUTC(try globalObject.gregorianDateTimeToMSUTC(dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second, 0));

            if (!bitSet(u16, self.months, @intCast(dt.month))) {
                dt.month += 1;
                dt.day = 1;
                dt.hour = 0;
                dt.minute = 0;
                continue;
            }
            // POSIX: if both DOM and DOW are restricted (not `*`), either
            // matching is enough; otherwise the `*` field matches all anyway.
            const day_ok = bitSet(u32, self.days, @intCast(dt.day));
            const weekday_ok = bitSet(u8, self.weekdays, @intCast(dt.weekday));
            const day_match = if (!self.days_is_wildcard and !self.weekdays_is_wildcard)
                day_ok or weekday_ok
            else
                day_ok and weekday_ok;
            if (!day_match) {
                dt.day += 1;
                dt.hour = 0;
                dt.minute = 0;
                continue;
            }
            if (!bitSet(u32, self.hours, @intCast(dt.hour))) {
                dt.hour += 1;
                dt.minute = 0;
                continue;
            }
            if (!bitSet(u64, self.minutes, @intCast(dt.minute))) {
                dt.minute += 1;
                continue;
            }

            return try globalObject.gregorianDateTimeToMSUTC(dt.year, dt.month, dt.day, dt.hour, dt.minute, 0, 0);
        }
        return null;
    }
};

// ============================================================================
// Name lookup tables
// ============================================================================

const all_hours: u32 = (1 << 24) - 1;
pub const all_days: u32 = ((1 << 32) - 1) & ~@as(u32, 1);
pub const all_months: u16 = ((1 << 13) - 1) & ~@as(u16, 1);
pub const all_weekdays: u8 = (1 << 7) - 1;

fn parseNickname(expr: []const u8) ?CronExpression {
    if (eqlCaseInsensitiveAscii(expr, "@yearly") or eqlCaseInsensitiveAscii(expr, "@annually"))
        return .{ .minutes = 1, .hours = 1, .days = 1 << 1, .months = 1 << 1, .weekdays = all_weekdays, .days_is_wildcard = false, .weekdays_is_wildcard = true };
    if (eqlCaseInsensitiveAscii(expr, "@monthly"))
        return .{ .minutes = 1, .hours = 1, .days = 1 << 1, .months = all_months, .weekdays = all_weekdays, .days_is_wildcard = false, .weekdays_is_wildcard = true };
    if (eqlCaseInsensitiveAscii(expr, "@weekly"))
        return .{ .minutes = 1, .hours = 1, .days = all_days, .months = all_months, .weekdays = 1, .days_is_wildcard = true, .weekdays_is_wildcard = false };
    if (eqlCaseInsensitiveAscii(expr, "@daily") or eqlCaseInsensitiveAscii(expr, "@midnight"))
        return .{ .minutes = 1, .hours = 1, .days = all_days, .months = all_months, .weekdays = all_weekdays, .days_is_wildcard = true, .weekdays_is_wildcard = true };
    if (eqlCaseInsensitiveAscii(expr, "@hourly"))
        return .{ .minutes = 1, .hours = all_hours, .days = all_days, .months = all_months, .weekdays = all_weekdays, .days_is_wildcard = true, .weekdays_is_wildcard = true };
    return null;
}

const weekday_map = home_rt.ComptimeStringMap(u7, .{
    .{ "sun", 0 },     .{ "mon", 1 },       .{ "tue", 2 },
    .{ "wed", 3 },     .{ "thu", 4 },       .{ "fri", 5 },
    .{ "sat", 6 },     .{ "sunday", 0 },    .{ "monday", 1 },
    .{ "tuesday", 2 }, .{ "wednesday", 3 }, .{ "thursday", 4 },
    .{ "friday", 5 },  .{ "saturday", 6 },
});

const month_map = home_rt.ComptimeStringMap(u7, .{
    .{ "jan", 1 },       .{ "feb", 2 },       .{ "mar", 3 },
    .{ "apr", 4 },       .{ "may", 5 },       .{ "jun", 6 },
    .{ "jul", 7 },       .{ "aug", 8 },       .{ "sep", 9 },
    .{ "oct", 10 },      .{ "nov", 11 },      .{ "dec", 12 },
    .{ "january", 1 },   .{ "february", 2 },  .{ "march", 3 },
    .{ "april", 4 },     .{ "june", 6 },      .{ "july", 7 },
    .{ "august", 8 },    .{ "september", 9 }, .{ "october", 10 },
    .{ "november", 11 }, .{ "december", 12 },
});

// ============================================================================
// Field parsing
// ============================================================================

const NameKind = enum { none, weekday, month };

/// Parse a single cron field (e.g. "1,5-10,*/3") into a bitset.
fn parseField(comptime T: type, field: []const u8, min: u7, max: u7, kind: NameKind) CronExpression.Error!T {
    if (field.len == 0) return error.InvalidField;
    var result: T = 0;
    var parts = std.mem.splitScalar(u8, field, ',');
    while (parts.next()) |part| {
        if (part.len == 0) return error.InvalidField;
        // Split by / for step
        var step_iter = std.mem.splitScalar(u8, part, '/');
        const base = step_iter.next() orelse return error.InvalidField;
        const step_str = step_iter.next();
        if (step_iter.next() != null) return error.InvalidStep;

        const step: u7 = if (step_str) |s| blk: {
            if (s.len == 0) return error.InvalidStep;
            break :blk std.fmt.parseInt(u7, s, 10) catch return error.InvalidStep;
        } else 1;
        if (step == 0) return error.InvalidStep;

        var range_min: u7 = undefined;
        var range_max: u7 = undefined;

        if (home_rt.strings.eql(base, "*")) {
            range_min = min;
            range_max = max;
        } else {
            if (splitRange(base)) |range_parts| {
                const lo = parseValue(range_parts[0], min, max, kind) catch return error.InvalidNumber;
                const hi = parseValue(range_parts[1], min, max, kind) catch return error.InvalidNumber;
                if (lo > hi) return error.InvalidRange;
                range_min = lo;
                range_max = hi;
            } else {
                const lo = parseValue(base, min, max, kind) catch return error.InvalidNumber;
                range_min = lo;
                range_max = if (step_str != null) max else lo;
            }
        }

        // Set bits
        var i: u7 = range_min;
        while (i <= range_max) : (i += step) {
            result |= @as(T, 1) << @intCast(i);
            if (@as(u8, i) + @as(u8, step) > range_max) break;
        }
    }
    // Weekday: fold bit 7 (Sunday alias) into bit 0 *after* range expansion so
    // 5-7, 0-7, etc. work like Vixie/croner/cron-parser.
    if (kind == .weekday) result = (result | (result >> 7)) & 0x7F;
    return result;
}

/// Split a base expression on '-' for ranges, returning null if not a range.
fn splitRange(base: []const u8) ?[2][]const u8 {
    const idx = home_rt.strings.indexOfChar(base, '-') orelse return null;
    if (idx == 0 or idx == base.len - 1) return null;
    const rest = base[idx + 1 ..];
    if (home_rt.strings.indexOfChar(rest, '-') != null) return null;
    return .{ base[0..idx], rest };
}

/// Parse a single value (number or name), validating range.
fn parseValue(str: []const u8, min: u7, max: u7, kind: NameKind) error{InvalidNumber}!u7 {
    // Try named value first via case-insensitive ComptimeStringMap lookup.
    switch (kind) {
        .weekday => if (getNamedValueCaseInsensitiveAscii(weekday_map, str)) |v| return v,
        .month => if (getNamedValueCaseInsensitiveAscii(month_map, str)) |v| return v,
        .none => {},
    }

    const val = std.fmt.parseInt(u8, str, 10) catch return error.InvalidNumber;
    if (val < min or val > max) return error.InvalidNumber;
    return @intCast(val);
}

// ============================================================================
// Helpers
// ============================================================================

inline fn bitSet(comptime T: type, set: T, pos: std.math.Log2Int(T)) bool {
    return (set >> pos) & 1 != 0;
}

/// Write a bitfield as a cron field string: "*" if all bits set, or comma-separated values.
fn formatBitfield(w: *std.Io.Writer, comptime T: type, bits: T, min: u8, max: u8) void {
    if (@popCount(bits) == @as(u32, max) - min + 1) {
        w.writeByte('*') catch unreachable;
        return;
    }
    var first = true;
    for (min..max + 1) |i| {
        if ((bits >> @intCast(i)) & 1 != 0) {
            if (!first) w.writeByte(',') catch unreachable;
            w.print("{d}", .{i}) catch unreachable;
            first = false;
        }
    }
}

// Locally-defined `bun.strings.trim` substitute: trims only ASCII space/tab.
fn trimAsciiWhitespace(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and (s[start] == ' ' or s[start] == '\t')) : (start += 1) {}
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t')) : (end -= 1) {}
    return s[start..end];
}

// Locally-defined `bun.strings.eqlCaseInsensitiveASCIIICheckLength` substitute.
fn eqlCaseInsensitiveAscii(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        const ca = std.ascii.toLower(a[i]);
        const cb = std.ascii.toLower(b[i]);
        if (ca != cb) return false;
    }
    return true;
}

// Locally-defined `M.getASCIIICaseInsensitive` substitute for u7-valued maps
// of names that fit inside `lower_buf`. Longest cron name is "wednesday" (9
// chars); anything longer than `lower_buf` is rejected (returns null), which
// matches the original semantics (no such key exists).
fn getNamedValueCaseInsensitiveAscii(comptime M: type, str: []const u8) ?u7 {
    var lower_buf: [16]u8 = undefined;
    if (str.len == 0 or str.len > lower_buf.len) return null;
    for (str, 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
    return M.get(lower_buf[0..str.len]);
}

const std = @import("std");
const home_rt = @import("home");

// JSC bridge: the real `jsc.JSGlobalObject` now carries
// `msToGregorianDateTimeUTC` / `gregorianDateTimeToMSUTC` + `GregorianDateTime`,
// so reference it directly (was a local opaque stub).
const JSError = home_rt.JSError;
const jsc = home_rt.jsc;

// ============================================================================
// Tests
// ============================================================================

test "CronExpression.parse: every minute" {
    const c = try CronExpression.parse("* * * * *");
    try std.testing.expect(c.days_is_wildcard);
    try std.testing.expect(c.weekdays_is_wildcard);
    // All 60 minute bits should be set.
    try std.testing.expectEqual(@as(u64, (1 << 60) - 1), c.minutes);
}

test "CronExpression.parse: list of minutes" {
    const c = try CronExpression.parse("1,5,30 * * * *");
    try std.testing.expect((c.minutes >> 1) & 1 == 1);
    try std.testing.expect((c.minutes >> 5) & 1 == 1);
    try std.testing.expect((c.minutes >> 30) & 1 == 1);
    try std.testing.expect((c.minutes >> 2) & 1 == 0);
}

test "CronExpression.parse: range and step" {
    const c = try CronExpression.parse("0-10/2 * * * *");
    for ([_]u6{ 0, 2, 4, 6, 8, 10 }) |m| try std.testing.expect((c.minutes >> m) & 1 == 1);
    try std.testing.expect((c.minutes >> 1) & 1 == 0);
    try std.testing.expect((c.minutes >> 12) & 1 == 0);
}

test "CronExpression.parse: named months are case-insensitive" {
    const a = try CronExpression.parse("0 0 1 JAN *");
    const b = try CronExpression.parse("0 0 1 Jan *");
    const c = try CronExpression.parse("0 0 1 january *");
    try std.testing.expectEqual(a.months, b.months);
    try std.testing.expectEqual(a.months, c.months);
    try std.testing.expectEqual(@as(u16, 1 << 1), a.months);
}

test "CronExpression.parse: weekday 7 folds to 0" {
    const a = try CronExpression.parse("0 0 * * 7");
    const b = try CronExpression.parse("0 0 * * 0");
    try std.testing.expectEqual(b.weekdays, a.weekdays);
}

test "CronExpression.parse: nicknames" {
    const yearly = try CronExpression.parse("@yearly");
    try std.testing.expectEqual(@as(u16, 1 << 1), yearly.months);
    const hourly = try CronExpression.parse("@hourly");
    try std.testing.expectEqual(@as(u32, all_hours), hourly.hours);
}

test "CronExpression.parse: error on too few fields" {
    try std.testing.expectError(error.TooFewFields, CronExpression.parse("* * * *"));
}

test "CronExpression.parse: error on too many fields" {
    try std.testing.expectError(error.TooManyFields, CronExpression.parse("* * * * * *"));
}

test "CronExpression.parse: error on invalid number" {
    try std.testing.expectError(error.InvalidNumber, CronExpression.parse("60 * * * *"));
}

test "CronExpression.parse: error on inverted range" {
    try std.testing.expectError(error.InvalidRange, CronExpression.parse("10-5 * * * *"));
}

test "CronExpression.validate: returns false on garbage" {
    try std.testing.expect(!CronExpression.validate("not a cron"));
    try std.testing.expect(CronExpression.validate("* * * * *"));
    try std.testing.expect(CronExpression.validate("@daily"));
}

test "CronExpression.formatNumeric: round-trips a parsed expression" {
    const c = try CronExpression.parse("0 0 * * *");
    var buf: [512]u8 = undefined;
    const s = c.formatNumeric(&buf);
    try std.testing.expectEqualStrings("0 0 * * *", s);
}

test "CronExpression.errorMessage: every variant has a non-empty message" {
    inline for (@typeInfo(CronExpression.Error).error_set.error_names.?) |e_name| {
        const err: CronExpression.Error = @field(CronExpression.Error, e_name);
        try std.testing.expect(CronExpression.errorMessage(err).len > 0);
    }
}

test "internal: trimAsciiWhitespace handles leading and trailing whitespace" {
    try std.testing.expectEqualStrings("a b", trimAsciiWhitespace("\t  a b \t "));
    try std.testing.expectEqualStrings("", trimAsciiWhitespace(" \t\t "));
}

test "internal: eqlCaseInsensitiveAscii rejects mismatched lengths" {
    try std.testing.expect(eqlCaseInsensitiveAscii("HELLO", "hello"));
    try std.testing.expect(!eqlCaseInsensitiveAscii("hello", "hello!"));
}
