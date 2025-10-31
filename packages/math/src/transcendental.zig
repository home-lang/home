// Home Programming Language - Transcendental Functions
// Trigonometric, hyperbolic, exponential, and logarithmic functions

const std = @import("std");

// Trigonometric functions
pub fn sin(x: anytype) @TypeOf(x) {
    return @sin(x);
}

pub fn cos(x: anytype) @TypeOf(x) {
    return @cos(x);
}

pub fn tan(x: anytype) @TypeOf(x) {
    return @tan(x);
}

// Inverse trigonometric functions
pub fn asin(x: anytype) @TypeOf(x) {
    return std.math.asin(x);
}

pub fn acos(x: anytype) @TypeOf(x) {
    return std.math.acos(x);
}

pub fn atan(x: anytype) @TypeOf(x) {
    return std.math.atan(x);
}

pub fn atan2(comptime T: type, y: T, x: T) T {
    return std.math.atan2(y, x);
}

// Hyperbolic functions
pub fn sinh(x: anytype) @TypeOf(x) {
    return std.math.sinh(x);
}

pub fn cosh(x: anytype) @TypeOf(x) {
    return std.math.cosh(x);
}

pub fn tanh(x: anytype) @TypeOf(x) {
    return std.math.tanh(x);
}

// Inverse hyperbolic functions
pub fn asinh(x: anytype) @TypeOf(x) {
    return std.math.asinh(x);
}

pub fn acosh(x: anytype) @TypeOf(x) {
    return std.math.acosh(x);
}

pub fn atanh(x: anytype) @TypeOf(x) {
    return std.math.atanh(x);
}

// Exponential and logarithmic functions
pub fn exp(x: anytype) @TypeOf(x) {
    return @exp(x);
}

pub fn exp2(x: anytype) @TypeOf(x) {
    return @exp2(x);
}

pub fn expm1(x: anytype) @TypeOf(x) {
    return std.math.expm1(x);
}

pub fn ln(x: anytype) @TypeOf(x) {
    return @log(x);
}

pub fn log(x: anytype) @TypeOf(x) {
    return @log(x);
}

pub fn log2(x: anytype) @TypeOf(x) {
    return @log2(x);
}

pub fn log10(x: anytype) @TypeOf(x) {
    return @log10(x);
}

pub fn log1p(x: anytype) @TypeOf(x) {
    return std.math.log1p(x);
}

// Degree/radian conversion
pub fn toRadians(comptime T: type, degrees: T) T {
    const pi: T = 3.14159265358979323846;
    return degrees * pi / 180.0;
}

pub fn toDegrees(comptime T: type, radians: T) T {
    const pi: T = 3.14159265358979323846;
    return radians * 180.0 / pi;
}

// Simultaneous sine and cosine (more efficient)
pub fn sincos(comptime T: type, x: T) struct { sin: T, cos: T } {
    return .{
        .sin = @sin(x),
        .cos = @cos(x),
    };
}

test "trig functions" {
    const testing = std.testing;
    const pi: f64 = 3.14159265358979323846;

    try testing.expectApproxEqAbs(@as(f64, 0.0), sin(@as(f64, 0.0)), 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 1.0), cos(@as(f64, 0.0)), 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 0.0), tan(@as(f64, 0.0)), 0.0001);

    try testing.expectApproxEqAbs(@as(f64, 1.0), sin(@as(f64, pi / 2.0)), 0.0001);
    try testing.expectApproxEqAbs(@as(f64, -1.0), cos(@as(f64, pi)), 0.0001);
}

test "inverse trig functions" {
    const testing = std.testing;

    try testing.expectApproxEqAbs(@as(f64, 0.0), asin(@as(f64, 0.0)), 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 0.0), atan(@as(f64, 0.0)), 0.0001);
}

test "hyperbolic functions" {
    const testing = std.testing;

    try testing.expectApproxEqAbs(@as(f64, 0.0), sinh(@as(f64, 0.0)), 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 1.0), cosh(@as(f64, 0.0)), 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 0.0), tanh(@as(f64, 0.0)), 0.0001);
}

test "exponential functions" {
    const testing = std.testing;

    try testing.expectApproxEqAbs(@as(f64, 1.0), exp(@as(f64, 0.0)), 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 2.71828), exp(@as(f64, 1.0)), 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 2.0), exp2(@as(f64, 1.0)), 0.0001);
}

test "logarithmic functions" {
    const testing = std.testing;

    try testing.expectApproxEqAbs(@as(f64, 0.0), ln(@as(f64, 1.0)), 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 1.0), ln(@as(f64, 2.71828)), 0.001);
    try testing.expectApproxEqAbs(@as(f64, 1.0), log2(@as(f64, 2.0)), 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 1.0), log10(@as(f64, 10.0)), 0.0001);
}

test "angle conversion" {
    const testing = std.testing;

    try testing.expectApproxEqAbs(@as(f64, 3.14159), toRadians(f64, 180.0), 0.001);
    try testing.expectApproxEqAbs(@as(f64, 180.0), toDegrees(f64, 3.14159), 0.001);
}
