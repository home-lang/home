const std = @import("std");
const image = @import("image");
test "public image package exposes native precision compositing without another owned image pool" {
    const pixels = image.PixelView.View{ .data = &.{ 17, 129, 255, 128 }, .width = 1, .height = 1, .stride = 4, .format = .rgba };
    var result = try image.PixelComposite.copied(std.testing.allocator, pixels, pixels, .{ .bits = 16 }, 8, .{});
    defer result.deinit();
    try std.testing.expectEqual([4]u16{ 17 * 257, 129 * 257, 65535, 49279 }, result.view.sample16(0, 0));
}
