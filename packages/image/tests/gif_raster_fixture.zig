//! Borrowed padded/unaligned inputs retire before independent giflib readback.
const std = @import("std");
const gif = @import("gif");
const a = std.heap.c_allocator;
fn value(index: usize, channel: usize, mode: u32) u8 {
    if (channel == 3) return if (mode == 2 or mode == 4) 0 else if (mode == 1) (if (index % 4 == 0) 127 else if (index % 4 == 1) 128 else 255) else 255;
    if (mode == 3) return @intCast(((index >> @as(u6, @intCast((2 - channel) * 4))) & 15) * 17);
    return @truncate(index * ([_]usize{ 1, 73, 151 })[channel]);
}
export fn home_gif_raster(format: u32, bits: u32, big: u32, mode: u32, width: u32, height: u32, output: *?[*]u8, length: *usize) c_int {
    output.* = null;
    length.* = 0;
    if (format > 2 or (bits != 8 and bits != 16) or big > 1 or mode > 4 or width == 0 or height == 0 or width > 512 or height > 512) return -1;
    const kind: gif.raster.Format = @enumFromInt(format);
    const row = @as(usize, width) * kind.channels() * (bits / 8);
    const stride = row + 7;
    const bytes = a.alloc(u8, 1 + (height - 1) * stride + row) catch return -2;
    defer {
        @memset(bytes, 0xee);
        a.free(bytes);
    }
    @memset(bytes, 0xee);
    for (0..height) |y| for (0..width) |x| for (0..kind.channels()) |ch| {
        const index = y * width + x;
        const hi = value(index, ch, mode);
        const lo: u8 = @truncate(index * 17 + ch * 43);
        const at = 1 + y * stride + (x * kind.channels() + ch) * (bits / 8);
        if (bits == 8) bytes[at] = hi else std.mem.writeInt(u16, bytes[at..][0..2], @as(u16, hi) << 8 | lo, if (big == 1) .big else .little);
    };
    const encoded = gif.encode(a, .{ .data = bytes[1..], .width = width, .height = height, .stride = stride, .format = kind, .bits = @intCast(bits), .endian = if (big == 1) .big else .little }, .{ .alpha_threshold = if (mode == 4) 0 else 128 }) catch return -3;
    output.* = encoded.ptr;
    length.* = encoded.len;
    return 0;
}
export fn home_gif_free(data: [*]u8, length: usize) void {
    a.free(data[0..length]);
}
