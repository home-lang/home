// Home Programming Language - Floating-Point Intrinsics
// Advanced floating-point operations and rounding modes

const std = @import("std");
const math = std.math;

// Floating-point classification
pub fn classify(comptime T: type, value: T) FpClass {
    if (math.isNan(value)) return .nan;
    if (math.isInf(value)) return if (value > 0) .positive_infinity else .negative_infinity;
    if (value == 0.0) return if (math.signbit(value)) .negative_zero else .positive_zero;
    if (math.isNormal(value)) return if (value > 0) .positive_normal else .negative_normal;
    return if (value > 0) .positive_subnormal else .negative_subnormal;
}

pub const FpClass = enum {
    negative_infinity,
    negative_normal,
    negative_subnormal,
    negative_zero,
    positive_zero,
    positive_subnormal,
    positive_normal,
    positive_infinity,
    nan,

    pub fn isNormal(self: FpClass) bool {
        return self == .positive_normal or self == .negative_normal;
    }

    pub fn isSubnormal(self: FpClass) bool {
        return self == .positive_subnormal or self == .negative_subnormal;
    }

    pub fn isZero(self: FpClass) bool {
        return self == .positive_zero or self == .negative_zero;
    }

    pub fn isInfinite(self: FpClass) bool {
        return self == .positive_infinity or self == .negative_infinity;
    }

    pub fn isNan(self: FpClass) bool {
        return self == .nan;
    }

    pub fn isFinite(self: FpClass) bool {
        return !self.isInfinite() and !self.isNan();
    }
};

// Rounding modes
pub const RoundingMode = enum {
    to_nearest,
    toward_zero,
    toward_positive,
    toward_negative,
};

// Round using specific rounding mode
pub fn roundMode(comptime T: type, value: T, mode: RoundingMode) T {
    return switch (mode) {
        .to_nearest => @round(value),
        .toward_zero => @trunc(value),
        .toward_positive => @ceil(value),
        .toward_negative => @floor(value),
    };
}

// Fused multiply-add: a * b + c
pub fn fma(comptime T: type, a: T, b: T, c: T) T {
    return @mulAdd(T, a, b, c);
}

// Fused multiply-subtract: a * b - c
pub fn fms(comptime T: type, a: T, b: T, c: T) T {
    return @mulAdd(T, a, b, -c);
}

// Fused negative multiply-add: -(a * b) + c
pub fn fnma(comptime T: type, a: T, b: T, c: T) T {
    return @mulAdd(T, -a, b, c);
}

// Fused negative multiply-subtract: -(a * b) - c
pub fn fnms(comptime T: type, a: T, b: T, c: T) T {
    return @mulAdd(T, -a, b, -c);
}

// Reciprocal approximation: 1/x
pub fn reciprocal(comptime T: type, x: T) T {
    return 1.0 / x;
}

// Reciprocal square root approximation: 1/sqrt(x)
pub fn reciprocalSqrt(comptime T: type, x: T) T {
    return 1.0 / @sqrt(x);
}

// Fast reciprocal (approximate)
pub fn fastReciprocal(x: f32) f32 {
    // Could use RCPSS on x86 SSE
    return 1.0 / x;
}

// Fast reciprocal square root (approximate)
pub fn fastReciprocalSqrt(x: f32) f32 {
    // Could use RSQRTSS on x86 SSE
    return 1.0 / @sqrt(x);
}

// Horizontal add: a[0] + a[1]
pub fn horizontalAdd(comptime T: type, a: @Vector(2, T)) T {
    return a[0] + a[1];
}

// Horizontal sub: a[0] - a[1]
pub fn horizontalSub(comptime T: type, a: @Vector(2, T)) T {
    return a[0] - a[1];
}

// Copy sign: magnitude of a with sign of b
pub fn copysign(comptime T: type, magnitude: T, sign: T) T {
    return @as(T, @bitCast(@as(std.meta.Int(.unsigned, @bitSizeOf(T)), @bitCast(magnitude)) & ~(@as(std.meta.Int(.unsigned, @bitSizeOf(T)), 1) << (@bitSizeOf(T) - 1)) | @as(std.meta.Int(.unsigned, @bitSizeOf(T)), @bitCast(sign)) & (@as(std.meta.Int(.unsigned, @bitSizeOf(T)), 1) << (@bitSizeOf(T) - 1))));
}

// Next representable value toward y
pub fn nextAfter(comptime T: type, x: T, y: T) T {
    if (math.isNan(x) or math.isNan(y)) {
        return math.nan(T);
    }

    if (x == y) return y;

    const bits = @bitSizeOf(T);
    const UInt = std.meta.Int(.unsigned, bits);
    var xi: UInt = @bitCast(x);

    if (x == 0) {
        // Return smallest value toward y
        const smallest: UInt = 1;
        return @bitCast(if (y > 0) smallest else smallest | (1 << (bits - 1)));
    }

    // Increment or decrement based on direction
    if ((x < y) == (x >= 0)) {
        xi +%= 1;
    } else {
        xi -%= 1;
    }

    return @bitCast(xi);
}

// Extract mantissa and exponent
pub fn frexp(comptime T: type, value: T) struct { mantissa: T, exponent: i32 } {
    if (value == 0 or math.isNan(value) or math.isInf(value)) {
        return .{ .mantissa = value, .exponent = 0 };
    }

    const bits = @bitSizeOf(T);
    const mantissa_bits = if (T == f32) 23 else 52;
    const exponent_bias = if (T == f32) 127 else 1023;
    const UInt = std.meta.Int(.unsigned, bits);

    const value_bits: UInt = @bitCast(value);
    const exponent_bits = (value_bits >> mantissa_bits) & ((1 << (bits - mantissa_bits - 1)) - 1);
    const exponent: i32 = @as(i32, @intCast(exponent_bits)) - exponent_bias + 1;

    // Reconstruct mantissa with exponent of -1 (0.5 <= mantissa < 1.0)
    const mantissa_mask = (1 << mantissa_bits) - 1;
    const new_exponent: UInt = @intCast(exponent_bias - 1);
    const mantissa_bits_result = (value_bits & mantissa_mask) | (new_exponent << mantissa_bits) | (value_bits & (1 << (bits - 1)));

    return .{
        .mantissa = @bitCast(mantissa_bits_result),
        .exponent = exponent,
    };
}

// Construct value from mantissa and exponent: mantissa * 2^exponent
pub fn ldexp(comptime T: type, mantissa: T, exponent: i32) T {
    return mantissa * math.pow(T, 2, @as(T, @floatFromInt(exponent)));
}

// Scale by power of 2: x * 2^n
pub fn scalbn(comptime T: type, x: T, n: i32) T {
    return x * math.pow(T, 2, @as(T, @floatFromInt(n)));
}

// Extract integer and fractional parts
pub fn modf(comptime T: type, value: T) struct { integer: T, fractional: T } {
    const integer = @trunc(value);
    return .{
        .integer = integer,
        .fractional = value - integer,
    };
}

// Remainder: x - n * y where n is the quotient rounded to nearest integer
pub fn remainder(comptime T: type, x: T, y: T) T {
    const n = @round(x / y);
    return x - n * y;
}

// IEEE 754 remainder (same as C fmod)
pub fn fmod(comptime T: type, x: T, y: T) T {
    return @mod(x, y);
}

test "floating-point classification" {
    const testing = std.testing;

    try testing.expect(classify(f32, 0.0).isZero());
    try testing.expect(classify(f32, -0.0).isZero());
    try testing.expect(classify(f32, 1.0).isNormal());
    try testing.expect(classify(f32, math.inf(f32)).isInfinite());
    try testing.expect(classify(f32, -math.inf(f32)).isInfinite());
    try testing.expect(classify(f32, math.nan(f32)).isNan());
}

test "rounding modes" {
    const testing = std.testing;

    try testing.expectEqual(@as(f32, 2.0), roundMode(f32, 1.5, .to_nearest));
    try testing.expectEqual(@as(f32, 1.0), roundMode(f32, 1.5, .toward_zero));
    try testing.expectEqual(@as(f32, 2.0), roundMode(f32, 1.5, .toward_positive));
    try testing.expectEqual(@as(f32, 1.0), roundMode(f32, 1.5, .toward_negative));

    try testing.expectEqual(@as(f32, -2.0), roundMode(f32, -1.5, .to_nearest));
    try testing.expectEqual(@as(f32, -1.0), roundMode(f32, -1.5, .toward_zero));
    try testing.expectEqual(@as(f32, -1.0), roundMode(f32, -1.5, .toward_positive));
    try testing.expectEqual(@as(f32, -2.0), roundMode(f32, -1.5, .toward_negative));
}

test "fused multiply operations" {
    const testing = std.testing;

    try testing.expectApproxEqAbs(@as(f32, 7.0), fma(f32, 2.0, 3.0, 1.0), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 5.0), fms(f32, 2.0, 3.0, 1.0), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, -5.0), fnma(f32, 2.0, 3.0, 1.0), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, -7.0), fnms(f32, 2.0, 3.0, 1.0), 0.0001);
}

test "reciprocal operations" {
    const testing = std.testing;

    try testing.expectApproxEqAbs(@as(f32, 0.5), reciprocal(f32, 2.0), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), reciprocalSqrt(f32, 4.0), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.25), fastReciprocal(4.0), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), fastReciprocalSqrt(4.0), 0.001);
}

test "frexp and ldexp" {
    const testing = std.testing;

    const result = frexp(f32, 12.5);
    try testing.expectApproxEqAbs(@as(f32, 0.78125), result.mantissa, 0.0001);
    try testing.expectEqual(@as(i32, 4), result.exponent);

    const reconstructed = ldexp(f32, result.mantissa, result.exponent);
    try testing.expectApproxEqAbs(@as(f32, 12.5), reconstructed, 0.0001);
}

test "modf" {
    const testing = std.testing;

    const result = modf(f32, 3.14159);
    try testing.expectApproxEqAbs(@as(f32, 3.0), result.integer, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.14159), result.fractional, 0.0001);
}
