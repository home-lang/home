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
const home_rt = @import("home_rt");

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

    /// The discriminated `(tag, index|name)` payload SQL bindings pass into
    /// `JSC__createStructure`. `name` carries a `bun.String` upstream; we keep
    /// the same memory layout (a single `usize` cell) so the extern call site
    /// matches the C++ side once the bindings re-attach. The pure-Zig field
    /// helpers are kept verbatim.
    pub const ExternColumnIdentifier = extern struct {
        tag: u8 = 0,
        value: extern union {
            index: u32,
            // Upstream stores `bun.String` (3 × usize) here. We mirror with a
            // raw `[3]usize` so the size + alignment matches in this leaf —
            // when `bun.String` lands we swap the type and remove the cast.
            name: [3]usize,
        },

        pub fn string(this: *ExternColumnIdentifier) ?*[3]usize {
            return switch (this.tag) {
                2 => &this.value.name,
                else => null,
            };
        }
    };
};

test "JSObject is an opaque type" {
    // The whole point of this leaf: `*JSObject` is a usable pointer-shape even
    // before the JSC bridge lands. We can't `@sizeOf` an opaque, but we can
    // assert that a `*JSObject` is pointer-sized.
    try std.testing.expectEqual(@sizeOf(*JSObject), @sizeOf(usize));
}

test "ExternColumnIdentifier tag dispatch" {
    var id_index = JSObject.ExternColumnIdentifier{ .tag = 1, .value = .{ .index = 42 } };
    try std.testing.expectEqual(@as(?*[3]usize, null), id_index.string());

    var id_name = JSObject.ExternColumnIdentifier{ .tag = 2, .value = .{ .name = .{ 0, 0, 0 } } };
    try std.testing.expect(id_name.string() != null);
}

comptime {
    _ = home_rt;
}
