// Copied from bun/src/jsc/Weak.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// JSC weak-reference handles. `Weak(T)` is the type-erased generic wrapper;
// `WeakImpl` is the opaque C++ pointer. `JSGlobalObject` and `JSValue` are not
// yet ported, so we stub them locally (the C++ ABI uses the same enum(i64)
// JSValue and an opaque global object). The real JSC bridge re-attaches in
// Phase 12.2.

const std = @import("std");

// JSC bridge stubs — re-attach in Phase 12.2.
const jsc = struct {
    pub const JSGlobalObject = opaque {};
    /// Real upstream JSValue is `enum(i64)` with many methods. `.zero` is the
    /// sentinel for "no value" that the C++ side returns when the weak ref
    /// has been collected. We preserve the same representation so that
    /// pass-by-value extern signatures stay ABI-compatible.
    pub const JSValue = enum(i64) {
        zero = 0,
        _,

        /// `function.call(global, args)` upstream lives on the full JSValue
        /// API. Until that re-attaches, we stub it as a no-op returning
        /// `.zero`; callers that hit this in tests should mock the WeakRef
        /// at the seam above this file.
        pub fn call(_: JSValue, _: *JSGlobalObject, _: []const JSValue) JSValue {
            return .zero;
        }
    };

    /// `markBinding` stubbed — re-attaches in Phase 12.2 once the binding
    /// trace infrastructure lands.
    pub inline fn markBinding(_: std.builtin.SourceLocation) void {}
};

pub const WeakRefType = enum(u32) {
    None = 0,
    FetchResponse = 1,
    PostgreSQLQueryClient = 2,
};

const WeakImpl = opaque {
    pub fn init(globalThis: *jsc.JSGlobalObject, value: jsc.JSValue, refType: WeakRefType, ctx: ?*anyopaque) *WeakImpl {
        jsc.markBinding(@src());
        return Bun__WeakRef__new(globalThis, value, refType, ctx);
    }

    pub fn get(this: *WeakImpl) jsc.JSValue {
        jsc.markBinding(@src());
        return Bun__WeakRef__get(this);
    }

    pub fn clear(this: *WeakImpl) void {
        jsc.markBinding(@src());
        Bun__WeakRef__clear(this);
    }

    pub fn deinit(
        this: *WeakImpl,
    ) void {
        jsc.markBinding(@src());
        Bun__WeakRef__delete(this);
    }

    extern fn Bun__WeakRef__delete(this: *WeakImpl) void;
    extern fn Bun__WeakRef__new(*jsc.JSGlobalObject, jsc.JSValue, refType: WeakRefType, ctx: ?*anyopaque) *WeakImpl;
    extern fn Bun__WeakRef__get(this: *WeakImpl) jsc.JSValue;
    extern fn Bun__WeakRef__clear(this: *WeakImpl) void;
};

pub fn Weak(comptime T: type) type {
    return struct {
        ref: ?*WeakImpl = null,
        globalThis: ?*jsc.JSGlobalObject = null,
        const WeakType = @This();

        pub fn init() WeakType {
            return .{};
        }

        pub fn call(
            this: *WeakType,
            args: []const jsc.JSValue,
        ) jsc.JSValue {
            const function = this.trySwap() orelse return .zero;
            return function.call(this.globalThis.?, args);
        }

        pub fn create(
            value: jsc.JSValue,
            globalThis: *jsc.JSGlobalObject,
            refType: WeakRefType,
            ctx: *T,
        ) WeakType {
            if (value != .zero) {
                return .{ .ref = WeakImpl.init(globalThis, value, refType, ctx), .globalThis = globalThis };
            }

            return .{ .globalThis = globalThis };
        }

        pub fn get(this: *const WeakType) ?jsc.JSValue {
            var ref = this.ref orelse return null;
            const result = ref.get();
            if (result == .zero) {
                return null;
            }

            return result;
        }

        pub fn swap(this: *WeakType) jsc.JSValue {
            var ref = this.ref orelse return .zero;
            const result = ref.get();
            if (result == .zero) {
                return .zero;
            }

            ref.clear();
            return result;
        }

        pub fn has(this: *WeakType) bool {
            var ref = this.ref orelse return false;
            return ref.get() != .zero;
        }

        pub fn trySwap(this: *WeakType) ?jsc.JSValue {
            const result = this.swap();
            if (result == .zero) {
                return null;
            }

            return result;
        }

        pub fn clear(this: *WeakType) void {
            var ref: *WeakImpl = this.ref orelse return;
            ref.clear();
        }

        pub fn deinit(this: *WeakType) void {
            var ref: *WeakImpl = this.ref orelse return;
            this.ref = null;
            ref.deinit();
        }
    };
}

test "WeakRefType has the expected tag values" {
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(WeakRefType.None));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(WeakRefType.FetchResponse));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(WeakRefType.PostgreSQLQueryClient));
}

test "WeakImpl is an opaque pointer-only type" {
    try std.testing.expect(@sizeOf(*WeakImpl) == @sizeOf(usize));
}

test "Weak(T) instantiates to a struct with the expected fields" {
    const Dummy = opaque {};
    const W = Weak(Dummy);
    const info = @typeInfo(W).@"struct";
    try std.testing.expectEqualStrings("ref", info.fields[0].name);
    try std.testing.expectEqualStrings("globalThis", info.fields[1].name);
}

test "Weak(T).init returns the zero state" {
    const Dummy = opaque {};
    const w = Weak(Dummy).init();
    try std.testing.expect(w.ref == null);
    try std.testing.expect(w.globalThis == null);
}
