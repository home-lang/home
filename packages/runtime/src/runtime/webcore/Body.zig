// Copied (partial) from bun/src/runtime/webcore/Body.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.
//
// Scope: the pure-data discriminator types from upstream's 1833-line
// `Body.zig`. These are reached for by ScriptExecutionContext, fetch
// plumbing, and the `Response`/`Request` classes — all of which want to
// know "what kind of body is this" / "what coercion did the caller ask
// for" before any JSC is involved.
//
// Ports here:
//   * `Value.Tag` — the discriminant for upstream's
//     `union(Tag) { Blob, WTFStringImpl, InternalBlob, Locked, Used,
//     Empty, Error, Null }`. The union itself is parked (it carries
//     `Blob`, `bun.WTF.StringImpl`, `InternalBlob`, `ValueError`,
//     `PendingValue` — none of which exist in the Home substrate yet).
//   * `PendingValue.Action` — the union-enum that records which
//     coercion (`text()`, `json()`, `blob()`, etc.) the caller is
//     awaiting. `getFormData` carries an optional pointer; we widen it
//     to `?*anyopaque` (upstream uses `?*bun.FormData.AsyncFormData`)
//     because the JSC-bridged AsyncFormData isn't ported.
//
// Everything else — `Body` itself, `PendingValue` (PendingState +
// owners), `Value` (the union), `ValueBufferer`, `Mixin(...)`, `extract`,
// the JSC stream/promise/error glue — stays in `upstream/`. Re-lands when
// `jsc.JSValue`, `jsc.WebCore.ReadableStream.Strong`, `Blob`,
// `bun.WTF.StringImpl`, and `streams.Result.StreamError` are ported.
//
// Rewritten imports: only `std`; no `@import("bun")` needed at this slice.

const std = @import("std");

/// Discriminator for the upstream `Body.Value` tagged union. Order matches
/// upstream so any future port of the union can be a copy of the variant
/// list onto these tags.
pub const Tag = enum {
    Blob,
    WTFStringImpl,
    InternalBlob,
    // InlineBlob,   // intentionally omitted upstream (commented out)
    Locked,
    Used,
    Empty,
    Error,
    Null,
};

/// Records which coercion the JS caller is awaiting on a `Locked` body.
/// `getFormData` carries an optional AsyncFormData pointer upstream;
/// widened to `?*anyopaque` here so the enum is JSC-/FormData-free.
pub const Action = union(enum) {
    none: void,
    getText: void,
    getJSON: void,
    getArrayBuffer: void,
    getBytes: void,
    getBlob: void,
    getFormData: ?*anyopaque,
};

test "Body.Tag: variants match upstream order" {
    // The integer order is load-bearing because the union(Tag) backing
    // in upstream uses these tags directly. Pin it.
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Tag.Blob));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(Tag.WTFStringImpl));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(Tag.InternalBlob));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(Tag.Locked));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(Tag.Used));
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(Tag.Empty));
    try std.testing.expectEqual(@as(u8, 6), @intFromEnum(Tag.Error));
    try std.testing.expectEqual(@as(u8, 7), @intFromEnum(Tag.Null));
}

test "Body.Action: default and shape" {
    const a: Action = .{ .none = {} };
    try std.testing.expect(a == .none);

    const t: Action = .{ .getText = {} };
    try std.testing.expect(t == .getText);

    const f: Action = .{ .getFormData = null };
    try std.testing.expect(f == .getFormData);
    try std.testing.expectEqual(@as(?*anyopaque, null), f.getFormData);
}

test "Body.Action: getFormData carries an opaque pointer" {
    var sentinel: u8 = 0;
    const f: Action = .{ .getFormData = @ptrCast(&sentinel) };
    try std.testing.expect(f == .getFormData);
    try std.testing.expect(f.getFormData != null);
}
