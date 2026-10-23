//! Exact orthogonal copies of borrowed integer pixels; no sample conversion.
const std = @import("std");
const pixel = @import("formats/pixel_view.zig");
pub const Transform = @import("ops/orientation.zig").Transform;
pub const Info = struct { width: u32, height: u32, row_bytes: usize, size: usize };
pub fn info(source: pixel.View, transform: Transform) !Info {
    _ = try source.validate();
    const extent = transform.extent(.{ .width = source.width, .height = source.height });
    const row = try pixel.packedRow(@intCast(extent.width), source.format, source.bits);
    return .{ .width = @intCast(extent.width), .height = @intCast(extent.height), .row_bytes = row, .size = try std.math.mul(usize, row, extent.height) };
}
/// Validate geometry, spans and all overlap before writing. Destination padding
/// is untouched. Samples, channel order, endian and straight alpha stay exact.
pub fn into(source: pixel.View, transform: Transform, output: []u8, stride: usize) !void {
    const planned = try info(source, transform);
    const target = pixel.View{ .data = output, .width = planned.width, .height = planned.height, .stride = stride, .format = source.format, .bits = source.bits, .endian = source.endian };
    _ = try target.validate();
    const source_row = try pixel.packedRow(source.width, source.format, source.bits);
    const source_span = (@as(usize, source.height) - 1) * source.stride + source_row;
    const target_span = (@as(usize, planned.height) - 1) * stride + planned.row_bytes;
    const a = @intFromPtr(source.data.ptr);
    const b = @intFromPtr(output.ptr);
    if ((a <= b and b - a < source_span) or (b < a and a - b < target_span)) return error.Overlap;
    // Identity and vertical flips need only whole-row copies.
    if (!transform.transpose and !transform.hflip) {
        for (0..planned.height) |y| {
            const sy = if (transform.vflip) source.height - 1 - y else y;
            @memcpy(output[y * stride ..][0..planned.row_bytes], source.row(sy, source_row));
        }
        return;
    }
    const bytes = source.format.channels() * (source.bits / 8);
    const extent = @import("ops/orientation.zig").Extent{ .width = source.width, .height = source.height };
    for (0..planned.height) |y| for (0..planned.width) |x| {
        const point = try transform.sourcePoint(extent, .{ .x = x, .y = y });
        const at = point.y * source.stride + point.x * bytes;
        @memcpy(output[y * stride + x * bytes ..][0..bytes], source.data[at..][0..bytes]);
    };
}
/// Owned compact result, including identity; never aliases or retains the input.
pub fn copy(allocator: std.mem.Allocator, source: pixel.View, transform: Transform) !pixel.Owned {
    const planned = try info(source, transform);
    const bytes = try allocator.alloc(u8, planned.size);
    errdefer allocator.free(bytes);
    try into(source, transform, bytes, planned.row_bytes);
    return .{ .allocator = allocator, .view = .{ .data = bytes, .width = planned.width, .height = planned.height, .stride = planned.row_bytes, .format = source.format, .bits = source.bits, .endian = source.endian } };
}

test "all eight transforms retain unaligned padded gray RGB RGBA words alpha and endian exactly" {
    const t = std.testing;
    for ([_]pixel.Format{ .gray, .rgb, .rgba }) |format| for ([_]u8{ 8, 16 }) |bits| for ([_]std.builtin.Endian{ .little, .big }) |endian| {
        for ([_][2]u32{ .{ 5, 3 }, .{ 1, 4 }, .{ 3, 1 }, .{ 1, 1 } }) |dims| {
            const w = dims[0];
            const h = dims[1];
            const bpp = format.channels() * (bits / 8);
            const row = w * bpp;
            const stride = row + 3;
            var storage: [200]u8 = @splat(0xa5);
            const data = storage[1 .. 1 + (h - 1) * stride + row];
            for (0..h) |y| for (0..w) |x| for (0..bpp) |byte| {
                data[y * stride + x * bpp + byte] = @intCast((x * 37 + y * 53 + byte * 29) % 256);
            };
            const source = pixel.View{ .data = data, .width = w, .height = h, .stride = stride, .format = format, .bits = bits, .endian = endian };
            for (0..8) |encoded| {
                const transform = try Transform.fromBits(@intCast(encoded));
                const planned = try info(source, transform);
                const out_stride = planned.row_bytes + 5;
                var out: [260]u8 = @splat(0xbb);
                try into(source, transform, out[1..], out_stride);
                for (0..h) |y| for (0..w) |x| {
                    const sx = if (encoded & 1 != 0) w - 1 - x else x;
                    const sy = if (encoded & 2 != 0) h - 1 - y else y;
                    const dx = if (encoded & 4 != 0) sy else sx;
                    const dy = if (encoded & 4 != 0) sx else sy;
                    try t.expectEqualSlices(u8, data[y * stride + x * bpp ..][0..bpp], out[1 + dy * out_stride + dx * bpp ..][0..bpp]);
                };
                try t.expectEqual(@as(u8, 0xbb), out[0]);
                for (0..planned.height) |y| try t.expect(std.mem.allEqual(u8, out[1 + y * out_stride + planned.row_bytes ..][0..5], 0xbb));
                try t.expectEqual(@as(u8, 0xa5), storage[0]);
            }
        }
    };
}
test "transform rejects malformed or overlapping spans before any destination prefix" {
    const t = std.testing;
    var data: [40]u8 = @splat(33);
    var out: [40]u8 = @splat(73);
    var source = pixel.View{ .data = &data, .width = 3, .height = 2, .stride = 10, .format = .rgb };
    const transform = try Transform.fromRotation(90, false, false);
    try t.expectError(error.BufferTooSmall, into(source, transform, out[0..17], 6));
    try t.expectError(error.InvalidGeometry, into(source, transform, &out, 5));
    try t.expectError(error.Overlap, into(source, transform, data[1..], 6));
    try t.expectError(error.Overlap, into(source, .{}, &data, 10));
    source.data = data[0..18];
    try t.expectError(error.BufferTooSmall, into(source, transform, &out, 6));
    source.data = &data;
    source.stride = std.math.maxInt(usize);
    try t.expectError(error.InvalidGeometry, into(source, transform, &out, 6));
    try t.expect(std.mem.allEqual(u8, &out, 73));
    try t.expect(std.mem.allEqual(u8, &data, 33));
}
fn allocationTest(allocator: std.mem.Allocator) !void {
    const t = std.testing;
    var data = [_]u8{ 0x34, 0x12, 0x78, 0x56 };
    const source = pixel.View{ .data = &data, .width = 2, .height = 1, .stride = 4, .format = .gray, .bits = 16 };
    var result = try copy(allocator, source, try Transform.fromRotation(90, false, false));
    defer result.deinit();
    @memset(&data, 0);
    try t.expectEqual(@as(u32, 1), result.view.width);
    try t.expectEqual(@as(u32, 2), result.view.height);
    try t.expectEqual(@as(u16, 0x1234), result.view.sample16(0, 0)[0]);
    try t.expectEqual(@as(u16, 0x5678), result.view.sample16(0, 1)[0]);
}
test "owned transformed pixels survive source mutation and unwind allocation failure" {
    try allocationTest(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationTest, .{});
}
