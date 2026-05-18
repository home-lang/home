// Copied from bun/src/jsc/bindgen_test.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
//! This namespace is used to test binding generator.
//
// Upstream exposes `getBindgenTestFunctions(global)` that bundles `add` and
// `requiredAndOptionalArg` into a JS object via `jsc.JSObject.create` plus a
// `bun.gen.bindgen_test` codegen output. Both deps are unported, so the
// entry point is parked behind a `// TODO(jsc-bridge)` until Phase 12.2.
// The two pure-math leaves (`add` + `requiredAndOptionalArg`) are kept
// verbatim — they are pure-Zig and exercise the binding-generator's
// argument-marshalling, not the JSC bridge itself.

const std = @import("std");
const home_rt = @import("home_rt");

// JSC bridge JSGlobalObject stubbed — re-attaches in Phase 12.2.
const JSGlobalObject = opaque {
    /// Stand-in for `JSGlobalObject.throwPretty` — upstream returns
    /// `bun.JSError` after queuing a JS exception on the global. The pure-math
    /// leaf only reaches this on integer overflow, so the stub returns the
    /// same error sentinel without any side-effects.
    pub fn throwPretty(_: *JSGlobalObject, comptime _: []const u8, _: anytype) error{JSError}!i32 {
        return error.JSError;
    }
};

// `getBindgenTestFunctions` is parked: it depends on `jsc.JSObject.create`
// (not yet ported) plus a codegen-emitted `home_rt.gen.bindgen_test` table.
// It re-attaches alongside the rest of the binding-generator surface in
// Phase 12.2.

// This example should be kept in sync with bindgen's documentation
pub fn add(global: *JSGlobalObject, a: i32, b: i32) !i32 {
    return std.math.add(i32, a, b) catch {
        // Binding functions can return `error.OutOfMemory` and `error.JSError`.
        // Others like `error.Overflow` from `std.math.add` must be converted.
        // Remember to be descriptive.
        return global.throwPretty("Integer overflow while adding", .{});
    };
}

pub fn requiredAndOptionalArg(a: bool, b: ?usize, c: i32, d: ?u8) i32 {
    const b_nonnull = b orelse {
        return (123456 +% c) +% (d orelse 0);
    };
    var math_result: i32 = @truncate(@as(isize, @as(u53, @truncate(
        (b_nonnull +% @as(usize, @abs(c))) *% (d orelse 1),
    ))));
    if (a) {
        math_result = -math_result;
    }
    return math_result;
}

test "add returns the integer sum" {
    const global: *JSGlobalObject = @ptrFromInt(@alignOf(usize));
    try std.testing.expectEqual(@as(i32, 7), try add(global, 3, 4));
    try std.testing.expectEqual(@as(i32, -5), try add(global, -8, 3));
}

test "add propagates overflow as error.JSError" {
    const global: *JSGlobalObject = @ptrFromInt(@alignOf(usize));
    const err = add(global, std.math.maxInt(i32), 1);
    try std.testing.expectError(error.JSError, err);
}

test "requiredAndOptionalArg with null b takes the optional path" {
    try std.testing.expectEqual(@as(i32, 123456 + 5 + 7), requiredAndOptionalArg(false, null, 5, 7));
}

test "requiredAndOptionalArg with all args computes signed product" {
    // (2 +% 3) *% 4 = 20, then negated because a = true.
    try std.testing.expectEqual(@as(i32, -20), requiredAndOptionalArg(true, 2, 3, 4));
}

test "home_rt import is wired" {
    try std.testing.expectEqualStrings(
        "fd0b6f1a271fca0b8124b69f230b100f4d636af6",
        home_rt.upstream_sha,
    );
}
