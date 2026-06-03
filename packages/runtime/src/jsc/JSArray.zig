// Copied from bun/src/jsc/JSArray.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// `JSGlobalObject`, `JSValue`, `JSArrayIterator`, `bun.JSError`, and
// `bun.jsc.fromJSHostCall` are not yet ported. The wrapping `create`/
// `createEmpty` helpers temporarily call the extern directly, returning the
// raw value — JSError propagation re-attaches in Phase 12.2.

const std = @import("std");

const JSGlobalObject = @import("home").jsc.JSGlobalObject;
pub const JSValue = @import("home").jsc.JSValue;
const JSArrayIterator = @import("./JSArrayIterator.zig").JSArrayIterator;
const bun = @import("bun");

pub const JSArray = opaque {
    // TODO(@paperclover): this can throw
    extern fn JSArray__constructArray(*JSGlobalObject, [*]const JSValue, usize) JSValue;

    pub fn create(global: *JSGlobalObject, items: []const JSValue) JSValue {
        return JSArray__constructArray(global, items.ptr, items.len);
    }

    extern fn JSArray__constructEmptyArray(*JSGlobalObject, usize) JSValue;

    pub fn createEmpty(global: *JSGlobalObject, len: usize) JSValue {
        return JSArray__constructEmptyArray(global, len);
    }

    pub fn iterator(this: *JSArray, global: *JSGlobalObject) bun.JSError!JSArrayIterator {
        return JSValue.fromCell(this).arrayIterator(global);
    }
};

test "JSArray is an opaque pointer-only type" {
    try std.testing.expect(@sizeOf(*JSArray) == @sizeOf(usize));
}

test "JSValue.zero tag is 0" {
    try std.testing.expectEqual(@as(i64, 0), @intFromEnum(JSValue.zero));
}
