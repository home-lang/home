// Home Programming Language - SIMD Math Operations
// SIMD-accelerated mathematical functions

const std = @import("std");
const basic = @import("basic.zig");
const transcendental = @import("transcendental.zig");

// Vector type alias
pub fn Vec(comptime len: comptime_int, comptime T: type) type {
    return @Vector(len, T);
}

// Element-wise operations
pub const ElementWise = struct {
    pub fn sqrt(comptime len: comptime_int, comptime T: type, v: Vec(len, T)) Vec(len, T) {
        return @sqrt(v);
    }

    pub fn abs(comptime len: comptime_int, comptime T: type, v: Vec(len, T)) Vec(len, T) {
        return @abs(v);
    }

    pub fn floor(comptime len: comptime_int, comptime T: type, v: Vec(len, T)) Vec(len, T) {
        return @floor(v);
    }

    pub fn ceil(comptime len: comptime_int, comptime T: type, v: Vec(len, T)) Vec(len, T) {
        return @ceil(v);
    }

    pub fn round(comptime len: comptime_int, comptime T: type, v: Vec(len, T)) Vec(len, T) {
        return @round(v);
    }

    pub fn sin(comptime len: comptime_int, comptime T: type, v: Vec(len, T)) Vec(len, T) {
        return @sin(v);
    }

    pub fn cos(comptime len: comptime_int, comptime T: type, v: Vec(len, T)) Vec(len, T) {
        return @cos(v);
    }

    pub fn exp(comptime len: comptime_int, comptime T: type, v: Vec(len, T)) Vec(len, T) {
        return @exp(v);
    }

    pub fn log(comptime len: comptime_int, comptime T: type, v: Vec(len, T)) Vec(len, T) {
        return @log(v);
    }

    pub fn min(comptime len: comptime_int, comptime T: type, a: Vec(len, T), b: Vec(len, T)) Vec(len, T) {
        return @min(a, b);
    }

    pub fn max(comptime len: comptime_int, comptime T: type, a: Vec(len, T), b: Vec(len, T)) Vec(len, T) {
        return @max(a, b);
    }
};

// Reductions
pub const Reduce = struct {
    pub fn sum(comptime len: comptime_int, comptime T: type, v: Vec(len, T)) T {
        return @reduce(.Add, v);
    }

    pub fn product(comptime len: comptime_int, comptime T: type, v: Vec(len, T)) T {
        return @reduce(.Mul, v);
    }

    pub fn min(comptime len: comptime_int, comptime T: type, v: Vec(len, T)) T {
        return @reduce(.Min, v);
    }

    pub fn max(comptime len: comptime_int, comptime T: type, v: Vec(len, T)) T {
        return @reduce(.Max, v);
    }

    pub fn and_(comptime len: comptime_int, comptime T: type, v: Vec(len, T)) T {
        return @reduce(.And, v);
    }

    pub fn or_(comptime len: comptime_int, comptime T: type, v: Vec(len, T)) T {
        return @reduce(.Or, v);
    }

    pub fn xor(comptime len: comptime_int, comptime T: type, v: Vec(len, T)) T {
        return @reduce(.Xor, v);
    }
};

// Horizontal operations
pub const Horizontal = struct {
    pub fn dot(comptime len: comptime_int, comptime T: type, a: Vec(len, T), b: Vec(len, T)) T {
        return @reduce(.Add, a * b);
    }

    pub fn sumSquares(comptime len: comptime_int, comptime T: type, v: Vec(len, T)) T {
        return @reduce(.Add, v * v);
    }

    pub fn magnitude(comptime len: comptime_int, comptime T: type, v: Vec(len, T)) T {
        return @sqrt(@reduce(.Add, v * v));
    }

    pub fn distance(comptime len: comptime_int, comptime T: type, a: Vec(len, T), b: Vec(len, T)) T {
        const diff = a - b;
        return @sqrt(@reduce(.Add, diff * diff));
    }
};

// Vector generation
pub const Generate = struct {
    pub fn splat(comptime len: comptime_int, comptime T: type, value: T) Vec(len, T) {
        return @splat(value);
    }

    pub fn range(comptime len: comptime_int, comptime T: type, start: T, step: T) Vec(len, T) {
        var result: Vec(len, T) = undefined;
        comptime var i: usize = 0;
        inline while (i < len) : (i += 1) {
            result[i] = start + @as(T, @floatFromInt(i)) * step;
        }
        return result;
    }

    pub fn iota(comptime len: comptime_int, comptime T: type) Vec(len, T) {
        var result: Vec(len, T) = undefined;
        comptime var i: usize = 0;
        inline while (i < len) : (i += 1) {
            result[i] = @as(T, @floatFromInt(i));
        }
        return result;
    }
};

// Fast approximate functions (trade accuracy for speed)
pub const FastApprox = struct {
    // Fast reciprocal (1/x) approximation
    pub fn reciprocal(comptime len: comptime_int, comptime T: type, v: Vec(len, T)) Vec(len, T) {
        const one: Vec(len, T) = @splat(@as(T, 1.0));
        return one / v;
    }

    // Fast inverse square root approximation
    pub fn rsqrt(comptime len: comptime_int, comptime T: type, v: Vec(len, T)) Vec(len, T) {
        const one: Vec(len, T) = @splat(@as(T, 1.0));
        return one / @sqrt(v);
    }

    // Fast normalize (make unit length)
    pub fn normalize(comptime len: comptime_int, comptime T: type, v: Vec(len, T)) Vec(len, T) {
        const mag = Horizontal.magnitude(len, T, v);
        const mag_vec: Vec(len, T) = @splat(mag);
        return v / mag_vec;
    }
};

// Fused multiply-add operations
pub const FMA = struct {
    pub fn mulAdd(comptime len: comptime_int, comptime T: type, a: Vec(len, T), b: Vec(len, T), c: Vec(len, T)) Vec(len, T) {
        return @mulAdd(Vec(len, T), a, b, c);
    }

    pub fn mulSub(comptime len: comptime_int, comptime T: type, a: Vec(len, T), b: Vec(len, T), c: Vec(len, T)) Vec(len, T) {
        return @mulAdd(Vec(len, T), a, b, -c);
    }
};

// Clamping and interpolation
pub const Clamp = struct {
    pub fn clamp(comptime len: comptime_int, comptime T: type, v: Vec(len, T), min_val: Vec(len, T), max_val: Vec(len, T)) Vec(len, T) {
        return @min(@max(v, min_val), max_val);
    }

    pub fn lerp(comptime len: comptime_int, comptime T: type, a: Vec(len, T), b: Vec(len, T), t: Vec(len, T)) Vec(len, T) {
        return @mulAdd(Vec(len, T), b - a, t, a);
    }

    pub fn saturate(comptime len: comptime_int, comptime T: type, v: Vec(len, T)) Vec(len, T) {
        const zero: Vec(len, T) = @splat(@as(T, 0.0));
        const one: Vec(len, T) = @splat(@as(T, 1.0));
        return @min(@max(v, zero), one);
    }
};

test "simd element-wise operations" {
    const testing = std.testing;

    const v: @Vector(4, f32) = .{ 4.0, 9.0, 16.0, 25.0 };
    const result = ElementWise.sqrt(4, f32, v);

    try testing.expectApproxEqAbs(@as(f32, 2.0), result[0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 3.0), result[1], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 4.0), result[2], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 5.0), result[3], 0.0001);
}

test "simd min/max" {
    const testing = std.testing;

    const a: @Vector(4, f32) = .{ 1.0, 5.0, 3.0, 8.0 };
    const b: @Vector(4, f32) = .{ 2.0, 4.0, 6.0, 7.0 };

    const min_result = ElementWise.min(4, f32, a, b);
    const max_result = ElementWise.max(4, f32, a, b);

    try testing.expectEqual(@as(f32, 1.0), min_result[0]);
    try testing.expectEqual(@as(f32, 4.0), min_result[1]);
    try testing.expectEqual(@as(f32, 8.0), max_result[3]);
}

test "simd reductions" {
    const testing = std.testing;

    const v: @Vector(4, f32) = .{ 1.0, 2.0, 3.0, 4.0 };

    try testing.expectApproxEqAbs(@as(f32, 10.0), Reduce.sum(4, f32, v), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 24.0), Reduce.product(4, f32, v), 0.0001);
    try testing.expectEqual(@as(f32, 1.0), Reduce.min(4, f32, v));
    try testing.expectEqual(@as(f32, 4.0), Reduce.max(4, f32, v));
}

test "simd dot product" {
    const testing = std.testing;

    const a: @Vector(4, f32) = .{ 1.0, 2.0, 3.0, 4.0 };
    const b: @Vector(4, f32) = .{ 2.0, 3.0, 4.0, 5.0 };

    const result = Horizontal.dot(4, f32, a, b);
    // 1*2 + 2*3 + 3*4 + 4*5 = 2 + 6 + 12 + 20 = 40
    try testing.expectApproxEqAbs(@as(f32, 40.0), result, 0.0001);
}

test "simd magnitude and distance" {
    const testing = std.testing;

    const v: @Vector(3, f32) = .{ 3.0, 4.0, 0.0 };
    const mag = Horizontal.magnitude(3, f32, v);
    try testing.expectApproxEqAbs(@as(f32, 5.0), mag, 0.0001);

    const a: @Vector(3, f32) = .{ 1.0, 2.0, 3.0 };
    const b: @Vector(3, f32) = .{ 4.0, 6.0, 3.0 };
    const dist = Horizontal.distance(3, f32, a, b);
    // sqrt((4-1)^2 + (6-2)^2 + (3-3)^2) = sqrt(9 + 16 + 0) = 5
    try testing.expectApproxEqAbs(@as(f32, 5.0), dist, 0.0001);
}

test "simd splat and iota" {
    const testing = std.testing;

    const splat_v = Generate.splat(4, f32, 5.0);
    try testing.expectEqual(@as(f32, 5.0), splat_v[0]);
    try testing.expectEqual(@as(f32, 5.0), splat_v[3]);

    const iota_v = Generate.iota(4, f32);
    try testing.expectEqual(@as(f32, 0.0), iota_v[0]);
    try testing.expectEqual(@as(f32, 1.0), iota_v[1]);
    try testing.expectEqual(@as(f32, 2.0), iota_v[2]);
    try testing.expectEqual(@as(f32, 3.0), iota_v[3]);
}

test "simd fast normalize" {
    const testing = std.testing;

    const v: @Vector(3, f32) = .{ 3.0, 4.0, 0.0 };
    const normalized = FastApprox.normalize(3, f32, v);

    // Should be (0.6, 0.8, 0.0)
    try testing.expectApproxEqAbs(@as(f32, 0.6), normalized[0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.8), normalized[1], 0.0001);
}

test "simd fma" {
    const testing = std.testing;

    const a: @Vector(4, f32) = .{ 1.0, 2.0, 3.0, 4.0 };
    const b: @Vector(4, f32) = .{ 2.0, 2.0, 2.0, 2.0 };
    const c: @Vector(4, f32) = .{ 1.0, 1.0, 1.0, 1.0 };

    const result = FMA.mulAdd(4, f32, a, b, c);
    // 1*2+1=3, 2*2+1=5, 3*2+1=7, 4*2+1=9
    try testing.expectEqual(@as(f32, 3.0), result[0]);
    try testing.expectEqual(@as(f32, 5.0), result[1]);
    try testing.expectEqual(@as(f32, 7.0), result[2]);
    try testing.expectEqual(@as(f32, 9.0), result[3]);
}

test "simd clamp and lerp" {
    const testing = std.testing;

    const v: @Vector(4, f32) = .{ -1.0, 0.5, 1.5, 2.0 };

    const saturated = Clamp.saturate(4, f32, v);
    try testing.expectEqual(@as(f32, 0.0), saturated[0]);
    try testing.expectApproxEqAbs(@as(f32, 0.5), saturated[1], 0.0001);
    try testing.expectEqual(@as(f32, 1.0), saturated[2]);
    try testing.expectEqual(@as(f32, 1.0), saturated[3]);

    const a: @Vector(4, f32) = @splat(0.0);
    const b: @Vector(4, f32) = @splat(10.0);
    const t: @Vector(4, f32) = @splat(0.5);
    const lerp_result = Clamp.lerp(4, f32, a, b, t);
    try testing.expectApproxEqAbs(@as(f32, 5.0), lerp_result[0], 0.0001);
}
