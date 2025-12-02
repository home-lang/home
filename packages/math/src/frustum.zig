// Home Programming Language - View Frustum
// Frustum culling for 3D rendering optimization
// Ported from C&C Generals engine for game compatibility

const std = @import("std");
const vector = @import("vector.zig");
const matrix = @import("matrix.zig");

/// A plane in 3D space represented by normal and distance from origin
/// Plane equation: ax + by + cz + d = 0
pub fn Plane(comptime T: type) type {
    return struct {
        normal: vector.Vec3(T),
        d: T,

        const Self = @This();
        const Vec3 = vector.Vec3(T);

        /// Create plane from normal and distance
        pub fn init(normal: Vec3, d: T) Self {
            return .{ .normal = normal, .d = d };
        }

        /// Create plane from normal and point on plane
        pub fn fromNormalAndPoint(normal: Vec3, point: Vec3) Self {
            const n = normal.normalize();
            return .{
                .normal = n,
                .d = -n.dot(point),
            };
        }

        /// Create plane from three points (counter-clockwise winding)
        pub fn fromPoints(p1: Vec3, p2: Vec3, p3: Vec3) Self {
            const v1 = p2.sub(p1);
            const v2 = p3.sub(p1);
            const normal = v1.cross(v2).normalize();
            return .{
                .normal = normal,
                .d = -normal.dot(p1),
            };
        }

        /// Normalize the plane equation
        pub fn normalize(self: Self) Self {
            const len = self.normal.length();
            if (len < 0.000001) {
                return self;
            }
            const inv_len = 1.0 / len;
            return .{
                .normal = self.normal.scale(inv_len),
                .d = self.d * inv_len,
            };
        }

        /// Signed distance from point to plane
        /// Positive = in front of plane, Negative = behind plane
        pub fn distanceToPoint(self: Self, point: Vec3) T {
            return self.normal.dot(point) + self.d;
        }

        /// Project point onto plane
        pub fn projectPoint(self: Self, point: Vec3) Vec3 {
            const dist = self.distanceToPoint(point);
            return point.sub(self.normal.scale(dist));
        }

        /// Check which side of the plane a point is on
        pub fn classify(self: Self, point: Vec3) PointClassification {
            const dist = self.distanceToPoint(point);
            if (dist > 0.0001) return .front;
            if (dist < -0.0001) return .back;
            return .on_plane;
        }
    };
}

pub const PointClassification = enum {
    front,
    back,
    on_plane,
};

/// Result of intersection test
pub const IntersectionResult = enum {
    inside,
    outside,
    intersecting,
};

/// Axis-Aligned Bounding Box
pub fn AABB(comptime T: type) type {
    return struct {
        min: vector.Vec3(T),
        max: vector.Vec3(T),

        const Self = @This();
        const Vec3 = vector.Vec3(T);

        /// Create AABB from min and max corners
        pub fn init(min_pt: Vec3, max_pt: Vec3) Self {
            return .{ .min = min_pt, .max = max_pt };
        }

        /// Create AABB from center and half-extents
        pub fn fromCenterExtents(center: Vec3, extents: Vec3) Self {
            return .{
                .min = center.sub(extents),
                .max = center.add(extents),
            };
        }

        /// Create empty AABB
        pub fn empty() Self {
            const inf = std.math.inf(T);
            return .{
                .min = Vec3.init(inf, inf, inf),
                .max = Vec3.init(-inf, -inf, -inf),
            };
        }

        /// Get center of AABB
        pub fn center(self: Self) Vec3 {
            return Vec3.init(
                (self.min.x + self.max.x) * 0.5,
                (self.min.y + self.max.y) * 0.5,
                (self.min.z + self.max.z) * 0.5,
            );
        }

        /// Get half-extents of AABB
        pub fn extents(self: Self) Vec3 {
            return Vec3.init(
                (self.max.x - self.min.x) * 0.5,
                (self.max.y - self.min.y) * 0.5,
                (self.max.z - self.min.z) * 0.5,
            );
        }

        /// Get size of AABB
        pub fn size(self: Self) Vec3 {
            return self.max.sub(self.min);
        }

        /// Expand AABB to include a point
        pub fn expandToInclude(self: Self, point: Vec3) Self {
            return .{
                .min = Vec3.init(
                    @min(self.min.x, point.x),
                    @min(self.min.y, point.y),
                    @min(self.min.z, point.z),
                ),
                .max = Vec3.init(
                    @max(self.max.x, point.x),
                    @max(self.max.y, point.y),
                    @max(self.max.z, point.z),
                ),
            };
        }

        /// Merge two AABBs
        pub fn merge(self: Self, other: Self) Self {
            return .{
                .min = Vec3.init(
                    @min(self.min.x, other.min.x),
                    @min(self.min.y, other.min.y),
                    @min(self.min.z, other.min.z),
                ),
                .max = Vec3.init(
                    @max(self.max.x, other.max.x),
                    @max(self.max.y, other.max.y),
                    @max(self.max.z, other.max.z),
                ),
            };
        }

        /// Check if AABB contains a point
        pub fn containsPoint(self: Self, point: Vec3) bool {
            return point.x >= self.min.x and point.x <= self.max.x and
                point.y >= self.min.y and point.y <= self.max.y and
                point.z >= self.min.z and point.z <= self.max.z;
        }

        /// Check if two AABBs intersect
        pub fn intersects(self: Self, other: Self) bool {
            return self.min.x <= other.max.x and self.max.x >= other.min.x and
                self.min.y <= other.max.y and self.max.y >= other.min.y and
                self.min.z <= other.max.z and self.max.z >= other.min.z;
        }

        /// Get corner points of the AABB (8 corners)
        pub fn getCorners(self: Self) [8]Vec3 {
            return .{
                Vec3.init(self.min.x, self.min.y, self.min.z),
                Vec3.init(self.max.x, self.min.y, self.min.z),
                Vec3.init(self.min.x, self.max.y, self.min.z),
                Vec3.init(self.max.x, self.max.y, self.min.z),
                Vec3.init(self.min.x, self.min.y, self.max.z),
                Vec3.init(self.max.x, self.min.y, self.max.z),
                Vec3.init(self.min.x, self.max.y, self.max.z),
                Vec3.init(self.max.x, self.max.y, self.max.z),
            };
        }

        /// Transform AABB by matrix (creates new AABB enclosing transformed box)
        pub fn transform(self: Self, mat: matrix.Mat4(T)) Self {
            const corners = self.getCorners();
            var result = empty();
            for (corners) |corner| {
                const transformed = mat.transformPoint(corner);
                result = result.expandToInclude(transformed);
            }
            return result;
        }
    };
}

/// Bounding Sphere
pub fn BoundingSphere(comptime T: type) type {
    return struct {
        center: vector.Vec3(T),
        radius: T,

        const Self = @This();
        const Vec3 = vector.Vec3(T);

        /// Create sphere from center and radius
        pub fn init(ctr: Vec3, r: T) Self {
            return .{ .center = ctr, .radius = r };
        }

        /// Create sphere enclosing an AABB
        pub fn fromAABB(aabb: AABB(T)) Self {
            const ctr = aabb.center();
            const ext = aabb.extents();
            const r = ext.length();
            return .{ .center = ctr, .radius = r };
        }

        /// Check if sphere contains a point
        pub fn containsPoint(self: Self, point: Vec3) bool {
            return self.center.distance(point) <= self.radius;
        }

        /// Check if two spheres intersect
        pub fn intersects(self: Self, other: Self) bool {
            return self.center.distance(other.center) <= (self.radius + other.radius);
        }
    };
}

/// View Frustum for culling
/// Uses 6 planes: near, far, left, right, top, bottom
pub fn Frustum(comptime T: type) type {
    return struct {
        planes: [6]Plane(T),

        const Self = @This();
        const Vec3 = vector.Vec3(T);
        const Mat4 = matrix.Mat4(T);
        const PlaneT = Plane(T);
        const AABBType = AABB(T);
        const SphereType = BoundingSphere(T);

        // Plane indices
        pub const NEAR = 0;
        pub const FAR = 1;
        pub const LEFT = 2;
        pub const RIGHT = 3;
        pub const TOP = 4;
        pub const BOTTOM = 5;

        /// Extract frustum planes from view-projection matrix
        /// Uses Gribb-Hartmann method
        pub fn fromViewProjection(vp: Mat4) Self {
            var result: Self = undefined;

            // Extract rows from matrix (column-major storage)
            const row0 = Vec3.init(vp.m[0][0], vp.m[1][0], vp.m[2][0]);
            const row1 = Vec3.init(vp.m[0][1], vp.m[1][1], vp.m[2][1]);
            const row2 = Vec3.init(vp.m[0][2], vp.m[1][2], vp.m[2][2]);
            const row3 = Vec3.init(vp.m[0][3], vp.m[1][3], vp.m[2][3]);
            const w0 = vp.m[3][0];
            const w1 = vp.m[3][1];
            const w2 = vp.m[3][2];
            const w3 = vp.m[3][3];

            // Left plane: row3 + row0
            result.planes[LEFT] = PlaneT.init(
                row3.add(row0),
                w3 + w0,
            ).normalize();

            // Right plane: row3 - row0
            result.planes[RIGHT] = PlaneT.init(
                row3.sub(row0),
                w3 - w0,
            ).normalize();

            // Bottom plane: row3 + row1
            result.planes[BOTTOM] = PlaneT.init(
                row3.add(row1),
                w3 + w1,
            ).normalize();

            // Top plane: row3 - row1
            result.planes[TOP] = PlaneT.init(
                row3.sub(row1),
                w3 - w1,
            ).normalize();

            // Near plane: row3 + row2
            result.planes[NEAR] = PlaneT.init(
                row3.add(row2),
                w3 + w2,
            ).normalize();

            // Far plane: row3 - row2
            result.planes[FAR] = PlaneT.init(
                row3.sub(row2),
                w3 - w2,
            ).normalize();

            return result;
        }

        /// Test if a point is inside the frustum
        pub fn containsPoint(self: Self, point: Vec3) bool {
            for (self.planes) |plane| {
                if (plane.distanceToPoint(point) < 0) {
                    return false;
                }
            }
            return true;
        }

        /// Test if a sphere intersects or is inside the frustum
        pub fn testSphere(self: Self, sphere: SphereType) IntersectionResult {
            var inside = true;

            for (self.planes) |plane| {
                const dist = plane.distanceToPoint(sphere.center);
                if (dist < -sphere.radius) {
                    return .outside;
                }
                if (dist < sphere.radius) {
                    inside = false;
                }
            }

            return if (inside) .inside else .intersecting;
        }

        /// Test if an AABB intersects or is inside the frustum
        pub fn testAABB(self: Self, aabb: AABBType) IntersectionResult {
            var result: IntersectionResult = .inside;

            for (self.planes) |plane| {
                // Find the positive and negative vertices relative to plane normal
                var p_vertex: Vec3 = aabb.min;
                var n_vertex: Vec3 = aabb.max;

                if (plane.normal.x >= 0) {
                    p_vertex.x = aabb.max.x;
                    n_vertex.x = aabb.min.x;
                }
                if (plane.normal.y >= 0) {
                    p_vertex.y = aabb.max.y;
                    n_vertex.y = aabb.min.y;
                }
                if (plane.normal.z >= 0) {
                    p_vertex.z = aabb.max.z;
                    n_vertex.z = aabb.min.z;
                }

                // If positive vertex is outside, AABB is completely outside
                if (plane.distanceToPoint(p_vertex) < 0) {
                    return .outside;
                }

                // If negative vertex is outside, AABB is intersecting
                if (plane.distanceToPoint(n_vertex) < 0) {
                    result = .intersecting;
                }
            }

            return result;
        }

        /// Quick sphere test (returns true if potentially visible)
        pub fn isVisible(self: Self, sphere: SphereType) bool {
            for (self.planes) |plane| {
                if (plane.distanceToPoint(sphere.center) < -sphere.radius) {
                    return false;
                }
            }
            return true;
        }

        /// Quick AABB test (returns true if potentially visible)
        pub fn isAABBVisible(self: Self, aabb: AABBType) bool {
            for (self.planes) |plane| {
                var p_vertex: Vec3 = aabb.min;

                if (plane.normal.x >= 0) p_vertex.x = aabb.max.x;
                if (plane.normal.y >= 0) p_vertex.y = aabb.max.y;
                if (plane.normal.z >= 0) p_vertex.z = aabb.max.z;

                if (plane.distanceToPoint(p_vertex) < 0) {
                    return false;
                }
            }
            return true;
        }
    };
}

// Type aliases for common use
pub const Planef = Plane(f32);
pub const Planed = Plane(f64);
pub const AABBf = AABB(f32);
pub const AABBd = AABB(f64);
pub const BoundingSpheref = BoundingSphere(f32);
pub const BoundingSphered = BoundingSphere(f64);
pub const Frustumf = Frustum(f32);
pub const Frustumd = Frustum(f64);

// ============================================
// Tests
// ============================================

test "plane distance to point" {
    const testing = std.testing;
    const P = Plane(f32);
    const V3 = vector.Vec3(f32);

    // XY plane at origin
    const plane = P.init(V3.init(0, 0, 1), 0);

    // Point in front
    try testing.expectApproxEqAbs(@as(f32, 5.0), plane.distanceToPoint(V3.init(0, 0, 5)), 0.0001);

    // Point behind
    try testing.expectApproxEqAbs(@as(f32, -3.0), plane.distanceToPoint(V3.init(0, 0, -3)), 0.0001);

    // Point on plane
    try testing.expectApproxEqAbs(@as(f32, 0.0), plane.distanceToPoint(V3.init(5, 5, 0)), 0.0001);
}

test "aabb contains point" {
    const testing = std.testing;
    const A = AABB(f32);
    const V3 = vector.Vec3(f32);

    const aabb = A.init(V3.init(-1, -1, -1), V3.init(1, 1, 1));

    try testing.expect(aabb.containsPoint(V3.init(0, 0, 0)));
    try testing.expect(aabb.containsPoint(V3.init(0.5, 0.5, 0.5)));
    try testing.expect(!aabb.containsPoint(V3.init(2, 0, 0)));
}

test "aabb intersection" {
    const testing = std.testing;
    const A = AABB(f32);
    const V3 = vector.Vec3(f32);

    const aabb1 = A.init(V3.init(0, 0, 0), V3.init(2, 2, 2));
    const aabb2 = A.init(V3.init(1, 1, 1), V3.init(3, 3, 3));
    const aabb3 = A.init(V3.init(5, 5, 5), V3.init(6, 6, 6));

    try testing.expect(aabb1.intersects(aabb2));
    try testing.expect(!aabb1.intersects(aabb3));
}

test "sphere intersection" {
    const testing = std.testing;
    const S = BoundingSphere(f32);
    const V3 = vector.Vec3(f32);

    const s1 = S.init(V3.init(0, 0, 0), 1);
    const s2 = S.init(V3.init(1.5, 0, 0), 1);
    const s3 = S.init(V3.init(5, 0, 0), 1);

    try testing.expect(s1.intersects(s2));
    try testing.expect(!s1.intersects(s3));
}

test "frustum point containment" {
    const testing = std.testing;
    const V3 = vector.Vec3(f32);
    const M4 = matrix.Mat4(f32);
    const F = Frustum(f32);

    // Simple orthographic frustum
    const proj = M4.orthographic(-10, 10, -10, 10, 0.1, 100);
    const view = M4.identity();
    const vp = proj.mul(view);
    const frustum = F.fromViewProjection(vp);

    // Point inside should be contained
    try testing.expect(frustum.containsPoint(V3.init(0, 0, -50)));
}
