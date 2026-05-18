// Copied verbatim from bun/src/safety/asan.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// AddressSanitizer + LeakSanitizer wrappers. All entry points compile to
// no-ops on the Home build because we don't surface an `enable_asan` flag
// in `home_rt.Environment` today. The full ASAN substrate re-attaches when
// `Environment.enable_asan` lands. The runtime-default `__asan_default_options`
// override is intentionally omitted (no symbol export when disabled).

/// stubbed: re-attaches when home_rt.Environment.enable_asan lands.
const enable_asan = false;

/// https://github.com/llvm/llvm-project/blob/main/compiler-rt/include/sanitizer/asan_interface.h
const c = if (enable_asan) struct {
    extern fn __asan_poison_memory_region(ptr: *const anyopaque, size: usize) void;
    extern fn __asan_unpoison_memory_region(ptr: *const anyopaque, size: usize) void;
    extern fn __asan_address_is_poisoned(ptr: *const anyopaque) bool;
    extern fn __asan_describe_address(ptr: *const anyopaque) void;
    extern fn __asan_update_allocation_context(ptr: *const anyopaque) c_int;
    /// https://github.com/llvm/llvm-project/blob/main/compiler-rt/include/sanitizer/lsan_interface.h
    extern fn __lsan_register_root_region(ptr: *const anyopaque, size: usize) void;
    extern fn __lsan_unregister_root_region(ptr: *const anyopaque, size: usize) void;

    pub fn poison(ptr: *const anyopaque, size: usize) void {
        __asan_poison_memory_region(ptr, size);
    }
    pub fn unpoison(ptr: *const anyopaque, size: usize) void {
        __asan_unpoison_memory_region(ptr, size);
    }
    pub fn isPoisoned(ptr: *const anyopaque) bool {
        return __asan_address_is_poisoned(ptr);
    }
    pub fn describe(ptr: *const anyopaque) void {
        __asan_describe_address(ptr);
    }
    pub fn updateAllocationContext(ptr: *const anyopaque) c_int {
        return __asan_update_allocation_context(ptr);
    }
    pub fn registerRootRegion(ptr: *const anyopaque, size: usize) void {
        __lsan_register_root_region(ptr, size);
    }
    pub fn unregisterRootRegion(ptr: *const anyopaque, size: usize) void {
        __lsan_unregister_root_region(ptr, size);
    }
} else struct {
    pub fn poison(_: *const anyopaque, _: usize) void {}
    pub fn unpoison(_: *const anyopaque, _: usize) void {}
    pub fn isPoisoned(_: *const anyopaque) bool {
        return false;
    }
    pub fn describe(_: *const anyopaque) void {}
    pub fn updateAllocationContext(_: *const anyopaque) c_int {
        return 0;
    }
    pub fn registerRootRegion(_: *const anyopaque, _: usize) void {}
    pub fn unregisterRootRegion(_: *const anyopaque, _: usize) void {}
};

pub const enabled = enable_asan;

/// Update allocation stack trace for the given allocation to the current stack
/// trace
pub fn updateAllocationContext(ptr: *const anyopaque) bool {
    if (!comptime enabled) return false;
    return c.updateAllocationContext(ptr) == 1;
}

/// Describes an address (prints out where it was allocated, freed, stacktraces,
/// etc.)
pub fn describe(ptr: *const anyopaque) void {
    if (!comptime enabled) return;
    c.describe(ptr);
}

/// Tell LSAN to scan `[ptr, ptr+size)` for live pointers during leak checking.
///
/// Needed when a malloc-backed object is reachable only through a pointer that
/// itself lives inside a mimalloc page (which LSAN does not scan). Registering
/// the mimalloc-backed owner as a root region restores the reachability chain
/// so the malloc allocation isn't reported as a false-positive leak at exit.
pub fn registerRootRegion(ptr: *const anyopaque, size: usize) void {
    if (!comptime enabled) return;
    c.registerRootRegion(ptr, size);
}

/// Undo a prior `registerRootRegion(ptr, size)` with the exact same arguments.
pub fn unregisterRootRegion(ptr: *const anyopaque, size: usize) void {
    if (!comptime enabled) return;
    c.unregisterRootRegion(ptr, size);
}

/// Manually poison a memory region
///
/// Useful for making custom allocators asan-aware (for example HiveArray)
///
/// *NOT* threadsafe
pub fn poison(ptr: *const anyopaque, size: usize) void {
    if (!comptime enabled) return;
    c.poison(ptr, size);
}

/// Manually unpoison a memory region
///
/// Useful for making custom allocators asan-aware (for example HiveArray)
///
/// *NOT* threadsafe
pub fn unpoison(ptr: *const anyopaque, size: usize) void {
    if (!comptime enabled) return;
    c.unpoison(ptr, size);
}

fn isPoisoned(ptr: *const anyopaque) bool {
    if (!comptime enabled) return false;
    return c.isPoisoned(ptr);
}

pub fn assertPoisoned(ptr: *const anyopaque) void {
    if (!comptime enabled) return;
    if (!isPoisoned(ptr)) {
        c.describe(ptr);
        @panic("Address is not poisoned");
    }
}

pub fn assertUnpoisoned(ptr: *const anyopaque) void {
    if (!comptime enabled) return;
    if (isPoisoned(ptr)) {
        c.describe(ptr);
        @panic("Address is poisoned");
    }
}

test "asan no-op path is callable when disabled" {
    const std = @import("std");
    try std.testing.expectEqual(false, enabled);
    var buf: [16]u8 = undefined;
    poison(&buf, buf.len);
    unpoison(&buf, buf.len);
    try std.testing.expectEqual(false, isPoisoned(&buf));
    describe(&buf);
    _ = updateAllocationContext(&buf);
    registerRootRegion(&buf, buf.len);
    unregisterRootRegion(&buf, buf.len);
    assertUnpoisoned(&buf);
}
