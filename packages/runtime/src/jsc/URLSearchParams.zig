// Copied from bun/src/jsc/URLSearchParams.zig at upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// `JSGlobalObject`, `JSValue`, `ZigString`, `jsc.markBinding`, and `bun.cast`
// are not yet ported. Local opaque/struct/fn stubs keep the public surface
// intact — the JSC bridge re-attaches in Phase 12.2.

const std = @import("std");
const bun = @import("home");
const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;
const JSValue = jsc.JSValue;
const ZigString = jsc.ZigString;

// `bun.cast` stubbed — `@ptrCast(@alignCast(...))` is the equivalent.
fn castPtr(comptime T: type, p: *anyopaque) T {
    return @ptrCast(@alignCast(p));
}

pub const URLSearchParams = opaque {
    extern fn URLSearchParams__create(globalObject: *JSGlobalObject, *const ZigString) JSValue;
    pub fn create(globalObject: *JSGlobalObject, init: ZigString) JSValue {
        jsc.markBinding(@src());
        return URLSearchParams__create(globalObject, &init);
    }

    extern fn URLSearchParams__fromJS(JSValue) ?*URLSearchParams;
    pub fn fromJS(value: JSValue) ?*URLSearchParams {
        jsc.markBinding(@src());
        return URLSearchParams__fromJS(value);
    }

    extern fn URLSearchParams__toString(
        self: *URLSearchParams,
        ctx: *anyopaque,
        callback: *const fn (ctx: *anyopaque, str: *const ZigString) callconv(.c) void,
    ) void;

    pub fn toString(
        self: *URLSearchParams,
        comptime Ctx: type,
        ctx: *Ctx,
        comptime callback: *const fn (ctx: *Ctx, str: ZigString) void,
    ) void {
        jsc.markBinding(@src());
        const Wrap = struct {
            const cb_ = callback;
            pub fn cb(c: *anyopaque, str: *const ZigString) callconv(.c) void {
                cb_(
                    castPtr(*Ctx, c),
                    str.*,
                );
            }
        };

        URLSearchParams__toString(self, ctx, Wrap.cb);
    }
};

test "URLSearchParams is an opaque pointer-only type" {
    try std.testing.expect(@sizeOf(*URLSearchParams) == @sizeOf(usize));
}

test "URLSearchParams exposes create / fromJS / toString" {
    try std.testing.expect(@hasDecl(URLSearchParams, "create"));
    try std.testing.expect(@hasDecl(URLSearchParams, "fromJS"));
    try std.testing.expect(@hasDecl(URLSearchParams, "toString"));
}
