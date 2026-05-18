// Copied from bun/src/jsc/JSMap.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// `bun.cpp.JSC__JSMap__*` and `JSValue.jsTypeLoose`/`asEncoded` are not yet
// ported. The `bun.cpp` aliases are inlined as direct `extern fn` declarations
// and `JSValue` is a local opaque stub. `bun.cast` is replaced with `@ptrCast`.
// JSC bridge re-attaches in Phase 12.2.

const std = @import("std");

// JSC bridge JSValue stubbed — re-attaches in Phase 12.2.
const JSValue = opaque {
    extern fn JSValue__jsTypeLoose(JSValue) u8;
    pub fn jsTypeLoose(self: *const JSValue) JSType {
        return @enumFromInt(JSValue__jsTypeLoose(self.*));
    }

    extern fn JSValue__asPtr(JSValue) ?*anyopaque;
    pub fn asEncodedPtr(self: *const JSValue) ?*anyopaque {
        return JSValue__asPtr(self.*);
    }
};

// JSC bridge JSType stubbed (only the .Map tag is referenced) —
// re-attaches in Phase 12.2.
const JSType = enum(u8) {
    Unknown = 0,
    Map = 1,
    _,
};

/// Opaque type for working with JavaScript `Map` objects.
pub const JSMap = opaque {
    extern fn JSC__JSMap__create(*anyopaque) *JSMap;
    extern fn JSC__JSMap__set(*JSMap, *anyopaque, JSValue, JSValue) void;
    extern fn JSC__JSMap__get(*JSMap, *anyopaque, JSValue) JSValue;
    extern fn JSC__JSMap__has(*JSMap, *anyopaque, JSValue) bool;
    extern fn JSC__JSMap__remove(*JSMap, *anyopaque, JSValue) bool;
    extern fn JSC__JSMap__clear(*JSMap, *anyopaque) void;
    extern fn JSC__JSMap__size(*JSMap, *anyopaque) usize;

    pub const create = JSC__JSMap__create;
    pub const set = JSC__JSMap__set;

    /// Retrieve a value from this JS Map object.
    ///
    /// Note this shares semantics with the JS `Map.prototype.get` method, and
    /// will return .js_undefined if a value is not found.
    pub const get = JSC__JSMap__get;

    /// Test whether this JS Map object has a given key.
    pub const has = JSC__JSMap__has;

    /// Attempt to remove a key from this JS Map object.
    pub const remove = JSC__JSMap__remove;

    /// Clear all entries from this JS Map object.
    pub const clear = JSC__JSMap__clear;

    /// Retrieve the number of entries in this JS Map object.
    pub const size = JSC__JSMap__size;

    /// Attempt to convert a `JSValue` to a `*JSMap`.
    ///
    /// Returns `null` if the value is not a Map.
    pub fn fromJS(value: *const JSValue) ?*JSMap {
        if (value.jsTypeLoose() == .Map) {
            const ptr = value.asEncodedPtr() orelse return null;
            return @ptrCast(@alignCast(ptr));
        }
        return null;
    }
};

test "JSMap is an opaque pointer-only type" {
    try std.testing.expect(@sizeOf(*JSMap) == @sizeOf(usize));
}

test "JSType.Map tag is reachable" {
    const t: JSType = .Map;
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(t));
}
