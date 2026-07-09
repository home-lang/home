// Copied from bun/src/jsc/codegen.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// JSC `JSValue` / `JSGlobalObject` are not yet ported. Local opaque stubs keep
// the public surface intact — the real JSC types re-attach in Phase 12.2. The
// `.call(...)` invocation inside `CallbackWrapper.call` cannot be reached via
// the stubs (the stub `JSValue` has no method); we keep the method body shape
// by inlining the type's `call` as an extern declaration on the stub so the
// `.zig` file still compiles. Real-world wiring uses the JSC method.

const std = @import("std");

// JSC bridge JSValue stubbed — re-attaches in Phase 12.2.
// Real upstream JSValue is `enum(i64)` with many methods; we keep the same
// representation so `extern fn (JSValue) JSValue` stays ABI-compatible.
pub const JSValue = enum(i64) {
    _,

    pub fn isEmptyOrUndefinedOrNull(_: JSValue) bool {
        return true;
    }

    pub fn call(_: JSValue, _: *JSGlobalObject, _: []const JSValue) ?JSValue {
        return null;
    }
};
// JSC bridge JSGlobalObject stubbed — re-attaches in Phase 12.2.
pub const JSGlobalObject = opaque {};

pub const CallbackGetterFn = fn (JSValue) callconv(.c) JSValue;
pub const CallbackSetterFn = fn (JSValue, JSValue) callconv(.c) void;

pub fn CallbackWrapper(comptime Getter: *const CallbackGetterFn, comptime Setter: *const CallbackSetterFn) type {
    return struct {
        const GetFn = Getter;
        const SetFn = Setter;
        container: JSValue,

        pub inline fn get(self: @This()) ?JSValue {
            const res = GetFn(self.container);
            if (res.isEmptyOrUndefinedOrNull())
                return null;

            return res;
        }

        pub inline fn set(self: @This(), value: JSValue) void {
            SetFn(self.container, value);
        }

        pub inline fn call(self: @This(), globalObject: *JSGlobalObject, args: []const JSValue) ?JSValue {
            if (self.get()) |callback| {
                return callback.call(globalObject, args);
            }

            return null;
        }
    };
}

test "CallbackWrapper instantiates with stub getter/setter function pointers" {
    const FakeGet = struct {
        fn fakeGet(_: JSValue) callconv(.c) JSValue {
            unreachable;
        }
    };
    const FakeSet = struct {
        fn fakeSet(_: JSValue, _: JSValue) callconv(.c) void {
            unreachable;
        }
    };
    const Wrapped = CallbackWrapper(&FakeGet.fakeGet, &FakeSet.fakeSet);
    // The wrapper type must expose a `container: JSValue` field.
    const info = @typeInfo(Wrapped);
    try std.testing.expect(info == .@"struct");
    try std.testing.expectEqualStrings("container", info.@"struct".field_names[0]);
}
