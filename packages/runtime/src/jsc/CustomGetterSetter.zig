// Copied from bun/src/jsc/CustomGetterSetter.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Upstream calls `bun.cpp.JSC__CustomGetterSetter__isGetterNull(this)`; we use
// direct `extern fn` declarations to match the shape of GetterSetter.zig (which
// already lives next door) since the `bun.cpp` namespace is not yet ported.

pub const CustomGetterSetter = opaque {
    pub fn isGetterNull(this: *CustomGetterSetter) bool {
        return JSC__CustomGetterSetter__isGetterNull(this);
    }

    pub fn isSetterNull(this: *CustomGetterSetter) bool {
        return JSC__CustomGetterSetter__isSetterNull(this);
    }

    extern fn JSC__CustomGetterSetter__isGetterNull(this: *CustomGetterSetter) bool;
    extern fn JSC__CustomGetterSetter__isSetterNull(this: *CustomGetterSetter) bool;
};

test "CustomGetterSetter is an opaque type" {
    const std = @import("std");
    // Smoke test: opaque types have no fields and only exist behind pointers.
    try std.testing.expect(@sizeOf(*CustomGetterSetter) == @sizeOf(usize));
}
