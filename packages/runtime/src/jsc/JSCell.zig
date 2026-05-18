// Copied from bun/src/jsc/JSCell.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// JSC-bridge methods omitted:
//   - getObject / toObject  (need *JSObject, *JSGlobalObject)
//   - toJS                  (needs JSValue.fromCell)
//   - getGetterSetter       (needs JSValue.fromCell + bun.Environment + bun.assert)
//   - getCustomGetterSetter (same)
// These re-land alongside the rest of the JSC binding surface in Phase 12.2.
//
// What survives: the opaque type itself, `getType` (which returns a raw u8 from
// the JSCell header — no JSType cast yet, since `JSType` is in a sibling file
// and we don't want a hard dep from JSCell to it), and `ensureStillAlive`.

const std = @import("std");

pub const JSCell = opaque {
    pub fn getType(this: *const JSCell) u8 {
        return JSC__JSCell__getType(this);
    }

    pub fn ensureStillAlive(this: *JSCell) void {
        std.mem.doNotOptimizeAway(this);
    }

    // NOTE: this function always returns a JSType, but by using `u8` then
    // casting it via `@enumFromInt` we can ensure our `JSType` enum matches
    // WebKit's. This protects us from possible future breaking changes made
    // when upgrading WebKit.
    extern fn JSC__JSCell__getType(this: *const JSCell) u8;
};

test "JSCell is an opaque pointer-only type" {
    try std.testing.expect(@sizeOf(*JSCell) == @sizeOf(usize));
}
