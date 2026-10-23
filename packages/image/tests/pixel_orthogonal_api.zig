const std = @import("std");
const image = @import("image");
test "orthogonal public Image API preserves a low-word sample" {
    var original = try image.Image.init(std.testing.allocator, 1, 1, .rgb16);
    defer original.deinit();
    original.setPixel16(0, 0, .{ .r = 0x1234, .g = 0x5678, .b = 0x9abc });
    var rotated = try image.Transform.rotate(&original, .degrees_90);
    defer rotated.deinit();
    const sample = rotated.getPixel16(0, 0).?;
    try std.testing.expectEqual(@as(u16, 0x1234), sample.r);
    try std.testing.expectEqual(@as(u16, 0x5678), sample.g);
    try std.testing.expectEqual(@as(u16, 0x9abc), sample.b);
}
