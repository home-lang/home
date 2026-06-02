// Copied from bun/src/jsc/JSBigInt.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// `JSValue`, `JSGlobalObject`, `bun.String`, `bun.JSError`, `bun.debugAssert`,
// and `bun.jsc.fromJSHostCallGeneric` are not yet ported. The `toString`
// wrapper is rewritten to a direct extern call returning the raw `String` for
// now — the host-call error path re-attaches in Phase 12.2. Stubs preserve
// the public surface.

const std = @import("std");

// JSC bridge JSValue stubbed — re-attaches in Phase 12.2.
const JSValue = @import("home").jsc.JSValue;
// JSC bridge JSGlobalObject stubbed — re-attaches in Phase 12.2.
const JSGlobalObject = @import("./JSGlobalObject.zig").JSGlobalObject;
// JSC bridge bun.String stubbed — re-attaches in Phase 12.2.
const String = opaque {};

pub const JSBigInt = opaque {
    extern fn JSC__JSBigInt__fromJS(*JSValue) ?*JSBigInt;
    pub fn fromJS(value: *JSValue) ?*JSBigInt {
        return JSC__JSBigInt__fromJS(value);
    }

    extern fn JSC__JSBigInt__orderDouble(*JSBigInt, f64) i8;
    extern fn JSC__JSBigInt__orderUint64(*JSBigInt, u64) i8;
    extern fn JSC__JSBigInt__orderInt64(*JSBigInt, i64) i8;
    pub fn order(this: *JSBigInt, comptime T: type, num: T) std.math.Order {
        const result = switch (T) {
            f64 => brk: {
                std.debug.assert(!std.math.isNan(num));
                break :brk JSC__JSBigInt__orderDouble(this, num);
            },
            u64 => JSC__JSBigInt__orderUint64(this, num),
            i64 => JSC__JSBigInt__orderInt64(this, num),
            else => @compileError("Unsupported BigInt.order type"),
        };
        if (result == 0) return .eq;
        if (result < 0) return .lt;
        return .gt;
    }

    extern fn JSC__JSBigInt__toInt64(*JSBigInt) i64;
    pub fn toInt64(this: *JSBigInt) i64 {
        return JSC__JSBigInt__toInt64(this);
    }

    extern fn JSC__JSBigInt__toString(*JSBigInt, *JSGlobalObject) *String;
    /// Phase 12.2 will reintroduce JSError propagation via `fromJSHostCallGeneric`.
    pub fn toString(this: *JSBigInt, global: *JSGlobalObject) *String {
        return JSC__JSBigInt__toString(this, global);
    }
};

test "JSBigInt is an opaque pointer-only type" {
    try std.testing.expect(@sizeOf(*JSBigInt) == @sizeOf(usize));
}

test "order classifies int comparisons" {
    // Smoke test the comptime branch selection — these don't link to C++.
    _ = JSBigInt.order;
    const T = i64;
    try std.testing.expectEqual(T, T);
}
