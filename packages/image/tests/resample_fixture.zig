const std = @import("std");
const resize = @import("resample");
const pixel = resize.pixel;
const a = std.heap.c_allocator;
export fn home_pixel_resize(format: u32, bits: u32, big: u32, filter: u32, sw: u32, sh: u32, dw: u32, dh: u32, output: *?[*]u8, length: *usize) c_int {
    output.* = null;
    length.* = 0;
    if (format > 2 or (bits != 8 and bits != 16) or big > 1 or filter > 4 or sw == 0 or sh == 0 or sw > 512 or sh > 512 or dw == 0 or dh == 0 or dw > 512 or dh > 512) return -1;
    const kind: pixel.Format = @enumFromInt(format);
    const endian: std.builtin.Endian = if (big == 1) .big else .little;
    const row = pixel.packedRow(sw, kind, @intCast(bits)) catch return -2;
    const stride = row + 7;
    const source = a.alloc(u8, 1 + (sh - 1) * stride + row) catch return -3;
    defer {
        @memset(source, 0xee);
        a.free(source);
    }
    @memset(source, 0xee);
    for (0..sh) |y| for (0..sw) |x| for (0..kind.channels()) |ch| {
        const hi: u8 = @truncate(x * 37 + y * 53 + ch * 79 + (x * y) % 251);
        const lo: u8 = @truncate(x * 17 + y * 29 + ch * 43);
        const at = 1 + y * stride + (x * kind.channels() + ch) * (bits / 8);
        if (bits == 8) source[at] = hi else std.mem.writeInt(u16, source[at..][0..2], @as(u16, hi) << 8 | lo, endian);
    };
    const result = resize.resize(a, .{ .data = source[1..], .width = sw, .height = sh, .stride = stride, .format = kind, .bits = @intCast(bits), .endian = endian }, dw, dh, @enumFromInt(filter), .{}) catch return -4;
    output.* = @constCast(result.view.data.ptr);
    length.* = result.view.data.len;
    return 0;
}
export fn home_resample_free(data: [*]u8, length: usize) void {
    a.free(data[0..length]);
}
