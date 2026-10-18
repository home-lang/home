//! Home RGB -> limited-range BT.601 I420. Adapted from perf/simd.zig, with
//! checked strides and actual 2x2 chroma averaging rather than corner sampling.
const std = @import("std");
pub fn convert(rgb: []const u8, width: u32, height: u32, stride: u32, out: []u8) !void {
    if (width == 0 or height == 0 or (width | height) & 1 != 0 or stride < @as(u64, width) * 3) return error.InvalidGeometry;
    const pixels = std.math.mul(usize, width, height) catch return error.InvalidGeometry;
    if (rgb.len < @as(u64, stride) * (height - 1) + @as(u64, width) * 3 or out.len < pixels + pixels / 2) return error.InvalidGeometry;
    for (0..height / 2) |cy| {
        for (0..width / 2) |cx| {
            var r: i32 = 0;
            var g: i32 = 0;
            var b: i32 = 0;
            for (0..2) |dy| {
                for (0..2) |dx| {
                    const x = cx * 2 + dx;
                    const y = cy * 2 + dy;
                    const p = rgb[y * stride + x * 3 ..][0..3];
                    out[y * width + x] = @intCast(((66 * @as(i32, p[0]) + 129 * @as(i32, p[1]) + 25 * @as(i32, p[2]) + 128) >> 8) + 16);
                    r += p[0];
                    g += p[1];
                    b += p[2];
                }
            }
            const uv = cy * (width / 2) + cx;
            out[pixels + uv] = @intCast(((-38 * r - 74 * g + 112 * b + 512) >> 10) + 128);
            out[pixels + pixels / 4 + uv] = @intCast(((112 * r - 94 * g - 18 * b + 512) >> 10) + 128);
        }
    }
}
test "strided RGB conversion averages chroma and rejects truncation" {
    var out: [6]u8 = undefined;
    const rgb = [_]u8{ 255, 0, 0, 0, 255, 0, 99, 99, 0, 0, 255, 255, 255, 255 };
    try convert(&rgb, 2, 2, 8, &out);
    try std.testing.expectEqualSlices(u8, &.{ 82, 144, 41, 235, 128, 128 }, &out);
    try std.testing.expectError(error.InvalidGeometry, convert(rgb[0..13], 2, 2, 8, &out));
    try std.testing.expectError(error.InvalidGeometry, convert(&rgb, 1, 2, 8, &out));
}
