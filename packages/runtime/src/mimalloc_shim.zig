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

pub fn mi_malloc(size: usize) callconv(.c) ?*anyopaque {
    return std.c.malloc(size);
}

pub fn mi_calloc(count: usize, size: usize) callconv(.c) ?*anyopaque {
    return std.c.calloc(count, size);
}

pub fn mi_zalloc(size: usize) callconv(.c) ?*anyopaque {
    return mi_calloc(1, size);
}

pub fn mi_realloc(p: ?*anyopaque, newsize: usize) callconv(.c) ?*anyopaque {
    return std.c.realloc(p, newsize);
}

pub fn mi_free(p: ?*anyopaque) callconv(.c) void {
    std.c.free(p);
}

pub fn mi_malloc_aligned(size: usize, alignment: usize) callconv(.c) ?*anyopaque {
    var ptr: ?*anyopaque = null;
    if (std.c.posix_memalign(&ptr, alignment, size) != 0) return null;
    return ptr;
}

pub fn mi_zalloc_aligned(size: usize, alignment: usize) callconv(.c) ?*anyopaque {
    const ptr = mi_malloc_aligned(size, alignment) orelse return null;
    @memset(@as([*]u8, @ptrCast(ptr))[0..size], 0);
    return ptr;
}

pub fn mi_realloc_aligned(p: ?*anyopaque, newsize: usize, alignment: usize) callconv(.c) ?*anyopaque {
    if (p == null) return mi_malloc_aligned(newsize, alignment);
    const old_size = mi_usable_size(p);
    const next = mi_malloc_aligned(newsize, alignment) orelse return null;
    @memcpy(@as([*]u8, @ptrCast(next))[0..@min(old_size, newsize)], @as([*]const u8, @ptrCast(p.?))[0..@min(old_size, newsize)]);
    std.c.free(p);
    return next;
}

pub fn mi_expand(p: ?*anyopaque, newsize: usize) callconv(.c) ?*anyopaque {
    _ = newsize;
    return p;
}

pub fn mi_heap_new() callconv(.c) ?*Heap {
    return asHeap(&main_heap_token);
}

pub fn mi_heap_delete(heap: *Heap) callconv(.c) void {
    _ = heap;
}

pub fn mi_heap_destroy(heap: *Heap) callconv(.c) void {
    _ = heap;
}

pub fn mi_heap_main() callconv(.c) *Heap {
    return asHeap(&main_heap_token);
}

pub fn mi_heap_contains(heap: *const Heap, p: ?*const anyopaque) callconv(.c) bool {
    _ = heap;
    return p != null;
}

pub fn mi_heap_collect(heap: *Heap, force: bool) callconv(.c) void {
    _ = heap;
    _ = force;
}

pub fn mi_heap_malloc(heap: *Heap, size: usize) callconv(.c) ?*anyopaque {
    _ = heap;
    return mi_malloc(size);
}

pub fn mi_heap_calloc(heap: *Heap, count: usize, size: usize) callconv(.c) ?*anyopaque {
    _ = heap;
    return mi_calloc(count, size);
}

pub fn mi_heap_realloc(heap: *Heap, p: ?*anyopaque, newsize: usize) callconv(.c) ?*anyopaque {
    _ = heap;
    return mi_realloc(p, newsize);
}

pub fn mi_heap_malloc_aligned(heap: *Heap, size: usize, alignment: usize) callconv(.c) ?*anyopaque {
    _ = heap;
    return mi_malloc_aligned(size, alignment);
}

pub fn mi_heap_realloc_aligned(heap: *Heap, p: ?*anyopaque, newsize: usize, alignment: usize) callconv(.c) ?*anyopaque {
    _ = heap;
    return mi_realloc_aligned(p, newsize, alignment);
}

pub fn mi_collect(force: bool) callconv(.c) void {
    _ = force;
}

pub const mi_output_fun = *const fn ([*:0]const u8, ?*anyopaque) callconv(.c) void;

pub fn mi_stats_print_out(out: ?mi_output_fun, arg: ?*anyopaque) callconv(.c) void {
    if (out) |cb| cb("mimalloc shim: libc allocator\n", arg);
}

pub fn mi_thread_stats_print_out(out: ?mi_output_fun, arg: ?*anyopaque) callconv(.c) void {
    if (out) |cb| cb("mimalloc shim: libc allocator\n", arg);
}

fn emptyJson() ?*anyopaque {
    const ptr = mi_malloc(3) orelse return null;
    const bytes = @as([*]u8, @ptrCast(ptr))[0..3];
    @memcpy(bytes, "{}\x00");
    return ptr;
}

pub fn mi_stats_get_json(out: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = out;
    return emptyJson();
}

pub fn mi_heap_dump_json(heap: *Heap, out: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = heap;
    _ = out;
    return emptyJson();
}

pub fn mi_process_info(
    elapsed_msecs: *usize,
    user_msecs: *usize,
    system_msecs: *usize,
    current_rss: *usize,
    peak_rss: *usize,
    current_commit: *usize,
    peak_commit: *usize,
    page_faults: *usize,
) callconv(.c) void {
    elapsed_msecs.* = 0;
    user_msecs.* = 0;
    system_msecs.* = 0;
    current_rss.* = 0;
    peak_rss.* = 0;
    current_commit.* = 0;
    peak_commit.* = 0;
    page_faults.* = 0;
}

pub const Option = enum(c_int) {
    show_errors,
    verbose,
    allow_decommit,
    limit_os_alloc,
};

pub fn mi_option_set(option: Option, value: c_long) callconv(.c) void {
    _ = option;
    _ = value;
}

pub fn mi_option_set_enabled(option: Option, enable: bool) callconv(.c) void {
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

pub fn mi_usable_size(p: ?*const anyopaque) callconv(.c) usize {
    if (p == null) return 0;
    if (builtin.os.tag.isDarwin()) {
        return malloc_size(p);
    }
    return malloc_usable_size(@constCast(p));
}

pub const mi_malloc_usable_size = mi_usable_size;

pub fn mi_free_size(p: ?*anyopaque, size: usize) callconv(.c) void {
    _ = size;
    std.c.free(p);
}

pub fn mi_free_size_aligned(p: ?*anyopaque, size: usize, alignment: usize) callconv(.c) void {
    _ = size;
    _ = alignment;
    std.c.free(p);
}

// Thread-pool hint. Upstream `mimalloc_sys/mimalloc.zig` declares this as an
// `extern fn` that marks the calling thread as a pool worker so mimalloc can
// tune its heaps. With the libc-backed shim there is no mimalloc heap to tune,
// so it is a faithful no-op until the vendored allocator re-attaches.
pub fn mi_thread_set_in_threadpool() callconv(.c) void {}

// Shim: with the libc-backed allocator there is no separate mimalloc heap
// region, so report ownership of any non-null heap pointer it handed out.
pub fn mi_is_in_heap_region(p: ?*const anyopaque) callconv(.c) bool {
    return p != null;
}

pub fn mi_check_owned(p: ?*const anyopaque) callconv(.c) bool {
    return p != null;
}

pub const mi_heap_area_t = extern struct {
    blocks: ?*anyopaque,
    reserved: usize,
    committed: usize,
    used: usize,
    block_size: usize,
    full_block_size: usize,
    reserved1: ?*anyopaque,
};

pub const mi_block_visit_fun = *const fn (?*const Heap, [*c]const mi_heap_area_t, ?*anyopaque, usize, ?*anyopaque) callconv(.c) bool;

pub fn mi_heap_visit_blocks(
    heap: *const Heap,
    visit_all_blocks: bool,
    visitor: ?mi_block_visit_fun,
    arg: ?*anyopaque,
) callconv(.c) bool {
    _ = heap;
    _ = visit_all_blocks;
    _ = visitor;
    _ = arg;
    return true;
}

test "mimalloc shim libc fallback symbols compile" {
    _ = @typeName(@TypeOf(mi_malloc));
    _ = @typeName(@TypeOf(mi_calloc));
    _ = @typeName(@TypeOf(mi_zalloc));
    _ = @typeName(@TypeOf(mi_realloc));
    _ = @typeName(@TypeOf(mi_free));
}

// With `-Denable_jsc` the exe links the real vendor/mimalloc static.c.o —
// exporting these libc wrappers would collide with (or worse, silently
// shadow) the real symbols, so the linker-level exports only exist for
// non-JSC targets. Zig-side callers always go through `bun.mimalloc`,
// which comptime-selects the real extern wrapper under enable_jsc.
comptime {
    if (!@import("build_options").enable_jsc) {
        @export(&mi_malloc, .{ .name = "mi_malloc" });
        @export(&mi_calloc, .{ .name = "mi_calloc" });
        @export(&mi_zalloc, .{ .name = "mi_zalloc" });
        @export(&mi_realloc, .{ .name = "mi_realloc" });
        @export(&mi_free, .{ .name = "mi_free" });
        @export(&mi_malloc_aligned, .{ .name = "mi_malloc_aligned" });
        @export(&mi_zalloc_aligned, .{ .name = "mi_zalloc_aligned" });
        @export(&mi_realloc_aligned, .{ .name = "mi_realloc_aligned" });
        @export(&mi_expand, .{ .name = "mi_expand" });
        @export(&mi_heap_new, .{ .name = "mi_heap_new" });
        @export(&mi_heap_delete, .{ .name = "mi_heap_delete" });
        @export(&mi_heap_destroy, .{ .name = "mi_heap_destroy" });
        @export(&mi_heap_main, .{ .name = "mi_heap_main" });
        @export(&mi_heap_contains, .{ .name = "mi_heap_contains" });
        @export(&mi_heap_collect, .{ .name = "mi_heap_collect" });
        @export(&mi_heap_malloc, .{ .name = "mi_heap_malloc" });
        @export(&mi_heap_calloc, .{ .name = "mi_heap_calloc" });
        @export(&mi_heap_realloc, .{ .name = "mi_heap_realloc" });
        @export(&mi_heap_malloc_aligned, .{ .name = "mi_heap_malloc_aligned" });
        @export(&mi_heap_realloc_aligned, .{ .name = "mi_heap_realloc_aligned" });
        @export(&mi_collect, .{ .name = "mi_collect" });
        @export(&mi_stats_print_out, .{ .name = "mi_stats_print_out" });
        @export(&mi_thread_stats_print_out, .{ .name = "mi_thread_stats_print_out" });
        @export(&mi_stats_get_json, .{ .name = "mi_stats_get_json" });
        @export(&mi_heap_dump_json, .{ .name = "mi_heap_dump_json" });
        @export(&mi_process_info, .{ .name = "mi_process_info" });
        @export(&mi_option_set, .{ .name = "mi_option_set" });
        @export(&mi_option_set_enabled, .{ .name = "mi_option_set_enabled" });
        @export(&mi_usable_size, .{ .name = "mi_usable_size" });
        @export(&mi_free_size, .{ .name = "mi_free_size" });
        @export(&mi_free_size_aligned, .{ .name = "mi_free_size_aligned" });
        @export(&mi_thread_set_in_threadpool, .{ .name = "mi_thread_set_in_threadpool" });
        @export(&mi_is_in_heap_region, .{ .name = "mi_is_in_heap_region" });
        @export(&mi_check_owned, .{ .name = "mi_check_owned" });
        @export(&mi_heap_visit_blocks, .{ .name = "mi_heap_visit_blocks" });
    }
}
