// Copied from bun/src/jsc/Exception.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// `JSGlobalObject`, `JSValue`, and `ZigStackTrace` are not yet ported. Local
// opaque/struct stubs keep the public surface intact — JSC bridge re-attaches
// in Phase 12.2.

const std = @import("std");
const home_rt = @import("home_rt");

// Use the canonical JSGlobalObject/JSValue so callers (VirtualMachine's
// uncaught-exception path) pass and receive the real types. `asJSValue`
// returns `JSValue` by value (it is an i64-backed enum), matching upstream.
const JSGlobalObject = home_rt.jsc.JSGlobalObject;
const JSValue = home_rt.jsc.JSValue;
// JSC bridge ZigStackTrace stubbed — re-attaches in Phase 12.2.
const ZigStackTrace = opaque {};

/// Opaque representation of a JavaScript exception
pub const Exception = opaque {
    extern fn JSC__Exception__getStackTrace(this: *Exception, global: *JSGlobalObject, stack: *ZigStackTrace) void;
    extern fn JSC__Exception__asJSValue(this: *Exception) JSValue;

    pub fn getStackTrace(this: *Exception, global: *JSGlobalObject, stack: *ZigStackTrace) void {
        JSC__Exception__getStackTrace(this, global, stack);
    }

    pub fn value(this: *Exception) JSValue {
        return JSC__Exception__asJSValue(this);
    }
};

test "Exception is an opaque pointer-only type" {
    try std.testing.expect(@sizeOf(*Exception) == @sizeOf(usize));
}
