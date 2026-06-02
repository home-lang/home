// Copied from bun/src/jsc/DeferredError.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// `jsc.Node.ErrorCode`, `bun.String`, `bun.handleOom`, `JSGlobalObject`,
// `JSValue`, `ZigString`, and `String.createFormat`/`toErrorInstance` are
// not yet ported. We stub them locally — the `toError` implementation is
// replaced with a documented "unimplemented" panic that re-attaches in
// Phase 12.2. The struct shape and `from` constructor remain so callers
// compile.

const std = @import("std");

// JSC bridge JSGlobalObject stubbed — re-attaches in Phase 12.2.
const JSGlobalObject = @import("./JSGlobalObject.zig").JSGlobalObject;
// JSC bridge JSValue stubbed — re-attaches in Phase 12.2.
pub const JSValue = enum(i64) { zero = 0, _ };
// JSC bridge bun.String stubbed — re-attaches in Phase 12.2.
pub const String = opaque {};
// JSC bridge jsc.Node.ErrorCode stubbed — re-attaches in Phase 12.2 once
// the Node error code list ports. The `@tagName` use in `toError` works
// against this enum tag list once it lands.
pub const NodeErrorCode = enum(u16) {
    ERR_INVALID_ARG_TYPE,
    ERR_INVALID_ARG_VALUE,
    ERR_OUT_OF_RANGE,
    _,
};

// Error's cannot be created off of the main thread. So we use this to store the
// information until its ready to be materialized later.
pub const DeferredError = struct {
    kind: Kind,
    code: NodeErrorCode,
    msg: ?*String,

    pub const Kind = enum { plainerror, typeerror, rangeerror };

    /// Phase 12.2 reattaches `bun.handleOom(String.createFormat(fmt, args))`.
    /// Until then, callers should set `msg` directly or pass a pre-formed
    /// `*String`.
    pub fn fromRaw(kind: Kind, code: NodeErrorCode, msg: ?*String) DeferredError {
        return .{ .kind = kind, .code = code, .msg = msg };
    }

    pub fn toError(this: *const DeferredError, globalThis: *JSGlobalObject) JSValue {
        _ = this;
        _ = globalThis;
        @panic("DeferredError.toError awaits String.toErrorInstance port (Phase 12.2)");
    }
};

test "DeferredError.Kind tags" {
    try std.testing.expectEqual(@as(DeferredError.Kind, .plainerror), DeferredError.Kind.plainerror);
    try std.testing.expectEqual(@as(DeferredError.Kind, .typeerror), DeferredError.Kind.typeerror);
    try std.testing.expectEqual(@as(DeferredError.Kind, .rangeerror), DeferredError.Kind.rangeerror);
}

test "DeferredError.fromRaw constructs correctly" {
    const d = DeferredError.fromRaw(.typeerror, .ERR_INVALID_ARG_TYPE, null);
    try std.testing.expectEqual(DeferredError.Kind.typeerror, d.kind);
    try std.testing.expectEqual(NodeErrorCode.ERR_INVALID_ARG_TYPE, d.code);
    try std.testing.expectEqual(@as(?*String, null), d.msg);
}
