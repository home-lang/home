const std = @import("std");

/// Check if value is a valid integer
pub fn isInteger(value: []const u8) bool {
    if (value.len == 0) return false;

    var start: usize = 0;
    if (value[0] == '-' or value[0] == '+') {
        start = 1;
        if (value.len == 1) return false;
    }

    for (value[start..]) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// Check if value is a valid float
pub fn isFloat(value: []const u8) bool {
    if (value.len == 0) return false;

    var has_dot = false;
    var start: usize = 0;

    if (value[0] == '-' or value[0] == '+') {
        start = 1;
        if (value.len == 1) return false;
    }

    for (value[start..]) |c| {
        if (c == '.') {
            if (has_dot) return false;
            has_dot = true;
        } else if (c < '0' or c > '9') {
            return false;
        }
    }
    return true;
}

/// Check if value is a valid boolean
pub fn isBoolean(value: []const u8) bool {
    return std.mem.eql(u8, value, "true") or
        std.mem.eql(u8, value, "false") or
        std.mem.eql(u8, value, "1") or
        std.mem.eql(u8, value, "0");
}

/// Check if value is a valid email (basic check)
pub fn isEmail(value: []const u8) bool {
    if (value.len < 3) return false;

    const at_pos = std.mem.indexOf(u8, value, "@") orelse return false;
    if (at_pos == 0 or at_pos == value.len - 1) return false;

    const domain = value[at_pos + 1 ..];
    const dot_pos = std.mem.indexOf(u8, domain, ".") orelse return false;
    if (dot_pos == 0 or dot_pos == domain.len - 1) return false;

    // Check for valid characters
    for (value[0..at_pos]) |c| {
        if (!isValidEmailChar(c)) return false;
    }

    return true;
}

fn isValidEmailChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '.' or c == '_' or c == '-' or c == '+';
}

/// Check if value is a valid URL (basic check)
pub fn isUrl(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "http://") or
        std.mem.startsWith(u8, value, "https://");
}

/// Check if value contains only alphabetic characters
pub fn isAlpha(value: []const u8) bool {
    for (value) |c| {
        if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z'))) {
            return false;
        }
    }
    return value.len > 0;
}

/// Check if value contains only alphanumeric characters
pub fn isAlphanumeric(value: []const u8) bool {
    for (value) |c| {
        if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9'))) {
            return false;
        }
    }
    return value.len > 0;
}

/// Check if value contains only numeric characters
pub fn isNumeric(value: []const u8) bool {
    for (value) |c| {
        if (c < '0' or c > '9') return false;
    }
    return value.len > 0;
}

/// Check if numeric value is at least min
pub fn minValue(value: []const u8, min: usize) bool {
    const num = std.fmt.parseInt(i64, value, 10) catch return false;
    return num >= @as(i64, @intCast(min));
}

/// Check if numeric value is at most max
pub fn maxValue(value: []const u8, max: usize) bool {
    const num = std.fmt.parseInt(i64, value, 10) catch return false;
    return num <= @as(i64, @intCast(max));
}

/// Check if numeric value is between min and max
pub fn between(value: []const u8, min: usize, max: usize) bool {
    const num = std.fmt.parseInt(i64, value, 10) catch return false;
    return num >= @as(i64, @intCast(min)) and num <= @as(i64, @intCast(max));
}

/// Check if value is in list
pub fn inList(value: []const u8, list: []const []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, value, item)) return true;
    }
    return false;
}

/// Check if value matches pattern (simple wildcard matching)
pub fn matchesRegex(value: []const u8, pattern: []const u8) bool {
    // Simple pattern matching - support * as wildcard
    // For real regex, would need external library
    if (std.mem.eql(u8, pattern, "*")) return true;

    if (std.mem.startsWith(u8, pattern, "*")) {
        const suffix = pattern[1..];
        return std.mem.endsWith(u8, value, suffix);
    }

    if (std.mem.endsWith(u8, pattern, "*")) {
        const prefix = pattern[0 .. pattern.len - 1];
        return std.mem.startsWith(u8, value, prefix);
    }

    return std.mem.eql(u8, value, pattern);
}

/// Check if value is a valid UUID
pub fn isUuid(value: []const u8) bool {
    // Format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx (36 chars)
    if (value.len != 36) return false;

    const expected_dashes = [_]usize{ 8, 13, 18, 23 };
    for (expected_dashes) |pos| {
        if (value[pos] != '-') return false;
    }

    for (value, 0..) |c, i| {
        // Skip dash positions
        var is_dash_pos = false;
        for (expected_dashes) |pos| {
            if (i == pos) {
                is_dash_pos = true;
                break;
            }
        }
        if (is_dash_pos) continue;

        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'))) {
            return false;
        }
    }

    return true;
}

/// Check if value is a valid date (YYYY-MM-DD format)
pub fn isDate(value: []const u8) bool {
    if (value.len != 10) return false;
    if (value[4] != '-' or value[7] != '-') return false;

    const year = std.fmt.parseInt(u16, value[0..4], 10) catch return false;
    const month = std.fmt.parseInt(u8, value[5..7], 10) catch return false;
    const day = std.fmt.parseInt(u8, value[8..10], 10) catch return false;

    if (year < 1 or year > 9999) return false;
    if (month < 1 or month > 12) return false;
    if (day < 1 or day > 31) return false;

    // Basic day validation per month
    const days_in_month = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var max_days = days_in_month[month - 1];

    // Leap year check for February
    if (month == 2) {
        const is_leap = (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
        if (is_leap) max_days = 29;
    }

    return day <= max_days;
}

/// Check if value is a valid IP address (v4 or v6)
pub fn isIp(value: []const u8) bool {
    return isIpv4(value) or isIpv6(value);
}

/// Check if value is a valid IPv4 address
pub fn isIpv4(value: []const u8) bool {
    var parts: usize = 0;
    var current: u16 = 0;
    var has_digit = false;

    for (value) |c| {
        if (c == '.') {
            if (!has_digit or current > 255) return false;
            parts += 1;
            current = 0;
            has_digit = false;
        } else if (c >= '0' and c <= '9') {
            current = current * 10 + (c - '0');
            has_digit = true;
        } else {
            return false;
        }
    }

    if (!has_digit or current > 255) return false;
    return parts == 3;
}

/// Check if value is a valid IPv6 address (basic check)
pub fn isIpv6(value: []const u8) bool {
    if (value.len < 2) return false;

    var groups: usize = 0;
    var current_len: usize = 0;
    var has_double_colon = false;

    var i: usize = 0;
    while (i < value.len) {
        const c = value[i];

        if (c == ':') {
            if (i + 1 < value.len and value[i + 1] == ':') {
                if (has_double_colon) return false; // Only one :: allowed
                has_double_colon = true;
                i += 1;
                if (current_len > 0) groups += 1;
                current_len = 0;
            } else {
                if (current_len == 0 and i > 0) return false;
                if (current_len > 4) return false;
                groups += 1;
                current_len = 0;
            }
        } else if ((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')) {
            current_len += 1;
            if (current_len > 4) return false;
        } else {
            return false;
        }
        i += 1;
    }

    if (current_len > 0) groups += 1;

    if (has_double_colon) {
        return groups <= 8;
    }
    return groups == 8;
}

/// Check if value is valid JSON
pub fn isJson(value: []const u8) bool {
    if (value.len == 0) return false;

    // Very basic check: starts with { or [ and ends with } or ]
    const first = value[0];
    const last = value[value.len - 1];

    if (first == '{' and last == '}') return true;
    if (first == '[' and last == ']') return true;

    return false;
}

/// Check if value is accepted (true, "true", "yes", "on", "1")
pub fn isAccepted(value: []const u8) bool {
    return std.mem.eql(u8, value, "true") or
        std.mem.eql(u8, value, "yes") or
        std.mem.eql(u8, value, "on") or
        std.mem.eql(u8, value, "1");
}

/// Check if value has exactly count digits
pub fn hasDigits(value: []const u8, count: usize) bool {
    if (value.len != count) return false;
    for (value) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

// Tests
test "isInteger" {
    try std.testing.expect(isInteger("123"));
    try std.testing.expect(isInteger("-123"));
    try std.testing.expect(isInteger("+123"));
    try std.testing.expect(!isInteger("12.3"));
    try std.testing.expect(!isInteger("abc"));
    try std.testing.expect(!isInteger(""));
}

test "isFloat" {
    try std.testing.expect(isFloat("123.45"));
    try std.testing.expect(isFloat("-123.45"));
    try std.testing.expect(isFloat("123"));
    try std.testing.expect(!isFloat("12.3.4"));
    try std.testing.expect(!isFloat("abc"));
}

test "isEmail" {
    try std.testing.expect(isEmail("test@example.com"));
    try std.testing.expect(isEmail("user.name@domain.co.uk"));
    try std.testing.expect(!isEmail("invalid"));
    try std.testing.expect(!isEmail("@example.com"));
    try std.testing.expect(!isEmail("test@"));
}

test "isUuid" {
    try std.testing.expect(isUuid("550e8400-e29b-41d4-a716-446655440000"));
    try std.testing.expect(!isUuid("invalid-uuid"));
    try std.testing.expect(!isUuid("550e8400e29b41d4a716446655440000")); // missing dashes
}

test "isDate" {
    try std.testing.expect(isDate("2024-01-15"));
    try std.testing.expect(isDate("2024-02-29")); // leap year
    try std.testing.expect(!isDate("2023-02-29")); // not leap year
    try std.testing.expect(!isDate("2024-13-01")); // invalid month
    try std.testing.expect(!isDate("invalid"));
}

test "isIpv4" {
    try std.testing.expect(isIpv4("192.168.1.1"));
    try std.testing.expect(isIpv4("255.255.255.255"));
    try std.testing.expect(isIpv4("0.0.0.0"));
    try std.testing.expect(!isIpv4("256.1.1.1")); // out of range
    try std.testing.expect(!isIpv4("192.168.1")); // too few parts
}

test "inList" {
    const list = [_][]const u8{ "apple", "banana", "cherry" };
    try std.testing.expect(inList("apple", &list));
    try std.testing.expect(inList("banana", &list));
    try std.testing.expect(!inList("orange", &list));
}

test "isAccepted" {
    try std.testing.expect(isAccepted("true"));
    try std.testing.expect(isAccepted("yes"));
    try std.testing.expect(isAccepted("on"));
    try std.testing.expect(isAccepted("1"));
    try std.testing.expect(!isAccepted("false"));
    try std.testing.expect(!isAccepted("no"));
}
