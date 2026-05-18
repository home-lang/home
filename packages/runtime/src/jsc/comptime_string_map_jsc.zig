// Copied from bun/src/jsc/comptime_string_map_jsc.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// JSC `JSGlobalObject` / `JSValue` and `bun.String` are not yet ported. We
// declare local opaque/struct stubs so the two `fromJS` helpers compile —
// they delegate to the stubbed `String.fromJS` + `Map.getWithEql` so the
// public surface stays correct. The real bridge re-attaches in Phase 12.2.

const std = @import("std");

// JSC bridge JSGlobalObject stubbed — re-attaches in Phase 12.2.
pub const JSGlobalObject = opaque {};
// JSC bridge JSValue stubbed — re-attaches in Phase 12.2.
pub const JSValue = enum(i64) { _ };
// JSC bridge JSError stubbed — re-attaches in Phase 12.2.
pub const JSError = error{JSError};

// JSC bridge bun.String stubbed — re-attaches in Phase 12.2. Only the surface
// referenced by this file is reproduced: a `tag` enum + `fromJS` + `deref` +
// `inMapCaseInsensitive` + the static `eqlComptime` comparator.
const String = struct {
    pub const Tag = enum(u8) { Dead, WTFStringImpl, ZigString, StaticZigString, Empty };

    tag: Tag = .Empty,

    pub fn fromJS(_: JSValue, _: *JSGlobalObject) JSError!String {
        return .{ .tag = .Empty };
    }
    pub fn deref(_: String) void {}

    pub fn eqlComptime(_: String, comptime _: []const u8) bool {
        return false;
    }

    pub fn inMapCaseInsensitive(_: String, comptime Map: type) ?Map.Value {
        return null;
    }
};

/// `Map` is the `ComptimeStringMap(V, ...)` instantiation; `Map.Value` is the value type.
pub fn fromJS(comptime Map: type, globalThis: *JSGlobalObject, input: JSValue) JSError!?Map.Value {
    const str = try String.fromJS(input, globalThis);
    std.debug.assert(str.tag != .Dead);
    defer str.deref();
    return Map.getWithEql(str, String.eqlComptime);
}

pub fn fromJSCaseInsensitive(comptime Map: type, globalThis: *JSGlobalObject, input: JSValue) JSError!?Map.Value {
    const str = try String.fromJS(input, globalThis);
    std.debug.assert(str.tag != .Dead);
    defer str.deref();
    return str.inMapCaseInsensitive(Map);
}

test "fromJS and fromJSCaseInsensitive expose the expected generic signatures" {
    // The `pub fn` declarations must exist and be addressable at comptime.
    try std.testing.expect(@TypeOf(fromJS) != void);
    try std.testing.expect(@TypeOf(fromJSCaseInsensitive) != void);
}

test "String stub tag defaults to Empty (not Dead)" {
    const s: String = .{};
    try std.testing.expect(s.tag == .Empty);
    try std.testing.expect(s.tag != .Dead);
}
