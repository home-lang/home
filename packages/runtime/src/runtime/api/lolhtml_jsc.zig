// Copied from bun/src/runtime/api/lolhtml_jsc.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Rewrites:
//   - @import("bun") → @import("home_rt") (via `home_rt.lolhtml_sys.lol_html.HTMLString`)
//
// Stubs:
//   - `bun.JSError`, `bun.jsc.JSGlobalObject`, `bun.jsc.JSValue`,
//     `bun.String` — not yet wired through home_rt. The bridge type
//     surface is preserved as opaques + an enum(i64) so the file
//     compiles standalone. The hot path is parked under a comptime
//     gate identical to `lol_html.zig`'s `HTMLString.toString()`:
//     home_rt's `HTMLString.toString()` is itself a no-op pending the
//     `bun.String` port, so calling through it here is also a no-op.
//
//! JSC bridge for lol-html `HTMLString`. Keeps `src/lolhtml_sys/` free of JSC types.

const std = @import("std");
const home_rt = @import("home_rt");
const HTMLString = home_rt.lolhtml_sys.lol_html.HTMLString;

// JSC stubs — re-attach when the matching home_rt.jsc surface lands.
const JSGlobalObject = opaque {};
// `JSValue` is ABI-compatible with `i64` (encoded ptr). Using `enum(i64)`
// matches the convention used by `home_rt/jsc/JSArray.zig`.
pub const JSValue = enum(i64) {
    zero = 0,
    js_undefined = 0xa,
    _,
};
pub const JSError = error{JSError};

pub fn htmlStringToJS(this: HTMLString, globalThis: *JSGlobalObject) JSError!JSValue {
    // Upstream body (parked — depends on `bun.String.toJS` + `HTMLString.toString`
    // returning a refcounted `bun.String`; `home_rt.lolhtml_sys.HTMLString.toString`
    // is itself a no-op pending the `bun.String` port):
    //
    //     var str = this.toString();
    //     defer str.deref();
    //     return try str.toJS(globalThis);
    _ = globalThis;
    // Exercise the no-op toString so future re-attachment is one line.
    this.toString();
    return .js_undefined;
}

test "lolhtml_jsc: htmlStringToJS returns js_undefined under the stubbed bun.String surface" {
    const hs: HTMLString = .{ .ptr = "".ptr, .len = 0 };
    // Cast a dummy pointer — JSGlobalObject is opaque so the body cannot
    // actually deref it (and the upstream body is parked).
    var dummy: u8 = 0;
    const g: *JSGlobalObject = @ptrCast(&dummy);
    const v = try htmlStringToJS(hs, g);
    try std.testing.expectEqual(JSValue.js_undefined, v);
}

test "lolhtml_jsc: JSValue tag size matches i64" {
    try std.testing.expectEqual(@as(usize, @sizeOf(i64)), @sizeOf(JSValue));
}
