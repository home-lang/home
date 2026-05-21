/// A fallback zero-initializing allocator.
pub const allocator = Allocator{
    .ptr = undefined,
    .vtable = &vtable,
};

const vtable = Allocator.VTable{
    .alloc = alloc,
    .resize = resize,
    .remap = Allocator.noRemap, // the mimalloc z_allocator doesn't support remap
    .free = free,
};

fn alloc(_: *anyopaque, len: usize, alignment: Alignment, return_address: usize) ?[*]u8 {
    const result = c_allocator.rawAlloc(len, alignment, return_address) orelse
        return null;
    @memset(result[0..len], 0);
    return result;
}

fn resize(
    _: *anyopaque,
    buf: []u8,
    alignment: Alignment,
    new_len: usize,
    return_address: usize,
) bool {
    if (!c_allocator.rawResize(buf, alignment, new_len, return_address)) {
        return false;
    }
    @memset(buf.ptr[buf.len..new_len], 0);
    return true;
}

fn free(_: *anyopaque, buf: []u8, alignment: Alignment, return_address: usize) void {
    c_allocator.rawFree(buf, alignment, return_address);
}

const std = @import("std");
const c_allocator = std.heap.c_allocator;

const Alignment = std.mem.Alignment;
const Allocator = std.mem.Allocator;

test "fallback.z: alloc returns zeroed memory" {
    const bytes = try allocator.alloc(u8, 16);
    defer allocator.free(bytes);

    const expected: [16]u8 = @splat(0);
    try std.testing.expectEqualSlices(u8, &expected, bytes);
}

test "fallback.z: resize growth zeroes the new tail" {
    var bytes = try allocator.alloc(u8, 4);
    errdefer allocator.free(bytes);
    @memset(bytes, 0x7F);

    if (!allocator.resize(bytes, 8)) {
        allocator.free(bytes);
        return error.SkipZigTest;
    }

    bytes = bytes.ptr[0..8];
    defer allocator.free(bytes);

    const original: [4]u8 = @splat(0x7F);
    const zeroed: [4]u8 = @splat(0);
    try std.testing.expectEqualSlices(u8, &original, bytes[0..4]);
    try std.testing.expectEqualSlices(u8, &zeroed, bytes[4..8]);
}
