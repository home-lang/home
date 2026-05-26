// Copied from bun/src/jsc/JSPromise.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// JSC-bridge methods (resolve/reject, status(), result(), Weak/Strong handles,
// wrap/wrapValue, attachAsyncStackFromPromise, …) are omitted — they re-land
// alongside the rest of the JSC binding surface in Phase 12.2 once
// `JSGlobalObject`, `JSValue`, `VM`, `bun.cpp`, `JSError`, and `String` exist.
// What remains here is the pure-Zig shape: the opaque type plus the Status /
// UnwrapMode / Unwrapped enums that callers spell in their signatures.

pub const JSPromise = opaque {
    pub const Status = enum(u32) {
        pending = 0, // Making this as 0, so that, we can change the status from Pending to others without masking.
        fulfilled = 1,
        rejected = 2,
    };

    pub const UnwrapMode = enum { mark_handled, leave_unhandled };

    // JSC-bridge `Unwrapped` union omitted — it carries `JSValue` payloads which
    // re-land in Phase 12.2.
    pub fn status(_: *JSPromise) Status {
        return .pending;
    }
};

test "JSPromise.Status tags" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(JSPromise.Status.pending));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(JSPromise.Status.fulfilled));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(JSPromise.Status.rejected));
}

test "JSPromise.UnwrapMode tags" {
    const std = @import("std");
    const a: JSPromise.UnwrapMode = .mark_handled;
    const b: JSPromise.UnwrapMode = .leave_unhandled;
    try std.testing.expect(a != b);
}
