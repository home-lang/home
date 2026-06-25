// Copied from bun/src/jsc/JSObject.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// `JSObject` is an opaque pointer type — every callable method in the upstream
// file talks through `JSValue`, `JSGlobalObject`, or `bun.cpp.JSC__*` externs
// which are not yet re-attached. We keep the opaque shape, the inline
// `maxInlineCapacity()` extern accessor (no JSC types in its signature), the
// `ensureStillAlive` no-op, and the pure-Zig `ExternColumnIdentifier` record so
// callers can spell every field/method name without needing the full JSC
// bridge. The rest re-lands alongside `JSValue` / `JSGlobalObject` /
// `host_fn.zig` in Phase 12.2.

const std = @import("std");
const home_rt = @import("home");

extern const JSC__JSObject__maxInlineCapacity: c_uint;

pub const JSObject = opaque {
    pub inline fn maxInlineCapacity() c_uint {
        return JSC__JSObject__maxInlineCapacity;
    }

    /// When the GC sees a JSValue referenced in the stack, it knows not to free it.
    /// This mimics the implementation in JavaScriptCore's C++.
    pub inline fn ensureStillAlive(this: *JSObject) void {
        std.mem.doNotOptimizeAway(this);
    }

    pub fn toJS(this: *JSObject) home_rt.jsc.JSValue {
        return @enumFromInt(@as(i64, @bitCast(@as(u64, @intCast(@intFromPtr(this))))));
    }

    pub fn getCodePropertyVMInquiry(_: *JSObject, _: *home_rt.jsc.JSGlobalObject) ?home_rt.jsc.JSValue {
        return null;
    }

    /// Faithful to upstream `jsc/JSObject.zig:24`. Marshall a struct into a
    /// JSObject (each field encoded via `jsc.JSValue.fromAny`).
    pub fn create(pojo: anytype, global: *home_rt.jsc.JSGlobalObject) home_rt.JSError!*JSObject {
        return createFromStructWithPrototype(@TypeOf(pojo), pojo, global, false);
    }

    pub fn createNullProto(pojo: anytype, global: *home_rt.jsc.JSGlobalObject) home_rt.JSError!*JSObject {
        return createFromStructWithPrototype(@TypeOf(pojo), pojo, global, true);
    }

    fn createFromStructWithPrototype(comptime T: type, pojo: T, global: *home_rt.jsc.JSGlobalObject, comptime null_prototype: bool) home_rt.JSError!*JSObject {
        const JSValue = home_rt.jsc.JSValue;
        const info: std.builtin.Type.Struct = @typeInfo(T).@"struct";

        const obj = obj: {
            const val = if (comptime null_prototype)
                JSValue.createEmptyObjectWithNullPrototype(global)
            else
                JSValue.createEmptyObject(global, comptime info.fields.len);
            if (home_rt.Environment.isDebug)
                home_rt.assert(val.isObject());
            break :obj val.uncheckedPtrCast(JSObject);
        };

        const cell = toJS(obj);
        inline for (info.fields) |field| {
            const property = @field(pojo, field.name);
            cell.put(
                global,
                field.name,
                try .fromAny(global, @TypeOf(property), property),
            );
        }

        return obj;
    }

    pub fn get(obj: *JSObject, global: *home_rt.jsc.JSGlobalObject, prop: anytype) home_rt.JSError!?home_rt.jsc.JSValue {
        return obj.toJS().get(global, prop);
    }

    pub inline fn put(obj: *JSObject, global: *home_rt.jsc.JSGlobalObject, key: anytype, value: home_rt.jsc.JSValue) !void {
        obj.toJS().put(global, key, value);
    }

    pub inline fn putAllFromStruct(obj: *JSObject, global: *home_rt.jsc.JSGlobalObject, properties: anytype) !void {
        inline for (comptime std.meta.fieldNames(@TypeOf(properties))) |field| {
            try obj.put(global, field, @field(properties, field));
        }
    }

    extern fn JSC__JSObject__getIndex(this: home_rt.jsc.JSValue, globalThis: *home_rt.jsc.JSGlobalObject, i: u32) home_rt.jsc.JSValue;

    pub fn getIndex(value: home_rt.jsc.JSValue, globalThis: *home_rt.jsc.JSGlobalObject, index: u32) home_rt.JSError!home_rt.jsc.JSValue {
        // Don't use fromJSHostCall — the underlying getter can legitimately
        // return `undefined` together with a pending exception, which that
        // helper would assert against. Mirror Bun's JSObject.getIndex.
        var scope: home_rt.jsc.TopExceptionScope = undefined;
        scope.init(globalThis, @src());
        defer scope.deinit();
        const result = JSC__JSObject__getIndex(value, globalThis, index);
        try scope.returnIfException();
        home_rt.assert(result != .zero);
        return result;
    }

    pub fn createWithInitializer(
        comptime Initializer: type,
        initializer: *Initializer,
        global: *home_rt.jsc.JSGlobalObject,
        count: usize,
    ) home_rt.jsc.JSValue {
        _ = initializer;
        return home_rt.jsc.JSValue.createEmptyObject(global, count);
    }

    /// The discriminated `(tag, index|name)` payload SQL bindings pass into
    /// `JSC__createStructure`. `name` carries a `bun.String` upstream; we keep
    /// the same memory layout (a single `usize` cell) so the extern call site
    /// matches the C++ side once the bindings re-attach. The pure-Zig field
    /// helpers are kept verbatim.
    pub const ExternColumnIdentifier = extern struct {
        tag: u8 = 0,
        value: extern union {
            index: u32,
            name: home_rt.String,
        },

        pub fn string(this: *ExternColumnIdentifier) ?*home_rt.String {
            return switch (this.tag) {
                2 => &this.value.name,
                else => null,
            };
        }

        pub fn deinit(_: *ExternColumnIdentifier) void {}
    };

    extern fn JSC__createStructure(global: *home_rt.jsc.JSGlobalObject, owner: *home_rt.jsc.JSCell, length: u32, names: [*]ExternColumnIdentifier) home_rt.jsc.JSValue;

    pub fn createStructure(global: *home_rt.jsc.JSGlobalObject, owner: home_rt.jsc.JSValue, length: u32, names: [*]ExternColumnIdentifier) home_rt.jsc.JSValue {
        return JSC__createStructure(global, owner.asCell(), length, names);
    }
};

test "JSObject is an opaque type" {
    // The whole point of this leaf: `*JSObject` is a usable pointer-shape even
    // before the JSC bridge lands. We can't `@sizeOf` an opaque, but we can
    // assert that a `*JSObject` is pointer-sized.
    try std.testing.expectEqual(@sizeOf(*JSObject), @sizeOf(usize));
}

test "ExternColumnIdentifier tag dispatch" {
    var id_index = JSObject.ExternColumnIdentifier{ .tag = 1, .value = .{ .index = 42 } };
    try std.testing.expectEqual(@as(?*home_rt.String, null), id_index.string());

    var id_name = JSObject.ExternColumnIdentifier{ .tag = 2, .value = .{ .name = home_rt.String.dead } };
    try std.testing.expect(id_name.string() != null);
}

comptime {
    _ = home_rt;
}
