//! CMM fixture boundary only. Production image code has no Little CMS dependency.
const std = @import("std");
const icc = @import("icc");
pub export fn home_test_srgb(length: *usize) ?[*]u8 {
    length.* = 0;
    const bytes = icc.createSRGBProfile(std.heap.c_allocator) catch return null;
    length.* = bytes.len;
    return bytes.ptr;
}
pub export fn home_test_icc_free(data: [*]u8, length: usize) void {
    std.heap.c_allocator.free(data[0..length]);
}
