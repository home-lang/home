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

// Usable-size query. Upstream `mi_usable_size` reports the actual allocation
// size mimalloc reserved for a pointer. With the libc-backed shim we route to
// the platform's libc equivalent (`malloc_size` on Darwin, `malloc_usable_size`
// elsewhere). `boringssl/boringssl.zig`'s `OPENSSL_memory_*` exports use it to
// zero freed blocks and report sizes.
const builtin = @import("builtin");
extern fn malloc_size(ptr: ?*const anyopaque) usize;
extern fn malloc_usable_size(ptr: ?*anyopaque) usize;

pub export fn mi_usable_size(p: ?*const anyopaque) callconv(.c) usize {
    if (p == null) return 0;
    if (builtin.os.tag.isDarwin()) {
        return malloc_size(p);
    }
    return malloc_usable_size(@constCast(p));
}

// Thread-pool hint. Upstream `mimalloc_sys/mimalloc.zig` declares this as an
// `extern fn` that marks the calling thread as a pool worker so mimalloc can
// tune its heaps. With the libc-backed shim there is no mimalloc heap to tune,
// so it is a faithful no-op until the vendored allocator re-attaches.
pub export fn mi_thread_set_in_threadpool() callconv(.c) void {}

// Shim: with the libc-backed allocator there is no separate mimalloc heap
// region, so report ownership of any non-null heap pointer it handed out.
pub export fn mi_is_in_heap_region(p: ?*const anyopaque) callconv(.c) bool {
    return p != null;
}

test "mimalloc shim libc fallback symbols compile" {
    _ = @typeName(@TypeOf(mi_malloc));
    _ = @typeName(@TypeOf(mi_calloc));
    _ = @typeName(@TypeOf(mi_realloc));
    _ = @typeName(@TypeOf(mi_free));
}
