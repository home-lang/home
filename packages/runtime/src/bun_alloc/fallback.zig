// Copied verbatim from bun/src/bun_alloc/fallback.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// The `z_allocator` reference points at `./fallback/z.zig` upstream
// (a zlib-backed allocator wrapper). Until that subtree is copied,
// we wire `z_allocator` to `c_allocator` so the namespace stays
// shaped — Phase 12 follow-ups will swap in the real impl.

pub const c_allocator = std.heap.c_allocator;
pub const z_allocator = std.heap.c_allocator; // TODO(phase-12-2): real z allocator

/// libc can free allocations without being given their size.
pub fn freeWithoutSize(ptr: ?*anyopaque) void {
    std.c.free(ptr);
}

const std = @import("std");
