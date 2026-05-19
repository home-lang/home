// Copied (partial) from bun/src/runtime/webcore/Sink.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.
//
// Scope:
//   * The `Status` enum (ready/closed), and the matching `pending`
//     sentinel pointer used by the stream/Sink VTable layer to mark a
//     placeholder `Sink` instance whose vtable hasn't been installed yet.
//
// The full upstream `Sink` is a 663-line VTable-bridge: `ptr`, `vtable`,
// `Data` union over `streams.Result`, `JSSink(...)` generic factory,
// `DestructorPtr` tagged-pointer union, `UTF8Fallback`, the `JSSinkLayout`
// extern struct, and a pile of `extern fn` glue. None of these stand
// without `streams.Result`, `Syscall.Error`, `bun.api.Subprocess`, the
// `jsc.Codegen.JS*` generated bindings, or `bun.ByteList` — so the
// stateful surface stays parked.
//
// `pending` keeps the same `0xaaaaaaaa` sentinel as upstream so any later
// port lines up with the C++/JS-side checks that look for that constant
// to mean "Sink wrapper not yet bound".

const std = @import("std");

pub const Status = enum {
    ready,
    closed,
};

/// Placeholder `Sink`-shaped value used before the real vtable is
/// installed. The pointer value (`0xaaaaaaaa`) is checked on the JSC
/// side to detect "not bound yet". `vtable` stays `undefined` — calling
/// through this is always a bug.
pub const pending = Sink{
    .ptr = @as(*anyopaque, @ptrFromInt(0xaaaaaaaa)),
    .vtable = undefined,
    .status = .closed,
    .used = false,
};

/// Minimal `Sink` shell — exactly the fields upstream lays down (`ptr`,
/// `vtable`, `status`, `used`) so anything that pattern-matches on the
/// struct layout keeps working when the VTable port lands. `VTable` is
/// itself parked (it carries function pointers over `streams.Result` /
/// `Syscall.Error` which aren't ported), so it stays `*anyopaque` here.
pub const Sink = struct {
    ptr: *anyopaque,
    vtable: *anyopaque,
    status: Status = .closed,
    used: bool = false,
};

test "Sink.Status: closed is the default" {
    const s = Sink{ .ptr = @ptrFromInt(0x1), .vtable = @ptrFromInt(0x2) };
    try std.testing.expectEqual(Status.closed, s.status);
    try std.testing.expectEqual(false, s.used);
}

test "Sink.pending: holds the well-known sentinel" {
    // The 0xaaaaaaaa sentinel is checked from the JSC side and must not
    // drift between Home and upstream — pin it.
    try std.testing.expectEqual(
        @as(usize, 0xaaaaaaaa),
        @intFromPtr(pending.ptr),
    );
    try std.testing.expectEqual(Status.closed, pending.status);
    try std.testing.expectEqual(false, pending.used);
}

test "Sink.Status: variants discriminate" {
    try std.testing.expect(Status.ready != Status.closed);
}
