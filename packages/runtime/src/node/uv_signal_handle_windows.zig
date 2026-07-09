// Copied from bun/src/runtime/node/uv_signal_handle_windows.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// **Partial port (shape-only declaration of the C exports).**
//
// Upstream `uv_signal_handle_windows.zig` is a 46-line Windows-only file
// exporting two `extern "C"` entrypoints (`Bun__UVSignalHandle__init`,
// `Bun__UVSignalHandle__close`) that `BunProcess.cpp` calls to register a
// libuv `uv_signal_t` against the per-VM uv loop. The body wires three
// things this port doesn't have yet:
//   * `bun.jsc.JSGlobalObject.bunVM().uvLoop()` — JSC + VM substrate,
//     unported.
//   * `bun.windows.libuv.uv_signal_t` / `uv_signal_init` /
//     `uv_signal_start` / `uv_close` / `uv_unref` — libuv FFI surface,
//     unported (Home only has the libuv types in process scaffolding).
//   * `bun.new` / `bun.destroy` — the per-thread heap-allocator pair,
//     unported.
//
// What's ported here:
//   * The `uv_signal_callback` typedef — the C signature
//     `BunProcess.cpp` declares in its header, **load-bearing** because
//     it's the only function-pointer shape we expose to the C++ side.
//   * Empty `init` / `close` Zig wrappers that compile down to no-ops on
//     non-Windows hosts (so `home_rt.node.uv_signal_handle_windows`
//     resolves on every target). On Windows the bodies stay as
//     `@compileError` placeholders until libuv + JSC re-land — same shape
//     as upstream's `comptime if (Environment.isWindows) @export`, so the
//     swap is mechanical.
//
// No imports rewritten — this slice only needs `std` and a local
// `home_rt.Environment` flag.

const std = @import("std");

const home_rt = @import("home");
const Environment = home_rt.Environment;

/// Stand-in for `bun.windows.libuv.uv_signal_t`. The libuv handle is a
/// fixed-layout `extern struct` whose internals only matter to libuv; here
/// we expose it as an `opaque` so callers can name the type and hold a
/// `*UvSignalT` pointer without copying the layout. Replace with the real
/// `home_rt.windows.libuv.uv_signal_t` when libuv FFI lands.
pub const UvSignalT = opaque {};

/// C-ABI signature for the signal-delivery callback. Carried verbatim from
/// upstream so the `BunProcess.cpp` declaration matches byte-for-byte.
pub const UvSignalCallback = *const fn (sig: *UvSignalT, num: c_int) callconv(.c) void;

/// Windows: allocates and registers a `uv_signal_t` on the calling VM's
/// uv loop. Non-Windows: this function is intentionally a no-op stub so
/// callers can name the symbol on every target — the C++ side gates its
/// call site on `OS(WINDOWS)`.
///
/// The `global` parameter is typed `*anyopaque` (instead of
/// `*jsc.JSGlobalObject`) until the JSC surface re-lands.
pub fn init(
    global: *anyopaque,
    signal_num: i32,
    callback: UvSignalCallback,
) ?*UvSignalT {
    _ = global;
    _ = signal_num;
    _ = callback;
    if (Environment.isWindows) {
        // TODO: re-attach to `home_rt.windows.libuv.uv_signal_*` once that
        // FFI surface ports. Upstream allocates with `bun.new`, calls
        // `uv_signal_init` / `uv_signal_start`, then `uv_unref`.
        return null;
    }
    return null;
}

/// Windows: stops + closes a `uv_signal_t`, freeing the heap slot in the
/// libuv close callback. Non-Windows: no-op stub.
pub fn close(signal: *UvSignalT) void {
    _ = signal;
    if (Environment.isWindows) {
        // TODO: `uv_signal_stop(signal); uv_close(@ptrCast(signal), &free_cb);`
    }
}

test "uv_signal_handle_windows: UvSignalCallback shape is the C-ABI signature" {
    // Compile-time check: the function-pointer alias must accept (*UvSignalT, c_int)
    // and return void with C calling convention. Stating it inline pins the shape.
    const Cb: type = UvSignalCallback;
    const info = @typeInfo(Cb);
    try std.testing.expectEqual(@as(usize, 1), @intFromBool(info == .pointer));
    const child = info.pointer.child;
    const fn_info = @typeInfo(child).@"fn";
    try std.testing.expectEqual(@as(usize, 2), fn_info.param_types.len);
    try std.testing.expectEqual(std.builtin.CallingConvention.c, fn_info.attrs.@"callconv");
    try std.testing.expectEqual(@as(?type, void), fn_info.return_type);
}

test "uv_signal_handle_windows: init/close are safe no-ops on non-Windows hosts" {
    if (Environment.isWindows) return error.SkipZigTest;

    var probe: i32 = 0;
    const cb: UvSignalCallback = struct {
        fn impl(_: *UvSignalT, _: c_int) callconv(.c) void {}
    }.impl;

    // The first arg is opaque on this stub; pass our own probe address so the
    // body can `_ =` it without dereferencing.
    const result = init(@ptrCast(&probe), 15, cb);
    try std.testing.expectEqual(@as(?*UvSignalT, null), result);
}
