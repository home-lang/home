// Copied from bun/src/runtime/webcore/CookieMap.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.
//
// Rewrites:
//   - @import("bun") → @import("home_rt")
//
// Stubs (re-attach when home_rt.jsc + home_rt.uws grow JSC bridges):
//   - `bun.jsc.JSGlobalObject` modelled as `opaque {}` (same convention as
//     `runtime/api/lolhtml_jsc.zig` and `runtime/api/cron_parser.zig`).
//   - `bun.uws.ResponseKind` inlined as `enum(i32)` mirroring the upstream
//     definition in `src/uws/uws.zig` line 51. The Bun source treats this
//     as a plain ABI enum, so inlining is safe.
//   - `bun.jsc.fromJSHostCallGeneric` (which intercepts exceptions on the
//     JS thread) is replaced by a direct extern call. The wrapper exists
//     in upstream for exception-pump scheduling that home_rt.jsc has not
//     re-attached yet.
//   - `bun.JSError` → `error{JSError}` (single-variant local set).
//
// The `CookieMap` itself is `opaque`: this file is a thin Zig-side
// reference to the C++ backing class. All three externs (`write`, `ref`,
// `deref`) are honoured verbatim; `Bun__` is the documented externs
// prefix that stays unchanged across ports.

const std = @import("std");

// JSC stub — re-attach when home_rt.jsc grows the `JSGlobalObject` surface.
const JSGlobalObject = opaque {};

// uws stub — re-attach when home_rt.uws grows the response-kind enum.
// Mirrors upstream `src/uws/uws.zig:51` exactly.
pub const ResponseKind = enum(i32) {
    /// Plain HTTP/1.1 over TCP.
    http1,
    /// HTTP/1.1 over TLS.
    http1_ssl,
    /// HTTP/3 over QUIC.
    http3,
};

pub const JSError = error{JSError};

pub const CookieMap = opaque {
    extern fn CookieMap__write(
        cookie_map: *CookieMap,
        global_this: *JSGlobalObject,
        kind: ResponseKind,
        uws_http_response: *anyopaque,
    ) void;

    /// Upstream wraps this in `bun.jsc.fromJSHostCallGeneric` to pump
    /// exceptions on the JS thread. That helper hasn't been ported into
    /// home_rt yet, so we expose the raw extern. The behaviour is
    /// identical when no exception is in flight (the common path); the
    /// exception-checking gate re-attaches with home_rt.jsc.
    pub fn write(
        cookie_map: *CookieMap,
        globalThis: *JSGlobalObject,
        kind: ResponseKind,
        uws_http_response: *anyopaque,
    ) JSError!void {
        CookieMap__write(cookie_map, globalThis, kind, uws_http_response);
    }

    extern fn CookieMap__deref(cookie_map: *CookieMap) void;

    pub const deref = CookieMap__deref;

    extern fn CookieMap__ref(cookie_map: *CookieMap) void;

    pub const ref = CookieMap__ref;
};

test "CookieMap: ResponseKind tag ordering matches upstream uws.zig" {
    // The tag ordering is ABI: C++ casts an i32 into this enum directly.
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(ResponseKind.http1));
    try std.testing.expectEqual(@as(i32, 1), @intFromEnum(ResponseKind.http1_ssl));
    try std.testing.expectEqual(@as(i32, 2), @intFromEnum(ResponseKind.http3));
}

test "CookieMap: opaque type has no Zig-side size" {
    // Sanity: CookieMap must stay opaque so the C++ side can change
    // layout without ABI breaks here.
    try std.testing.expect(@typeInfo(CookieMap) == .@"opaque");
}
