//! Canonical physical-object windows for one imported frame. No descriptor or
//! mapping ownership is acquired here; callers supply independently checked FD
//! identities and reserve the returned whole-object charge before preparation.
const std = @import("std");
pub const max_planes = 4;
pub const Identity = struct { device: u64, inode: u64, bytes: u64 };
pub const Plane = struct { fd: c_int, offset: u64 = 0, bytes: u64 };
pub const Frame = struct {
    plane_count: u8 = 0,
    planes: [max_planes]Plane = std.mem.zeroes([max_planes]Plane),
    pub fn init(planes: []const Plane) !Frame {
        if (planes.len == 0 or planes.len > max_planes) return error.InvalidResource;
        var result: Frame = .{ .plane_count = @intCast(planes.len) };
        for (planes) |plane| try validatePlane(plane);
        @memcpy(result.planes[0..planes.len], planes);
        return result;
    }
};
pub fn validatePlane(plane: Plane) !void {
    if (plane.fd < 0 or plane.bytes == 0 or plane.bytes > std.math.maxInt(u32) or
        plane.offset > std.math.maxInt(u32) - plane.bytes) return error.InvalidResource;
}
pub const Binding = struct { object: u8, offset: u64, bytes: u64 };
pub const Object = struct { fd: c_int, offset: u64, bytes: u64, identity: Identity };
pub fn sameObject(a: Identity, b: Identity) bool {
    return a.device == b.device and a.inode == b.inode;
}
pub const Plan = struct {
    plane_count: u8 = 0,
    object_count: u8 = 0,
    planes: [max_planes]Binding = std.mem.zeroes([max_planes]Binding),
    objects: [max_planes]Object = std.mem.zeroes([max_planes]Object),
    charge: usize = 0,
    pub fn init(frame: *const Frame, identities: []const Identity, minimum_bytes: u64) !Plan {
        if (frame.plane_count == 0 or frame.plane_count > max_planes or identities.len != frame.plane_count or
            minimum_bytes == 0 or minimum_bytes > std.math.maxInt(u32)) return error.InvalidResource;
        var result: Plan = .{ .plane_count = frame.plane_count };
        var visible: u64 = 0;
        for (frame.planes[0..frame.plane_count], identities, 0..) |plane, identity, i| {
            if (plane.fd < 0 or plane.bytes == 0 or plane.bytes > std.math.maxInt(u32) or plane.offset > std.math.maxInt(u32) - plane.bytes or
                identity.inode == 0 or plane.offset + plane.bytes > identity.bytes) return error.InvalidResource;
            visible = std.math.add(u64, visible, plane.bytes) catch return error.SizeOverflow;
            for (frame.planes[0..i], identities[0..i]) |previous, key| {
                if (previous.fd == plane.fd and !std.meta.eql(identity, key)) return error.InvalidResource;
            }
            var object: ?u8 = null;
            for (result.objects[0..result.object_count], 0..) |previous, index| {
                if (!sameObject(identity, previous.identity)) continue;
                if (identity.bytes != previous.identity.bytes) return error.InvalidResource;
                object = @intCast(index);
                break;
            }
            if (object == null) {
                object = result.object_count;
                result.objects[result.object_count] = .{ .fd = plane.fd, .offset = plane.offset, .bytes = plane.bytes, .identity = identity };
                result.object_count += 1;
                result.charge = std.math.add(usize, result.charge, std.math.cast(usize, identity.bytes) orelse return error.SizeOverflow) catch return error.SizeOverflow;
            } else {
                for (result.planes[0..i]) |previous| {
                    if (previous.object == object.? and plane.offset < previous.offset + previous.bytes and previous.offset < plane.offset + plane.bytes)
                        return error.OverlappingPlanes;
                }
                const target = &result.objects[object.?];
                const end = @max(target.offset + target.bytes, plane.offset + plane.bytes);
                target.offset = @min(target.offset, plane.offset);
                target.bytes = end - target.offset;
            }
            result.planes[i] = .{ .object = object.?, .offset = plane.offset, .bytes = plane.bytes };
        }
        if (visible < minimum_bytes) return error.InvalidResource;
        return result;
    }
    pub fn aliases(a: *const Plan, b: *const Plan) bool {
        for (a.objects[0..a.object_count]) |left| for (b.objects[0..b.object_count]) |right| {
            if (sameObject(left.identity, right.identity)) return true;
        };
        return false;
    }
};

test "disjoint planes sharing one inode have one charged window and preserve plane order" {
    const t = std.testing;
    const frame = try Frame.init(&.{ .{ .fd = 8, .offset = 400, .bytes = 32 }, .{ .fd = 9, .offset = 11, .bytes = 64 }, .{ .fd = 10, .offset = 80, .bytes = 16 } });
    const key = Identity{ .device = 1, .inode = 7, .bytes = 1024 };
    const plan = try Plan.init(&frame, &.{ key, key, key }, 112);
    try t.expectEqual(@as(u8, 1), plan.object_count);
    try t.expectEqual(@as(usize, 1024), plan.charge);
    try t.expectEqual(@as(u64, 11), plan.objects[0].offset);
    try t.expectEqual(@as(u64, 421), plan.objects[0].bytes);
    try t.expectEqual(@as(c_int, 8), plan.objects[0].fd);
    try t.expectEqual(@as(u64, 400), plan.planes[0].offset);
    const other = try Plan.init(&frame, &.{ .{ .device = 2, .inode = 7, .bytes = 1024 }, key, key }, 112);
    try t.expectEqual(@as(u8, 2), other.object_count);
    try t.expectEqual(@as(usize, 2048), other.charge);
    try t.expect(plan.aliases(&other));
}
test "overlap, changing extent, missing capacity and SDK range overflow reject atomically" {
    const t = std.testing;
    const key = Identity{ .device = 1, .inode = 7, .bytes = 1024 };
    var frame = try Frame.init(&.{ .{ .fd = 8, .offset = 0, .bytes = 64 }, .{ .fd = 9, .offset = 63, .bytes = 32 } });
    try t.expectError(error.OverlappingPlanes, Plan.init(&frame, &.{ key, key }, 96));
    frame.planes[1].offset = 64;
    _ = try Plan.init(&frame, &.{ key, key }, 96);
    try t.expectError(error.InvalidResource, Plan.init(&frame, &.{ key, .{ .device = 1, .inode = 7, .bytes = 1025 } }, 96));
    try t.expectError(error.InvalidResource, Plan.init(&frame, &.{ key, key }, 97));
    frame.planes[0].offset = std.math.maxInt(u64);
    try t.expectError(error.InvalidResource, Plan.init(&frame, &.{ key, key }, 1));
    frame.planes[0].offset = std.math.maxInt(u32);
    try t.expectError(error.InvalidResource, Plan.init(&frame, &.{ key, key }, 1));
    try t.expectError(error.InvalidResource, Frame.init(&.{}));
    try t.expectError(error.InvalidResource, Frame.init(&@as([5]Plane, @splat(.{ .fd = 1, .bytes = 1 }))));
}

test "inconsistent descriptor snapshots and aggregate object charge overflow reject" {
    const t = std.testing;
    const frame = try Frame.init(&.{ .{ .fd = 1, .offset = 0, .bytes = 1 }, .{ .fd = 1, .offset = 2, .bytes = 1 } });
    try t.expectError(error.InvalidResource, Plan.init(&frame, &.{ .{ .device = 1, .inode = 1, .bytes = 3 }, .{ .device = 2, .inode = 1, .bytes = 3 } }, 2));
    const unique = try Frame.init(&.{ .{ .fd = 1, .bytes = 1 }, .{ .fd = 2, .bytes = 1 } });
    try t.expectError(error.SizeOverflow, Plan.init(&unique, &.{ .{ .device = 1, .inode = 1, .bytes = std.math.maxInt(u64) }, .{ .device = 1, .inode = 2, .bytes = std.math.maxInt(u64) } }, 2));
}
