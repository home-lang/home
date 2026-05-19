// Libc-backed shim that satisfies the subset of the `mimalloc_sys.mimalloc`
// API surface called from `home_rt`-consuming wrappers (brotli, zlib,
// libdeflate, c-ares). Lets the `home_rt` test target link without the
// vendored `libmimalloc.a`. Real mimalloc gets re-attached in Phase 12.2
// once the Bun-style `mimalloc-bun` build lands under `pantry/`.
//
// Only the call sites actually exercised by current callers are shimmed:
//
//   - `mi_malloc(size)` → `std.c.malloc(size)`
//   - `mi_calloc(count, size)` → `std.c.calloc(count, size)`
//   - `mi_realloc(p, newsize)` → `std.c.realloc(p, newsize)`
//   - `mi_free(p)` → `std.c.free(p)`
//
// Constraint: this file lives outside `mimalloc_sys/` because the
// vendored extern wrappers there must stay verbatim with upstream Bun.

const std = @import("std");

// Signatures match the vendored `mimalloc.zig`'s `extern fn` decls (which
// default to `callconv(.c)`). Keeping `callconv(.c)` here means callers
// that take the function pointer (c-ares' `ares_library_init_mem`,
// libdeflate's `libdeflate_set_memory_allocator`) get a compatible value.

// Use `export fn` so the symbols `mi_malloc`, `mi_calloc`, `mi_realloc`,
// `mi_free` exist at the linker ABI level — `extern fn mi_malloc(...)`
// declarations in sibling files (e.g. libdeflate_sys/libdeflate.zig)
// resolve here. `pub` is still in place so Zig-side callers can reach
// them via `home_rt.mimalloc_sys.mimalloc.mi_malloc(...)`.

pub export fn mi_malloc(size: usize) callconv(.c) ?*anyopaque {
    return std.c.malloc(size);
}

pub export fn mi_calloc(count: usize, size: usize) callconv(.c) ?*anyopaque {
    return std.c.calloc(count, size);
}

pub export fn mi_realloc(p: ?*anyopaque, newsize: usize) callconv(.c) ?*anyopaque {
    return std.c.realloc(p, newsize);
}

pub export fn mi_free(p: ?*anyopaque) callconv(.c) void {
    std.c.free(p);
}

test "mimalloc shim libc fallback symbols compile" {
    _ = @typeName(@TypeOf(mi_malloc));
    _ = @typeName(@TypeOf(mi_calloc));
    _ = @typeName(@TypeOf(mi_realloc));
    _ = @typeName(@TypeOf(mi_free));
}
