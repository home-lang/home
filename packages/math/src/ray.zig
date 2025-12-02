// Home Programming Language - Ray Casting
// Ray/line segment intersection tests for picking, collision, etc.
// Essential for RTS object selection via click-to-select

const std = @import("std");
const vector = @import("vector.zig");
const frustum = @import("frustum.zig");

/// A ray in 3D space - origin point plus direction
pub fn Ray(comptime T: type) type {
    return struct {
        origin: vector.Vec3(T),
        direction: vector.Vec3(T), // Should be normalized

        const Self = @This();
        const Vec3 = vector.Vec3(T);
        const AABBType = frustum.AABB(T);
        const SphereType = frustum.BoundingSphere(T);
        const PlaneType = frustum.Plane(T);

        /// Create ray from origin and direction
        pub fn init(origin: Vec3, direction: Vec3) Self {
            return .{
                .origin = origin,
                .direction = direction.normalize(),
            };
        }

        /// Create ray from two points (origin to target)
        pub fn fromPoints(start: Vec3, end: Vec3) Self {
            const dir = end.sub(start);
            return .{
                .origin = start,
                .direction = dir.normalize(),
            };
        }

        /// Get point along ray at parameter t
        pub fn getPoint(self: Self, t: T) Vec3 {
            return self.origin.add(self.direction.scale(t));
        }

        /// Get closest point on ray to a given point
        pub fn closestPointTo(self: Self, point: Vec3) Vec3 {
            const v = point.sub(self.origin);
            const t = v.dot(self.direction);
            if (t < 0) {
                return self.origin;
            }
            return self.getPoint(t);
        }

        /// Get distance from ray to point
        pub fn distanceToPoint(self: Self, point: Vec3) T {
            const closest = self.closestPointTo(point);
            return closest.distance(point);
        }

        /// Ray-Plane intersection
        /// Returns distance t along ray, or null if parallel
        pub fn intersectPlane(self: Self, plane: PlaneType) ?T {
            const denom = plane.normal.dot(self.direction);

            // Ray parallel to plane
            if (@abs(denom) < 0.000001) {
                return null;
            }

            const t = -(plane.normal.dot(self.origin) + plane.d) / denom;

            // Intersection behind ray origin
            if (t < 0) {
                return null;
            }

            return t;
        }

        /// Ray-Sphere intersection
        /// Returns (t_near, t_far) or null if no intersection
        pub fn intersectSphere(self: Self, sphere: SphereType) ?struct { near: T, far: T } {
            const oc = self.origin.sub(sphere.center);
            const a = self.direction.dot(self.direction);
            const b = 2.0 * oc.dot(self.direction);
            const c = oc.dot(oc) - sphere.radius * sphere.radius;

            const discriminant = b * b - 4 * a * c;

            if (discriminant < 0) {
                return null;
            }

            const sqrt_disc = @sqrt(discriminant);
            const t1 = (-b - sqrt_disc) / (2 * a);
            const t2 = (-b + sqrt_disc) / (2 * a);

            // Both behind origin
            if (t2 < 0) {
                return null;
            }

            return .{
                .near = if (t1 < 0) 0 else t1,
                .far = t2,
            };
        }

        /// Ray-AABB intersection using slab method
        /// Returns (t_near, t_far) or null if no intersection
        pub fn intersectAABB(self: Self, aabb: AABBType) ?struct { near: T, far: T } {
            var t_min: T = -std.math.inf(T);
            var t_max: T = std.math.inf(T);

            // X slab
            if (@abs(self.direction.x) < 0.000001) {
                // Ray parallel to slab
                if (self.origin.x < aabb.min.x or self.origin.x > aabb.max.x) {
                    return null;
                }
            } else {
                const inv_d = 1.0 / self.direction.x;
                var t1 = (aabb.min.x - self.origin.x) * inv_d;
                var t2 = (aabb.max.x - self.origin.x) * inv_d;
                if (t1 > t2) {
                    const tmp = t1;
                    t1 = t2;
                    t2 = tmp;
                }
                t_min = @max(t_min, t1);
                t_max = @min(t_max, t2);
                if (t_min > t_max) return null;
            }

            // Y slab
            if (@abs(self.direction.y) < 0.000001) {
                if (self.origin.y < aabb.min.y or self.origin.y > aabb.max.y) {
                    return null;
                }
            } else {
                const inv_d = 1.0 / self.direction.y;
                var t1 = (aabb.min.y - self.origin.y) * inv_d;
                var t2 = (aabb.max.y - self.origin.y) * inv_d;
                if (t1 > t2) {
                    const tmp = t1;
                    t1 = t2;
                    t2 = tmp;
                }
                t_min = @max(t_min, t1);
                t_max = @min(t_max, t2);
                if (t_min > t_max) return null;
            }

            // Z slab
            if (@abs(self.direction.z) < 0.000001) {
                if (self.origin.z < aabb.min.z or self.origin.z > aabb.max.z) {
                    return null;
                }
            } else {
                const inv_d = 1.0 / self.direction.z;
                var t1 = (aabb.min.z - self.origin.z) * inv_d;
                var t2 = (aabb.max.z - self.origin.z) * inv_d;
                if (t1 > t2) {
                    const tmp = t1;
                    t1 = t2;
                    t2 = tmp;
                }
                t_min = @max(t_min, t1);
                t_max = @min(t_max, t2);
                if (t_min > t_max) return null;
            }

            // Intersection behind origin
            if (t_max < 0) {
                return null;
            }

            return .{
                .near = if (t_min < 0) 0 else t_min,
                .far = t_max,
            };
        }

        /// Ray-Triangle intersection using Möller–Trumbore algorithm
        /// Returns distance t or null if no intersection
        pub fn intersectTriangle(self: Self, v0: Vec3, v1: Vec3, v2: Vec3) ?T {
            const EPSILON: T = 0.0000001;

            const edge1 = v1.sub(v0);
            const edge2 = v2.sub(v0);
            const h = cross3(self.direction, edge2);
            const a = edge1.dot(h);

            // Ray parallel to triangle
            if (a > -EPSILON and a < EPSILON) {
                return null;
            }

            const f = 1.0 / a;
            const s = self.origin.sub(v0);
            const u = f * s.dot(h);

            if (u < 0.0 or u > 1.0) {
                return null;
            }

            const q = cross3(s, edge1);
            const v = f * self.direction.dot(q);

            if (v < 0.0 or u + v > 1.0) {
                return null;
            }

            const t = f * edge2.dot(q);

            if (t > EPSILON) {
                return t;
            }

            return null;
        }
    };
}

/// Helper cross product for Vec3
fn cross3(comptime T: type) fn (vector.Vec3(T), vector.Vec3(T)) vector.Vec3(T) {
    return struct {
        fn f(a: vector.Vec3(T), b: vector.Vec3(T)) vector.Vec3(T) {
            return a.cross(b);
        }
    }.f;
}

/// Line segment in 3D space
pub fn LineSegment(comptime T: type) type {
    return struct {
        start: vector.Vec3(T),
        end: vector.Vec3(T),

        const Self = @This();
        const Vec3 = vector.Vec3(T);

        pub fn init(start: Vec3, end: Vec3) Self {
            return .{ .start = start, .end = end };
        }

        pub fn length(self: Self) T {
            return self.start.distance(self.end);
        }

        pub fn lengthSq(self: Self) T {
            const d = self.end.sub(self.start);
            return d.lengthSq();
        }

        pub fn direction(self: Self) Vec3 {
            return self.end.sub(self.start).normalize();
        }

        pub fn midpoint(self: Self) Vec3 {
            return self.start.lerp(self.end, 0.5);
        }

        /// Get point along segment at parameter t (0 = start, 1 = end)
        pub fn getPoint(self: Self, t: T) Vec3 {
            return self.start.lerp(self.end, t);
        }

        /// Get closest point on segment to a given point
        pub fn closestPointTo(self: Self, point: Vec3) Vec3 {
            const ab = self.end.sub(self.start);
            const t = point.sub(self.start).dot(ab) / ab.dot(ab);
            const clamped_t = @max(0, @min(1, t));
            return self.getPoint(clamped_t);
        }

        /// Get distance from segment to point
        pub fn distanceToPoint(self: Self, point: Vec3) T {
            const closest = self.closestPointTo(point);
            return closest.distance(point);
        }

        /// Convert to ray (infinite in direction)
        pub fn toRay(self: Self) Ray(T) {
            return Ray(T).fromPoints(self.start, self.end);
        }
    };
}

/// Pick ray generation from screen coordinates
pub fn PickRay(comptime T: type) type {
    return struct {
        const Vec3 = vector.Vec3(T);
        const Mat4 = @import("matrix.zig").Mat4(T);
        const RayType = Ray(T);

        /// Generate pick ray from screen coordinates
        /// screen_x, screen_y: Normalized screen coordinates (-1 to 1)
        /// inverse_view_proj: Inverse of (projection * view) matrix
        pub fn fromScreenCoords(
            screen_x: T,
            screen_y: T,
            inverse_view_proj: Mat4,
        ) RayType {
            // Near plane point
            const near_point = inverse_view_proj.transformPoint(Vec3.init(screen_x, screen_y, -1));

            // Far plane point
            const far_point = inverse_view_proj.transformPoint(Vec3.init(screen_x, screen_y, 1));

            return RayType.fromPoints(near_point, far_point);
        }

        /// Generate pick ray from pixel coordinates
        /// pixel_x, pixel_y: Screen pixel coordinates
        /// screen_width, screen_height: Screen dimensions
        /// inverse_view_proj: Inverse of (projection * view) matrix
        pub fn fromPixelCoords(
            pixel_x: T,
            pixel_y: T,
            screen_width: T,
            screen_height: T,
            inverse_view_proj: Mat4,
        ) RayType {
            // Convert to normalized coordinates (-1 to 1)
            const ndc_x = (2.0 * pixel_x / screen_width) - 1.0;
            const ndc_y = 1.0 - (2.0 * pixel_y / screen_height); // Y is flipped

            return fromScreenCoords(ndc_x, ndc_y, inverse_view_proj);
        }
    };
}

// Type aliases
pub const Rayf = Ray(f32);
pub const Rayd = Ray(f64);
pub const LineSegmentf = LineSegment(f32);
pub const LineSegmentd = LineSegment(f64);
pub const PickRayf = PickRay(f32);
pub const PickRayd = PickRay(f64);

// ============================================
// Tests
// ============================================

test "ray point along" {
    const testing = std.testing;
    const V3 = vector.Vec3(f32);
    const R = Ray(f32);

    const ray = R.init(V3.init(0, 0, 0), V3.init(1, 0, 0));

    const p1 = ray.getPoint(0);
    try testing.expectApproxEqAbs(@as(f32, 0.0), p1.x, 0.0001);

    const p2 = ray.getPoint(5);
    try testing.expectApproxEqAbs(@as(f32, 5.0), p2.x, 0.0001);
}

test "ray plane intersection" {
    const testing = std.testing;
    const V3 = vector.Vec3(f32);
    const R = Ray(f32);
    const P = frustum.Plane(f32);

    // Ray pointing at XY plane from above
    const ray = R.init(V3.init(0, 0, 5), V3.init(0, 0, -1));
    const plane = P.init(V3.init(0, 0, 1), 0); // Z = 0 plane

    const t = ray.intersectPlane(plane);
    try testing.expect(t != null);
    try testing.expectApproxEqAbs(@as(f32, 5.0), t.?, 0.0001);
}

test "ray sphere intersection" {
    const testing = std.testing;
    const V3 = vector.Vec3(f32);
    const R = Ray(f32);
    const S = frustum.BoundingSphere(f32);

    // Ray through center of sphere
    const ray = R.init(V3.init(-5, 0, 0), V3.init(1, 0, 0));
    const sphere = S.init(V3.init(0, 0, 0), 1);

    const result = ray.intersectSphere(sphere);
    try testing.expect(result != null);
    try testing.expectApproxEqAbs(@as(f32, 4.0), result.?.near, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 6.0), result.?.far, 0.0001);
}

test "ray aabb intersection" {
    const testing = std.testing;
    const V3 = vector.Vec3(f32);
    const R = Ray(f32);
    const A = frustum.AABB(f32);

    // Ray through center of AABB
    const ray = R.init(V3.init(-5, 0, 0), V3.init(1, 0, 0));
    const aabb = A.init(V3.init(-1, -1, -1), V3.init(1, 1, 1));

    const result = ray.intersectAABB(aabb);
    try testing.expect(result != null);
    try testing.expectApproxEqAbs(@as(f32, 4.0), result.?.near, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 6.0), result.?.far, 0.0001);
}

test "line segment distance to point" {
    const testing = std.testing;
    const V3 = vector.Vec3(f32);
    const L = LineSegment(f32);

    const segment = L.init(V3.init(0, 0, 0), V3.init(10, 0, 0));

    // Point directly above middle
    const dist = segment.distanceToPoint(V3.init(5, 5, 0));
    try testing.expectApproxEqAbs(@as(f32, 5.0), dist, 0.0001);
}
