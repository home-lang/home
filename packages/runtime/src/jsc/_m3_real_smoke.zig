// Phase 12.2 M3-real — first live JSC C++ calls from Home tests.
//
// Per `JSC_BRIDGE_SCOPE_2026-05-19.md` §M3 (Real Linkage), the
// round-11 link-feasibility report confirmed all 38 M1 extern fns
// resolve against the system `JavaScriptCore.framework` on macOS
// when `-Denable_jsc=true` is set. This file is the first smoke
// test that *runs* JSC code — not just type-checks the extern
// signatures.
//
// Layering:
//   - Tests are unconditionally compiled (so the smoke driver and
//     the default-build test runner stay green).
//   - Each test body gates on `build_options.enable_jsc`: when the
//     flag is off, we return `error.SkipZigTest` and the test is
//     reported as skipped. The JSC symbols never make it to the
//     link step because Zig drops unreferenced extern fns from
//     unreached basic blocks.
//   - When `enable_jsc` is on, the body actually calls into the
//     framework, asserts a number round-trips, and asserts a UTF-8
//     string is created with the right length.
//
// M4-real (real bodies for the value_helpers / exception_helpers /
// property / call / callback / json / promise / iterator / global
// panic-stubs) is the next milestone; this file is the proof-of-life
// that M3 actually links + runs.

const std = @import("std");
const home_rt = @import("home");
const build_options = @import("build_options");

const extern_fns = home_rt.jsc.extern_fns;

test "JSC M3 smoke: create + release global context, round-trip a number" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const ctx = extern_fns.JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer extern_fns.JSGlobalContextRelease(ctx);

    // Round-trip: make a number, inspect, coerce back to f64.
    const num = extern_fns.JSValueMakeNumber(ctx, 42.5) orelse return error.JSValueMakeFailed;
    try std.testing.expect(extern_fns.JSValueIsNumber(ctx, num));
    const back = extern_fns.JSValueToNumber(ctx, num, null);
    try std.testing.expectEqual(@as(f64, 42.5), back);
}

test "JSC M3 smoke: round-trip a UTF-8 string" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const ctx = extern_fns.JSGlobalContextCreate(null) orelse return error.JSCInitFailed;
    defer extern_fns.JSGlobalContextRelease(ctx);

    const s = extern_fns.JSStringCreateWithUTF8CString("hello") orelse return error.StringInitFailed;
    defer extern_fns.JSStringRelease(s);

    const len = extern_fns.JSStringGetLength(s);
    try std.testing.expectEqual(@as(usize, 5), len);
}
