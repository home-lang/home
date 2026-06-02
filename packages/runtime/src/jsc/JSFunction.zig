// Copied from bun/src/jsc/JSFunction.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// `JSGlobalObject`, `JSValue`, `bun.String`, `ZigString`, `JSHostFn`, and
// `jsc.toJSHostFn` are not yet ported. The `create` wrapper that accepts
// either a `String` or arbitrary string is reduced to a String-only entry
// point — anytype `fn_name` handling and `JSHostFnZig`/`toJSHostFn`
// dispatch re-attach in Phase 12.2.

const std = @import("std");

// JSC bridge JSGlobalObject stubbed — re-attaches in Phase 12.2.
const JSGlobalObject = @import("./JSGlobalObject.zig").JSGlobalObject;
// JSC bridge JSValue stubbed — re-attaches in Phase 12.2.
pub const JSValue = enum(i64) { zero = 0, _ };
// JSC bridge bun.String stubbed — re-attaches in Phase 12.2.
pub const String = opaque {};
// JSC bridge ZigString stubbed — re-attaches in Phase 12.2.
pub const ZigString = opaque {};
// JSC bridge JSHostFn signature stubbed — re-attaches in Phase 12.2.
pub const JSHostFn = fn (*JSGlobalObject, *anyopaque) callconv(.c) JSValue;

pub const JSFunction = opaque {
    pub const ImplementationVisibility = enum(u8) {
        public,
        private,
        private_recursive,
    };

    /// In WebKit: Intrinsic.h
    pub const Intrinsic = enum(u8) {
        none,
        _,
    };

    pub const CreateJSFunctionOptions = struct {
        implementation_visibility: ImplementationVisibility = .public,
        intrinsic: Intrinsic = .none,
        constructor: ?*const JSHostFn = null,
    };

    extern fn JSFunction__createFromZig(
        global: *JSGlobalObject,
        fn_name: *String,
        implementation: *const JSHostFn,
        arg_count: u32,
        implementation_visibility: ImplementationVisibility,
        intrinsic: Intrinsic,
        constructor: ?*const JSHostFn,
    ) JSValue;

    pub fn create(
        global: *JSGlobalObject,
        fn_name: *String,
        implementation: *const JSHostFn,
        function_length: u32,
        options: CreateJSFunctionOptions,
    ) JSValue {
        return JSFunction__createFromZig(
            global,
            fn_name,
            implementation,
            function_length,
            options.implementation_visibility,
            options.intrinsic,
            options.constructor,
        );
    }

    pub extern fn JSC__JSFunction__optimizeSoon(value: JSValue) void;
    pub fn optimizeSoon(value: JSValue) void {
        JSC__JSFunction__optimizeSoon(value);
    }

    extern fn JSC__JSFunction__getSourceCode(value: JSValue, out: *ZigString) bool;

    /// Returns the raw `ZigString` out-pointer on success. Phase 12.2 will
    /// rewrap to `bun.String` once the conversion helper is available.
    pub fn getSourceCode(value: JSValue, out: *ZigString) bool {
        return JSC__JSFunction__getSourceCode(value, out);
    }
};

test "JSFunction is an opaque pointer-only type" {
    try std.testing.expect(@sizeOf(*JSFunction) == @sizeOf(usize));
}

test "ImplementationVisibility tags" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(JSFunction.ImplementationVisibility.public));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(JSFunction.ImplementationVisibility.private));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(JSFunction.ImplementationVisibility.private_recursive));
}

test "Intrinsic.none tag is 0" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(JSFunction.Intrinsic.none));
}
