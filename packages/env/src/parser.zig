// Home Programming Language - Environment Variable Parser
// Parser for .env files and environment variable syntax

const std = @import("std");

pub const ParseError = error{
    UnterminatedString,
    UnterminatedVariable,
    InvalidSyntax,
    InvalidEscapeSequence,
} || std.mem.Allocator.Error;

pub const Entry = struct {
    key: []const u8,
    value: []const u8,
};

// Parse a single line from .env file
pub fn parseLine(allocator: std.mem.Allocator, line: []const u8) ParseError!?Entry {
    // Trim whitespace
    const trimmed = std.mem.trim(u8, line, " \t\r\n");

    // Skip empty lines and comments
    if (trimmed.len == 0 or trimmed[0] == '#') {
        return null;
    }

    // Find '=' separator
    const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=') orelse return null;

    const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
    if (key.len == 0) return null;

    // Validate key (alphanumeric and underscore only)
    for (key) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') {
            return error.InvalidSyntax;
        }
    }

    const value_raw = std.mem.trim(u8, trimmed[eq_pos + 1..], " \t");
    const value = try parseValue(allocator, value_raw);

    return Entry{
        .key = try allocator.dupe(u8, key),
        .value = value,
    };
}

// Parse value with quote handling and escape sequences
fn parseValue(allocator: std.mem.Allocator, value: []const u8) ParseError![]const u8 {
    if (value.len == 0) {
        return try allocator.dupe(u8, "");
    }

    // Handle quoted strings
    if (value[0] == '"') {
        return try parseDoubleQuoted(allocator, value);
    } else if (value[0] == '\'') {
        return try parseSingleQuoted(allocator, value);
    }

    // Unquoted value - trim comments
    if (std.mem.indexOfScalar(u8, value, '#')) |comment_pos| {
        const before_comment = std.mem.trimRight(u8, value[0..comment_pos], " \t");
        return try allocator.dupe(u8, before_comment);
    }

    return try allocator.dupe(u8, value);
}

// Parse double-quoted string with escape sequences
fn parseDoubleQuoted(allocator: std.mem.Allocator, value: []const u8) ParseError![]const u8 {
    if (value.len < 2 or value[0] != '"') {
        return error.InvalidSyntax;
    }

    var result = std.ArrayList(u8){};
    errdefer result.deinit(allocator);

    var i: usize = 1; // Skip opening quote
    var found_closing_quote = false;

    while (i < value.len) {
        if (value[i] == '"') {
            found_closing_quote = true;
            break;
        }

        if (value[i] == '\\' and i + 1 < value.len) {
            i += 1;
            const escaped: u8 = switch (value[i]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '\\' => '\\',
                '"' => '"',
                '\'' => '\'',
                else => return error.InvalidEscapeSequence,
            };
            try result.append(allocator, escaped);
        } else {
            try result.append(allocator, value[i]);
        }

        i += 1;
    }

    if (!found_closing_quote) {
        return error.UnterminatedString;
    }

    return try result.toOwnedSlice(allocator);
}

// Parse single-quoted string (no escape sequences)
fn parseSingleQuoted(allocator: std.mem.Allocator, value: []const u8) ParseError![]const u8 {
    if (value.len < 2 or value[0] != '\'') {
        return error.InvalidSyntax;
    }

    const closing_pos = std.mem.indexOfScalarPos(u8, value, 1, '\'') orelse {
        return error.UnterminatedString;
    };

    return try allocator.dupe(u8, value[1..closing_pos]);
}

// Parse multi-line value
pub fn parseMultiLine(allocator: std.mem.Allocator, lines: []const []const u8) ParseError![]const u8 {
    var result = std.ArrayList(u8){};
    errdefer result.deinit(allocator);

    for (lines, 0..) |line, i| {
        if (i > 0) try result.append(allocator, '\n');
        try result.appendSlice(allocator, line);
    }

    return try result.toOwnedSlice(allocator);
}

// Parse entire .env file content
pub fn parseContent(allocator: std.mem.Allocator, content: []const u8) ParseError!std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var iter = map.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        map.deinit();
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (try parseLine(allocator, line)) |entry| {
            // If key already exists, free old value
            if (map.get(entry.key)) |old_value| {
                allocator.free(old_value);
            }
            try map.put(entry.key, entry.value);
        }
    }

    return map;
}

// Validate variable name
pub fn isValidVarName(name: []const u8) bool {
    if (name.len == 0) return false;

    // First character must be letter or underscore
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') {
        return false;
    }

    // Rest can be alphanumeric or underscore
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') {
            return false;
        }
    }

    return true;
}

test "parser parse simple line" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const entry = try parseLine(allocator, "KEY=value");
    try testing.expect(entry != null);

    const e = entry.?;
    defer allocator.free(e.key);
    defer allocator.free(e.value);

    try testing.expectEqualStrings("KEY", e.key);
    try testing.expectEqualStrings("value", e.value);
}

test "parser parse quoted value" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const entry = try parseLine(allocator, "KEY=\"hello world\"");
    try testing.expect(entry != null);

    const e = entry.?;
    defer allocator.free(e.key);
    defer allocator.free(e.value);

    try testing.expectEqualStrings("KEY", e.key);
    try testing.expectEqualStrings("hello world", e.value);
}

test "parser parse with escape sequences" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const entry = try parseLine(allocator, "KEY=\"line1\\nline2\\ttab\"");
    try testing.expect(entry != null);

    const e = entry.?;
    defer allocator.free(e.key);
    defer allocator.free(e.value);

    try testing.expectEqualStrings("KEY", e.key);
    try testing.expectEqualStrings("line1\nline2\ttab", e.value);
}

test "parser skip comments" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const entry = try parseLine(allocator, "# This is a comment");
    try testing.expectEqual(@as(?Entry, null), entry);
}

test "parser skip empty lines" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const entry = try parseLine(allocator, "   ");
    try testing.expectEqual(@as(?Entry, null), entry);
}

test "parser inline comments" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const entry = try parseLine(allocator, "KEY=value # inline comment");
    try testing.expect(entry != null);

    const e = entry.?;
    defer allocator.free(e.key);
    defer allocator.free(e.value);

    try testing.expectEqualStrings("KEY", e.key);
    try testing.expectEqualStrings("value", e.value);
}

test "parser single quotes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const entry = try parseLine(allocator, "KEY='single quoted'");
    try testing.expect(entry != null);

    const e = entry.?;
    defer allocator.free(e.key);
    defer allocator.free(e.value);

    try testing.expectEqualStrings("KEY", e.key);
    try testing.expectEqualStrings("single quoted", e.value);
}

test "parser validate var name" {
    const testing = std.testing;

    try testing.expect(isValidVarName("VALID_VAR"));
    try testing.expect(isValidVarName("_UNDERSCORE"));
    try testing.expect(isValidVarName("VAR123"));
    try testing.expect(!isValidVarName("123VAR"));
    try testing.expect(!isValidVarName("VAR-NAME"));
    try testing.expect(!isValidVarName(""));
}

test "parser parse content" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const content =
        \\# Comment line
        \\KEY1=value1
        \\KEY2="quoted value"
        \\
        \\KEY3=value3
    ;

    var map = try parseContent(allocator, content);
    defer {
        var iter = map.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        map.deinit();
    }

    try testing.expectEqual(@as(usize, 3), map.count());
    try testing.expectEqualStrings("value1", map.get("KEY1").?);
    try testing.expectEqualStrings("quoted value", map.get("KEY2").?);
    try testing.expectEqualStrings("value3", map.get("KEY3").?);
}
