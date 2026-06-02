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

pub const Heap = opaque {};
var main_heap_token: u8 = 0;

fn asHeap(ptr: *u8) *Heap {
    return @ptrCast(@alignCast(ptr));
}

pub fn mustUseAlignedAlloc(alignment: std.mem.Alignment) bool {
    return alignment.toByteUnits() > @alignOf(usize);
}

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

pub export fn mi_malloc_aligned(size: usize, alignment: usize) callconv(.c) ?*anyopaque {
    var ptr: ?*anyopaque = null;
    if (std.c.posix_memalign(&ptr, alignment, size) != 0) return null;
    return ptr;
}

pub export fn mi_realloc_aligned(p: ?*anyopaque, newsize: usize, alignment: usize) callconv(.c) ?*anyopaque {
    if (p == null) return mi_malloc_aligned(newsize, alignment);
    const old_size = mi_usable_size(p);
    const next = mi_malloc_aligned(newsize, alignment) orelse return null;
    @memcpy(@as([*]u8, @ptrCast(next))[0..@min(old_size, newsize)], @as([*]const u8, @ptrCast(p.?))[0..@min(old_size, newsize)]);
    std.c.free(p);
    return next;
}

pub export fn mi_expand(p: ?*anyopaque, newsize: usize) callconv(.c) ?*anyopaque {
    _ = newsize;
    return p;
}

pub export fn mi_heap_new() callconv(.c) ?*Heap {
    return asHeap(&main_heap_token);
}

pub export fn mi_heap_delete(heap: *Heap) callconv(.c) void {
    _ = heap;
}

pub export fn mi_heap_destroy(heap: *Heap) callconv(.c) void {
    _ = heap;
}

pub export fn mi_heap_main() callconv(.c) *Heap {
    return asHeap(&main_heap_token);
}

pub export fn mi_heap_contains(heap: *const Heap, p: ?*const anyopaque) callconv(.c) bool {
    _ = heap;
    return p != null;
}

pub export fn mi_heap_collect(heap: *Heap, force: bool) callconv(.c) void {
    _ = heap;
    _ = force;
}

pub export fn mi_heap_malloc(heap: *Heap, size: usize) callconv(.c) ?*anyopaque {
    _ = heap;
    return mi_malloc(size);
}

pub export fn mi_heap_calloc(heap: *Heap, count: usize, size: usize) callconv(.c) ?*anyopaque {
    _ = heap;
    return mi_calloc(count, size);
}

pub export fn mi_heap_realloc(heap: *Heap, p: ?*anyopaque, newsize: usize) callconv(.c) ?*anyopaque {
    _ = heap;
    return mi_realloc(p, newsize);
}

pub export fn mi_heap_malloc_aligned(heap: *Heap, size: usize, alignment: usize) callconv(.c) ?*anyopaque {
    _ = heap;
    return mi_malloc_aligned(size, alignment);
}

pub export fn mi_heap_realloc_aligned(heap: *Heap, p: ?*anyopaque, newsize: usize, alignment: usize) callconv(.c) ?*anyopaque {
    _ = heap;
    return mi_realloc_aligned(p, newsize, alignment);
}

pub export fn mi_collect(force: bool) callconv(.c) void {
    _ = force;
}

pub const mi_output_fun = *const fn ([*:0]const u8, ?*anyopaque) callconv(.c) void;

pub export fn mi_stats_print_out(out: ?mi_output_fun, arg: ?*anyopaque) callconv(.c) void {
    if (out) |cb| cb("mimalloc shim: libc allocator\n", arg);
}

pub export fn mi_thread_stats_print_out(out: ?mi_output_fun, arg: ?*anyopaque) callconv(.c) void {
    if (out) |cb| cb("mimalloc shim: libc allocator\n", arg);
}

pub const Option = enum(c_int) {
    show_errors,
    verbose,
    allow_decommit,
    limit_os_alloc,
};

pub export fn mi_option_set(option: Option, value: c_long) callconv(.c) void {
    _ = option;
    _ = value;
}

pub export fn mi_option_set_enabled(option: Option, enable: bool) callconv(.c) void {
    _ = option;
    _ = enable;
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

pub const mi_malloc_usable_size = mi_usable_size;

pub export fn mi_free_size(p: ?*anyopaque, size: usize) callconv(.c) void {
    _ = size;
    std.c.free(p);
}

pub export fn mi_free_size_aligned(p: ?*anyopaque, size: usize, alignment: usize) callconv(.c) void {
    _ = size;
    _ = alignment;
    std.c.free(p);
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

pub export fn mi_check_owned(p: ?*const anyopaque) callconv(.c) bool {
    return p != null;
}

test "mimalloc shim libc fallback symbols compile" {
    _ = @typeName(@TypeOf(mi_malloc));
    _ = @typeName(@TypeOf(mi_calloc));
    _ = @typeName(@TypeOf(mi_realloc));
    _ = @typeName(@TypeOf(mi_free));
}
