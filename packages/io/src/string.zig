// String utilities for Home Language
// Provides common string operations for game development

const std = @import("std");
const Allocator = std.mem.Allocator;

/// String builder for efficient concatenation
pub const StringBuilder = struct {
    buffer: std.ArrayList(u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator) !StringBuilder {
        return StringBuilder{
            .buffer = try std.ArrayList(u8).initCapacity(allocator, 256),
            .allocator = allocator,
        };
    }

    pub fn initCapacity(allocator: Allocator, capacity: usize) !StringBuilder {
        return StringBuilder{
            .buffer = try std.ArrayList(u8).initCapacity(allocator, capacity),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StringBuilder) void {
        self.buffer.deinit(self.allocator);
    }

    /// Append a string
    pub fn append(self: *StringBuilder, string: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, string);
    }

    /// Append a single character
    pub fn appendChar(self: *StringBuilder, ch: u8) !void {
        try self.buffer.append(self.allocator, ch);
    }

    /// Append formatted text
    pub fn appendFmt(self: *StringBuilder, comptime fmt: []const u8, args: anytype) !void {
        const formatted = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(formatted);
        try self.append(formatted);
    }

    /// Get the built string (does not transfer ownership)
    pub fn str(self: *const StringBuilder) []const u8 {
        return self.buffer.items;
    }

    /// Get owned slice (transfers ownership to caller)
    pub fn toOwnedSlice(self: *StringBuilder) ![]u8 {
        return self.buffer.toOwnedSlice(self.allocator);
    }

    /// Clear the buffer
    pub fn clear(self: *StringBuilder) void {
        self.buffer.clearRetainingCapacity();
    }

    /// Get current length
    pub fn len(self: *const StringBuilder) usize {
        return self.buffer.items.len;
    }
};

/// Concatenate multiple strings (caller owns returned memory)
pub fn concat(allocator: Allocator, strings: []const []const u8) ![]u8 {
    var total_len: usize = 0;
    for (strings) |s| {
        total_len += s.len;
    }

    var result = try allocator.alloc(u8, total_len);
    var pos: usize = 0;

    for (strings) |s| {
        @memcpy(result[pos..][0..s.len], s);
        pos += s.len;
    }

    return result;
}

/// Format a string (caller owns returned memory)
pub fn format(allocator: Allocator, comptime fmt: []const u8, args: anytype) ![]u8 {
    return try std.fmt.allocPrint(allocator, fmt, args);
}

/// Check if string starts with prefix
pub fn startsWith(str: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, str, prefix);
}

/// Check if string ends with suffix
pub fn endsWith(str: []const u8, suffix: []const u8) bool {
    return std.mem.endsWith(u8, str, suffix);
}

/// Check if string contains substring
pub fn contains(str: []const u8, substring: []const u8) bool {
    return std.mem.indexOf(u8, str, substring) != null;
}

/// Find index of substring (returns null if not found)
pub fn indexOf(str: []const u8, substring: []const u8) ?usize {
    return std.mem.indexOf(u8, str, substring);
}

/// Find last index of substring
pub fn lastIndexOf(str: []const u8, substring: []const u8) ?usize {
    return std.mem.lastIndexOf(u8, str, substring);
}

/// Split string by delimiter (caller owns returned memory)
pub fn split(allocator: Allocator, str: []const u8, delimiter: []const u8) ![][]const u8 {
    var result = try std.ArrayList([]const u8).initCapacity(allocator, 8);
    errdefer result.deinit(allocator);

    var iter = std.mem.splitSequence(u8, str, delimiter);
    while (iter.next()) |part| {
        try result.append(allocator, part);
    }

    return result.toOwnedSlice(allocator);
}

/// Join strings with separator (caller owns returned memory)
pub fn join(allocator: Allocator, strings: []const []const u8, separator: []const u8) ![]u8 {
    if (strings.len == 0) return try allocator.dupe(u8, "");
    if (strings.len == 1) return try allocator.dupe(u8, strings[0]);

    var total_len: usize = 0;
    for (strings, 0..) |s, i| {
        total_len += s.len;
        if (i < strings.len - 1) {
            total_len += separator.len;
        }
    }

    var result = try allocator.alloc(u8, total_len);
    var pos: usize = 0;

    for (strings, 0..) |s, i| {
        @memcpy(result[pos..][0..s.len], s);
        pos += s.len;

        if (i < strings.len - 1) {
            @memcpy(result[pos..][0..separator.len], separator);
            pos += separator.len;
        }
    }

    return result;
}

/// Trim whitespace from both ends
pub fn trim(str: []const u8) []const u8 {
    return std.mem.trim(u8, str, &std.ascii.whitespace);
}

/// Trim whitespace from left
pub fn trimLeft(str: []const u8) []const u8 {
    return std.mem.trimLeft(u8, str, &std.ascii.whitespace);
}

/// Trim whitespace from right
pub fn trimRight(str: []const u8) []const u8 {
    return std.mem.trimRight(u8, str, &std.ascii.whitespace);
}

/// Replace all occurrences of a substring (caller owns returned memory)
pub fn replace(allocator: Allocator, str: []const u8, old: []const u8, new: []const u8) ![]u8 {
    if (old.len == 0) return try allocator.dupe(u8, str);

    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOf(u8, str[pos..], old)) |idx| {
        count += 1;
        pos += idx + old.len;
    }

    if (count == 0) return try allocator.dupe(u8, str);

    // Calculate new length accounting for potential shrinkage
    const new_len = if (new.len >= old.len)
        str.len + count * (new.len - old.len)
    else
        str.len - count * (old.len - new.len);

    var result = try allocator.alloc(u8, new_len);

    pos = 0;
    var result_pos: usize = 0;
    var search_pos: usize = 0;

    while (std.mem.indexOf(u8, str[search_pos..], old)) |idx| {
        const actual_idx = search_pos + idx;

        // Copy everything before the match
        if (actual_idx > search_pos) {
            const len = actual_idx - search_pos;
            @memcpy(result[result_pos..][0..len], str[search_pos..actual_idx]);
            result_pos += len;
        }

        // Copy the replacement
        @memcpy(result[result_pos..][0..new.len], new);
        result_pos += new.len;

        search_pos = actual_idx + old.len;
    }

    // Copy remaining
    if (search_pos < str.len) {
        const len = str.len - search_pos;
        @memcpy(result[result_pos..][0..len], str[search_pos..]);
    }

    return result;
}

/// Convert to lowercase (caller owns returned memory)
pub fn toLower(allocator: Allocator, str: []const u8) ![]u8 {
    var result = try allocator.alloc(u8, str.len);
    for (str, 0..) |ch, i| {
        result[i] = std.ascii.toLower(ch);
    }
    return result;
}

/// Convert to uppercase (caller owns returned memory)
pub fn toUpper(allocator: Allocator, str: []const u8) ![]u8 {
    var result = try allocator.alloc(u8, str.len);
    for (str, 0..) |ch, i| {
        result[i] = std.ascii.toUpper(ch);
    }
    return result;
}

/// Compare strings (case-insensitive)
pub fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |ch, i| {
        if (std.ascii.toLower(ch) != std.ascii.toLower(b[i])) {
            return false;
        }
    }
    return true;
}

/// Parse integer from string
pub fn parseInt(comptime T: type, str: []const u8, base: u8) !T {
    return try std.fmt.parseInt(T, str, base);
}

/// Parse float from string
pub fn parseFloat(comptime T: type, str: []const u8) !T {
    return try std.fmt.parseFloat(T, str);
}

/// Repeat a string n times (caller owns returned memory)
pub fn repeat(allocator: Allocator, str: []const u8, n: usize) ![]u8 {
    if (n == 0) return try allocator.dupe(u8, "");
    if (n == 1) return try allocator.dupe(u8, str);

    var result = try allocator.alloc(u8, str.len * n);
    var pos: usize = 0;

    var i: usize = 0;
    while (i < n) : (i += 1) {
        @memcpy(result[pos..][0..str.len], str);
        pos += str.len;
    }

    return result;
}

/// Pad string to the left with a character
pub fn padLeft(allocator: Allocator, str: []const u8, total_width: usize, pad_char: u8) ![]u8 {
    if (str.len >= total_width) return try allocator.dupe(u8, str);

    var result = try allocator.alloc(u8, total_width);

    const pad_len = total_width - str.len;
    @memset(result[0..pad_len], pad_char);
    @memcpy(result[pad_len..], str);

    return result;
}

/// Pad string to the right with a character
pub fn padRight(allocator: Allocator, str: []const u8, total_width: usize, pad_char: u8) ![]u8 {
    if (str.len >= total_width) return try allocator.dupe(u8, str);

    var result = try allocator.alloc(u8, total_width);

    @memcpy(result[0..str.len], str);
    @memset(result[str.len..], pad_char);

    return result;
}

// ==================== Tests ====================

test "StringBuilder: basic operations" {
    const allocator = std.testing.allocator;

    var sb = try StringBuilder.init(allocator);
    defer sb.deinit();

    try sb.append("Hello");
    try sb.appendChar(' ');
    try sb.append("World");

    try std.testing.expectEqualStrings("Hello World", sb.str());
}

test "StringBuilder: format" {
    const allocator = std.testing.allocator;

    var sb = try StringBuilder.init(allocator);
    defer sb.deinit();

    try sb.appendFmt("Health: {d}, Damage: {d}", .{ 100, 25 });

    try std.testing.expectEqualStrings("Health: 100, Damage: 25", sb.str());
}

test "String: concat" {
    const allocator = std.testing.allocator;

    const parts = [_][]const u8{ "Command", " & ", "Conquer", ": ", "Generals" };
    const result = try concat(allocator, &parts);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Command & Conquer: Generals", result);
}

test "String: split and join" {
    const allocator = std.testing.allocator;

    const str = "apple,banana,orange";
    const parts = try split(allocator, str, ",");
    defer {
        allocator.free(parts);
    }

    try std.testing.expectEqual(@as(usize, 3), parts.len);
    try std.testing.expectEqualStrings("apple", parts[0]);
    try std.testing.expectEqualStrings("banana", parts[1]);
    try std.testing.expectEqualStrings("orange", parts[2]);

    const joined = try join(allocator, parts, ", ");
    defer allocator.free(joined);

    try std.testing.expectEqualStrings("apple, banana, orange", joined);
}

test "String: replace" {
    const allocator = std.testing.allocator;

    const str = "Hello World, Hello Universe";
    const result = try replace(allocator, str, "Hello", "Hi");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hi World, Hi Universe", result);
}

test "String: case conversion" {
    const allocator = std.testing.allocator;

    const lower = try toLower(allocator, "GENERALS");
    defer allocator.free(lower);
    try std.testing.expectEqualStrings("generals", lower);

    const upper = try toUpper(allocator, "generals");
    defer allocator.free(upper);
    try std.testing.expectEqualStrings("GENERALS", upper);

    try std.testing.expect(equalsIgnoreCase("Generals", "GENERALS"));
    try std.testing.expect(equalsIgnoreCase("generals", "Generals"));
}

test "String: trim" {
    try std.testing.expectEqualStrings("hello", trim("  hello  "));
    try std.testing.expectEqualStrings("hello", trimLeft("  hello"));
    try std.testing.expectEqualStrings("hello", trimRight("hello  "));
}

test "String: startsWith, endsWith, contains" {
    try std.testing.expect(startsWith("Generals", "Gen"));
    try std.testing.expect(!startsWith("Generals", "gen"));
    try std.testing.expect(endsWith("Generals", "als"));
    try std.testing.expect(contains("Generals", "era"));
}

test "String: parse" {
    try std.testing.expectEqual(@as(i32, 42), try parseInt(i32, "42", 10));
    try std.testing.expectEqual(@as(f64, 3.14), try parseFloat(f64, "3.14"));
}

test "String: repeat" {
    const allocator = std.testing.allocator;

    const result = try repeat(allocator, "Hi", 3);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("HiHiHi", result);
}

test "String: padding" {
    const allocator = std.testing.allocator;

    const left = try padLeft(allocator, "42", 5, '0');
    defer allocator.free(left);
    try std.testing.expectEqualStrings("00042", left);

    const right = try padRight(allocator, "42", 5, '0');
    defer allocator.free(right);
    try std.testing.expectEqualStrings("42000", right);
}
