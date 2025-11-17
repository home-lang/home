// Home Language - 3D Mathematics Library
// Optimized for game development and real-time applications
//
// Based on implementation from C&C Generals Zero Hour port
// Provides Vec2, Vec3, Vec4, Mat4, Quat, and collision primitives

const std = @import("std");
const math = std.math;

// ============================================================================
// Vector Types
// ============================================================================

/// 2D vector
pub const Vec2 = struct {
    x: f32,
    y: f32,

    pub fn init(x: f32, y: f32) Vec2 {
        return .{ .x = x, .y = y };
    }

    pub fn zero() Vec2 {
        return .{ .x = 0.0, .y = 0.0 };
    }

    pub fn one() Vec2 {
        return .{ .x = 1.0, .y = 1.0 };
    }

    pub fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    pub fn sub(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }

    pub fn mul(a: Vec2, scalar: f32) Vec2 {
        return .{ .x = a.x * scalar, .y = a.y * scalar };
    }

    pub fn div(a: Vec2, scalar: f32) Vec2 {
        return .{ .x = a.x / scalar, .y = a.y / scalar };
    }

    pub fn dot(a: Vec2, b: Vec2) f32 {
        return a.x * b.x + a.y * b.y;
    }

    pub fn lengthSquared(self: Vec2) f32 {
        return self.x * self.x + self.y * self.y;
    }

    pub fn length(self: Vec2) f32 {
        return @sqrt(self.lengthSquared());
    }

    pub fn normalize(self: Vec2) Vec2 {
        const len = self.length();
        if (len == 0.0) return self;
        return self.div(len);
    }

    pub fn distance(a: Vec2, b: Vec2) f32 {
        return a.sub(b).length();
    }

    pub fn lerp(a: Vec2, b: Vec2, t: f32) Vec2 {
        return .{
            .x = a.x + (b.x - a.x) * t,
            .y = a.y + (b.y - a.y) * t,
        };
    }
};

/// 3D vector
pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    pub fn init(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn zero() Vec3 {
        return .{ .x = 0.0, .y = 0.0, .z = 0.0 };
    }

    pub fn one() Vec3 {
        return .{ .x = 1.0, .y = 1.0, .z = 1.0 };
    }

    pub fn up() Vec3 {
        return .{ .x = 0.0, .y = 1.0, .z = 0.0 };
    }

    pub fn right() Vec3 {
        return .{ .x = 1.0, .y = 0.0, .z = 0.0 };
    }

    pub fn forward() Vec3 {
        return .{ .x = 0.0, .y = 0.0, .z = 1.0 };
    }

    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }

    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }

    pub fn mul(a: Vec3, scalar: f32) Vec3 {
        return .{ .x = a.x * scalar, .y = a.y * scalar, .z = a.z * scalar };
    }

    pub fn div(a: Vec3, scalar: f32) Vec3 {
        return .{ .x = a.x / scalar, .y = a.y / scalar, .z = a.z / scalar };
    }

    pub fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }

    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        return .{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }

    pub fn lengthSquared(self: Vec3) f32 {
        return self.x * self.x + self.y * self.y + self.z * self.z;
    }

    pub fn length(self: Vec3) f32 {
        return @sqrt(self.lengthSquared());
    }

    pub fn normalize(self: Vec3) Vec3 {
        const len = self.length();
        if (len == 0.0) return self;
        return self.div(len);
    }

    pub fn distance(a: Vec3, b: Vec3) f32 {
        return a.sub(b).length();
    }

    pub fn distanceSquared(a: Vec3, b: Vec3) f32 {
        return a.sub(b).lengthSquared();
    }

    pub fn lerp(a: Vec3, b: Vec3, t: f32) Vec3 {
        return .{
            .x = a.x + (b.x - a.x) * t,
            .y = a.y + (b.y - a.y) * t,
            .z = a.z + (b.z - a.z) * t,
        };
    }

    pub fn reflect(incident: Vec3, normal: Vec3) Vec3 {
        const d = 2.0 * dot(incident, normal);
        return sub(incident, normal.mul(d));
    }
};

/// 4D vector (homogeneous coordinates)
pub const Vec4 = struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,

    pub fn init(x: f32, y: f32, z: f32, w: f32) Vec4 {
        return .{ .x = x, .y = y, .z = z, .w = w };
    }

    pub fn fromVec3(v: Vec3, w: f32) Vec4 {
        return .{ .x = v.x, .y = v.y, .z = v.z, .w = w };
    }

    pub fn toVec3(self: Vec4) Vec3 {
        return .{ .x = self.x, .y = self.y, .z = self.z };
    }

    pub fn add(a: Vec4, b: Vec4) Vec4 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z, .w = a.w + b.w };
    }

    pub fn mul(a: Vec4, scalar: f32) Vec4 {
        return .{ .x = a.x * scalar, .y = a.y * scalar, .z = a.z * scalar, .w = a.w * scalar };
    }

    pub fn dot(a: Vec4, b: Vec4) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
    }
};

// ============================================================================
// Matrix Types
// ============================================================================

/// 4x4 matrix (column-major order)
pub const Mat4 = struct {
    m: [16]f32,

    pub fn identity() Mat4 {
        return .{ .m = [_]f32{
            1.0, 0.0, 0.0, 0.0,
            0.0, 1.0, 0.0, 0.0,
            0.0, 0.0, 1.0, 0.0,
            0.0, 0.0, 0.0, 1.0,
        } };
    }

    pub fn zero() Mat4 {
        return .{ .m = [_]f32{0.0} ** 16 };
    }

    /// Create translation matrix
    pub fn translation(v: Vec3) Mat4 {
        return .{ .m = [_]f32{
            1.0, 0.0, 0.0, 0.0,
            0.0, 1.0, 0.0, 0.0,
            0.0, 0.0, 1.0, 0.0,
            v.x, v.y, v.z, 1.0,
        } };
    }

    /// Create scale matrix
    pub fn scale(v: Vec3) Mat4 {
        return .{ .m = [_]f32{
            v.x, 0.0, 0.0, 0.0,
            0.0, v.y, 0.0, 0.0,
            0.0, 0.0, v.z, 0.0,
            0.0, 0.0, 0.0, 1.0,
        } };
    }

    /// Create rotation matrix around X axis (radians)
    pub fn rotationX(angle: f32) Mat4 {
        const c = @cos(angle);
        const s = @sin(angle);
        return .{ .m = [_]f32{
            1.0, 0.0, 0.0, 0.0,
            0.0, c,   s,   0.0,
            0.0, -s,  c,   0.0,
            0.0, 0.0, 0.0, 1.0,
        } };
    }

    /// Create rotation matrix around Y axis (radians)
    pub fn rotationY(angle: f32) Mat4 {
        const c = @cos(angle);
        const s = @sin(angle);
        return .{ .m = [_]f32{
            c,   0.0, -s,  0.0,
            0.0, 1.0, 0.0, 0.0,
            s,   0.0, c,   0.0,
            0.0, 0.0, 0.0, 1.0,
        } };
    }

    /// Create rotation matrix around Z axis (radians)
    pub fn rotationZ(angle: f32) Mat4 {
        const c = @cos(angle);
        const s = @sin(angle);
        return .{ .m = [_]f32{
            c,   s,   0.0, 0.0,
            -s,  c,   0.0, 0.0,
            0.0, 0.0, 1.0, 0.0,
            0.0, 0.0, 0.0, 1.0,
        } };
    }

    /// Matrix multiplication
    pub fn multiply(a: Mat4, b: Mat4) Mat4 {
        var result = Mat4.zero();
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            var j: usize = 0;
            while (j < 4) : (j += 1) {
                var sum: f32 = 0.0;
                var k: usize = 0;
                while (k < 4) : (k += 1) {
                    sum += a.m[i + k * 4] * b.m[k + j * 4];
                }
                result.m[i + j * 4] = sum;
            }
        }
        return result;
    }

    /// Transform Vec3 by matrix (treats as point with w=1)
    pub fn transformPoint(self: Mat4, v: Vec3) Vec3 {
        const x = v.x * self.m[0] + v.y * self.m[4] + v.z * self.m[8] + self.m[12];
        const y = v.x * self.m[1] + v.y * self.m[5] + v.z * self.m[9] + self.m[13];
        const z = v.x * self.m[2] + v.y * self.m[6] + v.z * self.m[10] + self.m[14];
        return Vec3.init(x, y, z);
    }

    /// Transform Vec3 by matrix (treats as direction with w=0)
    pub fn transformDirection(self: Mat4, v: Vec3) Vec3 {
        const x = v.x * self.m[0] + v.y * self.m[4] + v.z * self.m[8];
        const y = v.x * self.m[1] + v.y * self.m[5] + v.z * self.m[9];
        const z = v.x * self.m[2] + v.y * self.m[6] + v.z * self.m[10];
        return Vec3.init(x, y, z);
    }

    /// Create perspective projection matrix
    pub fn perspective(fov_y: f32, aspect: f32, near: f32, far: f32) Mat4 {
        const tan_half_fov = @tan(fov_y / 2.0);
        var result = Mat4.zero();
        result.m[0] = 1.0 / (aspect * tan_half_fov);
        result.m[5] = 1.0 / tan_half_fov;
        result.m[10] = -(far + near) / (far - near);
        result.m[11] = -1.0;
        result.m[14] = -(2.0 * far * near) / (far - near);
        return result;
    }

    /// Create orthographic projection matrix
    pub fn orthographic(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) Mat4 {
        var result = Mat4.identity();
        result.m[0] = 2.0 / (right - left);
        result.m[5] = 2.0 / (top - bottom);
        result.m[10] = -2.0 / (far - near);
        result.m[12] = -(right + left) / (right - left);
        result.m[13] = -(top + bottom) / (top - bottom);
        result.m[14] = -(far + near) / (far - near);
        return result;
    }

    /// Create look-at view matrix
    pub fn lookAt(eye: Vec3, target: Vec3, up: Vec3) Mat4 {
        const f = Vec3.sub(target, eye).normalize();
        const s = Vec3.cross(f, up).normalize();
        const u = Vec3.cross(s, f);

        var result = Mat4.identity();
        result.m[0] = s.x;
        result.m[4] = s.y;
        result.m[8] = s.z;
        result.m[1] = u.x;
        result.m[5] = u.y;
        result.m[9] = u.z;
        result.m[2] = -f.x;
        result.m[6] = -f.y;
        result.m[10] = -f.z;
        result.m[12] = -Vec3.dot(s, eye);
        result.m[13] = -Vec3.dot(u, eye);
        result.m[14] = Vec3.dot(f, eye);
        return result;
    }

    /// Transpose matrix
    pub fn transpose(self: Mat4) Mat4 {
        return .{ .m = [_]f32{
            self.m[0], self.m[4], self.m[8],  self.m[12],
            self.m[1], self.m[5], self.m[9],  self.m[13],
            self.m[2], self.m[6], self.m[10], self.m[14],
            self.m[3], self.m[7], self.m[11], self.m[15],
        } };
    }
};

// ============================================================================
// Quaternion
// ============================================================================

pub const Quat = struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,

    pub fn identity() Quat {
        return .{ .x = 0.0, .y = 0.0, .z = 0.0, .w = 1.0 };
    }

    pub fn init(x: f32, y: f32, z: f32, w: f32) Quat {
        return .{ .x = x, .y = y, .z = z, .w = w };
    }

    /// Create quaternion from Euler angles (radians, YXZ order)
    pub fn fromEuler(yaw: f32, pitch: f32, roll: f32) Quat {
        const cy = @cos(yaw * 0.5);
        const sy = @sin(yaw * 0.5);
        const cp = @cos(pitch * 0.5);
        const sp = @sin(pitch * 0.5);
        const cr = @cos(roll * 0.5);
        const sr = @sin(roll * 0.5);

        return .{
            .x = sr * cp * cy - cr * sp * sy,
            .y = cr * sp * cy + sr * cp * sy,
            .z = cr * cp * sy - sr * sp * cy,
            .w = cr * cp * cy + sr * sp * sy,
        };
    }

    /// Convert quaternion to Euler angles
    pub fn toEuler(self: Quat) Vec3 {
        // Yaw (Y-axis rotation)
        const sinr_cosp = 2.0 * (self.w * self.x + self.y * self.z);
        const cosr_cosp = 1.0 - 2.0 * (self.x * self.x + self.y * self.y);
        const roll = math.atan2(f32, sinr_cosp, cosr_cosp);

        // Pitch (X-axis rotation)
        const sinp = 2.0 * (self.w * self.y - self.z * self.x);
        const pitch = if (@abs(sinp) >= 1.0)
            math.copysign(math.pi / 2.0, sinp)
        else
            math.asin(sinp);

        // Roll (Z-axis rotation)
        const siny_cosp = 2.0 * (self.w * self.z + self.x * self.y);
        const cosy_cosp = 1.0 - 2.0 * (self.y * self.y + self.z * self.z);
        const yaw = math.atan2(f32, siny_cosp, cosy_cosp);

        return Vec3.init(pitch, yaw, roll);
    }

    /// Quaternion multiplication
    pub fn multiply(a: Quat, b: Quat) Quat {
        return .{
            .x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            .y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            .z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
            .w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
        };
    }

    /// Normalize quaternion
    pub fn normalize(self: Quat) Quat {
        const len = @sqrt(self.x * self.x + self.y * self.y + self.z * self.z + self.w * self.w);
        if (len == 0.0) return self;
        return .{
            .x = self.x / len,
            .y = self.y / len,
            .z = self.z / len,
            .w = self.w / len,
        };
    }

    /// Spherical linear interpolation
    pub fn slerp(a: Quat, b: Quat, t: f32) Quat {
        var dot_product = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;

        var b_adjusted = b;
        if (dot_product < 0.0) {
            b_adjusted.x = -b.x;
            b_adjusted.y = -b.y;
            b_adjusted.z = -b.z;
            b_adjusted.w = -b.w;
            dot_product = -dot_product;
        }

        if (dot_product > 0.9995) {
            // Linear interpolation for very close quaternions
            return .{
                .x = a.x + (b_adjusted.x - a.x) * t,
                .y = a.y + (b_adjusted.y - a.y) * t,
                .z = a.z + (b_adjusted.z - a.z) * t,
                .w = a.w + (b_adjusted.w - a.w) * t,
            }.normalize();
        }

        const theta = math.acos(dot_product);
        const sin_theta = @sin(theta);
        const scale_a = @sin((1.0 - t) * theta) / sin_theta;
        const scale_b = @sin(t * theta) / sin_theta;

        return .{
            .x = a.x * scale_a + b_adjusted.x * scale_b,
            .y = a.y * scale_a + b_adjusted.y * scale_b,
            .z = a.z * scale_a + b_adjusted.z * scale_b,
            .w = a.w * scale_a + b_adjusted.w * scale_b,
        };
    }

    /// Rotate vector by quaternion
    pub fn rotateVec3(self: Quat, v: Vec3) Vec3 {
        const qv = Vec3.init(self.x, self.y, self.z);
        const uv = Vec3.cross(qv, v);
        const uuv = Vec3.cross(qv, uv);
        const uv_scaled = uv.mul(2.0 * self.w);
        const uuv_scaled = uuv.mul(2.0);
        return Vec3.add(v, Vec3.add(uv_scaled, uuv_scaled));
    }
};

// ============================================================================
// Collision Primitives
// ============================================================================

/// Axis-Aligned Bounding Box
pub const AABB = struct {
    min: Vec3,
    max: Vec3,

    pub fn init(min: Vec3, max: Vec3) AABB {
        return .{ .min = min, .max = max };
    }

    pub fn fromCenterSize(center_point: Vec3, bbox_size: Vec3) AABB {
        const half_size = bbox_size.mul(0.5);
        return .{
            .min = Vec3.sub(center_point, half_size),
            .max = Vec3.add(center_point, half_size),
        };
    }

    pub fn center(self: AABB) Vec3 {
        return Vec3.init(
            (self.min.x + self.max.x) * 0.5,
            (self.min.y + self.max.y) * 0.5,
            (self.min.z + self.max.z) * 0.5,
        );
    }

    pub fn size(self: AABB) Vec3 {
        return Vec3.sub(self.max, self.min);
    }

    pub fn containsPoint(self: AABB, point: Vec3) bool {
        return point.x >= self.min.x and point.x <= self.max.x and
               point.y >= self.min.y and point.y <= self.max.y and
               point.z >= self.min.z and point.z <= self.max.z;
    }

    pub fn intersects(self: AABB, other: AABB) bool {
        return self.min.x <= other.max.x and self.max.x >= other.min.x and
               self.min.y <= other.max.y and self.max.y >= other.min.y and
               self.min.z <= other.max.z and self.max.z >= other.min.z;
    }
};

/// Sphere
pub const Sphere = struct {
    center: Vec3,
    radius: f32,

    pub fn init(center: Vec3, radius: f32) Sphere {
        return .{ .center = center, .radius = radius };
    }

    pub fn containsPoint(self: Sphere, point: Vec3) bool {
        const dist_sq = Vec3.distanceSquared(self.center, point);
        return dist_sq <= self.radius * self.radius;
    }

    pub fn intersects(self: Sphere, other: Sphere) bool {
        const dist_sq = Vec3.distanceSquared(self.center, other.center);
        const radius_sum = self.radius + other.radius;
        return dist_sq <= radius_sum * radius_sum;
    }
};

/// Ray
pub const Ray = struct {
    origin: Vec3,
    direction: Vec3, // Should be normalized

    pub fn init(origin: Vec3, direction: Vec3) Ray {
        return .{ .origin = origin, .direction = direction.normalize() };
    }

    pub fn pointAt(self: Ray, t: f32) Vec3 {
        return Vec3.add(self.origin, self.direction.mul(t));
    }

    /// Ray-Sphere intersection (returns t value, or null if no intersection)
    pub fn intersectSphere(self: Ray, sphere: Sphere) ?f32 {
        const oc = Vec3.sub(self.origin, sphere.center);
        const a = Vec3.dot(self.direction, self.direction);
        const b = 2.0 * Vec3.dot(oc, self.direction);
        const c = Vec3.dot(oc, oc) - sphere.radius * sphere.radius;
        const discriminant = b * b - 4.0 * a * c;

        if (discriminant < 0.0) return null;

        const t = (-b - @sqrt(discriminant)) / (2.0 * a);
        if (t < 0.0) return null;
        return t;
    }

    /// Ray-AABB intersection (returns t value, or null if no intersection)
    pub fn intersectAABB(self: Ray, aabb: AABB) ?f32 {
        var tmin: f32 = 0.0;
        var tmax: f32 = math.inf(f32);

        // X axis
        if (@abs(self.direction.x) > 0.0001) {
            const t1 = (aabb.min.x - self.origin.x) / self.direction.x;
            const t2 = (aabb.max.x - self.origin.x) / self.direction.x;
            tmin = @max(tmin, @min(t1, t2));
            tmax = @min(tmax, @max(t1, t2));
        }

        // Y axis
        if (@abs(self.direction.y) > 0.0001) {
            const t1 = (aabb.min.y - self.origin.y) / self.direction.y;
            const t2 = (aabb.max.y - self.origin.y) / self.direction.y;
            tmin = @max(tmin, @min(t1, t2));
            tmax = @min(tmax, @max(t1, t2));
        }

        // Z axis
        if (@abs(self.direction.z) > 0.0001) {
            const t1 = (aabb.min.z - self.origin.z) / self.direction.z;
            const t2 = (aabb.max.z - self.origin.z) / self.direction.z;
            tmin = @max(tmin, @min(t1, t2));
            tmax = @min(tmax, @max(t1, t2));
        }

        if (tmax < tmin) return null;
        return tmin;
    }
};

// ============================================================================
// Utility Functions
// ============================================================================

pub fn degreesToRadians(degrees: f32) f32 {
    return degrees * (math.pi / 180.0);
}

pub fn radiansToDegrees(radians: f32) f32 {
    return radians * (180.0 / math.pi);
}

pub fn clamp(value: f32, min_val: f32, max_val: f32) f32 {
    return @max(min_val, @min(max_val, value));
}

pub fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}
