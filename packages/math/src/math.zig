// Home Programming Language - Advanced Math Library
// Transcendental functions, SIMD operations, and advanced mathematics

const std = @import("std");

// Math components
pub const basic = @import("basic.zig");
pub const transcendental = @import("transcendental.zig");
pub const simd_math = @import("simd_math.zig");
pub const special = @import("special.zig");
pub const complex = @import("complex.zig");
pub const vector = @import("vector.zig");
pub const matrix = @import("matrix.zig");
pub const quaternion = @import("quaternion.zig");
pub const frustum = @import("frustum.zig");
pub const easing = @import("easing.zig");
pub const ray = @import("ray.zig");
pub const transform = @import("transform.zig");

// Re-export commonly used functions
pub const sqrt = basic.sqrt;
pub const pow = basic.pow;
pub const abs = basic.abs;
pub const min = basic.min;
pub const max = basic.max;

// Transcendental functions
pub const sin = transcendental.sin;
pub const cos = transcendental.cos;
pub const tan = transcendental.tan;
pub const asin = transcendental.asin;
pub const acos = transcendental.acos;
pub const atan = transcendental.atan;
pub const atan2 = transcendental.atan2;
pub const sinh = transcendental.sinh;
pub const cosh = transcendental.cosh;
pub const tanh = transcendental.tanh;
pub const exp = transcendental.exp;
pub const ln = transcendental.ln;
pub const log10 = transcendental.log10;
pub const log2 = transcendental.log2;

// Re-export types
pub const Complex = complex.Complex;
pub const Vec2 = vector.Vec2;
pub const Vec3 = vector.Vec3;
pub const Vec4 = vector.Vec4;
pub const Mat2 = matrix.Mat2;
pub const Mat3 = matrix.Mat3;
pub const Mat4 = matrix.Mat4;
pub const Quat = quaternion.Quat;
pub const Quatf = quaternion.Quatf;
pub const Quatd = quaternion.Quatd;
pub const Plane = frustum.Plane;
pub const AABB = frustum.AABB;
pub const BoundingSphere = frustum.BoundingSphere;
pub const Frustum = frustum.Frustum;
pub const Frustumf = frustum.Frustumf;
pub const Easing = easing.Easing;
pub const Easingf = easing.Easingf;
pub const EasingType = easing.EasingType;
pub const getEasingFn = easing.getEasingFn;
pub const Ray = ray.Ray;
pub const Rayf = ray.Rayf;
pub const LineSegment = ray.LineSegment;
pub const PickRay = ray.PickRay;
pub const Transform = transform.Transform;
pub const Transformf = transform.Transformf;
pub const Transformd = transform.Transformd;
pub const TransformNode = transform.TransformNode;
pub const TransformNodef = transform.TransformNodef;

// Constants
pub const pi: f64 = 3.14159265358979323846;
pub const e: f64 = 2.71828182845904523536;
pub const tau: f64 = 6.28318530717958647692; // 2π
pub const phi: f64 = 1.61803398874989484820; // Golden ratio
pub const sqrt2: f64 = 1.41421356237309504880;
pub const sqrt3: f64 = 1.73205080756887729352;
pub const ln2: f64 = 0.69314718055994530942;
pub const ln10: f64 = 2.30258509299404568402;

test "math module imports" {
    _ = basic;
    _ = transcendental;
    _ = simd_math;
    _ = special;
    _ = complex;
    _ = vector;
    _ = matrix;
    _ = quaternion;
    _ = frustum;
    _ = easing;
    _ = ray;
    _ = transform;
}
