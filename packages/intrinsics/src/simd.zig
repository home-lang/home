// Home Programming Language - SIMD Intrinsics
// Vector operations for x86 and ARM architectures

const std = @import("std");
const builtin = @import("builtin");

// Vector type wrapper
pub fn Vector(comptime len: comptime_int, comptime T: type) type {
    return @Vector(len, T);
}

// SIMD operations
pub const Operations = struct {
    // Vector addition
    pub fn add(comptime len: comptime_int, comptime T: type, a: Vector(len, T), b: Vector(len, T)) Vector(len, T) {
        return a + b;
    }

    // Vector subtraction
    pub fn sub(comptime len: comptime_int, comptime T: type, a: Vector(len, T), b: Vector(len, T)) Vector(len, T) {
        return a - b;
    }

    // Vector multiplication
    pub fn mul(comptime len: comptime_int, comptime T: type, a: Vector(len, T), b: Vector(len, T)) Vector(len, T) {
        return a * b;
    }

    // Vector division
    pub fn div(comptime len: comptime_int, comptime T: type, a: Vector(len, T), b: Vector(len, T)) Vector(len, T) {
        return a / b;
    }

    // Vector negation
    pub fn neg(comptime len: comptime_int, comptime T: type, a: Vector(len, T)) Vector(len, T) {
        return -a;
    }

    // Vector minimum
    pub fn min(comptime len: comptime_int, comptime T: type, a: Vector(len, T), b: Vector(len, T)) Vector(len, T) {
        return @min(a, b);
    }

    // Vector maximum
    pub fn max(comptime len: comptime_int, comptime T: type, a: Vector(len, T), b: Vector(len, T)) Vector(len, T) {
        return @max(a, b);
    }

    // Vector absolute value
    pub fn abs(comptime len: comptime_int, comptime T: type, a: Vector(len, T)) Vector(len, T) {
        return @abs(a);
    }

    // Vector floor
    pub fn floor(comptime len: comptime_int, a: Vector(len, f32)) Vector(len, f32) {
        return @floor(a);
    }

    // Vector ceiling
    pub fn ceil(comptime len: comptime_int, a: Vector(len, f32)) Vector(len, f32) {
        return @ceil(a);
    }

    // Vector round
    pub fn round(comptime len: comptime_int, a: Vector(len, f32)) Vector(len, f32) {
        return @round(a);
    }

    // Vector truncate
    pub fn trunc(comptime len: comptime_int, a: Vector(len, f32)) Vector(len, f32) {
        return @trunc(a);
    }

    // Vector square root
    pub fn sqrt(comptime len: comptime_int, a: Vector(len, f32)) Vector(len, f32) {
        return @sqrt(a);
    }

    // Horizontal sum (reduce)
    pub fn reduce(comptime len: comptime_int, comptime T: type, vec: Vector(len, T)) T {
        return @reduce(.Add, vec);
    }

    // Horizontal min
    pub fn reduceMin(comptime len: comptime_int, comptime T: type, vec: Vector(len, T)) T {
        return @reduce(.Min, vec);
    }

    // Horizontal max
    pub fn reduceMax(comptime len: comptime_int, comptime T: type, vec: Vector(len, T)) T {
        return @reduce(.Max, vec);
    }

    // Dot product
    pub fn dot(comptime len: comptime_int, comptime T: type, a: Vector(len, T), b: Vector(len, T)) T {
        return @reduce(.Add, a * b);
    }

    // Fused multiply-add: a * b + c
    pub fn fma(comptime len: comptime_int, a: Vector(len, f32), b: Vector(len, f32), c: Vector(len, f32)) Vector(len, f32) {
        return @mulAdd(Vector(len, f32), a, b, c);
    }

    // Shuffle/permute vector
    pub fn shuffle(
        comptime len: comptime_int,
        comptime T: type,
        a: Vector(len, T),
        b: Vector(len, T),
        mask: Vector(len, i32),
    ) Vector(len, T) {
        return @shuffle(T, a, b, mask);
    }

    // Splat scalar to all lanes
    pub fn splat(comptime len: comptime_int, comptime T: type, value: T) Vector(len, T) {
        return @splat(value);
    }

    // Select elements based on mask
    pub fn select(
        comptime len: comptime_int,
        comptime T: type,
        mask: Vector(len, bool),
        a: Vector(len, T),
        b: Vector(len, T),
    ) Vector(len, T) {
        return @select(T, mask, a, b);
    }
};

// Common vector sizes
pub const Vec2f32 = Vector(2, f32);
pub const Vec4f32 = Vector(4, f32);
pub const Vec8f32 = Vector(8, f32);
pub const Vec16f32 = Vector(16, f32);

pub const Vec2f64 = Vector(2, f64);
pub const Vec4f64 = Vector(4, f64);

pub const Vec4i32 = Vector(4, i32);
pub const Vec8i32 = Vector(8, i32);
pub const Vec16i32 = Vector(16, i32);

pub const Vec4u32 = Vector(4, u32);
pub const Vec8u32 = Vector(8, u32);
pub const Vec16u32 = Vector(16, u32);

// Helper functions for common operations
pub fn vec4Add(a: Vec4f32, b: Vec4f32) Vec4f32 {
    return Operations.add(4, f32, a, b);
}

pub fn vec4Sub(a: Vec4f32, b: Vec4f32) Vec4f32 {
    return Operations.sub(4, f32, a, b);
}

pub fn vec4Mul(a: Vec4f32, b: Vec4f32) Vec4f32 {
    return Operations.mul(4, f32, a, b);
}

pub fn vec4Div(a: Vec4f32, b: Vec4f32) Vec4f32 {
    return Operations.div(4, f32, a, b);
}

pub fn vec4Dot(a: Vec4f32, b: Vec4f32) f32 {
    return Operations.dot(4, f32, a, b);
}

pub fn vec4Length(a: Vec4f32) f32 {
    return @sqrt(Operations.dot(4, f32, a, a));
}

pub fn vec4Normalize(a: Vec4f32) Vec4f32 {
    const len = vec4Length(a);
    const splat_len = Operations.splat(4, f32, len);
    return a / splat_len;
}

test "vector addition" {
    const testing = std.testing;

    const a = Vec4f32{ 1.0, 2.0, 3.0, 4.0 };
    const b = Vec4f32{ 5.0, 6.0, 7.0, 8.0 };
    const result = vec4Add(a, b);

    try testing.expectEqual(@as(f32, 6.0), result[0]);
    try testing.expectEqual(@as(f32, 8.0), result[1]);
    try testing.expectEqual(@as(f32, 10.0), result[2]);
    try testing.expectEqual(@as(f32, 12.0), result[3]);
}

test "vector multiplication" {
    const testing = std.testing;

    const a = Vec4f32{ 2.0, 3.0, 4.0, 5.0 };
    const b = Vec4f32{ 1.0, 2.0, 3.0, 4.0 };
    const result = vec4Mul(a, b);

    try testing.expectEqual(@as(f32, 2.0), result[0]);
    try testing.expectEqual(@as(f32, 6.0), result[1]);
    try testing.expectEqual(@as(f32, 12.0), result[2]);
    try testing.expectEqual(@as(f32, 20.0), result[3]);
}

test "dot product" {
    const testing = std.testing;

    const a = Vec4f32{ 1.0, 2.0, 3.0, 4.0 };
    const b = Vec4f32{ 5.0, 6.0, 7.0, 8.0 };
    const result = vec4Dot(a, b);

    // 1*5 + 2*6 + 3*7 + 4*8 = 5 + 12 + 21 + 32 = 70
    try testing.expectEqual(@as(f32, 70.0), result);
}

test "vector reduce" {
    const testing = std.testing;

    const a = Vec4i32{ 1, 2, 3, 4 };
    const sum = Operations.reduce(4, i32, a);

    try testing.expectEqual(@as(i32, 10), sum);
}

test "vector min/max" {
    const testing = std.testing;

    const a = Vec4i32{ 1, 5, 3, 7 };
    const b = Vec4i32{ 2, 4, 6, 1 };

    const min_result = Operations.min(4, i32, a, b);
    const max_result = Operations.max(4, i32, a, b);

    try testing.expectEqual(@as(i32, 1), min_result[0]);
    try testing.expectEqual(@as(i32, 4), min_result[1]);
    try testing.expectEqual(@as(i32, 3), min_result[2]);
    try testing.expectEqual(@as(i32, 1), min_result[3]);

    try testing.expectEqual(@as(i32, 2), max_result[0]);
    try testing.expectEqual(@as(i32, 5), max_result[1]);
    try testing.expectEqual(@as(i32, 6), max_result[2]);
    try testing.expectEqual(@as(i32, 7), max_result[3]);
}

test "vector splat" {
    const testing = std.testing;

    const result = Operations.splat(4, f32, 42.0);

    try testing.expectEqual(@as(f32, 42.0), result[0]);
    try testing.expectEqual(@as(f32, 42.0), result[1]);
    try testing.expectEqual(@as(f32, 42.0), result[2]);
    try testing.expectEqual(@as(f32, 42.0), result[3]);
}

test "fused multiply-add" {
    const testing = std.testing;

    const a = Vec4f32{ 2.0, 3.0, 4.0, 5.0 };
    const b = Vec4f32{ 1.0, 2.0, 3.0, 4.0 };
    const c = Vec4f32{ 1.0, 1.0, 1.0, 1.0 };
    const result = Operations.fma(4, a, b, c);

    // a * b + c = {2*1+1, 3*2+1, 4*3+1, 5*4+1} = {3, 7, 13, 21}
    try testing.expectEqual(@as(f32, 3.0), result[0]);
    try testing.expectEqual(@as(f32, 7.0), result[1]);
    try testing.expectEqual(@as(f32, 13.0), result[2]);
    try testing.expectEqual(@as(f32, 21.0), result[3]);
}
