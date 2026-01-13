// Home Programming Language - Transform System
// 3D transformation hierarchy with position, rotation, scale
// Essential for scene graph and object hierarchies in games

const std = @import("std");
const vector = @import("vector.zig");
const matrix = @import("matrix.zig");
const quaternion = @import("quaternion.zig");

/// 3D Transform with position, rotation (quaternion), and scale
pub fn Transform(comptime T: type) type {
    return struct {
        position: vector.Vec3(T),
        rotation: quaternion.Quat(T),
        scale: vector.Vec3(T),

        const Self = @This();
        const Vec3 = vector.Vec3(T);
        const Quat = quaternion.Quat(T);
        const Mat4 = matrix.Mat4(T);

        /// Create identity transform
        pub fn identity() Self {
            return .{
                .position = Vec3.zero(),
                .rotation = Quat.identity(),
                .scale = Vec3.one(),
            };
        }

        /// Create transform from position only
        pub fn fromPosition(pos: Vec3) Self {
            return .{
                .position = pos,
                .rotation = Quat.identity(),
                .scale = Vec3.one(),
            };
        }

        /// Create transform from position and rotation
        pub fn fromPositionRotation(pos: Vec3, rot: Quat) Self {
            return .{
                .position = pos,
                .rotation = rot,
                .scale = Vec3.one(),
            };
        }

        /// Create transform from all components
        pub fn init(pos: Vec3, rot: Quat, scl: Vec3) Self {
            return .{
                .position = pos,
                .rotation = rot,
                .scale = scl,
            };
        }

        /// Get the local-to-world matrix (TRS order: translate * rotate * scale)
        pub fn toMatrix(self: Self) Mat4 {
            const t = Mat4.translation(self.position.x, self.position.y, self.position.z);
            const r = self.rotation.toMatrix();
            const s = Mat4.scaling(self.scale.x, self.scale.y, self.scale.z);

            // TRS: first scale, then rotate, then translate
            return t.mul(r).mul(s);
        }

        /// Get the world-to-local matrix (inverse transform)
        pub fn toInverseMatrix(self: Self) Mat4 {
            // Inverse of TRS = S^-1 * R^-1 * T^-1
            const inv_s = Mat4.scaling(1.0 / self.scale.x, 1.0 / self.scale.y, 1.0 / self.scale.z);
            const inv_r = self.rotation.conjugate().toMatrix();
            const inv_t = Mat4.translation(-self.position.x, -self.position.y, -self.position.z);

            return inv_s.mul(inv_r).mul(inv_t);
        }

        /// Transform a point from local to world space
        pub fn transformPoint(self: Self, point: Vec3) Vec3 {
            // First scale
            var result = Vec3.init(
                point.x * self.scale.x,
                point.y * self.scale.y,
                point.z * self.scale.z,
            );
            // Then rotate
            result = self.rotation.rotateVector(result);
            // Then translate
            return result.add(self.position);
        }

        /// Transform a direction (ignores translation and scale)
        pub fn transformDirection(self: Self, dir: Vec3) Vec3 {
            return self.rotation.rotateVector(dir);
        }

        /// Transform a vector (applies rotation and scale, no translation)
        pub fn transformVector(self: Self, vec: Vec3) Vec3 {
            const scaled = Vec3.init(
                vec.x * self.scale.x,
                vec.y * self.scale.y,
                vec.z * self.scale.z,
            );
            return self.rotation.rotateVector(scaled);
        }

        /// Inverse transform a point from world to local space
        pub fn inverseTransformPoint(self: Self, point: Vec3) Vec3 {
            // First undo translation
            var result = point.sub(self.position);
            // Then undo rotation
            result = self.rotation.conjugate().rotateVector(result);
            // Then undo scale
            return Vec3.init(
                result.x / self.scale.x,
                result.y / self.scale.y,
                result.z / self.scale.z,
            );
        }

        /// Get forward direction (local +Z in world space)
        pub fn forward(self: Self) Vec3 {
            return self.rotation.rotateVector(Vec3.init(0, 0, 1));
        }

        /// Get right direction (local +X in world space)
        pub fn right(self: Self) Vec3 {
            return self.rotation.rotateVector(Vec3.init(1, 0, 0));
        }

        /// Get up direction (local +Y in world space)
        pub fn up(self: Self) Vec3 {
            return self.rotation.rotateVector(Vec3.init(0, 1, 0));
        }

        /// Look at a target position
        pub fn lookAt(self: *Self, target: Vec3, world_up: Vec3) void {
            const dir = target.sub(self.position).normalize();
            self.rotation = Quat.lookRotation(dir, world_up);
        }

        /// Translate the transform
        pub fn translate(self: *Self, delta: Vec3) void {
            self.position = self.position.add(delta);
        }

        /// Translate in local space
        pub fn translateLocal(self: *Self, delta: Vec3) void {
            self.position = self.position.add(self.transformDirection(delta));
        }

        /// Rotate by euler angles (degrees)
        pub fn rotateEuler(self: *Self, euler: Vec3) void {
            const q = Quat.fromEuler(euler.x, euler.y, euler.z);
            self.rotation = self.rotation.mul(q);
        }

        /// Rotate around an axis
        pub fn rotateAxis(self: *Self, axis: Vec3, angle: T) void {
            const q = Quat.fromAxisAngle(axis, angle);
            self.rotation = self.rotation.mul(q);
        }

        /// Scale uniformly
        pub fn scaleUniform(self: *Self, factor: T) void {
            self.scale = self.scale.scale(factor);
        }

        /// Combine two transforms (self * other)
        /// Result transforms first by other, then by self
        pub fn combine(self: Self, other: Self) Self {
            // Position: transform other's position by self
            const new_pos = self.transformPoint(other.position);

            // Rotation: combine rotations
            const new_rot = self.rotation.mul(other.rotation);

            // Scale: multiply scales
            const new_scale = Vec3.init(
                self.scale.x * other.scale.x,
                self.scale.y * other.scale.y,
                self.scale.z * other.scale.z,
            );

            return .{
                .position = new_pos,
                .rotation = new_rot,
                .scale = new_scale,
            };
        }

        /// Get the inverse transform
        pub fn inverse(self: Self) Self {
            const inv_rot = self.rotation.conjugate();
            const inv_scale = Vec3.init(
                1.0 / self.scale.x,
                1.0 / self.scale.y,
                1.0 / self.scale.z,
            );
            const inv_pos = inv_rot.rotateVector(Vec3.init(
                -self.position.x * inv_scale.x,
                -self.position.y * inv_scale.y,
                -self.position.z * inv_scale.z,
            ));

            return .{
                .position = inv_pos,
                .rotation = inv_rot,
                .scale = inv_scale,
            };
        }

        /// Interpolate between two transforms
        pub fn lerp(self: Self, other: Self, t: T) Self {
            return .{
                .position = self.position.lerp(other.position, t),
                .rotation = self.rotation.slerp(other.rotation, t),
                .scale = self.scale.lerp(other.scale, t),
            };
        }

        /// Check if transforms are approximately equal
        pub fn approxEqual(self: Self, other: Self, epsilon: T) bool {
            const pos_eq = @abs(self.position.x - other.position.x) < epsilon and
                @abs(self.position.y - other.position.y) < epsilon and
                @abs(self.position.z - other.position.z) < epsilon;

            const scale_eq = @abs(self.scale.x - other.scale.x) < epsilon and
                @abs(self.scale.y - other.scale.y) < epsilon and
                @abs(self.scale.z - other.scale.z) < epsilon;

            // For quaternions, q and -q represent the same rotation
            const rot_eq = self.rotation.dot(other.rotation) > (1.0 - epsilon);

            return pos_eq and scale_eq and rot_eq;
        }
    };
}

/// Transform hierarchy node - for scene graphs
pub fn TransformNode(comptime T: type) type {
    return struct {
        local: Transform(T),
        parent: ?*Self,
        children: std.ArrayList(*Self),

        const Self = @This();
        const TransformT = Transform(T);
        const Vec3 = vector.Vec3(T);
        const Mat4 = matrix.Mat4(T);

        /// Create a new transform node
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .local = TransformT.identity(),
                .parent = null,
                .children = std.ArrayList(*Self).init(allocator),
            };
        }

        /// Clean up children list
        pub fn deinit(self: *Self) void {
            self.children.deinit();
        }

        /// Set parent (removes from old parent if any)
        pub fn setParent(self: *Self, new_parent: ?*Self) void {
            // Remove from old parent
            if (self.parent) |old_parent| {
                var i: usize = 0;
                while (i < old_parent.children.items.len) {
                    if (old_parent.children.items[i] == self) {
                        _ = old_parent.children.orderedRemove(i);
                        break;
                    }
                    i += 1;
                }
            }

            // Add to new parent
            self.parent = new_parent;
            if (new_parent) |p| {
                p.children.append(self) catch {};
            }
        }

        /// Get world transform (accumulates parent transforms)
        pub fn getWorldTransform(self: *const Self) TransformT {
            if (self.parent) |p| {
                return p.getWorldTransform().combine(self.local);
            }
            return self.local;
        }

        /// Get world position
        pub fn getWorldPosition(self: *const Self) Vec3 {
            return self.getWorldTransform().position;
        }

        /// Get local-to-world matrix
        pub fn getWorldMatrix(self: *const Self) Mat4 {
            return self.getWorldTransform().toMatrix();
        }

        /// Set world position (adjusts local position based on parent)
        pub fn setWorldPosition(self: *Self, world_pos: Vec3) void {
            if (self.parent) |p| {
                self.local.position = p.getWorldTransform().inverseTransformPoint(world_pos);
            } else {
                self.local.position = world_pos;
            }
        }
    };
}

// Type aliases
pub const Transformf = Transform(f32);
pub const Transformd = Transform(f64);
pub const TransformNodef = TransformNode(f32);
pub const TransformNoded = TransformNode(f64);

// ============================================
// Tests
// ============================================

test "transform identity" {
    const testing = std.testing;
    const T = Transform(f32);
    const V3 = vector.Vec3(f32);

    const t = T.identity();
    const point = V3.init(1, 2, 3);
    const transformed = t.transformPoint(point);

    try testing.expectApproxEqAbs(@as(f32, 1.0), transformed.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 2.0), transformed.y, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 3.0), transformed.z, 0.0001);
}

test "transform translation" {
    const testing = std.testing;
    const T = Transform(f32);
    const V3 = vector.Vec3(f32);

    const t = T.fromPosition(V3.init(10, 0, 0));
    const point = V3.init(0, 0, 0);
    const transformed = t.transformPoint(point);

    try testing.expectApproxEqAbs(@as(f32, 10.0), transformed.x, 0.0001);
}

test "transform scale" {
    const testing = std.testing;
    const T = Transform(f32);
    const V3 = vector.Vec3(f32);
    const Q = quaternion.Quat(f32);

    var t = T.init(V3.zero(), Q.identity(), V3.init(2, 2, 2));
    const point = V3.init(1, 1, 1);
    const transformed = t.transformPoint(point);

    try testing.expectApproxEqAbs(@as(f32, 2.0), transformed.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 2.0), transformed.y, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 2.0), transformed.z, 0.0001);
}

test "transform inverse" {
    const testing = std.testing;
    const T = Transform(f32);
    const V3 = vector.Vec3(f32);
    const Q = quaternion.Quat(f32);

    const t = T.init(
        V3.init(5, 3, 2),
        Q.fromAxisAngle(V3.init(0, 1, 0), 0.5),
        V3.init(2, 2, 2),
    );

    const point = V3.init(1, 2, 3);
    const transformed = t.transformPoint(point);
    const back = t.inverseTransformPoint(transformed);

    try testing.expectApproxEqAbs(point.x, back.x, 0.001);
    try testing.expectApproxEqAbs(point.y, back.y, 0.001);
    try testing.expectApproxEqAbs(point.z, back.z, 0.001);
}

test "transform combine" {
    const testing = std.testing;
    const T = Transform(f32);
    const V3 = vector.Vec3(f32);

    const t1 = T.fromPosition(V3.init(10, 0, 0));
    const t2 = T.fromPosition(V3.init(5, 0, 0));

    const combined = t1.combine(t2);

    try testing.expectApproxEqAbs(@as(f32, 15.0), combined.position.x, 0.0001);
}

test "transform lerp" {
    const testing = std.testing;
    const T = Transform(f32);
    const V3 = vector.Vec3(f32);

    const t1 = T.fromPosition(V3.init(0, 0, 0));
    const t2 = T.fromPosition(V3.init(10, 0, 0));

    const mid = t1.lerp(t2, 0.5);

    try testing.expectApproxEqAbs(@as(f32, 5.0), mid.position.x, 0.0001);
}
