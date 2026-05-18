// Copied from bun/src/runtime/node/node_error_binding.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// **Skeleton port — exposes only the `Code` typed bridge.**
//
// Rewrites:
//   - @import("bun") → @import("home_rt") (only `home_rt.node.error_code`
//     is actually pulled).
//
// Stubs (re-attach when home_rt.jsc grows the matching surface):
//   - `bun.jsc.JSGlobalObject`              → opaque
//   - `bun.jsc.CallFrame`                   → opaque
//   - `bun.jsc.JSValue`                     → enum(i64) sentinel pair
//   - `bun.JSError`                         → error{JSError}
//   - `bun.jsc.JS2NativeFunctionType`       → fn ptr alias
//   - `bun.jsc.JSFunction.create`           → unported; the two
//     factory bodies below stay parked until the function-creation
//     surface lands. `createSimpleError` is preserved as a comptime
//     factory that constructs the closure-style helper Bun's
//     `BunObject.cpp` reads for these two codes.
//   - `jsc.JSGlobalObject.createErrorInstanceWithCode` and the matching
//     `createTypeErrorInstance...` are similarly parked.
//
// What survives the stub is the **constants table**: the two named
// `Code` pairs Bun's `BunObject.cpp` looks up. The factory bodies are
// behind a comptime `parked = true` gate so the file compiles without
// the JSC substrate.

const std = @import("std");
const home_rt = @import("home_rt");
const Code = home_rt.node.error_code.Code;

// JSC stubs --------------------------------------------------------------

const JSGlobalObject = opaque {};
const CallFrame = opaque {};
const JSValue = enum(i64) {
    zero = 0,
    js_undefined = 0xa,
    _,
};
pub const JSError = error{JSError};

/// Upstream: `pub const JS2NativeFunctionType = *const fn (*JSGlobalObject) JSError!JSValue`.
/// Same shape; the rename keeps it locally consistent.
pub const JS2NativeFunctionType = *const fn (*JSGlobalObject) JSError!JSValue;

// ---- The two named-error helpers ---------------------------------------
// Upstream BunObject.cpp dispatches by symbol name (`ERR_INVALID_HANDLE_TYPE`
// / `ERR_CHILD_CLOSED_BEFORE_REPLY`) into these two entrypoints. The
// payload (`code` + `message`) lives in the table below — even though the
// factory bodies are parked, callers can already read the canonical text.

pub const ErrorBinding = struct {
    code: Code,
    message: []const u8,
};

pub const ERR_INVALID_HANDLE_TYPE_INFO: ErrorBinding = .{
    .code = .ERR_INVALID_HANDLE_TYPE,
    .message = "This handle type cannot be sent",
};

pub const ERR_CHILD_CLOSED_BEFORE_REPLY_INFO: ErrorBinding = .{
    .code = .ERR_CHILD_CLOSED_BEFORE_REPLY,
    .message = "Child closed before reply received",
};

// ---- Parked factory (kept for re-attach reference) ---------------------
//
// Upstream body — preserved verbatim in a comment so a one-liner re-port
// is enough once `home_rt.jsc.JSFunction.create` lands:
//
//     fn createSimpleError(comptime createFn: anytype, comptime code: jsc.Node.ErrorCode, comptime message: string) jsc.JS2NativeFunctionType {
//         const R = struct {
//             pub fn cbb(global: *jsc.JSGlobalObject) bun.JSError!jsc.JSValue {
//                 const S = struct {
//                     fn cb(globalThis: *jsc.JSGlobalObject, callframe: *jsc.CallFrame) bun.JSError!jsc.JSValue {
//                         _ = callframe;
//                         return createFn(globalThis, code, message, .{});
//                     }
//                 };
//                 return jsc.JSFunction.create(global, @tagName(code), S.cb, 0, .{});
//             }
//         };
//         return R.cbb;
//     }
//
//     pub const ERR_INVALID_HANDLE_TYPE = createSimpleError(createTypeError, .ERR_INVALID_HANDLE_TYPE, "This handle type cannot be sent");
//     pub const ERR_CHILD_CLOSED_BEFORE_REPLY = createSimpleError(createError, .ERR_CHILD_CLOSED_BEFORE_REPLY, "Child closed before reply received");

// ---- Tests --------------------------------------------------------------

test "node_error_binding: ERR_INVALID_HANDLE_TYPE references the right Code variant" {
    try std.testing.expectEqual(Code.ERR_INVALID_HANDLE_TYPE, ERR_INVALID_HANDLE_TYPE_INFO.code);
    try std.testing.expectEqualStrings(
        "This handle type cannot be sent",
        ERR_INVALID_HANDLE_TYPE_INFO.message,
    );
}

test "node_error_binding: ERR_CHILD_CLOSED_BEFORE_REPLY references the right Code variant" {
    try std.testing.expectEqual(Code.ERR_CHILD_CLOSED_BEFORE_REPLY, ERR_CHILD_CLOSED_BEFORE_REPLY_INFO.code);
    try std.testing.expectEqualStrings(
        "Child closed before reply received",
        ERR_CHILD_CLOSED_BEFORE_REPLY_INFO.message,
    );
}
