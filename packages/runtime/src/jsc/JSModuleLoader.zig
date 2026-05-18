// Copied from bun/src/jsc/JSModuleLoader.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// `JSGlobalObject`, `JSValue`, and `bun.String` are not yet ported. Stubs
// preserve the public surface; `bun.JSError` propagation in `import` is
// reduced to an optional-returning shape — Phase 12.2 reattaches the
// JSError throw path. `JSInternalPromise` is the already-ported alias.

const std = @import("std");

// JSC bridge JSGlobalObject stubbed — re-attaches in Phase 12.2.
const JSGlobalObject = opaque {};
// JSC bridge JSValue stubbed — re-attaches in Phase 12.2.
pub const JSValue = enum(i64) { zero = 0, _ };
// JSC bridge bun.String stubbed — re-attaches in Phase 12.2.
const String = opaque {};

const JSInternalPromise = @import("./JSInternalPromise.zig").JSInternalPromise;

pub const JSModuleLoader = opaque {
    extern fn JSC__JSModuleLoader__evaluate(
        globalObject: *JSGlobalObject,
        sourceCodePtr: [*]const u8,
        sourceCodeLen: usize,
        originUrlPtr: [*]const u8,
        originUrlLen: usize,
        referrerUrlPtr: [*]const u8,
        referrerUrlLen: usize,
        thisValue: JSValue,
        exception: [*]JSValue,
    ) JSValue;

    pub fn evaluate(
        globalObject: *JSGlobalObject,
        sourceCodePtr: [*]const u8,
        sourceCodeLen: usize,
        originUrlPtr: [*]const u8,
        originUrlLen: usize,
        referrerUrlPtr: [*]const u8,
        referrerUrlLen: usize,
        thisValue: JSValue,
        exception: [*]JSValue,
    ) JSValue {
        return JSC__JSModuleLoader__evaluate(
            globalObject,
            sourceCodePtr,
            sourceCodeLen,
            originUrlPtr,
            originUrlLen,
            referrerUrlPtr,
            referrerUrlLen,
            thisValue,
            exception,
        );
    }
    extern fn JSC__JSModuleLoader__loadAndEvaluateModule(arg0: *JSGlobalObject, arg1: ?*const String) ?*JSInternalPromise;
    pub fn loadAndEvaluateModule(globalObject: *JSGlobalObject, module_name: ?*const String) ?*JSInternalPromise {
        return JSC__JSModuleLoader__loadAndEvaluateModule(globalObject, module_name);
    }

    extern fn JSModuleLoader__import(*JSGlobalObject, *const String) ?*JSInternalPromise;
    /// Returns `null` if JSC threw — Phase 12.2 reattaches JSError propagation.
    pub fn import(globalObject: *JSGlobalObject, module_name: *const String) ?*JSInternalPromise {
        return JSModuleLoader__import(globalObject, module_name);
    }
};

test "JSModuleLoader is an opaque pointer-only type" {
    try std.testing.expect(@sizeOf(*JSModuleLoader) == @sizeOf(usize));
}

test "JSInternalPromise alias resolves" {
    try std.testing.expectEqual(JSInternalPromise, @import("./JSInternalPromise.zig").JSInternalPromise);
}
