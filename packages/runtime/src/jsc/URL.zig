// Copied from bun/src/jsc/URL.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Zig wrapper around WebKit's WHATWG URL parser. Each method is an extern
// shim into `vendor/WebKit`; the JSC-visible methods (`fromJS`, `hrefFromJS`)
// signal failure with a pending JSC exception.
//
// `JSGlobalObject`, `JSValue`, and `bun.String` are not yet ported (Phase
// 12.2). We stub them as the layouts upstream uses so the extern signatures
// line up. The `JSError` channel is mapped to a plain `error{JSError}` until
// the global error-set re-attaches.
//
// Omitted (re-attach in Phase 12.2):
//   - `originFromSlice` — needs `home_rt.strings.firstNonASCII`, which has
//     not been ported yet. The extern (`URL__originLength`) stays declared
//     in case a follow-up needs it.

const std = @import("std");
const home_rt = @import("home");

// JSC bridge stubs — re-attach in Phase 12.2.
const JSGlobalObject = opaque {
    // Real upstream has `hasException(): bool` which checks the VM. The
    // local fromJS/hrefFromJS paths defer the check to the JSC bridge.
    pub fn hasException(_: *JSGlobalObject) bool {
        return false;
    }
};
const JSValue = @import("home").jsc.JSValue;

// The real `bun.String` (`BunString`, `string/string.zig`) is now ported, so
// the URL extern shims return / accept it directly — matching upstream, where
// every `URL__*` returns `bun.String`. (Previously stubbed as a layout-only
// placeholder while `bun.String` was unported.)
const String = home_rt.String;

const JSError = error{JSError};

pub const URL = opaque {
    extern fn URL__fromJS(JSValue, *JSGlobalObject) ?*URL;
    extern fn URL__fromString(*String) ?*URL;
    extern fn URL__protocol(*URL) String;
    extern fn URL__href(*URL) String;
    extern fn URL__username(*URL) String;
    extern fn URL__password(*URL) String;
    extern fn URL__search(*URL) String;
    extern fn URL__host(*URL) String;
    extern fn URL__hostname(*URL) String;
    extern fn URL__port(*URL) u32;
    extern fn URL__deinit(*URL) void;
    extern fn URL__pathname(*URL) String;
    extern fn URL__getHrefFromJS(JSValue, *JSGlobalObject) String;
    extern fn URL__getHref(*String) String;
    extern fn URL__getFileURLString(*String) String;
    extern fn URL__getHrefJoin(*String, *String) String;
    extern fn URL__pathFromFileURL(*String) String;
    extern fn URL__hash(*URL) String;
    extern fn URL__fragmentIdentifier(*URL) String;

    /// Includes the leading '#'.
    pub fn hash(url: *URL) String {
        return URL__hash(url);
    }

    /// Exactly the same as `hash`, excluding the leading '#'.
    pub fn fragmentIdentifier(url: *URL) String {
        return URL__fragmentIdentifier(url);
    }

    pub fn hrefFromString(str: String) String {
        var input = str;
        return URL__getHref(&input);
    }

    pub fn join(base: String, relative: String) String {
        var base_str = base;
        var relative_str = relative;
        return URL__getHrefJoin(&base_str, &relative_str);
    }

    pub fn fileURLFromString(str: String) String {
        var input = str;
        return URL__getFileURLString(&input);
    }

    pub fn pathFromFileURL(str: String) String {
        var input = str;
        return URL__pathFromFileURL(&input);
    }

    /// This percent-encodes the URL, punycode-encodes the hostname, and returns the
    /// result. If it fails, the tag is marked Dead.
    pub fn hrefFromJS(value: JSValue, globalObject: *JSGlobalObject) JSError!String {
        const result = URL__getHrefFromJS(value, globalObject);
        if (globalObject.hasException()) return error.JSError;
        return result;
    }

    pub fn fromJS(value: JSValue, globalObject: *JSGlobalObject) JSError!?*URL {
        const result = URL__fromJS(value, globalObject);
        if (globalObject.hasException()) return error.JSError;
        return result;
    }

    pub fn fromUTF8(input: []const u8) ?*URL {
        return fromString(String.borrowUTF8(input));
    }

    pub fn fromString(str: String) ?*URL {
        var input = str;
        return URL__fromString(&input);
    }

    pub fn protocol(url: *URL) String {
        return URL__protocol(url);
    }

    pub fn href(url: *URL) String {
        return URL__href(url);
    }

    pub fn username(url: *URL) String {
        return URL__username(url);
    }

    pub fn password(url: *URL) String {
        return URL__password(url);
    }

    pub fn search(url: *URL) String {
        return URL__search(url);
    }

    /// Returns the host WITHOUT the port.
    ///
    /// Note that this does NOT match JS behavior, which returns the host with
    /// the port. See `hostname` for the JS equivalent of `host`.
    ///
    /// ```
    /// URL("http://example.com:8080").host() => "example.com"
    /// ```
    pub fn host(url: *URL) String {
        return URL__host(url);
    }

    /// Returns the host WITH the port.
    ///
    /// Note that this does NOT match JS behavior which returns the host without
    /// the port. See `host` for the JS equivalent of `hostname`.
    ///
    /// ```
    /// URL("http://example.com:8080").hostname() => "example.com:8080"
    /// ```
    pub fn hostname(url: *URL) String {
        return URL__hostname(url);
    }

    /// Returns `std.math.maxInt(u32)` if the port is not set. Otherwise, `port`
    /// is guaranteed to be within the `u16` range.
    pub fn port(url: *URL) u32 {
        return URL__port(url);
    }

    pub fn deinit(url: *URL) void {
        return URL__deinit(url);
    }

    pub fn pathname(url: *URL) String {
        return URL__pathname(url);
    }

    /// Declared (but not yet wrapped) — `originFromSlice` reaches into
    /// `bun.strings.firstNonASCII`, which the runtime has not yet exposed.
    extern fn URL__originLength(latin1_slice: [*]const u8, len: usize) u32;
};

test "URL is an opaque pointer-only type" {
    try std.testing.expect(@sizeOf(*URL) == @sizeOf(usize));
}

test "URL exposes the expected entrypoints" {
    try std.testing.expect(@hasDecl(URL, "fromJS"));
    try std.testing.expect(@hasDecl(URL, "fromUTF8"));
    try std.testing.expect(@hasDecl(URL, "fromString"));
    try std.testing.expect(@hasDecl(URL, "hrefFromJS"));
    try std.testing.expect(@hasDecl(URL, "hrefFromString"));
    try std.testing.expect(@hasDecl(URL, "join"));
    try std.testing.expect(@hasDecl(URL, "fileURLFromString"));
    try std.testing.expect(@hasDecl(URL, "pathFromFileURL"));
    try std.testing.expect(@hasDecl(URL, "protocol"));
    try std.testing.expect(@hasDecl(URL, "href"));
    try std.testing.expect(@hasDecl(URL, "username"));
    try std.testing.expect(@hasDecl(URL, "password"));
    try std.testing.expect(@hasDecl(URL, "search"));
    try std.testing.expect(@hasDecl(URL, "host"));
    try std.testing.expect(@hasDecl(URL, "hostname"));
    try std.testing.expect(@hasDecl(URL, "port"));
    try std.testing.expect(@hasDecl(URL, "deinit"));
    try std.testing.expect(@hasDecl(URL, "pathname"));
    try std.testing.expect(@hasDecl(URL, "hash"));
    try std.testing.expect(@hasDecl(URL, "fragmentIdentifier"));
}

test "URL String aliases the real home_rt.String (BunString)" {
    // The URL extern shims now return/accept the real `bun.String`
    // (`home_rt.String`, the WTF-backed `BunString`) instead of a layout-only
    // stub, matching upstream where every `URL__*` returns `bun.String`.
    try std.testing.expectEqual(String, home_rt.String);
}

comptime {
    _ = home_rt;
}
