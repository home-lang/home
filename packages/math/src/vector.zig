// Home Programming Language - Vector Math
// 2D, 3D, and 4D vector types and operations

const std = @import("std");
const basic = @import("basic.zig");

// 2D Vector
pub fn Vec2(comptime T: type) type {
    return struct {
        x: T,
        y: T,

        const Self = @This();

        pub fn init(x: T, y: T) Self {
            return .{ .x = x, .y = y };
        }

        pub fn zero() Self {
            return .{ .x = 0, .y = 0 };
        }

        pub fn one() Self {
            return .{ .x = 1, .y = 1 };
        }

        // Arithmetic
        pub fn add(self: Self, other: Self) Self {
            return .{ .x = self.x + other.x, .y = self.y + other.y };
        }

        pub fn sub(self: Self, other: Self) Self {
            return .{ .x = self.x - other.x, .y = self.y - other.y };
        }

        pub fn mul(self: Self, other: Self) Self {
            return .{ .x = self.x * other.x, .y = self.y * other.y };
        }

        pub fn div(self: Self, other: Self) Self {
            return .{ .x = self.x / other.x, .y = self.y / other.y };
        }

        pub fn scale(self: Self, scalar: T) Self {
            return .{ .x = self.x * scalar, .y = self.y * scalar };
        }

        pub fn neg(self: Self) Self {
            return .{ .x = -self.x, .y = -self.y };
        }

        // Dot product
        pub fn dot(self: Self, other: Self) T {
            return self.x * other.x + self.y * other.y;
        }

        // Cross product (returns scalar for 2D)
        pub fn cross(self: Self, other: Self) T {
            return self.x * other.y - self.y * other.x;
        }

        // Length operations
        pub fn lengthSq(self: Self) T {
            return self.x * self.x + self.y * self.y;
        }

        pub fn length(self: Self) T {
            return @sqrt(self.lengthSq());
        }

        pub fn normalize(self: Self) Self {
            const len = self.length();
            return .{ .x = self.x / len, .y = self.y / len };
        }

        pub fn distance(self: Self, other: Self) T {
            return self.sub(other).length();
        }

        // Angle operations
        pub fn angle(self: Self) T {
            return std.math.atan2(self.y, self.x);
        }

        pub fn angleTo(self: Self, other: Self) T {
            const d = self.dot(other);
            const l = self.length() * other.length();
            return std.math.acos(d / l);
        }

        // Linear interpolation
        pub fn lerp(self: Self, other: Self, t: T) Self {
            return .{
                .x = self.x + (other.x - self.x) * t,
                .y = self.y + (other.y - self.y) * t,
            };
        }

        // Reflection
        pub fn reflect(self: Self, normal: Self) Self {
            const d = self.dot(normal);
            return self.sub(normal.scale(2.0 * d));
        }
    };
}

// 3D Vector
pub fn Vec3(comptime T: type) type {
    return struct {
        x: T,
        y: T,
        z: T,

        const Self = @This();

        pub fn init(x: T, y: T, z: T) Self {
            return .{ .x = x, .y = y, .z = z };
        }

        pub fn zero() Self {
            return .{ .x = 0, .y = 0, .z = 0 };
        }

        pub fn one() Self {
            return .{ .x = 1, .y = 1, .z = 1 };
        }

        // Arithmetic
        pub fn add(self: Self, other: Self) Self {
            return .{ .x = self.x + other.x, .y = self.y + other.y, .z = self.z + other.z };
        }

        pub fn sub(self: Self, other: Self) Self {
            return .{ .x = self.x - other.x, .y = self.y - other.y, .z = self.z - other.z };
        }

        pub fn mul(self: Self, other: Self) Self {
            return .{ .x = self.x * other.x, .y = self.y * other.y, .z = self.z * other.z };
        }

        pub fn div(self: Self, other: Self) Self {
            return .{ .x = self.x / other.x, .y = self.y / other.y, .z = self.z / other.z };
        }

        pub fn scale(self: Self, scalar: T) Self {
            return .{ .x = self.x * scalar, .y = self.y * scalar, .z = self.z * scalar };
        }

        pub fn neg(self: Self) Self {
            return .{ .x = -self.x, .y = -self.y, .z = -self.z };
        }

        // Dot product
        pub fn dot(self: Self, other: Self) T {
            return self.x * other.x + self.y * other.y + self.z * other.z;
        }

        // Cross product
        pub fn cross(self: Self, other: Self) Self {
            return .{
                .x = self.y * other.z - self.z * other.y,
                .y = self.z * other.x - self.x * other.z,
                .z = self.x * other.y - self.y * other.x,
            };
        }

        // Length operations
        pub fn lengthSq(self: Self) T {
            return self.x * self.x + self.y * self.y + self.z * self.z;
        }

        pub fn length(self: Self) T {
            return @sqrt(self.lengthSq());
        }

        pub fn normalize(self: Self) Self {
            const len = self.length();
            return .{ .x = self.x / len, .y = self.y / len, .z = self.z / len };
        }

        pub fn distance(self: Self, other: Self) T {
            return self.sub(other).length();
        }

        // Linear interpolation
        pub fn lerp(self: Self, other: Self, t: T) Self {
            return .{
                .x = self.x + (other.x - self.x) * t,
                .y = self.y + (other.y - self.y) * t,
                .z = self.z + (other.z - self.z) * t,
            };
        }

        // Reflection
        pub fn reflect(self: Self, normal: Self) Self {
            const d = self.dot(normal);
            return self.sub(normal.scale(2.0 * d));
        }

        // Project onto another vector
        pub fn project(self: Self, onto: Self) Self {
            const d = self.dot(onto);
            const len_sq = onto.lengthSq();
            return onto.scale(d / len_sq);
        }
    };
}

// 4D Vector
pub fn Vec4(comptime T: type) type {
    return struct {
        x: T,
        y: T,
        z: T,
        w: T,

        const Self = @This();

        pub fn init(x: T, y: T, z: T, w: T) Self {
            return .{ .x = x, .y = y, .z = z, .w = w };
        }

        pub fn zero() Self {
            return .{ .x = 0, .y = 0, .z = 0, .w = 0 };
        }

        pub fn one() Self {
            return .{ .x = 1, .y = 1, .z = 1, .w = 1 };
        }

        // Arithmetic
        pub fn add(self: Self, other: Self) Self {
            return .{
                .x = self.x + other.x,
                .y = self.y + other.y,
                .z = self.z + other.z,
                .w = self.w + other.w,
            };
        }

        pub fn sub(self: Self, other: Self) Self {
            return .{
                .x = self.x - other.x,
                .y = self.y - other.y,
                .z = self.z - other.z,
                .w = self.w - other.w,
            };
        }

        pub fn mul(self: Self, other: Self) Self {
            return .{
                .x = self.x * other.x,
                .y = self.y * other.y,
                .z = self.z * other.z,
                .w = self.w * other.w,
            };
        }

        pub fn div(self: Self, other: Self) Self {
            return .{
                .x = self.x / other.x,
                .y = self.y / other.y,
                .z = self.z / other.z,
                .w = self.w / other.w,
            };
        }

        pub fn scale(self: Self, scalar: T) Self {
            return .{
                .x = self.x * scalar,
                .y = self.y * scalar,
                .z = self.z * scalar,
                .w = self.w * scalar,
            };
        }

        pub fn neg(self: Self) Self {
            return .{ .x = -self.x, .y = -self.y, .z = -self.z, .w = -self.w };
        }

        // Dot product
        pub fn dot(self: Self, other: Self) T {
            return self.x * other.x + self.y * other.y + self.z * other.z + self.w * other.w;
        }

        // Length operations
        pub fn lengthSq(self: Self) T {
            return self.x * self.x + self.y * self.y + self.z * self.z + self.w * self.w;
        }

        pub fn length(self: Self) T {
            return @sqrt(self.lengthSq());
        }

        pub fn normalize(self: Self) Self {
            const len = self.length();
            return .{
                .x = self.x / len,
                .y = self.y / len,
                .z = self.z / len,
                .w = self.w / len,
            };
        }

        pub fn distance(self: Self, other: Self) T {
            return self.sub(other).length();
        }

        // Linear interpolation
        pub fn lerp(self: Self, other: Self, t: T) Self {
            return .{
                .x = self.x + (other.x - self.x) * t,
                .y = self.y + (other.y - self.y) * t,
                .z = self.z + (other.z - self.z) * t,
                .w = self.w + (other.w - self.w) * t,
            };
        }
    };
}

test "vec2 basic operations" {
    const testing = std.testing;
    const V2 = Vec2(f32);

    const a = V2.init(1.0, 2.0);
    const b = V2.init(3.0, 4.0);

    const sum = a.add(b);
    try testing.expectEqual(@as(f32, 4.0), sum.x);
    try testing.expectEqual(@as(f32, 6.0), sum.y);

    const diff = b.sub(a);
    try testing.expectEqual(@as(f32, 2.0), diff.x);
    try testing.expectEqual(@as(f32, 2.0), diff.y);

    const scaled = a.scale(2.0);
    try testing.expectEqual(@as(f32, 2.0), scaled.x);
    try testing.expectEqual(@as(f32, 4.0), scaled.y);
}

test "vec2 dot and cross" {
    const testing = std.testing;
    const V2 = Vec2(f32);

    const a = V2.init(1.0, 0.0);
    const b = V2.init(0.0, 1.0);

    try testing.expectEqual(@as(f32, 0.0), a.dot(b));
    try testing.expectEqual(@as(f32, 1.0), a.cross(b));
}

test "vec2 length and normalize" {
    const testing = std.testing;
    const V2 = Vec2(f32);

    const v = V2.init(3.0, 4.0);
    try testing.expectApproxEqAbs(@as(f32, 5.0), v.length(), 0.0001);

    const normalized = v.normalize();
    try testing.expectApproxEqAbs(@as(f32, 1.0), normalized.length(), 0.0001);
}

test "vec3 basic operations" {
    const testing = std.testing;
    const V3 = Vec3(f32);

    const a = V3.init(1.0, 2.0, 3.0);
    const b = V3.init(4.0, 5.0, 6.0);

    const sum = a.add(b);
    try testing.expectEqual(@as(f32, 5.0), sum.x);
    try testing.expectEqual(@as(f32, 7.0), sum.y);
    try testing.expectEqual(@as(f32, 9.0), sum.z);
}

test "vec3 cross product" {
    const testing = std.testing;
    const V3 = Vec3(f32);

    const a = V3.init(1.0, 0.0, 0.0);
    const b = V3.init(0.0, 1.0, 0.0);
    const c = a.cross(b);

    try testing.expectEqual(@as(f32, 0.0), c.x);
    try testing.expectEqual(@as(f32, 0.0), c.y);
    try testing.expectEqual(@as(f32, 1.0), c.z);
}

test "vec3 length" {
    const testing = std.testing;
    const V3 = Vec3(f32);

    const v = V3.init(2.0, 3.0, 6.0);
    try testing.expectApproxEqAbs(@as(f32, 7.0), v.length(), 0.0001);
}

test "vec4 basic operations" {
    const testing = std.testing;
    const V4 = Vec4(f32);

    const a = V4.init(1.0, 2.0, 3.0, 4.0);
    const b = V4.init(5.0, 6.0, 7.0, 8.0);

    const sum = a.add(b);
    try testing.expectEqual(@as(f32, 6.0), sum.x);
    try testing.expectEqual(@as(f32, 8.0), sum.y);
    try testing.expectEqual(@as(f32, 10.0), sum.z);
    try testing.expectEqual(@as(f32, 12.0), sum.w);
}

test "vec4 dot product" {
    const testing = std.testing;
    const V4 = Vec4(f32);

    const a = V4.init(1.0, 2.0, 3.0, 4.0);
    const b = V4.init(2.0, 3.0, 4.0, 5.0);
    const result = a.dot(b);

    // 1*2 + 2*3 + 3*4 + 4*5 = 2 + 6 + 12 + 20 = 40
    try testing.expectEqual(@as(f32, 40.0), result);
}

test "vec lerp" {
    const testing = std.testing;
    const V3 = Vec3(f32);

    const a = V3.init(0.0, 0.0, 0.0);
    const b = V3.init(10.0, 10.0, 10.0);
    const mid = a.lerp(b, 0.5);

    try testing.expectApproxEqAbs(@as(f32, 5.0), mid.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 5.0), mid.y, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 5.0), mid.z, 0.0001);
}
