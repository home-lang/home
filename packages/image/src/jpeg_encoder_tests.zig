const std = @import("std");
const image = @import("image.zig");
const jpeg = @import("formats/jpeg.zig");
test {
    _ = jpeg;
}
test "native JPEG encodes scan data readable by the Home decoder" {
    var img = try image.Image.init(std.testing.allocator, 17, 9, .rgb8);
    defer img.deinit();
    for (0..17 * 9) |i| {
        @memcpy(img.pixels[i * 3 ..][0..3], &[_]u8{ 200, 50, 100 });
    }
    const encoded = try jpeg.encodeWithQuality(std.testing.allocator, &img, 98);
    defer std.testing.allocator.free(encoded);
    var decoded = try jpeg.decode(std.testing.allocator, encoded);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u32, 17), decoded.width);
    try std.testing.expectEqual(@as(u32, 9), decoded.height);
    const pixel = decoded.getPixel(8, 4).?;
    try std.testing.expectApproxEqAbs(@as(f64, 200), @as(f64, @floatFromInt(pixel.r)), 5);
    try std.testing.expectApproxEqAbs(@as(f64, 50), @as(f64, @floatFromInt(pixel.g)), 5);
    try std.testing.expectApproxEqAbs(@as(f64, 100), @as(f64, @floatFromInt(pixel.b)), 5);
}
