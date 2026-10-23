const std = @import("std");
const pixel = @import("pixel");
const a = std.heap.c_allocator;
export fn home_pixel_convert(sf: u32, sb: u32, se: u32, tf: u32, tb: u32, te: u32, width: u32, height: u32, output: *?[*]u8, length: *usize) c_int {
    output.* = null;
    length.* = 0;
    if (sf > 2 or tf > 2 or (sb != 8 and sb != 16) or (tb != 8 and tb != 16) or se > 1 or te > 1 or width == 0 or height == 0 or width > 512 or height > 512) return -1;
    const format: pixel.Format = @enumFromInt(sf);
    const row = pixel.packedRow(width, format, @intCast(sb)) catch return -2;
    const stride = row + 7;
    const source = a.alloc(u8, 1 + (height - 1) * stride + row) catch return -3;
    defer {
        @memset(source, 0xee);
        a.free(source);
    }
    @memset(source, 0xee);
    for (0..height) |y| for (0..width) |x| for (0..format.channels()) |ch| {
        const hi: u8 = @truncate(x * 37 + y * 53 + ch * 79 + (x * y) % 251);
        const lo: u8 = @truncate(x * 17 + y * 29 + ch * 43);
        const at = 1 + y * stride + (x * format.channels() + ch) * (sb / 8);
        if (sb == 8) source[at] = hi else std.mem.writeInt(u16, source[at..][0..2], @as(u16, hi) << 8 | lo, if (se == 1) .big else .little);
    };
    const result = pixel.Owned.copy(a, .{ .data = source[1..], .width = width, .height = height, .stride = stride, .format = format, .bits = @intCast(sb), .endian = if (se == 1) .big else .little }, @enumFromInt(tf), @intCast(tb), if (te == 1) .big else .little) catch return -4;
    output.* = @constCast(result.view.data.ptr);
    length.* = result.view.data.len;
    return 0;
}
export fn home_pixel_free(data: [*]u8, length: usize) void {
    a.free(data[0..length]);
}
