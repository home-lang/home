//! Exact orthogonal image transforms. Flip source axes first, then transpose.
//! No allocation, pixel format, stride or ownership policy is imposed here.
const std = @import("std");
pub const Extent = struct { width: usize, height: usize };
pub const Point = struct { x: usize, y: usize };
pub const Transform = struct {
    hflip: bool = false,
    vflip: bool = false,
    transpose: bool = false,

    pub fn fromBits(encoded: u32) !Transform {
        if (encoded > 7) return error.InvalidTransform;
        return .{ .hflip = encoded & 1 != 0, .vflip = encoded & 2 != 0, .transpose = encoded & 4 != 0 };
    }
    pub fn bits(self: Transform) u3 {
        return @as(u3, @intFromBool(self.hflip)) | (@as(u3, @intFromBool(self.vflip)) << 1) | (@as(u3, @intFromBool(self.transpose)) << 2);
    }
    /// Clockwise rotation, followed by flips along the OUTPUT axes.
    pub fn fromRotation(rotation: u32, hflip: bool, vflip: bool) !Transform {
        var value: u32 = switch (rotation) {
            0 => 0,
            90 => 6,
            180 => 3,
            270 => 5,
            else => return error.InvalidTransform,
        };
        const transposed = value & 4 != 0;
        if (hflip) value ^= if (transposed) @as(u32, 2) else 1;
        if (vflip) value ^= if (transposed) @as(u32, 1) else 2;
        return fromBits(value);
    }
    /// libcamera Orientation values, using its named clockwise rotations.
    /// These numbers must not be applied again as an image file EXIF tag.
    pub fn orientation(self: Transform) u32 {
        return ([_]u32{ 1, 2, 4, 3, 5, 6, 8, 7 })[self.bits()];
    }
    pub fn fromOrientation(value: u32) !Transform {
        if (value < 1 or value > 8) return error.InvalidTransform;
        return fromBits(([_]u32{ 0, 1, 3, 2, 4, 5, 7, 6 })[value - 1]);
    }
    pub fn extent(self: Transform, source: Extent) Extent {
        return if (self.transpose) .{ .width = source.height, .height = source.width } else source;
    }
    /// Inverse map one destination pixel. Reject empty/out-of-bounds geometry
    /// before subtraction, including on maximal machine-size dimensions.
    pub fn sourcePoint(self: Transform, source: Extent, point: Point) !Point {
        const dest = self.extent(source);
        if (source.width == 0 or source.height == 0 or point.x >= dest.width or point.y >= dest.height) return error.InvalidGeometry;
        const x = if (self.transpose) point.y else point.x;
        const y = if (self.transpose) point.x else point.y;
        return .{ .x = if (self.hflip) source.width - 1 - x else x, .y = if (self.vflip) source.height - 1 - y else y };
    }
    /// Transform a repeating 2x2 tile (e.g. Bayer colours or black levels).
    /// Odd source sizes and one-pixel dimensions preserve the correct phase.
    pub fn tile(self: Transform, comptime T: type, input: [4]T, source: Extent) ![4]T {
        if (source.width == 0 or source.height == 0) return error.InvalidGeometry;
        var out: [4]T = undefined;
        for (0..2) |y| for (0..2) |x| {
            const sx = (if (self.transpose) y else x) ^ (if (self.hflip) ((source.width - 1) & 1) else @as(usize, 0));
            const sy = (if (self.transpose) x else y) ^ (if (self.vflip) ((source.height - 1) & 1) else @as(usize, 0));
            out[y * 2 + x] = input[sy * 2 + sx];
        };
        return out;
    }
};

test "all transforms are exact bijections for rectangular, odd and singleton images" {
    for (1..7) |w| for (1..6) |h| for (0..8) |bits| {
        const t = try Transform.fromBits(@intCast(bits));
        try std.testing.expectEqual(t.bits(), (try Transform.fromOrientation(t.orientation())).bits());
        const source = Extent{ .width = w, .height = h };
        const output = t.extent(source);
        var seen: [30]bool = @splat(false);
        const tile = try t.tile(u8, .{ 0, 1, 2, 3 }, source);
        for (0..output.height) |y| for (0..output.width) |x| {
            const p = try t.sourcePoint(source, .{ .x = x, .y = y });
            try std.testing.expect(!seen[p.y * w + p.x]);
            seen[p.y * w + p.x] = true;
            try std.testing.expectEqual(@as(u8, @intCast((p.y % 2) * 2 + p.x % 2)), tile[(y % 2) * 2 + x % 2]);
        };
        for (seen[0 .. w * h]) |value| try std.testing.expect(value);
    };
}
test "clockwise rotations followed by output flips have known corner mappings" {
    const source = Extent{ .width = 3, .height = 2 };
    for ([_]u32{ 0, 90, 180, 270 }, [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 1 }, .{ .x = 2, .y = 1 }, .{ .x = 2, .y = 0 } }) |rotation, first| {
        const plain = try Transform.fromRotation(rotation, false, false);
        try std.testing.expectEqualDeep(first, try plain.sourcePoint(source, .{ .x = 0, .y = 0 }));
        const output = plain.extent(source);
        for ([_]bool{ false, true }) |hflip| for ([_]bool{ false, true }) |vflip| {
            const t = try Transform.fromRotation(rotation, hflip, vflip);
            for (0..output.height) |y| for (0..output.width) |x| {
                try std.testing.expectEqualDeep(try plain.sourcePoint(source, .{ .x = if (hflip) output.width - 1 - x else x, .y = if (vflip) output.height - 1 - y else y }), try t.sourcePoint(source, .{ .x = x, .y = y }));
            };
        };
    }
}
test "invalid values reject and maximal coordinate arithmetic does not wrap" {
    try std.testing.expectError(error.InvalidTransform, Transform.fromBits(8));
    try std.testing.expectError(error.InvalidTransform, Transform.fromOrientation(0));
    try std.testing.expectError(error.InvalidTransform, Transform.fromOrientation(9));
    try std.testing.expectError(error.InvalidTransform, Transform.fromRotation(360, false, false));
    const t = try Transform.fromBits(7);
    try std.testing.expectError(error.InvalidGeometry, t.sourcePoint(.{ .width = 0, .height = 2 }, .{ .x = 0, .y = 0 }));
    try std.testing.expectError(error.InvalidGeometry, t.tile(u8, .{ 0, 1, 2, 3 }, .{ .width = 2, .height = 0 }));
    try std.testing.expectError(error.InvalidGeometry, t.sourcePoint(.{ .width = 3, .height = 2 }, .{ .x = 2, .y = 0 }));
    try std.testing.expectEqualDeep(Point{ .x = 0, .y = 0 }, try t.sourcePoint(.{ .width = std.math.maxInt(usize), .height = std.math.maxInt(usize) }, .{ .x = std.math.maxInt(usize) - 1, .y = std.math.maxInt(usize) - 1 }));
}
