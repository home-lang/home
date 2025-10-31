// Home Programming Language - Bit Manipulation Intrinsics
// Fast bit operations and population count

const std = @import("std");

// Count leading zeros
pub fn countLeadingZeros(comptime T: type, value: T) T {
    return @clz(value);
}

// Count trailing zeros
pub fn countTrailingZeros(comptime T: type, value: T) T {
    return @ctz(value);
}

// Population count (number of set bits)
pub fn popCount(comptime T: type, value: T) T {
    return @popCount(value);
}

// Byte swap
pub fn byteSwap(comptime T: type, value: T) T {
    return @byteSwap(value);
}

// Bit reverse
pub fn bitReverse(comptime T: type, value: T) T {
    return @bitReverse(value);
}

// Find first set bit (1-indexed, 0 if no bits set)
pub fn findFirstSet(comptime T: type, value: T) T {
    if (value == 0) return 0;
    return @ctz(value) + 1;
}

// Find last set bit (1-indexed, 0 if no bits set)
pub fn findLastSet(comptime T: type, value: T) T {
    if (value == 0) return 0;
    const bit_width = @typeInfo(T).int.bits;
    return bit_width - @clz(value);
}

// Check if value is power of two
pub fn isPowerOfTwo(comptime T: type, value: T) bool {
    return value > 0 and (value & (value - 1)) == 0;
}

// Round up to next power of two
pub fn nextPowerOfTwo(comptime T: type, value: T) T {
    if (value == 0) return 1;
    if (value == 1) return 1;
    const bit_width: usize = @typeInfo(T).int.bits;
    var v = value - 1;
    var shift: usize = 1;
    while (shift < bit_width) {
        v |= v >> @intCast(shift);
        shift <<= 1;
    }
    return v + 1;
}

// Rotate left
pub fn rotateLeft(comptime T: type, value: T, shift: T) T {
    const bit_width: usize = @typeInfo(T).int.bits;
    const s: T = shift & @as(T, @intCast(bit_width - 1));
    return (value << @intCast(s)) | (value >> @intCast(bit_width - s));
}

// Rotate right
pub fn rotateRight(comptime T: type, value: T, shift: T) T {
    const bit_width: usize = @typeInfo(T).int.bits;
    const s: T = shift & @as(T, @intCast(bit_width - 1));
    return (value >> @intCast(s)) | (value << @intCast(bit_width - s));
}

// Extract bit field
pub fn extractBits(comptime T: type, value: T, pos: T, width: T) T {
    const mask = (@as(T, 1) << @intCast(width)) - 1;
    return (value >> @intCast(pos)) & mask;
}

// Insert bit field
pub fn insertBits(comptime T: type, dest: T, src: T, pos: T, width: T) T {
    const mask = (@as(T, 1) << @intCast(width)) - 1;
    return (dest & ~(mask << @intCast(pos))) | ((src & mask) << @intCast(pos));
}

// Parity (even = 0, odd = 1)
pub fn parity(comptime T: type, value: T) T {
    return @popCount(value) & 1;
}

test "count leading zeros" {
    const testing = std.testing;
    try testing.expectEqual(@as(u32, 31), countLeadingZeros(u32, 1));
    try testing.expectEqual(@as(u32, 0), countLeadingZeros(u32, 0x80000000));
}

test "count trailing zeros" {
    const testing = std.testing;
    try testing.expectEqual(@as(u32, 0), countTrailingZeros(u32, 1));
    try testing.expectEqual(@as(u32, 3), countTrailingZeros(u32, 8));
}

test "population count" {
    const testing = std.testing;
    try testing.expectEqual(@as(u32, 0), popCount(u32, 0));
    try testing.expectEqual(@as(u32, 1), popCount(u32, 1));
    try testing.expectEqual(@as(u32, 8), popCount(u32, 0xFF));
}

test "byte swap" {
    const testing = std.testing;
    try testing.expectEqual(@as(u32, 0x78563412), byteSwap(u32, 0x12345678));
}

test "find first set" {
    const testing = std.testing;
    try testing.expectEqual(@as(u32, 1), findFirstSet(u32, 1));
    try testing.expectEqual(@as(u32, 4), findFirstSet(u32, 8));
    try testing.expectEqual(@as(u32, 0), findFirstSet(u32, 0));
}

test "is power of two" {
    const testing = std.testing;
    try testing.expect(isPowerOfTwo(u32, 1));
    try testing.expect(isPowerOfTwo(u32, 2));
    try testing.expect(isPowerOfTwo(u32, 64));
    try testing.expect(!isPowerOfTwo(u32, 3));
    try testing.expect(!isPowerOfTwo(u32, 0));
}

test "next power of two" {
    const testing = std.testing;
    try testing.expectEqual(@as(u32, 1), nextPowerOfTwo(u32, 0));
    try testing.expectEqual(@as(u32, 1), nextPowerOfTwo(u32, 1));
    try testing.expectEqual(@as(u32, 2), nextPowerOfTwo(u32, 2));
    try testing.expectEqual(@as(u32, 4), nextPowerOfTwo(u32, 3));
    try testing.expectEqual(@as(u32, 64), nextPowerOfTwo(u32, 63));
}

test "rotate operations" {
    const testing = std.testing;
    try testing.expectEqual(@as(u8, 0x02), rotateLeft(u8, 0x01, 1));
    try testing.expectEqual(@as(u8, 0x80), rotateRight(u8, 0x01, 1));
}

test "bit field operations" {
    const testing = std.testing;
    // Extract bits 4-7 from 0x12345678: bits are 0111 = 0x7
    try testing.expectEqual(@as(u32, 0x7), extractBits(u32, 0x12345678, 4, 4));
    // Insert 0x0A into bits 4-7: 0x12345678 -> 0x123456A8
    try testing.expectEqual(@as(u32, 0x123456A8), insertBits(u32, 0x12345678, 0x0A, 4, 4));
}

test "parity" {
    const testing = std.testing;
    try testing.expectEqual(@as(u32, 0), parity(u32, 0));
    try testing.expectEqual(@as(u32, 1), parity(u32, 1));
    try testing.expectEqual(@as(u32, 0), parity(u32, 3));
    try testing.expectEqual(@as(u32, 1), parity(u32, 7));
}
