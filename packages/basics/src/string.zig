// Home Language - String Module
// String manipulation and utilities

const std = @import("std");
const Allocator = std.mem.Allocator;

/// String type (just a slice for now)
pub const String = []const u8;

/// Mutable string builder
pub const StringBuilder = std.ArrayList(u8);

/// Create a string builder
pub fn createStringBuilder(allocator: Allocator) StringBuilder {
    return StringBuilder.init(allocator);
}

/// Check if strings are equal
pub fn equals(a: String, b: String) bool {
    return std.mem.eql(u8, a, b);
}

/// Check if string starts with prefix
pub fn startsWith(str: String, prefix: String) bool {
    return std.mem.startsWith(u8, str, prefix);
}

/// Check if string ends with suffix
pub fn endsWith(str: String, suffix: String) bool {
    return std.mem.endsWith(u8, str, suffix);
}

/// Find substring in string
pub fn indexOf(str: String, needle: String) ?usize {
    return std.mem.indexOf(u8, str, needle);
}

/// Split string by delimiter
pub fn split(allocator: Allocator, str: String, delimiter: String) ![]String {
    var list = std.ArrayList(String).init(allocator);
    var iter = std.mem.split(u8, str, delimiter);
    while (iter.next()) |part| {
        try list.append(part);
    }
    return list.toOwnedSlice();
}

/// Concatenate strings
pub fn concat(allocator: Allocator, strings: []const String) !String {
    var total_len: usize = 0;
    for (strings) |s| total_len += s.len;

    var result = try allocator.alloc(u8, total_len);
    var offset: usize = 0;
    for (strings) |s| {
        @memcpy(result[offset..offset + s.len], s);
        offset += s.len;
    }
    return result;
}

/// Duplicate a string
pub fn duplicate(allocator: Allocator, str: String) !String {
    return try allocator.dupe(u8, str);
}

/// Convert to lowercase
pub fn toLowercase(allocator: Allocator, str: String) !String {
    var result = try allocator.alloc(u8, str.len);
    for (str, 0..) |c, i| {
        result[i] = std.ascii.toLower(c);
    }
    return result;
}

/// Convert to uppercase
pub fn toUppercase(allocator: Allocator, str: String) !String {
    var result = try allocator.alloc(u8, str.len);
    for (str, 0..) |c, i| {
        result[i] = std.ascii.toUpper(c);
    }
    return result;
}

/// Trim whitespace from both ends
pub fn trim(str: String) String {
    return std.mem.trim(u8, str, &std.ascii.whitespace);
}

/// Trim whitespace from left
pub fn trimLeft(str: String) String {
    return std.mem.trimLeft(u8, str, &std.ascii.whitespace);
}

/// Trim whitespace from right
pub fn trimRight(str: String) String {
    return std.mem.trimRight(u8, str, &std.ascii.whitespace);
}

/// Format a string (like sprintf)
pub fn format(allocator: Allocator, comptime fmt: []const u8, args: anytype) !String {
    return std.fmt.allocPrint(allocator, fmt, args);
}
