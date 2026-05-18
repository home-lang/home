// Copied from bun/src/jsc/URLSearchParams.zig at upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// `JSGlobalObject`, `JSValue`, `ZigString`, `jsc.markBinding`, and `bun.cast`
// are not yet ported. Local opaque/struct/fn stubs keep the public surface
// intact — the JSC bridge re-attaches in Phase 12.2.

const std = @import("std");

// JSC bridge JSGlobalObject stubbed — re-attaches in Phase 12.2.
const JSGlobalObject = opaque {};
// JSC bridge JSValue stubbed — re-attaches in Phase 12.2.
// Modeled as an extern struct to preserve pass-by-value FFI semantics.
const JSValue = extern struct {
    bits: u64 = 0,
};
// JSC bridge ZigString stubbed — re-attaches in Phase 12.2. Layout mirrors the
// real ZigString slice header (ptr + len, with the high bit of len encoding
// the UTF-16 flag).
const ZigString = extern struct {
    _ptr: ?[*]const u8 = null,
    _len: usize = 0,
};

// JSC bridge markBinding stubbed — re-attaches in Phase 12.2.
fn markBinding(_: std.builtin.SourceLocation) void {}

// `bun.cast` stubbed — `@ptrCast(@alignCast(...))` is the equivalent.
fn castPtr(comptime T: type, p: *anyopaque) T {
    return @ptrCast(@alignCast(p));
}

pub const URLSearchParams = opaque {
    extern fn URLSearchParams__create(globalObject: *JSGlobalObject, *const ZigString) JSValue;
    pub fn create(globalObject: *JSGlobalObject, init: ZigString) JSValue {
        markBinding(@src());
        return URLSearchParams__create(globalObject, &init);
    }

    extern fn URLSearchParams__fromJS(JSValue) ?*URLSearchParams;
    pub fn fromJS(value: JSValue) ?*URLSearchParams {
        markBinding(@src());
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
        markBinding(@src());
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
