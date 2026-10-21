//! Allocation-free unsigned image regions. Reject invalid extents without overflow.
const std = @import("std");
pub const Region = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,

    pub fn isValid(self: Region, img_width: u32, img_height: u32) bool {
        return self.x < img_width and
            self.y < img_height and
            self.width > 0 and
            self.height > 0 and
            self.width <= img_width - self.x and
            self.height <= img_height - self.y;
    }

    pub fn clamp(self: Region, img_width: u32, img_height: u32) Region {
        const x = @min(self.x, img_width);
        const y = @min(self.y, img_height);
        const max_width = img_width - x;
        const max_height = img_height - y;

        return Region{
            .x = x,
            .y = y,
            .width = @min(self.width, max_width),
            .height = @min(self.height, max_height),
        };
    }
};

test "maximal image regions reject wrapped extents and preserve exact right and bottom edges" {
    const max = std.math.maxInt(u32);
    try std.testing.expect((Region{ .x = 0, .y = 0, .width = max, .height = max }).isValid(max, max));
    try std.testing.expect((Region{ .x = max - 1, .y = max - 1, .width = 1, .height = 1 }).isValid(max, max));
    try std.testing.expect(!(Region{ .x = max - 1, .y = 0, .width = 2, .height = 1 }).isValid(max, max));
    try std.testing.expect(!(Region{ .x = 0, .y = max - 1, .width = 1, .height = 2 }).isValid(max, max));
    try std.testing.expect(!(Region{ .x = 1, .y = 1, .width = max, .height = max }).isValid(max, max));
    try std.testing.expectEqualDeep(Region{ .x = max - 1, .y = max - 1, .width = 1, .height = 1 }, (Region{ .x = max - 1, .y = max - 1, .width = max, .height = max }).clamp(max, max));
}
test "validation matches wide arithmetic and clamping stays within every boundary" {
    const values = [_]u32{ 0, 1, 2, std.math.maxInt(u32) - 1, std.math.maxInt(u32) };
    for (values) |iw| for (values) |ih| for (values) |x| for (values) |y| for (values) |w| for (values) |h| {
        const src = Region{ .x = x, .y = y, .width = w, .height = h };
        const valid = x < iw and y < ih and w != 0 and h != 0 and @as(u64, x) + w <= iw and @as(u64, y) + h <= ih;
        try std.testing.expectEqual(valid, src.isValid(iw, ih));
        const clipped = src.clamp(iw, ih);
        try std.testing.expect(clipped.x <= iw and clipped.y <= ih);
        try std.testing.expect(@as(u64, clipped.x) + clipped.width <= iw and @as(u64, clipped.y) + clipped.height <= ih);
        try std.testing.expect(clipped.width <= w and clipped.height <= h);
        try std.testing.expectEqual(clipped.width > 0 and clipped.height > 0, clipped.isValid(iw, ih));
        if (valid) try std.testing.expectEqualDeep(src, clipped);
    };
}
