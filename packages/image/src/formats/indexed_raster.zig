//! Shared checked palette expansion for Home image adapters.
const std = @import("std");
const raster = @import("raster_encoder.zig");
pub fn indexedView(pixels: []const u8, width: u32, height: u32) !raster.View {
    const view = raster.View{ .data = pixels, .width = width, .height = height, .stride = width, .format = .gray };
    _ = try view.validate();
    return view;
}
pub fn validateIndices(img: anytype, view: raster.View) !void {
    const palette = img.palette orelse return error.InvalidPalette;
    if (palette.len == 0 or palette.len > 256) return error.InvalidPalette;
    for (0..view.height) |y| for (view.data[y * view.stride ..][0..view.width]) |index| {
        if (index >= palette.len) return error.InvalidPalette;
    };
}
pub fn expandIndices(allocator: std.mem.Allocator, img: anytype, view: raster.View) !raster.View {
    const stride = std.math.mul(usize, view.width, 4) catch return error.InvalidGeometry;
    const size = std.math.mul(usize, stride, view.height) catch return error.InvalidGeometry;
    const rgba = try allocator.alloc(u8, size);
    for (0..view.height) |y| for (view.data[y * view.stride ..][0..view.width], 0..) |index, x| {
        const color = img.palette.?[index];
        @memcpy(rgba[y * stride + x * 4 ..][0..4], &[_]u8{ color.r, color.g, color.b, color.a });
    };
    return .{ .data = rgba, .width = view.width, .height = view.height, .stride = stride, .format = .rgba };
}
