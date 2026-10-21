//! Compare the original per-pixel path to block conversion on the same fixture.
//! Run with --dep yuv -Mroot=<this file> -Myuv=packages/video/src/core/yuv_rgb.zig.
const std = @import("std");
const yuv = @import("yuv");
fn legacy(src: yuv.I420, conversion: yuv.Conversion, out: []u8, stride: u32) !void {
    try src.validate();
    if (stride < @as(u64, src.width) * 3 or @as(u64, stride) * (src.height - 1) + @as(u64, src.width) * 3 > out.len) return error.BufferTooSmall;
    for (0..src.height) |y| for (0..src.width) |x| {
        out[y * stride + x * 3 ..][0..3].* = conversion.toRgb(src.planes[0][y * src.strides[0] + x], src.planes[1][(y / 2) * src.strides[1] + x / 2], src.planes[2][(y / 2) * src.strides[2] + x / 2]);
    };
}
fn measure(comptime block: bool, src: yuv.I420, conversion: yuv.Conversion, output: []u8, stride: u32, frames: usize) !u64 {
    for (0..3) |_| {
        if (block) try yuv.decode420(src, conversion, output, stride) else try legacy(src, conversion, output, stride);
        std.mem.doNotOptimizeAway(output);
    }
    var timer = try std.time.Timer.start();
    for (0..frames) |_| {
        if (block) try yuv.decode420(src, conversion, output, stride) else try legacy(src, conversion, output, stride);
        std.mem.doNotOptimizeAway(output);
    }
    return timer.read();
}
pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const width = 640;
    const height = 480;
    const ystride = width + 32;
    const cstride = width / 2 + 16;
    const stride = width * 3 + 32;
    const ys = try allocator.alloc(u8, ystride * height);
    defer allocator.free(ys);
    const us = try allocator.alloc(u8, cstride * height / 2);
    defer allocator.free(us);
    const vs = try allocator.alloc(u8, cstride * height / 2);
    defer allocator.free(vs);
    var seed: u32 = 12345;
    for ([_][]u8{ ys, us, vs }) |plane| for (plane) |*pixel| {
        seed = seed *% 1664525 +% 1013904223;
        pixel.* = @truncate(seed >> 24);
    };
    const src = yuv.I420{ .width = width, .height = height, .planes = .{ ys, us, vs }, .strides = .{ ystride, cstride, cstride } };
    const old = try allocator.alloc(u8, stride * height);
    defer allocator.free(old);
    const new = try allocator.alloc(u8, stride * height);
    defer allocator.free(new);
    @memset(old, 99);
    @memset(new, 99);
    const frames = 20;
    std.debug.print("matrix,range,width,height,method,frames,total_ns,checksum\n", .{});
    for ([_]yuv.Matrix{ .bt601, .bt709, .bt2020 }) |matrix| for ([_]yuv.Range{ .full, .limited }) |range| {
        const conversion = yuv.Conversion.init(matrix, range);
        for (0..3) |repeat| {
            var before: u64 = 0;
            var after: u64 = 0;
            if (repeat & 1 == 0) {
                before = try measure(false, src, conversion, old, stride, frames);
                after = try measure(true, src, conversion, new, stride, frames);
            } else {
                after = try measure(true, src, conversion, new, stride, frames);
                before = try measure(false, src, conversion, old, stride, frames);
            }
            if (!std.mem.eql(u8, old, new)) return error.OutputMismatch;
            const checksum = std.hash.Wyhash.hash(0, new);
            std.debug.print("{s},{s},{d},{d},legacy,{d},{d},{d}\n", .{ @tagName(matrix), @tagName(range), width, height, frames, before, checksum });
            std.debug.print("{s},{s},{d},{d},block,{d},{d},{d}\n", .{ @tagName(matrix), @tagName(range), width, height, frames, after, checksum });
        }
    };
}
