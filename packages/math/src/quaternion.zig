// Home Programming Language - Quaternion Math
// Quaternion type for 3D rotations
// Ported from C&C Generals engine for game compatibility

const std = @import("std");
const vector = @import("vector.zig");

/// Quaternion for representing 3D rotations
/// Components: x, y, z (vector/imaginary part), w (scalar/real part)
/// Unit quaternion represents a rotation: q = cos(θ/2) + sin(θ/2)(xi + yj + zk)
pub fn Quat(comptime T: type) type {
    return struct {
        x: T,
        y: T,
        z: T,
        w: T,

        const Self = @This();
        const Vec3 = vector.Vec3(T);

        // ============================================
        // Constructors
        // ============================================

        /// Create quaternion from components (x, y, z are vector part, w is scalar)
        pub fn init(x: T, y: T, z: T, w: T) Self {
            return .{ .x = x, .y = y, .z = z, .w = w };
        }

        /// Identity quaternion (no rotation)
        pub fn identity() Self {
            return .{ .x = 0, .y = 0, .z = 0, .w = 1 };
        }

        /// Create quaternion from axis-angle representation
        /// axis: normalized rotation axis
        /// angle: rotation angle in radians
        pub fn fromAxisAngle(axis: Vec3, angle: T) Self {
            const half_angle = angle * 0.5;
            const s = @sin(half_angle);
            const c = @cos(half_angle);
            return .{
                .x = axis.x * s,
                .y = axis.y * s,
                .z = axis.z * s,
                .w = c,
            };
        }

        /// Create quaternion from Euler angles (XYZ rotation order)
        /// pitch: rotation around X axis
        /// yaw: rotation around Y axis
        /// roll: rotation around Z axis
        pub fn fromEuler(pitch: T, yaw: T, roll: T) Self {
            const cp = @cos(pitch * 0.5);
            const sp = @sin(pitch * 0.5);
            const cy = @cos(yaw * 0.5);
            const sy = @sin(yaw * 0.5);
            const cr = @cos(roll * 0.5);
            const sr = @sin(roll * 0.5);

            return .{
                .x = sp * cy * cr - cp * sy * sr,
                .y = cp * sy * cr + sp * cy * sr,
                .z = cp * cy * sr - sp * sy * cr,
                .w = cp * cy * cr + sp * sy * sr,
            };
        }

        /// Create rotation quaternion around X axis
        pub fn fromRotationX(angle: T) Self {
            const half = angle * 0.5;
            return .{ .x = @sin(half), .y = 0, .z = 0, .w = @cos(half) };
        }

        /// Create rotation quaternion around Y axis
        pub fn fromRotationY(angle: T) Self {
            const half = angle * 0.5;
            return .{ .x = 0, .y = @sin(half), .z = 0, .w = @cos(half) };
        }

        /// Create rotation quaternion around Z axis
        pub fn fromRotationZ(angle: T) Self {
            const half = angle * 0.5;
            return .{ .x = 0, .y = 0, .z = @sin(half), .w = @cos(half) };
        }

        // ============================================
        // Basic Operations
        // ============================================

        /// Add two quaternions
        pub fn add(self: Self, other: Self) Self {
            return .{
                .x = self.x + other.x,
                .y = self.y + other.y,
                .z = self.z + other.z,
                .w = self.w + other.w,
            };
        }

        /// Subtract quaternions
        pub fn sub(self: Self, other: Self) Self {
            return .{
                .x = self.x - other.x,
                .y = self.y - other.y,
                .z = self.z - other.z,
                .w = self.w - other.w,
            };
        }

        /// Scale quaternion by scalar
        pub fn scale(self: Self, scalar: T) Self {
            return .{
                .x = self.x * scalar,
                .y = self.y * scalar,
                .z = self.z * scalar,
                .w = self.w * scalar,
            };
        }

        /// Negate quaternion (represents same rotation)
        pub fn neg(self: Self) Self {
            return .{ .x = -self.x, .y = -self.y, .z = -self.z, .w = -self.w };
        }

        /// Quaternion multiplication (combines rotations)
        /// Result represents rotating by self first, then by other
        pub fn mul(self: Self, other: Self) Self {
            return .{
                .x = self.w * other.x + self.x * other.w + self.y * other.z - self.z * other.y,
                .y = self.w * other.y - self.x * other.z + self.y * other.w + self.z * other.x,
                .z = self.w * other.z + self.x * other.y - self.y * other.x + self.z * other.w,
                .w = self.w * other.w - self.x * other.x - self.y * other.y - self.z * other.z,
            };
        }

        /// Dot product of two quaternions
        pub fn dot(self: Self, other: Self) T {
            return self.x * other.x + self.y * other.y + self.z * other.z + self.w * other.w;
        }

        // ============================================
        // Length and Normalization
        // ============================================

        /// Squared length (magnitude squared)
        pub fn lengthSq(self: Self) T {
            return self.x * self.x + self.y * self.y + self.z * self.z + self.w * self.w;
        }

        /// Length (magnitude)
        pub fn length(self: Self) T {
            return @sqrt(self.lengthSq());
        }

        /// Normalize to unit quaternion
        pub fn normalize(self: Self) Self {
            const len = self.length();
            if (len < 0.000001) {
                return identity();
            }
            const inv_len = 1.0 / len;
            return .{
                .x = self.x * inv_len,
                .y = self.y * inv_len,
                .z = self.z * inv_len,
                .w = self.w * inv_len,
            };
        }

        /// Check if quaternion is unit length (within epsilon)
        pub fn isUnit(self: Self) bool {
            const len_sq = self.lengthSq();
            return @abs(len_sq - 1.0) < 0.0001;
        }

        // ============================================
        // Conjugate and Inverse
        // ============================================

        /// Conjugate (negates vector part)
        /// For unit quaternions, conjugate equals inverse
        pub fn conjugate(self: Self) Self {
            return .{ .x = -self.x, .y = -self.y, .z = -self.z, .w = self.w };
        }

        /// Inverse quaternion
        /// For unit quaternions, this equals the conjugate
        pub fn inverse(self: Self) Self {
            const len_sq = self.lengthSq();
            if (len_sq < 0.000001) {
                return identity();
            }
            const inv_len_sq = 1.0 / len_sq;
            return .{
                .x = -self.x * inv_len_sq,
                .y = -self.y * inv_len_sq,
                .z = -self.z * inv_len_sq,
                .w = self.w * inv_len_sq,
            };
        }

        // ============================================
        // Rotation Operations
        // ============================================

        /// Rotate a 3D vector by this quaternion
        /// Assumes quaternion is normalized
        pub fn rotateVector(self: Self, v: Vec3) Vec3 {
            // Optimized quaternion-vector rotation
            // v' = q * v * q^-1
            // Using the formula: v' = v + 2w(q_xyz × v) + 2(q_xyz × (q_xyz × v))
            const qv = Vec3.init(self.x, self.y, self.z);
            const uv = qv.cross(v);
            const uuv = qv.cross(uv);

            return Vec3.init(
                v.x + (uv.x * self.w + uuv.x) * 2.0,
                v.y + (uv.y * self.w + uuv.y) * 2.0,
                v.z + (uv.z * self.w + uuv.z) * 2.0,
            );
        }

        /// Get the axis of rotation (for non-identity quaternions)
        pub fn getAxis(self: Self) Vec3 {
            const sin_sq = 1.0 - self.w * self.w;
            if (sin_sq < 0.000001) {
                // No rotation or very small rotation, return arbitrary axis
                return Vec3.init(1, 0, 0);
            }
            const inv_sin = 1.0 / @sqrt(sin_sq);
            return Vec3.init(
                self.x * inv_sin,
                self.y * inv_sin,
                self.z * inv_sin,
            );
        }

        /// Get the angle of rotation in radians
        pub fn getAngle(self: Self) T {
            return 2.0 * std.math.acos(@min(@max(self.w, -1.0), 1.0));
        }

        // ============================================
        // Interpolation
        // ============================================

        /// Linear interpolation (not normalized - use nlerp for rotations)
        pub fn lerp(self: Self, other: Self, t: T) Self {
            return .{
                .x = self.x + (other.x - self.x) * t,
                .y = self.y + (other.y - self.y) * t,
                .z = self.z + (other.z - self.z) * t,
                .w = self.w + (other.w - self.w) * t,
            };
        }

        /// Normalized linear interpolation (faster than slerp, good for small angles)
        pub fn nlerp(self: Self, other: Self, t: T) Self {
            // Handle antipodal quaternions (choose shorter path)
            var o = other;
            if (self.dot(other) < 0) {
                o = other.neg();
            }
            return self.lerp(o, t).normalize();
        }

        /// Spherical linear interpolation (smooth rotation interpolation)
        /// Maintains constant angular velocity
        pub fn slerp(self: Self, other: Self, t: T) Self {
            var d = self.dot(other);

            // Handle antipodal quaternions (choose shorter path)
            var o = other;
            if (d < 0) {
                o = other.neg();
                d = -d;
            }

            // If quaternions are very close, use linear interpolation to avoid division by zero
            if (d > 0.9995) {
                return self.nlerp(o, t);
            }

            // Calculate interpolation factors using spherical geometry
            const theta_0 = std.math.acos(d);
            const theta = theta_0 * t;
            const sin_theta = @sin(theta);
            const sin_theta_0 = @sin(theta_0);

            const s0 = @cos(theta) - d * sin_theta / sin_theta_0;
            const s1 = sin_theta / sin_theta_0;

            return .{
                .x = self.x * s0 + o.x * s1,
                .y = self.y * s0 + o.y * s1,
                .z = self.z * s0 + o.z * s1,
                .w = self.w * s0 + o.w * s1,
            };
        }

        // ============================================
        // Conversion
        // ============================================

        /// Convert to Euler angles (XYZ rotation order)
        /// Returns (pitch, yaw, roll) in radians
        pub fn toEuler(self: Self) struct { pitch: T, yaw: T, roll: T } {
            // Pitch (x-axis rotation) - matches fromEuler convention
            const sinp_cosy = 2.0 * (self.w * self.x + self.y * self.z);
            const cosp_cosy = 1.0 - 2.0 * (self.x * self.x + self.y * self.y);
            const pitch = std.math.atan2(sinp_cosy, cosp_cosy);

            // Yaw (y-axis rotation)
            const siny = 2.0 * (self.w * self.y - self.z * self.x);
            const half_pi: T = std.math.pi / 2.0;
            const yaw = if (@abs(siny) >= 1.0)
                std.math.copysign(half_pi, siny)
            else
                std.math.asin(siny);

            // Roll (z-axis rotation)
            const sinr_cosy = 2.0 * (self.w * self.z + self.x * self.y);
            const cosr_cosy = 1.0 - 2.0 * (self.y * self.y + self.z * self.z);
            const roll = std.math.atan2(sinr_cosy, cosr_cosy);

            return .{ .pitch = pitch, .yaw = yaw, .roll = roll };
        }

        /// Get forward direction vector (Z-axis after rotation)
        pub fn getForward(self: Self) Vec3 {
            return self.rotateVector(Vec3.init(0, 0, 1));
        }

        /// Get right direction vector (X-axis after rotation)
        pub fn getRight(self: Self) Vec3 {
            return self.rotateVector(Vec3.init(1, 0, 0));
        }

        /// Get up direction vector (Y-axis after rotation)
        pub fn getUp(self: Self) Vec3 {
            return self.rotateVector(Vec3.init(0, 1, 0));
        }

        // ============================================
        // Comparison
        // ============================================

        /// Check if two quaternions are approximately equal
        pub fn equals(self: Self, other: Self, epsilon: T) bool {
            return @abs(self.x - other.x) < epsilon and
                @abs(self.y - other.y) < epsilon and
                @abs(self.z - other.z) < epsilon and
                @abs(self.w - other.w) < epsilon;
        }

        /// Check if quaternion represents the same rotation (accounts for q == -q)
        pub fn sameRotation(self: Self, other: Self, epsilon: T) bool {
            return self.equals(other, epsilon) or self.equals(other.neg(), epsilon);
        }

        /// Check if quaternion values are valid (not NaN or Inf)
        pub fn isValid(self: Self) bool {
            return !std.math.isNan(self.x) and !std.math.isNan(self.y) and
                !std.math.isNan(self.z) and !std.math.isNan(self.w) and
                !std.math.isInf(self.x) and !std.math.isInf(self.y) and
                !std.math.isInf(self.z) and !std.math.isInf(self.w);
        }
    };
}

// Type aliases for common use
pub const Quatf = Quat(f32);
pub const Quatd = Quat(f64);

// ============================================
// Tests
// ============================================

test "quaternion identity" {
    const testing = std.testing;
    const Q = Quat(f32);

    const q = Q.identity();
    try testing.expectEqual(@as(f32, 0), q.x);
    try testing.expectEqual(@as(f32, 0), q.y);
    try testing.expectEqual(@as(f32, 0), q.z);
    try testing.expectEqual(@as(f32, 1), q.w);
    try testing.expect(q.isUnit());
}

test "quaternion from axis angle" {
    const testing = std.testing;
    const Q = Quat(f32);
    const V3 = vector.Vec3(f32);

    // 90 degree rotation around Y axis
    const axis = V3.init(0, 1, 0);
    const angle: f32 = std.math.pi / 2.0;
    const q = Q.fromAxisAngle(axis, angle);

    try testing.expect(q.isUnit());
    try testing.expectApproxEqAbs(@as(f32, angle), q.getAngle(), 0.0001);
}

test "quaternion multiplication" {
    const testing = std.testing;
    const Q = Quat(f32);

    // Two 90-degree rotations around Y should give 180 degrees
    const q90 = Q.fromRotationY(std.math.pi / 2.0);
    const q180 = q90.mul(q90);

    try testing.expectApproxEqAbs(@as(f32, std.math.pi), q180.getAngle(), 0.001);
}

test "quaternion vector rotation" {
    const testing = std.testing;
    const Q = Quat(f32);
    const V3 = vector.Vec3(f32);

    // 90 degree rotation around Y axis
    const q = Q.fromRotationY(std.math.pi / 2.0);
    const v = V3.init(1, 0, 0); // X axis
    const rotated = q.rotateVector(v);

    // X axis rotated 90 degrees around Y should give -Z axis
    try testing.expectApproxEqAbs(@as(f32, 0), rotated.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0), rotated.y, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, -1), rotated.z, 0.0001);
}

test "quaternion conjugate and inverse" {
    const testing = std.testing;
    const Q = Quat(f32);

    const q = Q.fromRotationY(std.math.pi / 4.0);
    const q_inv = q.inverse();
    const product = q.mul(q_inv);

    // q * q^-1 should equal identity
    try testing.expect(product.equals(Q.identity(), 0.0001));
}

test "quaternion slerp" {
    const testing = std.testing;
    const Q = Quat(f32);

    const q1 = Q.identity();
    const q2 = Q.fromRotationY(std.math.pi / 2.0);

    // Halfway interpolation should give 45 degree rotation
    const mid = q1.slerp(q2, 0.5);
    try testing.expectApproxEqAbs(@as(f32, std.math.pi / 4.0), mid.getAngle(), 0.001);
}

test "quaternion euler conversion" {
    const testing = std.testing;
    const Q = Quat(f32);

    const pitch: f32 = 0.3;
    const yaw: f32 = 0.5;
    const roll: f32 = 0.2;

    const q = Q.fromEuler(pitch, yaw, roll);
    const euler = q.toEuler();

    try testing.expectApproxEqAbs(pitch, euler.pitch, 0.001);
    try testing.expectApproxEqAbs(yaw, euler.yaw, 0.001);
    try testing.expectApproxEqAbs(roll, euler.roll, 0.001);
}

test "quaternion normalization" {
    const testing = std.testing;
    const Q = Quat(f32);

    const q = Q.init(1, 2, 3, 4);
    const normalized = q.normalize();

    try testing.expectApproxEqAbs(@as(f32, 1.0), normalized.length(), 0.0001);
}
