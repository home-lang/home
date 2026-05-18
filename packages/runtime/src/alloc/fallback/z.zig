// Copied verbatim from bun/src/alloc/fallback/z.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Zero-initializing allocator that wraps `std.heap.c_allocator`. This is
// the fallback implementation used when mimalloc isn't linked; the
// real mimalloc-backed `z_allocator` re-lands when Phase 12.2 wires
// the alloc subsystem.

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

test "fallback.z.allocator zero-initializes new allocations" {
    const a = allocator;
    const buf = a.rawAlloc(32, .@"1", @returnAddress()) orelse return error.OutOfMemory;
    defer a.rawFree(buf[0..32], .@"1", @returnAddress());
    for (buf[0..32]) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}
