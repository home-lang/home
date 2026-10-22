//! C-only independent decoder fixture; no image codec is supplied by the test.
const std = @import("std");
const lzw = @import("lzw");
const gif = @import("gif");
export fn home_gif_lzw(data: [*]const u8, length: usize, minimum: u8, output: [*]u8, capacity: usize, written: *usize) c_int {
    const encoded = lzw.encode(std.heap.c_allocator, data[0..length], minimum) catch return -1;
    defer std.heap.c_allocator.free(encoded);
    if (encoded.len > capacity) return -2;
    @memcpy(output[0..encoded.len], encoded);
    written.* = encoded.len;
    return 0;
}

export fn home_video_gif(data: [*]const u8, length: usize, width: u16, height: u16, output: [*]u8, capacity: usize, written: *usize) c_int {
    const pixels = std.math.mul(usize, width, height) catch return -1;
    const frame_bytes = std.math.mul(usize, pixels, 3) catch return -1;
    if (length != frame_bytes * 2) return -1;
    var writer = gif.GifWriter.init(std.heap.c_allocator, width, height);
    defer writer.deinit();
    writer.addFrame(data[0..frame_bytes], 10) catch return -2;
    writer.addFrame(data[frame_bytes..length], 20) catch return -3;
    const bytes = writer.write() catch return -4;
    defer std.heap.c_allocator.free(bytes);
    if (bytes.len > capacity) return -5;
    @memcpy(output[0..bytes.len], bytes);
    written.* = bytes.len;
    return 0;
}
