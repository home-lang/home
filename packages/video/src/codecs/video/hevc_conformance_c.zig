//! Private scalar bridge for native_encoder.c. C-only builds must link this Zig object.
const crop = @import("hevc_conformance.zig");
export fn home_hevc_crop_sps(source: ?[*]const u8, length: usize, padded_width: u32, padded_height: u32, width: u32, height: u32, destination: ?[*]u8, capacity: usize, written: ?*usize) c_int {
    const size = written orelse return -1;
    size.* = 0;
    const input = source orelse return -1;
    const output = destination orelse return -1;
    if (length > crop.maximum_nal or capacity > crop.maximum_output) return -1;
    const result = crop.rewrite(input[0..length], .{ .width = padded_width, .height = padded_height }, .{ .width = width, .height = height }, output[0..capacity]) catch return -1;
    size.* = result.len;
    return 0;
}
