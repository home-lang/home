//! Checked copies from padded capture planes into tightly packed owned buffers.
//! Callers retain source ownership and must provide non-overlapping destination.
const std = @import("std");
pub const Plane = struct {
    source: []const u8,
    stride: usize,
    row_bytes: usize,
    height: usize,
};
fn planeSize(plane: Plane) !usize {
    if (plane.row_bytes == 0 or plane.height == 0 or plane.stride < plane.row_bytes) return error.InvalidGeometry;
    const size = std.math.mul(usize, plane.row_bytes, plane.height) catch return error.InvalidGeometry;
    const last = std.math.mul(usize, plane.stride, plane.height - 1) catch return error.InvalidGeometry;
    const needed = std.math.add(usize, last, plane.row_bytes) catch return error.InvalidGeometry;
    if (plane.source.len < needed) return error.BufferTooSmall;
    return size;
}
/// Validate all borrowed planes and checked aggregate geometry without reading
/// pixels, allocating, or mutating destination. At least one plane is required.
pub fn packedSize(planes: []const Plane) !usize {
    if (planes.len == 0) return error.InvalidGeometry;
    var size: usize = 0;
    for (planes) |plane| size = std.math.add(usize, size, try planeSize(plane)) catch return error.InvalidGeometry;
    return size;
}
/// Copy in plane order after validating every source and the complete output.
/// Source/destination must not overlap or change during the call. Failure never
/// writes a prefix. Returns bytes written; unused destination bytes are untouched.
pub fn pack(planes: []const Plane, destination: []u8) !usize {
    const size = try packedSize(planes);
    if (destination.len < size) return error.BufferTooSmall;
    var at: usize = 0;
    for (planes) |plane| {
        for (0..plane.height) |y| {
            @memcpy(destination[at..][0..plane.row_bytes], plane.source[y * plane.stride ..][0..plane.row_bytes]);
            at += plane.row_bytes;
        }
    }
    return size;
}
pub fn rows(source: []const u8, stride: usize, width: usize, height: usize, destination: []u8) !void {
    _ = try pack(&.{.{ .source = source, .stride = stride, .row_bytes = width, .height = height }}, destination);
}
/// I420 Y,U,V planes; strides are independent. Dimensions must be even.
/// Validate all three planes before touching destination (failure is atomic).
pub fn packI420(planes: [3][]const u8, strides: [3]usize, width: usize, height: usize, destination: []u8) !void {
    if (width == 0 or height == 0 or (width | height) & 1 != 0) return error.InvalidGeometry;
    var descriptions: [3]Plane = undefined;
    for (0..3) |i| descriptions[i] = .{ .source = planes[i], .stride = strides[i], .row_bytes = if (i == 0) width else width / 2, .height = if (i == 0) height else height / 2 };
    _ = try pack(&descriptions, destination);
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

test "heterogeneous plane bundles concatenate active rows and retain destination suffix" {
    const t = std.testing;
    const planes = [_]Plane{
        .{ .source = &.{ 1, 2, 99, 3, 4 }, .stride = 3, .row_bytes = 2, .height = 2 },
        .{ .source = &.{ 5, 6, 7 }, .stride = 8, .row_bytes = 3, .height = 1 },
        .{ .source = &.{8}, .stride = 1, .row_bytes = 1, .height = 1 },
    };
    var out: [10]u8 = @splat(42);
    try t.expectEqual(@as(usize, 8), try packedSize(&planes));
    try t.expectEqual(@as(usize, 8), try pack(&planes, &out));
    try t.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 42, 42 }, &out);
}
test "late invalid bundle planes short destinations and aggregate overflow preserve all output" {
    const t = std.testing;
    var out: [8]u8 = @splat(42);
    const good = Plane{ .source = &.{ 1, 2 }, .stride = 2, .row_bytes = 2, .height = 1 };
    const short = Plane{ .source = &.{3}, .stride = 2, .row_bytes = 2, .height = 1 };
    try t.expectError(error.BufferTooSmall, pack(&.{ good, short }, &out));
    try t.expectError(error.BufferTooSmall, pack(&.{ good, good }, out[0..3]));
    try t.expectError(error.InvalidGeometry, pack(&.{}, &out));
    const huge = Plane{ .source = @as([*]const u8, @ptrFromInt(1))[0..std.math.maxInt(usize)], .stride = std.math.maxInt(usize), .row_bytes = std.math.maxInt(usize), .height = 1 };
    try t.expectError(error.InvalidGeometry, packedSize(&.{ huge, good }));
    try t.expectEqualSlices(u8, &@as([8]u8, @splat(42)), &out);
}
