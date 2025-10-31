// Constant-Time Operations
// Operations that take the same time regardless of input values

const std = @import("std");
const timing = @import("timing.zig");

/// Constant-time byte comparison
/// Returns 1 if equal, 0 if not equal
/// Time complexity: O(n) regardless of where mismatch occurs
pub fn compareBytes(a: []const u8, b: []const u8) u8 {
    if (a.len != b.len) return 0;

    var diff: u8 = 0;
    for (a, b) |byte_a, byte_b| {
        diff |= byte_a ^ byte_b;
    }

    // diff is 0 if equal, non-zero if different
    // Convert to 1 or 0 in constant time
    return @intFromBool(diff == 0);
}

/// Constant-time equality check for fixed-size arrays
pub fn equal(comptime T: type, a: T, b: T) bool {
    const bytes_a = std.mem.asBytes(&a);
    const bytes_b = std.mem.asBytes(&b);
    return compareBytes(bytes_a, bytes_b) == 1;
}

/// Constant-time conditional select
/// Returns a if condition is true (1), b if false (0)
/// WARNING: condition must be 0 or 1 only
pub fn select(comptime T: type, condition: u1, a: T, b: T) T {
    const Info = @typeInfo(T);

    return switch (Info) {
        .Int => blk: {
            // Use bitwise operations for integers
            const mask = @as(T, condition) *% std.math.maxInt(T);
            break :blk (a & mask) | (b & ~mask);
        },
        else => if (condition == 1) a else b,
    };
}

/// Constant-time conditional copy
/// Copies src to dst if condition is 1, otherwise leaves dst unchanged
pub fn conditionalCopy(dst: []u8, src: []const u8, condition: u1) void {
    std.debug.assert(dst.len == src.len);

    // Create mask: all 1s if condition=1, all 0s if condition=0
    const mask = @as(u8, condition) *% 0xFF;

    for (dst, src) |*d, s| {
        // If condition=1: d = (d & 0) | (s & 0xFF) = s
        // If condition=0: d = (d & 0xFF) | (s & 0) = d
        d.* = (d.* & ~mask) | (s & mask);
    }
}

/// Constant-time less than comparison
/// Returns 1 if a < b, 0 otherwise
pub fn lessThan(comptime T: type, a: T, b: T) u1 {
    const Info = @typeInfo(T);
    if (Info != .Int) @compileError("lessThan only works with integers");

    // XOR to find differing bits
    const diff = a ^ b;

    // Find most significant differing bit
    var result: u1 = 0;
    var mask: T = @as(T, 1) << (@bitSizeOf(T) - 1);

    while (mask != 0) {
        const bit_a = (a & mask) != 0;
        const bit_b = (b & mask) != 0;
        const bits_differ = (diff & mask) != 0;

        // If this is the first differing bit, a < b iff bit_a is 0 and bit_b is 1
        if (bits_differ) {
            result = @intFromBool(!bit_a and bit_b);
            break;
        }

        mask >>= 1;
    }

    return result;
}

/// Constant-time maximum
pub fn max(comptime T: type, a: T, b: T) T {
    const a_less = lessThan(T, a, b);
    return select(T, 1 - a_less, a, b);
}

/// Constant-time minimum
pub fn min(comptime T: type, a: T, b: T) T {
    const a_less = lessThan(T, a, b);
    return select(T, a_less, a, b);
}

/// Constant-time zero check
/// Returns 1 if value is zero, 0 otherwise
pub fn isZero(comptime T: type, value: T) u1 {
    const Info = @typeInfo(T);
    if (Info != .Int) @compileError("isZero only works with integers");

    // If value is 0, all bits are 0
    // If value is non-zero, at least one bit is 1
    var result = value;
    var i: usize = 1;
    while (i < @bitSizeOf(T)) : (i *= 2) {
        result |= result >> @intCast(i);
    }

    // Now result has all bits set if value was non-zero
    // Return 1 if zero, 0 if non-zero
    return @intFromBool(result == 0);
}

/// Constant-time absolute value
pub fn abs(comptime T: type, value: T) T {
    const Info = @typeInfo(T);
    if (Info != .Int or Info.Int.signedness != .signed) {
        @compileError("abs only works with signed integers");
    }

    // Extract sign bit (1 if negative, 0 if positive)
    const sign = @as(T, @bitCast(@as(std.meta.Int(.unsigned, @bitSizeOf(T)), @bitCast(value)))) >> (@bitSizeOf(T) - 1);

    // If negative: flip bits and add 1 (two's complement negation)
    // If positive: leave unchanged
    const mask = -sign; // All 1s if negative, all 0s if positive
    return (value ^ mask) -% mask;
}

/// Constant-time string comparison for passwords/tokens
pub fn secureCompare(a: []const u8, b: []const u8) bool {
    return compareBytes(a, b) == 1;
}

/// Constant-time password hash comparison
/// Always compares full length even if mismatch found early
pub fn verifyHash(hash: []const u8, expected: []const u8) bool {
    // Ensure same length
    if (hash.len != expected.len) return false;

    // Compare in constant time
    return secureCompare(hash, expected);
}

/// Zero memory securely (prevents compiler optimization)
pub fn secureZero(buffer: []u8) void {
    // Use volatile to prevent compiler from optimizing away the memset
    @memset(buffer, 0);
    timing.compilerBarrier();
}

test "constant-time byte comparison" {
    const testing = std.testing;

    const a = "hello";
    const b = "hello";
    const c = "world";

    try testing.expectEqual(@as(u8, 1), compareBytes(a, b));
    try testing.expectEqual(@as(u8, 0), compareBytes(a, c));
    try testing.expectEqual(@as(u8, 0), compareBytes(a, "hi")); // Different length
}

test "constant-time equality" {
    const testing = std.testing;

    const a: [32]u8 = [_]u8{0x01} ++ [_]u8{0} ** 31;
    const b: [32]u8 = [_]u8{0x01} ++ [_]u8{0} ** 31;
    const c: [32]u8 = [_]u8{0x02} ++ [_]u8{0} ** 31;

    try testing.expect(equal([32]u8, a, b));
    try testing.expect(!equal([32]u8, a, c));
}

test "constant-time select" {
    const testing = std.testing;

    try testing.expectEqual(@as(u32, 42), select(u32, 1, 42, 99));
    try testing.expectEqual(@as(u32, 99), select(u32, 0, 42, 99));
}

test "constant-time conditional copy" {
    const testing = std.testing;

    var dst = [_]u8{ 1, 2, 3, 4 };
    const src = [_]u8{ 5, 6, 7, 8 };

    // Copy with condition=1
    conditionalCopy(&dst, &src, 1);
    try testing.expectEqualSlices(u8, &[_]u8{ 5, 6, 7, 8 }, &dst);

    // Don't copy with condition=0
    conditionalCopy(&dst, &[_]u8{ 9, 10, 11, 12 }, 0);
    try testing.expectEqualSlices(u8, &[_]u8{ 5, 6, 7, 8 }, &dst);
}

test "constant-time less than" {
    const testing = std.testing;

    try testing.expectEqual(@as(u1, 1), lessThan(u32, 10, 20));
    try testing.expectEqual(@as(u1, 0), lessThan(u32, 20, 10));
    try testing.expectEqual(@as(u1, 0), lessThan(u32, 15, 15));
}

test "constant-time min/max" {
    const testing = std.testing;

    try testing.expectEqual(@as(u32, 10), min(u32, 10, 20));
    try testing.expectEqual(@as(u32, 10), min(u32, 20, 10));

    try testing.expectEqual(@as(u32, 20), max(u32, 10, 20));
    try testing.expectEqual(@as(u32, 20), max(u32, 20, 10));
}

test "constant-time zero check" {
    const testing = std.testing;

    try testing.expectEqual(@as(u1, 1), isZero(u32, 0));
    try testing.expectEqual(@as(u1, 0), isZero(u32, 1));
    try testing.expectEqual(@as(u1, 0), isZero(u32, 0xFFFFFFFF));
}

test "constant-time absolute value" {
    const testing = std.testing;

    try testing.expectEqual(@as(i32, 42), abs(i32, 42));
    try testing.expectEqual(@as(i32, 42), abs(i32, -42));
    try testing.expectEqual(@as(i32, 0), abs(i32, 0));
}

test "secure compare" {
    const testing = std.testing;

    const password = "secret123";
    const correct = "secret123";
    const wrong = "secret124";

    try testing.expect(secureCompare(password, correct));
    try testing.expect(!secureCompare(password, wrong));
}

test "secure zero" {
    const testing = std.testing;

    var buffer = [_]u8{ 1, 2, 3, 4, 5 };
    secureZero(&buffer);

    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 0 }, &buffer);
}
