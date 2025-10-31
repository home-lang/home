// Home Programming Language - Basic Math Operations
// Elementary mathematical functions

const std = @import("std");

// Square root
pub fn sqrt(x: anytype) @TypeOf(x) {
    return @sqrt(x);
}

// Power
pub fn pow(comptime T: type, base: T, exponent: T) T {
    return std.math.pow(T, base, exponent);
}

// Absolute value
pub fn abs(x: anytype) @TypeOf(x) {
    const T = @TypeOf(x);
    const info = @typeInfo(T);

    // For unsigned integers, just return the value
    if (info == .int and info.int.signedness == .unsigned) {
        return x;
    }

    // For signed integers, convert to avoid unsigned return type
    if (info == .int and info.int.signedness == .signed) {
        return if (x < 0) -x else x;
    }

    return @abs(x);
}

// Minimum
pub fn min(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return @min(a, b);
}

// Maximum
pub fn max(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return @max(a, b);
}

// Floor
pub fn floor(x: anytype) @TypeOf(x) {
    return @floor(x);
}

// Ceiling
pub fn ceil(x: anytype) @TypeOf(x) {
    return @ceil(x);
}

// Round
pub fn round(x: anytype) @TypeOf(x) {
    return @round(x);
}

// Truncate
pub fn trunc(x: anytype) @TypeOf(x) {
    return @trunc(x);
}

// Modulo (floating point remainder)
pub fn mod(comptime T: type, x: T, y: T) T {
    return @mod(x, y);
}

// Remainder
pub fn rem(comptime T: type, x: T, y: T) T {
    return @rem(x, y);
}

// Clamp value between min and max
pub fn clamp(x: anytype, min_val: @TypeOf(x), max_val: @TypeOf(x)) @TypeOf(x) {
    return @min(@max(x, min_val), max_val);
}

// Linear interpolation
pub fn lerp(comptime T: type, a: T, b: T, t: T) T {
    return a + (b - a) * t;
}

// Sign function (-1, 0, or 1)
pub fn sign(x: anytype) @TypeOf(x) {
    const T = @TypeOf(x);
    if (x > 0) return @as(T, 1);
    if (x < 0) return @as(T, -1);
    return @as(T, 0);
}

// Copy sign from one number to another
pub fn copysign(comptime T: type, mag: T, sgn: T) T {
    return std.math.copysign(mag, sgn);
}

// Fused multiply-add: (x * y) + z
pub fn fma(comptime T: type, x: T, y: T, z: T) T {
    return std.math.fma(T, x, y, z);
}

// Square
pub fn square(x: anytype) @TypeOf(x) {
    return x * x;
}

// Cube
pub fn cube(x: anytype) @TypeOf(x) {
    return x * x * x;
}

// Check if number is NaN
pub fn isNan(x: anytype) bool {
    return std.math.isNan(x);
}

// Check if number is infinite
pub fn isInf(x: anytype) bool {
    return std.math.isInf(x);
}

// Check if number is finite
pub fn isFinite(x: anytype) bool {
    return !isNan(x) and !isInf(x);
}

test "basic sqrt" {
    const testing = std.testing;
    try testing.expectApproxEqAbs(@as(f64, 2.0), sqrt(@as(f64, 4.0)), 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 3.0), sqrt(@as(f64, 9.0)), 0.0001);
}

test "basic pow" {
    const testing = std.testing;
    try testing.expectApproxEqAbs(@as(f64, 8.0), pow(f64, 2.0, 3.0), 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 16.0), pow(f64, 4.0, 2.0), 0.0001);
}

test "basic abs" {
    const testing = std.testing;
    try testing.expectEqual(@as(f64, 5.0), abs(@as(f64, -5.0)));
    try testing.expectEqual(@as(i32, 10), abs(@as(i32, -10)));
}

test "basic min max" {
    const testing = std.testing;
    try testing.expectEqual(@as(i32, 2), min(@as(i32, 2), @as(i32, 5)));
    try testing.expectEqual(@as(i32, 5), max(@as(i32, 2), @as(i32, 5)));
}

test "basic clamp" {
    const testing = std.testing;
    try testing.expectEqual(@as(f64, 5.0), clamp(@as(f64, 3.0), @as(f64, 5.0), @as(f64, 10.0)));
    try testing.expectEqual(@as(f64, 10.0), clamp(@as(f64, 15.0), @as(f64, 5.0), @as(f64, 10.0)));
    try testing.expectEqual(@as(f64, 7.0), clamp(@as(f64, 7.0), @as(f64, 5.0), @as(f64, 10.0)));
}

test "basic lerp" {
    const testing = std.testing;
    try testing.expectApproxEqAbs(@as(f64, 5.0), lerp(f64, 0.0, 10.0, 0.5), 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 2.5), lerp(f64, 0.0, 10.0, 0.25), 0.0001);
}

test "basic sign" {
    const testing = std.testing;
    try testing.expectEqual(@as(f64, 1.0), sign(@as(f64, 5.0)));
    try testing.expectEqual(@as(f64, -1.0), sign(@as(f64, -5.0)));
    try testing.expectEqual(@as(f64, 0.0), sign(@as(f64, 0.0)));
}
