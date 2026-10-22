//! Independent libpng harness input: owners and padded/unaligned raster data
//! retire before the C test reads the returned APNG. No C codec in production.
const std = @import("std");
const apng = @import("apng");
const a = std.heap.c_allocator;

fn pattern(x: usize, y: usize, channel: usize, frame: usize, bits: u8) u16 {
    const hi: u16 = @intCast((x * 37 + y * 53 + channel * 79 + frame * 91 + (x * y) % 251) % 256);
    const lo: u16 = @intCast((x * 17 + y * 29 + channel * 43 + frame * 61) % 256);
    return if (bits == 8) hi else (hi << 8) | lo;
}
fn fill(bytes: []u8, view: apng.raster.View, id: usize) void {
    @memset(bytes, 0xee);
    for (0..view.height) |y| for (0..view.width) |x| for (0..view.format.channels()) |ch| {
        const value = pattern(x, y, ch, id, view.bits);
        const at = 1 + y * view.stride + (x * view.format.channels() + ch) * (view.bits / 8);
        if (view.bits == 8) bytes[at] = @intCast(value) else switch (view.endian) {
            .little => std.mem.writeInt(u16, bytes[at..][0..2], value, .little),
            .big => std.mem.writeInt(u16, bytes[at..][0..2], value, .big),
        }
    };
}
pub export fn home_apng(format: u32, bits: u32, filter: u32, poster: u32, width: u32, height: u32, output: *?[*]u8, length: *usize) c_int {
    output.* = null;
    length.* = 0;
    if (format > 2 or (bits != 8 and bits != 16) or filter > 5 or poster > 1 or width < 3 or height < 2 or width > 512 or height > 512) return -1;
    const kind: apng.raster.Format = @enumFromInt(format);
    var storage: [4][]u8 = @splat(&.{});
    defer for (&storage) |*bytes| {
        @memset(bytes.*, 0xee);
        a.free(bytes.*);
    };
    var frames: [3]apng.Frame = undefined;
    var default: ?apng.raster.View = null;
    for (0..4) |i| {
        const w = if (i == 1) width - 1 else if (i == 2) 1 else width;
        const h = if (i == 1) height - 1 else if (i == 2) 1 else height;
        const row = @as(usize, w) * kind.channels() * (bits / 8);
        const stride = row + 7;
        // No padding after the last row; first sample is intentionally unaligned.
        storage[i] = a.alloc(u8, 1 + (h - 1) * stride + row) catch return -2;
        const view = apng.raster.View{ .data = storage[i][1..], .width = w, .height = h, .stride = stride, .format = kind, .bits = @intCast(bits), .endian = if (i % 2 == 0) .little else .big };
        fill(storage[i], view, if (i == 3) 9 else i);
        if (i == 3) {
            if (poster == 1) default = view;
        } else frames[i] = .{ .view = view, .x = if (i == 1) 1 else 0, .y = if (i == 1) 1 else 0, .delay = switch (i) {
            0 => .{},
            1 => .{ .numerator = 8192, .denominator = 125 },
            else => .{ .numerator = 7, .denominator = 0 },
        }, .dispose = @enumFromInt(i), .blend = if (i == 1) .over else .source };
    }
    const encoded = apng.encode(a, .{ .width = width, .height = height, .frames = &frames, .default_image = default, .plays = 3, .options = .{ .filter = @enumFromInt(filter), .compression = if (filter == 0) 0 else 6 } }) catch return -3;
    output.* = encoded.ptr;
    length.* = encoded.len;
    return 0;
}
pub export fn home_apng_free(data: [*]u8, length: usize) void {
    a.free(data[0..length]);
}
