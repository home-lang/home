// Copied from bun/src/jsc/Exception.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// `JSGlobalObject`, `JSValue`, and `ZigStackTrace` are not yet ported. Local
// opaque/struct stubs keep the public surface intact — JSC bridge re-attaches
// in Phase 12.2.

const std = @import("std");

// JSC bridge JSGlobalObject stubbed — re-attaches in Phase 12.2.
const JSGlobalObject = @import("./JSGlobalObject.zig").JSGlobalObject;
// JSC bridge JSValue stubbed — re-attaches in Phase 12.2.
const JSValue = @import("home").jsc.JSValue;
const ZigStackTrace = @import("./ZigStackTrace.zig").ZigStackTrace;

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
