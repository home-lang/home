// Home Programming Language - Matrix Operations
// 2x2, 3x3, and 4x4 matrix types and operations

const std = @import("std");
const basic = @import("basic.zig");
const vector = @import("vector.zig");

// 2x2 Matrix
pub fn Mat2(comptime T: type) type {
    return struct {
        data: [4]T, // Column-major order

        const Self = @This();

        pub fn init(m00: T, m01: T, m10: T, m11: T) Self {
            return .{ .data = .{ m00, m10, m01, m11 } };
        }

        pub fn identity() Self {
            return .{ .data = .{ 1, 0, 0, 1 } };
        }

        pub fn zero() Self {
            return .{ .data = .{ 0, 0, 0, 0 } };
        }

        pub fn get(self: Self, row: usize, col: usize) T {
            return self.data[col * 2 + row];
        }

        pub fn set(self: *Self, row: usize, col: usize, value: T) void {
            self.data[col * 2 + row] = value;
        }

        // Matrix addition
        pub fn add(self: Self, other: Self) Self {
            var result = self;
            for (0..4) |i| {
                result.data[i] += other.data[i];
            }
            return result;
        }

        // Matrix subtraction
        pub fn sub(self: Self, other: Self) Self {
            var result = self;
            for (0..4) |i| {
                result.data[i] -= other.data[i];
            }
            return result;
        }

        // Scalar multiplication
        pub fn scale(self: Self, scalar: T) Self {
            var result = self;
            for (0..4) |i| {
                result.data[i] *= scalar;
            }
            return result;
        }

        // Matrix multiplication
        pub fn mul(self: Self, other: Self) Self {
            var result: Self = undefined;
            for (0..2) |col| {
                for (0..2) |row| {
                    var sum: T = 0;
                    for (0..2) |k| {
                        sum += self.get(row, k) * other.get(k, col);
                    }
                    result.set(row, col, sum);
                }
            }
            return result;
        }

        // Matrix-vector multiplication
        pub fn mulVec(self: Self, v: vector.Vec2(T)) vector.Vec2(T) {
            return vector.Vec2(T).init(
                self.get(0, 0) * v.x + self.get(0, 1) * v.y,
                self.get(1, 0) * v.x + self.get(1, 1) * v.y,
            );
        }

        // Transpose
        pub fn transpose(self: Self) Self {
            return init(
                self.get(0, 0),
                self.get(1, 0),
                self.get(0, 1),
                self.get(1, 1),
            );
        }

        // Determinant
        pub fn determinant(self: Self) T {
            return self.get(0, 0) * self.get(1, 1) - self.get(0, 1) * self.get(1, 0);
        }

        // Inverse
        pub fn inverse(self: Self) ?Self {
            const det = self.determinant();
            if (@abs(det) < 1e-10) return null;

            const inv_det = 1.0 / det;
            return init(
                self.get(1, 1) * inv_det,
                -self.get(0, 1) * inv_det,
                -self.get(1, 0) * inv_det,
                self.get(0, 0) * inv_det,
            );
        }
    };
}

// 3x3 Matrix
pub fn Mat3(comptime T: type) type {
    return struct {
        data: [9]T, // Column-major order

        const Self = @This();

        pub fn init(
            m00: T,
            m01: T,
            m02: T,
            m10: T,
            m11: T,
            m12: T,
            m20: T,
            m21: T,
            m22: T,
        ) Self {
            return .{ .data = .{ m00, m10, m20, m01, m11, m21, m02, m12, m22 } };
        }

        pub fn identity() Self {
            return .{ .data = .{ 1, 0, 0, 0, 1, 0, 0, 0, 1 } };
        }

        pub fn zero() Self {
            return .{ .data = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0 } };
        }

        pub fn get(self: Self, row: usize, col: usize) T {
            return self.data[col * 3 + row];
        }

        pub fn set(self: *Self, row: usize, col: usize, value: T) void {
            self.data[col * 3 + row] = value;
        }

        // Matrix addition
        pub fn add(self: Self, other: Self) Self {
            var result = self;
            for (0..9) |i| {
                result.data[i] += other.data[i];
            }
            return result;
        }

        // Matrix subtraction
        pub fn sub(self: Self, other: Self) Self {
            var result = self;
            for (0..9) |i| {
                result.data[i] -= other.data[i];
            }
            return result;
        }

        // Scalar multiplication
        pub fn scale(self: Self, scalar: T) Self {
            var result = self;
            for (0..9) |i| {
                result.data[i] *= scalar;
            }
            return result;
        }

        // Matrix multiplication
        pub fn mul(self: Self, other: Self) Self {
            var result: Self = undefined;
            for (0..3) |col| {
                for (0..3) |row| {
                    var sum: T = 0;
                    for (0..3) |k| {
                        sum += self.get(row, k) * other.get(k, col);
                    }
                    result.set(row, col, sum);
                }
            }
            return result;
        }

        // Matrix-vector multiplication
        pub fn mulVec(self: Self, v: vector.Vec3(T)) vector.Vec3(T) {
            return vector.Vec3(T).init(
                self.get(0, 0) * v.x + self.get(0, 1) * v.y + self.get(0, 2) * v.z,
                self.get(1, 0) * v.x + self.get(1, 1) * v.y + self.get(1, 2) * v.z,
                self.get(2, 0) * v.x + self.get(2, 1) * v.y + self.get(2, 2) * v.z,
            );
        }

        // Transpose
        pub fn transpose(self: Self) Self {
            return init(
                self.get(0, 0),
                self.get(1, 0),
                self.get(2, 0),
                self.get(0, 1),
                self.get(1, 1),
                self.get(2, 1),
                self.get(0, 2),
                self.get(1, 2),
                self.get(2, 2),
            );
        }

        // Determinant
        pub fn determinant(self: Self) T {
            const a = self.get(0, 0);
            const b = self.get(0, 1);
            const c = self.get(0, 2);
            const d = self.get(1, 0);
            const e = self.get(1, 1);
            const f = self.get(1, 2);
            const g = self.get(2, 0);
            const h = self.get(2, 1);
            const i = self.get(2, 2);

            return a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
        }

        // Inverse
        pub fn inverse(self: Self) ?Self {
            const det = self.determinant();
            if (@abs(det) < 1e-10) return null;

            const inv_det = 1.0 / det;

            const a = self.get(0, 0);
            const b = self.get(0, 1);
            const c = self.get(0, 2);
            const d = self.get(1, 0);
            const e = self.get(1, 1);
            const f = self.get(1, 2);
            const g = self.get(2, 0);
            const h = self.get(2, 1);
            const i = self.get(2, 2);

            return init(
                (e * i - f * h) * inv_det,
                (c * h - b * i) * inv_det,
                (b * f - c * e) * inv_det,
                (f * g - d * i) * inv_det,
                (a * i - c * g) * inv_det,
                (c * d - a * f) * inv_det,
                (d * h - e * g) * inv_det,
                (b * g - a * h) * inv_det,
                (a * e - b * d) * inv_det,
            );
        }
    };
}

// 4x4 Matrix
pub fn Mat4(comptime T: type) type {
    return struct {
        data: [16]T, // Column-major order

        const Self = @This();

        pub fn init(
            m00: T,
            m01: T,
            m02: T,
            m03: T,
            m10: T,
            m11: T,
            m12: T,
            m13: T,
            m20: T,
            m21: T,
            m22: T,
            m23: T,
            m30: T,
            m31: T,
            m32: T,
            m33: T,
        ) Self {
            return .{ .data = .{
                m00, m10, m20, m30,
                m01, m11, m21, m31,
                m02, m12, m22, m32,
                m03, m13, m23, m33,
            } };
        }

        pub fn identity() Self {
            return .{ .data = .{
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                0, 0, 0, 1,
            } };
        }

        pub fn zero() Self {
            return .{ .data = .{
                0, 0, 0, 0,
                0, 0, 0, 0,
                0, 0, 0, 0,
                0, 0, 0, 0,
            } };
        }

        pub fn get(self: Self, row: usize, col: usize) T {
            return self.data[col * 4 + row];
        }

        pub fn set(self: *Self, row: usize, col: usize, value: T) void {
            self.data[col * 4 + row] = value;
        }

        // Matrix multiplication
        pub fn mul(self: Self, other: Self) Self {
            var result: Self = undefined;
            for (0..4) |col| {
                for (0..4) |row| {
                    var sum: T = 0;
                    for (0..4) |k| {
                        sum += self.get(row, k) * other.get(k, col);
                    }
                    result.set(row, col, sum);
                }
            }
            return result;
        }

        // Matrix-vector multiplication
        pub fn mulVec(self: Self, v: vector.Vec4(T)) vector.Vec4(T) {
            return vector.Vec4(T).init(
                self.get(0, 0) * v.x + self.get(0, 1) * v.y + self.get(0, 2) * v.z + self.get(0, 3) * v.w,
                self.get(1, 0) * v.x + self.get(1, 1) * v.y + self.get(1, 2) * v.z + self.get(1, 3) * v.w,
                self.get(2, 0) * v.x + self.get(2, 1) * v.y + self.get(2, 2) * v.z + self.get(2, 3) * v.w,
                self.get(3, 0) * v.x + self.get(3, 1) * v.y + self.get(3, 2) * v.z + self.get(3, 3) * v.w,
            );
        }

        // Transpose
        pub fn transpose(self: Self) Self {
            return init(
                self.get(0, 0),
                self.get(1, 0),
                self.get(2, 0),
                self.get(3, 0),
                self.get(0, 1),
                self.get(1, 1),
                self.get(2, 1),
                self.get(3, 1),
                self.get(0, 2),
                self.get(1, 2),
                self.get(2, 2),
                self.get(3, 2),
                self.get(0, 3),
                self.get(1, 3),
                self.get(2, 3),
                self.get(3, 3),
            );
        }

        // Translation matrix
        pub fn translation(x: T, y: T, z: T) Self {
            return init(
                1, 0, 0, x,
                0, 1, 0, y,
                0, 0, 1, z,
                0, 0, 0, 1,
            );
        }

        // Scale matrix
        pub fn scaling(x: T, y: T, z: T) Self {
            return init(
                x, 0, 0, 0,
                0, y, 0, 0,
                0, 0, z, 0,
                0, 0, 0, 1,
            );
        }

        // Rotation around X axis
        pub fn rotationX(angle: T) Self {
            const c = @cos(angle);
            const s = @sin(angle);
            return init(
                1, 0,  0, 0,
                0, c, -s, 0,
                0, s,  c, 0,
                0, 0,  0, 1,
            );
        }

        // Rotation around Y axis
        pub fn rotationY(angle: T) Self {
            const c = @cos(angle);
            const s = @sin(angle);
            return init(
                c,  0, s, 0,
                0,  1, 0, 0,
                -s, 0, c, 0,
                0,  0, 0, 1,
            );
        }

        // Rotation around Z axis
        pub fn rotationZ(angle: T) Self {
            const c = @cos(angle);
            const s = @sin(angle);
            return init(
                c, -s, 0, 0,
                s,  c, 0, 0,
                0,  0, 1, 0,
                0,  0, 0, 1,
            );
        }

        // Perspective projection
        pub fn perspective(fov: T, aspect: T, near: T, far: T) Self {
            const tan_half_fov = @tan(fov / 2.0);
            return init(
                1.0 / (aspect * tan_half_fov), 0, 0, 0,
                0, 1.0 / tan_half_fov, 0, 0,
                0, 0, -(far + near) / (far - near), -(2.0 * far * near) / (far - near),
                0, 0, -1, 0,
            );
        }

        // Orthographic projection
        pub fn orthographic(left: T, right: T, bottom: T, top: T, near: T, far: T) Self {
            return init(
                2.0 / (right - left), 0, 0, -(right + left) / (right - left),
                0, 2.0 / (top - bottom), 0, -(top + bottom) / (top - bottom),
                0, 0, -2.0 / (far - near), -(far + near) / (far - near),
                0, 0, 0, 1,
            );
        }
    };
}

test "mat2 identity" {
    const testing = std.testing;
    const M2 = Mat2(f32);

    const m = M2.identity();
    try testing.expectEqual(@as(f32, 1.0), m.get(0, 0));
    try testing.expectEqual(@as(f32, 0.0), m.get(0, 1));
    try testing.expectEqual(@as(f32, 0.0), m.get(1, 0));
    try testing.expectEqual(@as(f32, 1.0), m.get(1, 1));
}

test "mat2 multiplication" {
    const testing = std.testing;
    const M2 = Mat2(f32);

    const a = M2.init(1, 2, 3, 4);
    const b = M2.init(5, 6, 7, 8);
    const c = a.mul(b);

    try testing.expectEqual(@as(f32, 19.0), c.get(0, 0));
    try testing.expectEqual(@as(f32, 22.0), c.get(0, 1));
    try testing.expectEqual(@as(f32, 43.0), c.get(1, 0));
    try testing.expectEqual(@as(f32, 50.0), c.get(1, 1));
}

test "mat2 determinant" {
    const testing = std.testing;
    const M2 = Mat2(f32);

    const m = M2.init(1, 2, 3, 4);
    const det = m.determinant();

    try testing.expectApproxEqAbs(@as(f32, -2.0), det, 0.0001);
}

test "mat3 identity" {
    const testing = std.testing;
    const M3 = Mat3(f32);

    const m = M3.identity();
    try testing.expectEqual(@as(f32, 1.0), m.get(0, 0));
    try testing.expectEqual(@as(f32, 1.0), m.get(1, 1));
    try testing.expectEqual(@as(f32, 1.0), m.get(2, 2));
    try testing.expectEqual(@as(f32, 0.0), m.get(0, 1));
}

test "mat3 transpose" {
    const testing = std.testing;
    const M3 = Mat3(f32);

    const m = M3.init(1, 2, 3, 4, 5, 6, 7, 8, 9);
    const t = m.transpose();

    try testing.expectEqual(@as(f32, 1.0), t.get(0, 0));
    try testing.expectEqual(@as(f32, 4.0), t.get(0, 1));
    try testing.expectEqual(@as(f32, 7.0), t.get(0, 2));
    try testing.expectEqual(@as(f32, 2.0), t.get(1, 0));
}

test "mat4 identity" {
    const testing = std.testing;
    const M4 = Mat4(f32);

    const m = M4.identity();
    try testing.expectEqual(@as(f32, 1.0), m.get(0, 0));
    try testing.expectEqual(@as(f32, 1.0), m.get(1, 1));
    try testing.expectEqual(@as(f32, 1.0), m.get(2, 2));
    try testing.expectEqual(@as(f32, 1.0), m.get(3, 3));
}

test "mat4 translation" {
    const testing = std.testing;
    const M4 = Mat4(f32);

    const m = M4.translation(5.0, 10.0, 15.0);
    try testing.expectEqual(@as(f32, 5.0), m.get(0, 3));
    try testing.expectEqual(@as(f32, 10.0), m.get(1, 3));
    try testing.expectEqual(@as(f32, 15.0), m.get(2, 3));
}

test "mat4 scaling" {
    const testing = std.testing;
    const M4 = Mat4(f32);

    const m = M4.scaling(2.0, 3.0, 4.0);
    try testing.expectEqual(@as(f32, 2.0), m.get(0, 0));
    try testing.expectEqual(@as(f32, 3.0), m.get(1, 1));
    try testing.expectEqual(@as(f32, 4.0), m.get(2, 2));
}
