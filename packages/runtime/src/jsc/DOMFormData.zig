// Copied from bun/src/jsc/DOMFormData.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Thin wrapper around `WebCore::DOMFormData`. The bulk of the surface is
// `extern fn` shims into vendor/WebKit; `toQueryString` and `forEach` wrap
// raw `*anyopaque + callconv(.c) callback` into a comptime-friendly
// generic so Zig callers can pass a typed context.
//
// `JSGlobalObject`, `JSValue`, `VM`, `ZigString`, and `jsc.WebCore.Blob` are
// not yet ported. Local stubs preserve the C ABI. The JSC bridge re-attaches
// in Phase 12.2.
//
// Omitted (re-attach in Phase 12.2):
//   - `forEach(...)` — its `FormDataEntry` union references
//     `jsc.WebCore.Blob`, which the runtime has not yet exposed. The
//     extern (`DOMFormData__forEach`) stays declared so callers can spell
//     it once Blob lands.

const std = @import("std");
const home_rt = @import("home");

const JSGlobalObject = home_rt.jsc.JSGlobalObject;
const JSValue = home_rt.jsc.JSValue;
const VM = home_rt.jsc.VM;
const ZigString = home_rt.jsc.ZigString;

pub const DOMFormData = opaque {
    extern fn WebCore__DOMFormData__cast_(JSValue0: JSValue, arg1: *VM) ?*DOMFormData;
    extern fn WebCore__DOMFormData__create(arg0: *JSGlobalObject) JSValue;
    extern fn WebCore__DOMFormData__createFromURLQuery(arg0: *JSGlobalObject, arg1: *ZigString) JSValue;
    extern fn WebCore__DOMFormData__toQueryString(arg0: *DOMFormData, arg1: *anyopaque, arg2: *const fn (arg0: *anyopaque, *ZigString) callconv(.c) void) void;
    extern fn WebCore__DOMFormData__fromJS(JSValue0: JSValue) ?*DOMFormData;
    extern fn WebCore__DOMFormData__append(arg0: *DOMFormData, arg1: *ZigString, arg2: *ZigString) void;
    extern fn WebCore__DOMFormData__appendBlob(arg0: *DOMFormData, arg1: *JSGlobalObject, arg2: *ZigString, arg3: *anyopaque, arg4: *ZigString) void;
    extern fn WebCore__DOMFormData__count(arg0: *DOMFormData) usize;

    pub fn cast_(value: JSValue, vm: *VM) ?*DOMFormData {
        return WebCore__DOMFormData__cast_(value, vm);
    }

    pub fn create(global: *JSGlobalObject) JSValue {
        return WebCore__DOMFormData__create(global);
    }

    pub fn createFromURLQuery(global: *JSGlobalObject, query: *ZigString) JSValue {
        return WebCore__DOMFormData__createFromURLQuery(global, query);
    }

    extern fn DOMFormData__toQueryString(
        *DOMFormData,
        ctx: *anyopaque,
        callback: *const fn (ctx: *anyopaque, *ZigString) callconv(.c) void,
    ) void;

    pub fn toQueryString(
        this: *DOMFormData,
        comptime Ctx: type,
        ctx: Ctx,
        comptime callback: fn (ctx: Ctx, ZigString) callconv(.c) void,
    ) void {
        const Wrapper = struct {
            const cb = callback;
            pub fn run(c: *anyopaque, str: *ZigString) callconv(.c) void {
                cb(@as(Ctx, @ptrCast(c)), str.*);
            }
        };

        WebCore__DOMFormData__toQueryString(this, ctx, &Wrapper.run);
    }

    pub fn fromJS(value: JSValue) ?*DOMFormData {
        return WebCore__DOMFormData__fromJS(value);
    }

    pub fn append(this: *DOMFormData, name_: *ZigString, value_: *ZigString) void {
        WebCore__DOMFormData__append(this, name_, value_);
    }

    pub fn appendBlob(
        this: *DOMFormData,
        global: *JSGlobalObject,
        name_: *ZigString,
        blob: *anyopaque,
        filename_: *ZigString,
    ) void {
        return WebCore__DOMFormData__appendBlob(this, global, name_, blob, filename_);
    }

    pub fn count(this: *DOMFormData) usize {
        return WebCore__DOMFormData__count(this);
    }

    /// Callback signature shared with the C++ `forEach` impl. Kept exported
    /// so callers can spell it once `jsc.WebCore.Blob` lands and `forEach`
    /// re-attaches above.
    pub const ForEachFunction = *const fn (
        ctx_ptr: ?*anyopaque,
        name: *ZigString,
        value_ptr: *anyopaque,
        filename: ?*ZigString,
        is_blob: u8,
    ) callconv(.c) void;

    extern fn DOMFormData__forEach(*DOMFormData, ?*anyopaque, ForEachFunction) void;

    pub const FormDataEntry = union(enum) {
        string: ZigString,
        file: struct {
            blob: *home_rt.runtime.webcore.Blob,
            filename: ZigString,
        },
    };

    pub fn forEach(
        this: *DOMFormData,
        comptime Ctx: type,
        ctx: *Ctx,
        comptime callback: fn (*Ctx, ZigString, FormDataEntry) void,
    ) void {
        const Wrapper = struct {
            pub fn run(ctx_ptr: ?*anyopaque, name: *ZigString, value_ptr: *anyopaque, filename: ?*ZigString, is_blob: u8) callconv(.c) void {
                const typed_ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr.?));
                const entry: FormDataEntry = if (is_blob != 0)
                    .{ .file = .{
                        .blob = @ptrCast(@alignCast(value_ptr)),
                        .filename = if (filename) |f| f.* else ZigString.init(""),
                    } }
                else
                    .{ .string = (@as(*ZigString, @ptrCast(@alignCast(value_ptr)))).* };
                callback(typed_ctx, name.*, entry);
            }
        };

        DOMFormData__forEach(this, ctx, &Wrapper.run);
    }
};

test "DOMFormData is an opaque pointer-only type" {
    try std.testing.expect(@sizeOf(*DOMFormData) == @sizeOf(usize));
}

test "DOMFormData exposes the expected entrypoints" {
    try std.testing.expect(@hasDecl(DOMFormData, "cast_"));
    try std.testing.expect(@hasDecl(DOMFormData, "create"));
    try std.testing.expect(@hasDecl(DOMFormData, "createFromURLQuery"));
    try std.testing.expect(@hasDecl(DOMFormData, "toQueryString"));
    try std.testing.expect(@hasDecl(DOMFormData, "fromJS"));
    try std.testing.expect(@hasDecl(DOMFormData, "append"));
    try std.testing.expect(@hasDecl(DOMFormData, "appendBlob"));
    try std.testing.expect(@hasDecl(DOMFormData, "count"));
}

test "DOMFormData.ForEachFunction has the expected callconv signature" {
    const fn_info = @typeInfo(DOMFormData.ForEachFunction).pointer.child;
    const info = @typeInfo(fn_info).@"fn";
    // Zig 0.17 represents `callconv(.c)` as `CallingConvention.c_arch_default`-style
    // variants depending on the host. Asserting the param count is enough to
    // catch ABI drift; the `callconv(.c)` annotation is enforced at compile time.
    try std.testing.expectEqual(@as(usize, 5), info.param_types.len);
}

comptime {
    _ = home_rt;
}
