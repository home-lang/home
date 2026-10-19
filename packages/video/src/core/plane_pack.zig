//! Checked copies from padded capture planes into tightly packed owned buffers.
//! Callers retain source ownership and must provide non-overlapping destination.
const std = @import("std");
pub fn rows(source: []const u8, stride: usize, width: usize, height: usize, destination: []u8) !void {
    if (width == 0 or height == 0 or stride < width) return error.InvalidGeometry;
    const size = std.math.mul(usize, width, height) catch return error.InvalidGeometry;
    const last = std.math.mul(usize, stride, height - 1) catch return error.InvalidGeometry;
    const needed = std.math.add(usize, last, width) catch return error.InvalidGeometry;
    if (source.len < needed or destination.len < size) return error.BufferTooSmall;
    for (0..height) |y| @memcpy(destination[y * width ..][0..width], source[y * stride ..][0..width]);
}
/// I420 Y,U,V planes; strides are independent. Dimensions must be even.
/// Validate all three planes before touching destination (failure is atomic).
pub fn packI420(planes: [3][]const u8, strides: [3]usize, width: usize, height: usize, destination: []u8) !void {
    if (width == 0 or height == 0 or (width | height) & 1 != 0) return error.InvalidGeometry;
    const pixels = std.math.mul(usize, width, height) catch return error.InvalidGeometry;
    const size = std.math.add(usize, pixels, pixels / 2) catch return error.InvalidGeometry;
    if (destination.len < size) return error.BufferTooSmall;
    for (0..3) |i| {
        const w = if (i == 0) width else width / 2;
        const h = if (i == 0) height else height / 2;
        if (strides[i] < w) return error.InvalidGeometry;
        const last = std.math.mul(usize, strides[i], h - 1) catch return error.InvalidGeometry;
        const needed = std.math.add(usize, last, w) catch return error.InvalidGeometry;
        if (planes[i].len < needed) return error.BufferTooSmall;
    }
    try rows(planes[0], strides[0], width, height, destination[0..pixels]);
    try rows(planes[1], strides[1], width / 2, height / 2, destination[pixels..][0 .. pixels / 4]);
    try rows(planes[2], strides[2], width / 2, height / 2, destination[pixels + pixels / 4 ..][0 .. pixels / 4]);
}
test "I420 padded planes omit padding and accept absent final padding" {
    var out: [12]u8 = undefined;
    try packI420(.{ &.{ 1, 2, 3, 4, 99, 99, 5, 6, 7, 8 }, &.{ 9, 10 }, &.{ 11, 12 } }, .{ 6, 4, 3 }, 4, 2, &out);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 }, &out);
}
test "invalid geometry, overflow and truncated chroma never write output" {
    var out: [12]u8 = @splat(42);
    try std.testing.expectError(error.BufferTooSmall, packI420(.{ &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, &.{ 9, 10 }, &.{11} }, .{ 4, 2, 2 }, 4, 2, &out));
    try std.testing.expectEqualSlices(u8, &@as([12]u8, @splat(42)), &out);
    try std.testing.expectError(error.InvalidGeometry, rows(&.{}, std.math.maxInt(usize), 2, 3, &out));
    try std.testing.expectError(error.InvalidGeometry, packI420(.{ &.{}, &.{}, &.{} }, .{ 0, 0, 0 }, 3, 2, &out));
    try std.testing.expectError(error.BufferTooSmall, rows(&.{ 1, 2, 3, 4 }, 2, 2, 2, out[0..3]));
}
