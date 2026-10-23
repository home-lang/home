const std = @import("std");
const png = @import("png");
const a = std.heap.c_allocator;
export fn home_png_decode(data: [*]const u8, length: usize, output: *?[*]u8, size: *usize, width: *u32, height: *u32, format: *u32, bits: *u32) c_int {
    output.* = null;
    size.* = 0;
    var result = png.decode(a, data[0..length], .{ .expand_palette = true }) catch return -1;
    defer result.deinit();
    const pixels = a.dupe(u8, result.default_image.pixels) catch return -2;
    output.* = pixels.ptr;
    size.* = pixels.len;
    width.* = result.default_image.width;
    height.* = result.default_image.height;
    format.* = switch (result.default_image.format) {
        .gray => 0,
        .rgb => 1,
        .rgba => 2,
        .indexed => unreachable,
    };
    bits.* = result.default_image.bits;
    return 0;
}
export fn home_png_free(data: [*]u8, length: usize) void {
    a.free(data[0..length]);
}
