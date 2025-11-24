// Home Programming Language - C String Utilities
// Utilities for working with C null-terminated strings

const std = @import("std");

// ============================================================================
// C String Type Aliases
// ============================================================================

/// C null-terminated string (const)
pub const CStr = [*:0]const u8;

/// Mutable C null-terminated string
pub const CStrMut = [*:0]u8;

// ============================================================================
// Conversion Functions
// ============================================================================

/// Convert Home string slice to C string (allocates)
pub fn fromHome(allocator: std.mem.Allocator, home_str: []const u8) ![:0]const u8 {
    const c_str = try allocator.allocSentinel(u8, home_str.len, 0);
    @memcpy(c_str[0..home_str.len], home_str);
    return c_str;
}

/// Convert C string to Home string slice (no allocation)
pub fn toHome(c_str: CStr) []const u8 {
    return std.mem.span(c_str);
}

/// Convert C string to Home string slice with known length
pub fn toHomeLen(c_str: CStr, len: usize) []const u8 {
    return c_str[0..len];
}

/// Duplicate a C string (allocates)
pub fn duplicate(allocator: std.mem.Allocator, c_str: CStr) ![:0]const u8 {
    const len = length(c_str);
    const new_str = try allocator.allocSentinel(u8, len, 0);
    @memcpy(new_str[0..len], c_str[0..len]);
    return new_str;
}

// ============================================================================
// Length and Comparison
// ============================================================================

/// Get length of C string (like strlen)
pub fn length(c_str: CStr) usize {
    var len: usize = 0;
    while (c_str[len] != 0) : (len += 1) {}
    return len;
}

/// Compare two C strings (like strcmp)
pub fn compare(s1: CStr, s2: CStr) i32 {
    var i: usize = 0;
    while (true) : (i += 1) {
        if (s1[i] != s2[i]) {
            return if (s1[i] < s2[i]) -1 else 1;
        }
        if (s1[i] == 0) break;
    }
    return 0;
}

/// Compare two C strings up to n characters (like strncmp)
pub fn compareN(s1: CStr, s2: CStr, n: usize) i32 {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (s1[i] != s2[i]) {
            return if (s1[i] < s2[i]) -1 else 1;
        }
        if (s1[i] == 0) break;
    }
    return 0;
}

/// Check if two C strings are equal
pub fn equals(s1: CStr, s2: CStr) bool {
    return compare(s1, s2) == 0;
}

// ============================================================================
// String Operations
// ============================================================================

/// Copy C string (like strcpy) - caller ensures dest has enough space
pub fn copy(dest: CStrMut, src: CStr) void {
    var i: usize = 0;
    while (src[i] != 0) : (i += 1) {
        dest[i] = src[i];
    }
    dest[i] = 0;
}

/// Copy C string with length limit (like strncpy)
pub fn copyN(dest: CStrMut, src: CStr, n: usize) void {
    var i: usize = 0;
    while (i < n and src[i] != 0) : (i += 1) {
        dest[i] = src[i];
    }
    while (i < n) : (i += 1) {
        dest[i] = 0;
    }
}

/// Concatenate two C strings (like strcat) - caller ensures dest has enough space
pub fn concat(dest: CStrMut, src: CStr) void {
    const dest_len = length(dest);
    var i: usize = 0;
    while (src[i] != 0) : (i += 1) {
        dest[dest_len + i] = src[i];
    }
    dest[dest_len + i] = 0;
}

/// Concatenate with length limit (like strncat)
pub fn concatN(dest: CStrMut, src: CStr, n: usize) void {
    const dest_len = length(dest);
    var i: usize = 0;
    while (i < n and src[i] != 0) : (i += 1) {
        dest[dest_len + i] = src[i];
    }
    dest[dest_len + i] = 0;
}

// ============================================================================
// Search Functions
// ============================================================================

/// Find character in C string (like strchr)
pub fn findChar(c_str: CStr, char: u8) ?CStr {
    var i: usize = 0;
    while (c_str[i] != 0) : (i += 1) {
        if (c_str[i] == char) {
            return c_str + i;
        }
    }
    return null;
}

/// Find last occurrence of character (like strrchr)
pub fn findCharLast(c_str: CStr, char: u8) ?CStr {
    const len = length(c_str);
    var i: usize = len;
    while (i > 0) {
        i -= 1;
        if (c_str[i] == char) {
            return c_str + i;
        }
    }
    return null;
}

/// Find substring in C string (like strstr)
pub fn findSubstring(haystack: CStr, needle: CStr) ?CStr {
    const needle_len = length(needle);
    if (needle_len == 0) return haystack;

    var i: usize = 0;
    while (haystack[i] != 0) : (i += 1) {
        var j: usize = 0;
        while (j < needle_len and haystack[i + j] == needle[j]) : (j += 1) {}

        if (j == needle_len) {
            return haystack + i;
        }
    }
    return null;
}

// ============================================================================
// Character Classification
// ============================================================================

/// Check if character is whitespace
pub fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\x0B' or c == '\x0C';
}

/// Check if character is alphanumeric
pub fn isAlnum(c: u8) bool {
    return isAlpha(c) or isDigit(c);
}

/// Check if character is alphabetic
pub fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

/// Check if character is digit
pub fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Convert character to uppercase
pub fn toUpper(c: u8) u8 {
    if (c >= 'a' and c <= 'z') {
        return c - ('a' - 'A');
    }
    return c;
}

/// Convert character to lowercase
pub fn toLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') {
        return c + ('a' - 'A');
    }
    return c;
}

// ============================================================================
// Utility Functions
// ============================================================================

/// Check if C string is empty
pub fn isEmpty(c_str: CStr) bool {
    return c_str[0] == 0;
}

/// Get pointer to end of C string (points to null terminator)
pub fn end(c_str: CStr) CStr {
    return c_str + length(c_str);
}

// ============================================================================
// Tests
// ============================================================================

test "C string length" {
    const testing = std.testing;

    const str: CStr = "Hello";
    try testing.expectEqual(@as(usize, 5), length(str));

    const empty: CStr = "";
    try testing.expectEqual(@as(usize, 0), length(empty));
}

test "fromHome and toHome" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const home_str = "Hello, World!";
    const c_str = try fromHome(allocator, home_str);
    defer allocator.free(c_str);

    try testing.expectEqual(@as(usize, 13), length(c_str.ptr));

    const back = toHome(c_str.ptr);
    try testing.expectEqualStrings(home_str, back);
}

test "C string comparison" {
    const testing = std.testing;

    const str1: CStr = "apple";
    const str2: CStr = "banana";
    const str3: CStr = "apple";

    try testing.expect(compare(str1, str2) < 0);
    try testing.expect(compare(str2, str1) > 0);
    try testing.expect(compare(str1, str3) == 0);

    try testing.expect(equals(str1, str3));
    try testing.expect(!equals(str1, str2));
}

test "C string copy" {
    const testing = std.testing;

    var dest: [20:0]u8 = undefined;
    const src: CStr = "test";

    copy(&dest, src);

    try testing.expectEqualStrings("test", dest[0..4]);
    try testing.expectEqual(@as(u8, 0), dest[4]);
}

test "C string concatenation" {
    const testing = std.testing;

    var dest: [20:0]u8 = undefined;
    @memcpy(dest[0..5], "Hello");
    dest[5] = 0;

    const src: CStr = ", World!";
    concat(&dest, src);

    const result = toHome(&dest);
    try testing.expectEqualStrings("Hello, World!", result);
}

test "Find character" {
    const testing = std.testing;

    const str: CStr = "Hello, World!";

    const result1 = findChar(str, 'W');
    try testing.expect(result1 != null);
    try testing.expectEqual(@as(u8, 'W'), result1.?[0]);

    const result2 = findChar(str, 'x');
    try testing.expect(result2 == null);
}

test "Find substring" {
    const testing = std.testing;

    const haystack: CStr = "Hello, World!";
    const needle: CStr = "World";

    const result = findSubstring(haystack, needle);
    try testing.expect(result != null);

    const found = toHome(result.?);
    try testing.expect(std.mem.startsWith(u8, found, "World"));
}

test "Character classification" {
    const testing = std.testing;

    try testing.expect(isSpace(' '));
    try testing.expect(isSpace('\t'));
    try testing.expect(!isSpace('a'));

    try testing.expect(isAlpha('a'));
    try testing.expect(isAlpha('Z'));
    try testing.expect(!isAlpha('5'));

    try testing.expect(isDigit('5'));
    try testing.expect(!isDigit('a'));

    try testing.expectEqual(@as(u8, 'A'), toUpper('a'));
    try testing.expectEqual(@as(u8, 'a'), toLower('A'));
}

test "isEmpty and end" {
    const testing = std.testing;

    const str: CStr = "test";
    const empty_str: CStr = "";

    try testing.expect(!isEmpty(str));
    try testing.expect(isEmpty(empty_str));

    const str_end = end(str);
    try testing.expectEqual(@as(u8, 0), str_end[0]);
}

test "duplicate C string" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const original: CStr = "Hello";
    const dup = try duplicate(allocator, original);
    defer allocator.free(dup);

    try testing.expect(equals(original, dup.ptr));
    try testing.expectEqualStrings("Hello", dup);
}
