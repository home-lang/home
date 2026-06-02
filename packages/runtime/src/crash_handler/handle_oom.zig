// Copied from bun/src/crash_handler/handle_oom.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Rewrite note: upstream's `handleOom` calls `bun.outOfMemory()`, which in
// turn routes through `crash_handler.crashHandler(.out_of_memory, ...)` —
// infrastructure not yet ported to home_rt. We re-export the existing
// `home_rt.handleOom` (a panic-on-OOM shim defined in global.zig) so callers
// have a stable `crash_handler.handle_oom.handleOom` entry point that
// matches the upstream module path.

const home_rt = @import("home");
const std = @import("std");

/// If `result` is `error.OutOfMemory`, panics. Otherwise returns the
/// success payload. Thin wrapper over `home_rt.handleOom` so the upstream
/// module path (`crash_handler/handle_oom.zig`) remains importable.
///
/// The full upstream signature differentiates OOM-only error sets from
/// mixed sets (returning the residual error set without `OutOfMemory`).
/// We don't yet need that distinction; calls that require it should be
/// updated when the broader crash_handler is ported.
pub fn handleOom(result: anytype) @typeInfo(@TypeOf(result)).error_union.payload {
    return home_rt.handleOom(result);
}

test "handleOom passes through success" {
    const allocator = std.testing.allocator;
    const ptr = handleOom(allocator.create(u32));
    defer allocator.destroy(ptr);
    ptr.* = 7;
    try std.testing.expectEqual(@as(u32, 7), ptr.*);
}

test "handleOom forwards to home_rt.handleOom" {
    // Sanity: the wrapper and the underlying home_rt symbol have the
    // same observable behavior on the success path.
    const allocator = std.testing.allocator;
    const a = handleOom(allocator.create(u8));
    defer allocator.destroy(a);
    const b = home_rt.handleOom(allocator.create(u8));
    defer allocator.destroy(b);
    a.* = 1;
    b.* = 1;
    try std.testing.expectEqual(a.*, b.*);
}
