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

// Advanced SIMD operations
pub const AdvancedOps = struct {
    /// Horizontal sum with explicit reduction
    pub fn horizontalSum(comptime len: comptime_int, comptime T: type, vec: Vector(len, T)) T {
        var result = vec[0];
        comptime var i = 1;
        inline while (i < len) : (i += 1) {
            result += vec[i];
        }
        return result;
    }

    /// Matrix-vector multiply (4x4 matrix * 4-element vector)
    pub fn matrixVectorMul4(matrix: [4]Vec4f32, vec: Vec4f32) Vec4f32 {
        const row0 = Operations.dot(4, f32, matrix[0], vec);
        const row1 = Operations.dot(4, f32, matrix[1], vec);
        const row2 = Operations.dot(4, f32, matrix[2], vec);
        const row3 = Operations.dot(4, f32, matrix[3], vec);
        return Vec4f32{ row0, row1, row2, row3 };
    }

    /// Cross product for 3D vectors (stored in Vec4 with w=0)
    pub fn cross3(a: Vec4f32, b: Vec4f32) Vec4f32 {
        return Vec4f32{
            a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0],
            0.0,
        };
    }

    /// Linear interpolation
    pub fn lerp(comptime len: comptime_int, a: Vector(len, f32), b: Vector(len, f32), t: f32) Vector(len, f32) {
        const t_vec = Operations.splat(len, f32, t);
        const one_minus_t = Operations.splat(len, f32, 1.0 - t);
        return a * one_minus_t + b * t_vec;
    }

    /// Clamp vector values between min and max
    pub fn clamp(comptime len: comptime_int, comptime T: type, vec: Vector(len, T), min_val: T, max_val: T) Vector(len, T) {
        const min_vec = Operations.splat(len, T, min_val);
        const max_vec = Operations.splat(len, T, max_val);
        return Operations.min(len, T, Operations.max(len, T, vec, min_vec), max_vec);
    }

    /// Sum of absolute differences
    pub fn sad(comptime len: comptime_int, a: Vector(len, i32), b: Vector(len, i32)) i32 {
        const diff = a - b;
        const abs_diff = Operations.abs(len, i32, diff);
        return Operations.reduce(len, i32, abs_diff);
    }

    /// Population count (count set bits) for each element
    pub fn popcount(comptime len: comptime_int, vec: Vector(len, u32)) Vector(len, u32) {
        var result: Vector(len, u32) = undefined;
        inline for (0..len) |i| {
            result[i] = @popCount(vec[i]);
        }
        return result;
    }

    /// Reverse bits in each element
    pub fn bitReverse(comptime len: comptime_int, vec: Vector(len, u32)) Vector(len, u32) {
        var result: Vector(len, u32) = undefined;
        inline for (0..len) |i| {
            result[i] = @bitReverse(vec[i]);
        }
        return result;
    }

    /// Count leading zeros for each element
    pub fn clz(comptime len: comptime_int, vec: Vector(len, u32)) Vector(len, u32) {
        var result: Vector(len, u32) = undefined;
        inline for (0..len) |i| {
            result[i] = @clz(vec[i]);
        }
        return result;
    }

    /// Count trailing zeros for each element
    pub fn ctz(comptime len: comptime_int, vec: Vector(len, u32)) Vector(len, u32) {
        var result: Vector(len, u32) = undefined;
        inline for (0..len) |i| {
            result[i] = @ctz(vec[i]);
        }
        return result;
    }

    /// Byte swap for endian conversion
    pub fn byteSwap(comptime len: comptime_int, vec: Vector(len, u32)) Vector(len, u32) {
        var result: Vector(len, u32) = undefined;
        inline for (0..len) |i| {
            result[i] = @byteSwap(vec[i]);
        }
        return result;
    }

    /// Saturating add
    pub fn addSaturate(comptime len: comptime_int, a: Vector(len, u8), b: Vector(len, u8)) Vector(len, u8) {
        var result: Vector(len, u8) = undefined;
        inline for (0..len) |i| {
            const sum: u16 = @as(u16, a[i]) + @as(u16, b[i]);
            result[i] = if (sum > 255) 255 else @truncate(sum);
        }
        return result;
    }

    /// Saturating subtract
    pub fn subSaturate(comptime len: comptime_int, a: Vector(len, u8), b: Vector(len, u8)) Vector(len, u8) {
        var result: Vector(len, u8) = undefined;
        inline for (0..len) |i| {
            result[i] = if (a[i] > b[i]) a[i] - b[i] else 0;
        }
        return result;
    }

    /// Average (a + b + 1) / 2
    pub fn average(comptime len: comptime_int, a: Vector(len, u8), b: Vector(len, u8)) Vector(len, u8) {
        var result: Vector(len, u8) = undefined;
        inline for (0..len) |i| {
            result[i] = @truncate((@as(u16, a[i]) + @as(u16, b[i]) + 1) / 2);
        }
        return result;
    }
};

test "advanced horizontal sum" {
    const testing = std.testing;

    const vec = Vec4i32{ 1, 2, 3, 4 };
    const sum = AdvancedOps.horizontalSum(4, i32, vec);

    try testing.expectEqual(@as(i32, 10), sum);
}

test "cross product" {
    const testing = std.testing;

    const a = Vec4f32{ 1.0, 0.0, 0.0, 0.0 };
    const b = Vec4f32{ 0.0, 1.0, 0.0, 0.0 };
    const result = AdvancedOps.cross3(a, b);

    try testing.expectEqual(@as(f32, 0.0), result[0]);
    try testing.expectEqual(@as(f32, 0.0), result[1]);
    try testing.expectEqual(@as(f32, 1.0), result[2]);
}

test "vector clamp" {
    const testing = std.testing;

    const vec = Vec4f32{ -1.0, 0.5, 1.5, 2.0 };
    const result = AdvancedOps.clamp(4, f32, vec, 0.0, 1.0);

    try testing.expectEqual(@as(f32, 0.0), result[0]);
    try testing.expectEqual(@as(f32, 0.5), result[1]);
    try testing.expectEqual(@as(f32, 1.0), result[2]);
    try testing.expectEqual(@as(f32, 1.0), result[3]);
}

test "saturating operations" {
    const testing = std.testing;

    const a = @Vector(4, u8){ 250, 100, 50, 10 };
    const b = @Vector(4, u8){ 10, 50, 100, 250 };

    const add_result = AdvancedOps.addSaturate(4, a, b);
    try testing.expectEqual(@as(u8, 255), add_result[0]); // 250+10 saturates to 255
    try testing.expectEqual(@as(u8, 150), add_result[1]);

    const sub_result = AdvancedOps.subSaturate(4, a, b);
    try testing.expectEqual(@as(u8, 240), sub_result[0]); // 250-10
    try testing.expectEqual(@as(u8, 0), sub_result[3]); // 10-250 saturates to 0
}
