// Copied from bun/src/jsc/MarkedArgumentBuffer.zig at upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// `JSGlobalObject`, `JSValue`, `CallFrame`, `JSHostFnZig`, `bun.JSError` are
// all not yet ported. Local opaque/struct stubs keep the public surface
// intact — the JSC bridge re-attaches in Phase 12.2.

const std = @import("std");

// JSC bridge JSGlobalObject stubbed — re-attaches in Phase 12.2.
const JSGlobalObject = opaque {};
// JSC bridge CallFrame stubbed — re-attaches in Phase 12.2.
const CallFrame = opaque {};
// JSC bridge JSValue stubbed — re-attaches in Phase 12.2.
// Modeled as an extern struct preserving the 64-bit EncodedJSValue C ABI.
const JSValue = extern struct {
    bits: u64 = 0,
};
// JSC bridge bun.JSError stubbed — re-attaches in Phase 12.2.
const JSError = error{JSError};
// JSC bridge JSHostFnZig stubbed — re-attaches in Phase 12.2. The real type is
// `*const fn (*JSGlobalObject, *CallFrame) JSError!JSValue`.
const JSHostFnZig = *const fn (*JSGlobalObject, *CallFrame) JSError!JSValue;

pub const MarkedArgumentBuffer = opaque {
    extern fn MarkedArgumentBuffer__append(args: *MarkedArgumentBuffer, value: JSValue) callconv(.c) void;
    pub fn append(this: *MarkedArgumentBuffer, value: JSValue) void {
        MarkedArgumentBuffer__append(this, value);
    }

    extern fn MarkedArgumentBuffer__run(ctx: *anyopaque, *const fn (ctx: *anyopaque, args: *anyopaque) callconv(.c) void) void;
    pub fn run(comptime T: type, ctx: *T, func: *const fn (ctx: *T, args: *MarkedArgumentBuffer) callconv(.c) void) void {
        MarkedArgumentBuffer__run(@ptrCast(ctx), @ptrCast(func));
    }

    pub fn wrap(comptime function: *const fn (globalThis: *JSGlobalObject, callframe: *CallFrame, marked_argument_buffer: *MarkedArgumentBuffer) JSError!JSValue) JSHostFnZig {
        return struct {
            pub fn wrapper(globalThis: *JSGlobalObject, callframe: *CallFrame) JSError!JSValue {
                const Context = struct {
                    result: JSError!JSValue,
                    globalThis: *JSGlobalObject,
                    callframe: *CallFrame,
                    pub fn run(this: *@This(), marked_argument_buffer: *MarkedArgumentBuffer) callconv(.c) void {
                        this.result = function(this.globalThis, this.callframe, marked_argument_buffer);
                    }
                };

                var ctx = Context{
                    .globalThis = globalThis,
                    .callframe = callframe,
                    .result = undefined,
                };
                MarkedArgumentBuffer.run(Context, &ctx, &Context.run);
                return try ctx.result;
            }
        }.wrapper;
    }
};

test "MarkedArgumentBuffer is opaque pointer-only" {
    try std.testing.expect(@sizeOf(*MarkedArgumentBuffer) == @sizeOf(usize));
}

test "MarkedArgumentBuffer exposes expected public API" {
    try std.testing.expect(@hasDecl(MarkedArgumentBuffer, "append"));
    try std.testing.expect(@hasDecl(MarkedArgumentBuffer, "run"));
    try std.testing.expect(@hasDecl(MarkedArgumentBuffer, "wrap"));
}
