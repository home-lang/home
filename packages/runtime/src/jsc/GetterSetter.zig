// Copied verbatim from bun/src/jsc/GetterSetter.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.

pub const GetterSetter = opaque {
    pub fn isGetterNull(this: *GetterSetter) bool {
        return JSC__GetterSetter__isGetterNull(this);
    }

    pub fn isSetterNull(this: *GetterSetter) bool {
        return JSC__GetterSetter__isSetterNull(this);
    }
    extern fn JSC__GetterSetter__isGetterNull(this: *GetterSetter) bool;
    extern fn JSC__GetterSetter__isSetterNull(this: *GetterSetter) bool;
};
