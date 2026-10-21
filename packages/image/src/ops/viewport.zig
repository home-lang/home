//! Integer display fitting and independent orthogonal texture coordinates.
//! No pixels, allocations, window system or renderer are owned here.
const std = @import("std");
const orientation = @import("orientation.zig");
const Region = @import("region.zig").Region;
pub const Plan = struct {
    logical_width: u32,
    logical_height: u32,
    image: Region,
    overlay: Region,
    image_uv: [8]f32,
    overlay_uv: [8]f32,
    pub fn init(width: u32, height: u32, output_width: u32, output_height: u32, image_orientation: u32, overlay_orientation: u32, keep_aspect: bool, rectangle: ?Region) !Plan {
        if (width == 0 or height == 0 or output_width == 0 or output_height == 0) return error.InvalidGeometry;
        const image_transform = try orientation.Transform.fromOrientation(image_orientation);
        const overlay_transform = try orientation.Transform.fromOrientation(overlay_orientation);
        const logical = image_transform.extent(.{ .width = width, .height = height });
        const lw: u32 = @intCast(logical.width);
        const lh: u32 = @intCast(logical.height);
        var w = output_width;
        var h = output_height;
        if (keep_aspect) {
            if (@as(u64, lw) * output_height > @as(u64, output_width) * lh) {
                h = @intCast(@max(1, @as(u64, output_width) * lh / lw));
            } else w = @intCast(@max(1, @as(u64, output_height) * lw / lh));
        }
        const image = Region{ .x = (output_width - w) / 2, .y = (output_height - h) / 2, .width = w, .height = h };
        const r = rectangle orelse Region{ .x = 0, .y = 0, .width = lw, .height = lh };
        if (!r.isValid(lw, lh)) return error.InvalidRectangle;
        const left: u32 = @intCast(@as(u64, r.x) * w / lw);
        const top: u32 = @intCast(@as(u64, r.y) * h / lh);
        const right: u32 = @intCast((@as(u64, r.x) + r.width) * w / lw);
        const bottom: u32 = @intCast((@as(u64, r.y) + r.height) * h / lh);
        return .{
            .logical_width = lw,
            .logical_height = lh,
            .image = image,
            // Half-open edges share rounding, preventing seams at adjacent regions.
            // A subpixel rectangle may map to empty; renderer should skip it.
            .overlay = .{ .x = image.x + left, .y = image.y + top, .width = right - left, .height = bottom - top },
            .image_uv = try coordinates(image_transform),
            .overlay_uv = try coordinates(overlay_transform),
        };
    }
};
fn coordinates(transform: orientation.Transform) ![8]f32 {
    var out: [8]f32 = undefined;
    for ([_]orientation.Point{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 0, .y = 1 } }, 0..) |point, i| {
        const source = try transform.sourcePoint(.{ .width = 2, .height = 2 }, point);
        out[i * 2] = @floatFromInt(source.x);
        out[i * 2 + 1] = @floatFromInt(source.y);
    }
    return out;
}
test "letterbox stretch rectangle placement and transpose use display coordinates" {
    const r = Region{ .x = 1, .y = 0, .width = 2, .height = 1 };
    const plain = try Plan.init(4, 2, 8, 8, 1, 1, true, r);
    try std.testing.expectEqualDeep(Region{ .x = 0, .y = 2, .width = 8, .height = 4 }, plain.image);
    try std.testing.expectEqualDeep(Region{ .x = 2, .y = 2, .width = 4, .height = 2 }, plain.overlay);
    const stretch = try Plan.init(4, 2, 8, 8, 1, 1, false, r);
    try std.testing.expectEqualDeep(Region{ .x = 0, .y = 0, .width = 8, .height = 8 }, stretch.image);
    try std.testing.expectEqualDeep(Region{ .x = 2, .y = 0, .width = 4, .height = 4 }, stretch.overlay);
    const turned = try Plan.init(4, 2, 8, 8, 6, 1, true, null);
    try std.testing.expectEqual(@as(u32, 2), turned.logical_width);
    try std.testing.expectEqual(@as(u32, 4), turned.logical_height);
    try std.testing.expectEqualDeep(Region{ .x = 2, .y = 0, .width = 4, .height = 8 }, turned.image);
    try std.testing.expectEqualDeep(turned.image, turned.overlay);
}
test "all eight UV maps are exact and image/overlay orientation is independent" {
    const expected = [_][8]f32{
        .{ 0, 0, 1, 0, 1, 1, 0, 1 }, .{ 1, 0, 0, 0, 0, 1, 1, 1 },
        .{ 1, 1, 0, 1, 0, 0, 1, 0 }, .{ 0, 1, 1, 1, 1, 0, 0, 0 },
        .{ 0, 0, 0, 1, 1, 1, 1, 0 }, .{ 1, 0, 1, 1, 0, 1, 0, 0 },
        .{ 1, 1, 1, 0, 0, 0, 0, 1 }, .{ 0, 1, 0, 0, 1, 0, 1, 1 },
    };
    for (1..9) |main| for (1..9) |over| {
        const plan = try Plan.init(3, 2, 9, 7, @intCast(main), @intCast(over), true, null);
        try std.testing.expectEqualDeep(expected[main - 1], plan.image_uv);
        try std.testing.expectEqualDeep(expected[over - 1], plan.overlay_uv);
    };
}
test "maximal and subpixel geometry stays bounded; invalid extents reject" {
    const max = std.math.maxInt(u32);
    const plan = try Plan.init(max, 1, max, max, 1, 1, true, .{ .x = max - 1, .y = 0, .width = 1, .height = 1 });
    try std.testing.expect(plan.image.isValid(max, max));
    try std.testing.expectEqual(@as(u32, 1), plan.overlay.width);
    const tiny = try Plan.init(1, max, 1, 1, 1, 1, true, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    try std.testing.expectEqual(@as(u32, 0), tiny.overlay.height);
    try std.testing.expectError(error.InvalidGeometry, Plan.init(0, 1, 1, 1, 1, 1, true, null));
    try std.testing.expectError(error.InvalidGeometry, Plan.init(1, 1, 0, 1, 1, 1, true, null));
    try std.testing.expectError(error.InvalidTransform, Plan.init(1, 1, 1, 1, 0, 1, true, null));
    try std.testing.expectError(error.InvalidTransform, Plan.init(1, 1, 1, 1, 1, 9, true, null));
    try std.testing.expectError(error.InvalidRectangle, Plan.init(4, 2, 8, 8, 1, 1, true, .{ .x = 3, .y = 0, .width = max, .height = 1 }));
    try std.testing.expectError(error.InvalidRectangle, Plan.init(4, 2, 8, 8, 1, 1, true, .{ .x = 0, .y = 0, .width = 0, .height = 1 }));
}
