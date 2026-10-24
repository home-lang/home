//! Home JPEG Image adapter. Shared strict decoder owns parsing/scan reconstruction.
const std = @import("std");
const Image = @import("../image.zig").Image;
pub const decoder = @import("../jpeg_decoder.zig");
/// Adopts decoded gray/RGB pixels without a second image copy. Source metadata
/// is available through decoder.decode; the legacy Image has no metadata owner.
pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Image {
    var result = try decoder.decode(allocator, data, .{});
    defer result.deinit();
    const pixels = result.pixels;
    result.pixels = &.{};
    return .{ .allocator = allocator, .pixels = pixels, .width = result.width, .height = result.height, .format = if (result.components == 1) .grayscale8 else .rgb8, .palette = null };
}

pub fn encode(allocator: std.mem.Allocator, img: *const Image) ![]u8 {
    return encodeWithQuality(allocator, img, 90);
}
pub fn encodeWithQuality(allocator: std.mem.Allocator, img: *const Image, quality: u8) ![]u8 {
    const channels: u8 = switch (img.format) {
        .grayscale8 => 1,
        .rgb8 => 3,
        .rgba8 => 4,
        else => return error.UnsupportedFormat,
    };
    var encoder = @import("../jpeg_encoder.zig").Encoder.init(allocator);
    defer encoder.deinit();
    _ = try encoder.encode(img.pixels, img.width, img.height, @as(usize, img.width) * channels, channels, quality);
    return encoder.output.toOwnedSlice(allocator);
}

test "JPEG encoder writes bounded baseline dimensions" {
    const allocator = std.testing.allocator;
    var img = try Image.init(allocator, 3, 2, .rgb8);
    defer img.deinit();

    const encoded = try encode(allocator, &img);
    defer allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0xD8 }, encoded[0..2]);
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0xD9 }, encoded[encoded.len - 2 ..]);

    const sof = std.mem.indexOf(u8, encoded, &.{ 0xFF, 0xC0 }) orelse return error.MissingStartOfFrame;
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, encoded[sof + 5 ..][0..2], .big));
    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, encoded[sof + 7 ..][0..2], .big));

    var empty = try Image.init(allocator, 0, 1, .rgb8);
    defer empty.deinit();
    try std.testing.expectError(error.InvalidDimensions, encode(allocator, &empty));

    var unsupported = try Image.init(allocator, 1, 1, .rgb16);
    defer unsupported.deinit();
    try std.testing.expectError(error.UnsupportedFormat, encode(allocator, &unsupported));
}
