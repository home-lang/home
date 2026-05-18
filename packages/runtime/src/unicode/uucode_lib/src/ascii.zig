// Copied verbatim from bun/src/unicode/uucode_lib/src/ascii.zig at upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.

/// Returns whether the code point is alphanumeric: A-Z, a-z, or 0-9.
pub fn isAlphanumeric(c: u21) bool {
    return switch (c) {
        '0'...'9', 'A'...'Z', 'a'...'z' => true,
        else => false,
    };
}

/// Returns whether the code point is alphabetic: A-Z or a-z.
pub fn isAlphabetic(c: u21) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z' => true,
        else => false,
    };
}

/// Returns whether the code point is a control character.
///
/// See also: `control_code`
pub fn isControl(c: u21) bool {
    return c <= std.ascii.control_code.us or c == std.ascii.control_code.del;
}

/// Returns whether the code point is a digit.
pub fn isDigit(c: u21) bool {
    return switch (c) {
        '0'...'9' => true,
        else => false,
    };
}

/// Returns whether the code point is a lowercase letter.
pub fn isLower(c: u21) bool {
    return switch (c) {
        'a'...'z' => true,
        else => false,
    };
}

/// Returns whether the code point is printable and has some graphical representation,
/// including the space code point.
pub fn isPrint(c: u21) bool {
    return isAscii(c) and !isControl(c);
}

/// Returns whether this code point is included in `whitespace`.
pub fn isWhitespace(c: u21) bool {
    return switch (c) {
        ' ', '\t'...'\r' => true,
        else => false,
    };
}

/// Returns whether the code point is an uppercase letter.
pub fn isUpper(c: u21) bool {
    return switch (c) {
        'A'...'Z' => true,
        else => false,
    };
}

/// Returns whether the code point is a hexadecimal digit: A-F, a-f, or 0-9.
pub fn isHex(c: u21) bool {
    return switch (c) {
        '0'...'9', 'A'...'F', 'a'...'f' => true,
        else => false,
    };
}

/// Returns whether the code point is a 7-bit ASCII character.
pub fn isAscii(c: u21) bool {
    return c < 128;
}

/// Uppercases the code point and returns it as-is if already uppercase or not a letter.
pub fn toUpper(c: u21) u21 {
    const mask = @as(u21, @intFromBool(isLower(c))) << 5;
    return c ^ mask;
}

/// Lowercases the code point and returns it as-is if already lowercase or not a letter.
pub fn toLower(c: u21) u21 {
    const mask = @as(u21, @intFromBool(isUpper(c))) << 5;
    return c | mask;
}

const std = @import("std");

test "ascii.isAlphanumeric / isAlphabetic / isDigit" {
    try std.testing.expect(isAlphanumeric('A'));
    try std.testing.expect(isAlphanumeric('z'));
    try std.testing.expect(isAlphanumeric('0'));
    try std.testing.expect(!isAlphanumeric(' '));
    try std.testing.expect(!isAlphanumeric(0x80));

    try std.testing.expect(isAlphabetic('A'));
    try std.testing.expect(isAlphabetic('z'));
    try std.testing.expect(!isAlphabetic('0'));

    try std.testing.expect(isDigit('0'));
    try std.testing.expect(isDigit('9'));
    try std.testing.expect(!isDigit('a'));
}

test "ascii.toUpper / toLower are pure case flips" {
    try std.testing.expectEqual(@as(u21, 'A'), toUpper('a'));
    try std.testing.expectEqual(@as(u21, 'Z'), toUpper('z'));
    try std.testing.expectEqual(@as(u21, 'A'), toUpper('A'));
    try std.testing.expectEqual(@as(u21, '7'), toUpper('7'));

    try std.testing.expectEqual(@as(u21, 'a'), toLower('A'));
    try std.testing.expectEqual(@as(u21, 'z'), toLower('Z'));
    try std.testing.expectEqual(@as(u21, 'a'), toLower('a'));
    try std.testing.expectEqual(@as(u21, '7'), toLower('7'));
}

test "ascii.isHex covers both cases and digits" {
    try std.testing.expect(isHex('0'));
    try std.testing.expect(isHex('9'));
    try std.testing.expect(isHex('a'));
    try std.testing.expect(isHex('F'));
    try std.testing.expect(!isHex('g'));
    try std.testing.expect(!isHex('G'));
}

test "ascii.isControl / isPrint / isWhitespace" {
    try std.testing.expect(isControl(0));
    try std.testing.expect(isControl(0x1F));
    try std.testing.expect(isControl(0x7F));
    try std.testing.expect(!isControl(' '));

    try std.testing.expect(isPrint(' '));
    try std.testing.expect(isPrint('a'));
    try std.testing.expect(!isPrint(0x7F));
    try std.testing.expect(!isPrint(0x100));

    try std.testing.expect(isWhitespace(' '));
    try std.testing.expect(isWhitespace('\t'));
    try std.testing.expect(isWhitespace('\n'));
    try std.testing.expect(!isWhitespace('A'));
}
