const std = @import("std");
const oriented = @import("oriented");
const a = std.heap.c_allocator;
export fn home_pixel_orient(format: u32, bits: u32, big: u32, orientation: u32, width: u32, height: u32, output: *?[*]u8, length: *usize, out_width: *u32, out_height: *u32) c_int {
    output.* = null;
    length.* = 0;
    if (format > 2 or (bits != 8 and bits != 16) or big > 1 or width == 0 or height == 0 or width > 512 or height > 512) return -1;
    const transform = oriented.Transform.fromOrientation(orientation) catch return -2;
    const channels: usize = if (format == 0) 1 else if (format == 1) 3 else 4;
    const row = width * channels * (bits / 8);
    const stride = row + 7;
    const data = a.alloc(u8, 1 + (height - 1) * stride + row) catch return -3;
    defer {
        @memset(data, 0xee);
        a.free(data);
    }
    @memset(data, 0xee);
    for (0..height) |y| for (0..width) |x| for (0..channels) |ch| {
        const hi: u8 = @truncate(x * 37 + y * 53 + ch * 79 + (x * y) % 251);
        const lo: u8 = @truncate(x * 17 + y * 29 + ch * 43);
        const at = 1 + y * stride + (x * channels + ch) * (bits / 8);
        if (bits == 8) data[at] = hi else std.mem.writeInt(u16, data[at..][0..2], @as(u16, hi) << 8 | lo, if (big == 1) .big else .little);
    };
    const result = oriented.copy(a, .{ .data = data[1..], .width = width, .height = height, .stride = stride, .format = @enumFromInt(format), .bits = @intCast(bits), .endian = if (big == 1) .big else .little }, transform) catch return -4;
    output.* = @constCast(result.view.data.ptr);
    length.* = result.view.data.len;
    out_width.* = result.view.width;
    out_height.* = result.view.height;
    return 0;
}
export fn home_orient_free(data: [*]u8, length: usize) void {
    a.free(data[0..length]);
}
