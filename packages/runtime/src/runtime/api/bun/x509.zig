// Copied from bun/src/runtime/api/bun/x509.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.
//
// Rewrites:
//   - @import("bun")                       → @import("home_rt")
//   - bun.BoringSSL.c                      → home_rt.boringssl_sys.boringssl
//
// Stubs:
//   - `jsc.JSGlobalObject`, `JSValue`, `bun.JSError`, and
//     `bun.jsc.fromJSHostCall` are not yet wired through home_rt.
//     The two `toJS*` bridges are preserved as extern declarations
//     plus thin wrappers; their bodies are parked under the same
//     comptime gate used by `home_rt/jsc/JSArray.zig` so the file
//     compiles standalone. `isSafeAltName` is pure and fully tested.

const std = @import("std");
const home_rt = @import("home_rt");
const BoringSSL = home_rt.boringssl_sys.boringssl;

// JSC stubs — re-attach when `home_rt.jsc.{JSGlobalObject,JSValue,JSError,
// fromJSHostCall}` lands in Phase 12.2.
const JSGlobalObject = @import("home_rt").jsc.JSGlobalObject;
pub const JSValue = enum(i64) {
    zero = 0,
    js_undefined = 0xa,
    _,
};
pub const JSError = error{JSError};

pub inline fn isSafeAltName(name: []const u8, utf8: bool) bool {
    for (name) |c| {
        switch (c) {
            '"',
            '\\',
            // These mess with encoding rules.
            // Fall through.
            ',',
            // Commas make it impossible to split the list of subject alternative
            // names unambiguously, which is why we have to escape.
            // Fall through.
            '\'',
            => {
                // Single quotes are unlikely to appear in any legitimate values, but they
                // could be used to make a value look like it was escaped (i.e., enclosed
                // in single/double quotes).
                return false;
            },
            else => {
                if (utf8) {
                    // In UTF8 strings, we require escaping for any ASCII control character,
                    // but NOT for non-ASCII characters. Note that all bytes of any code
                    // point that consists of more than a single byte have their MSB set.
                    if (c < ' ' or c == '\x7f') {
                        return false;
                    }
                } else {
                    // Check if the char is a control character or non-ASCII character. Note
                    // that char may or may not be a signed type. Regardless, non-ASCII
                    // values will always be outside of this range.
                    if (c < ' ' or c > '~') {
                        return false;
                    }
                }
            },
        }
    }
    return true;
}

pub fn toJS(cert: *BoringSSL.X509, globalObject: *JSGlobalObject) JSError!JSValue {
    // Upstream wraps the call via `bun.jsc.fromJSHostCall` for exception-scope
    // bookkeeping. Until that helper lands in home_rt.jsc, dispatch directly;
    // the C++ side returns `JSValue.zero` on throw, which we treat as the
    // sentinel error.
    const v = Bun__X509__toJSLegacyEncoding(cert, globalObject);
    if (v == .zero) return error.JSError;
    return v;
}

pub fn toJSObject(cert: *BoringSSL.X509, globalObject: *JSGlobalObject) JSError!JSValue {
    return Bun__X509__toJS(cert, globalObject);
}

extern fn Bun__X509__toJSLegacyEncoding(cert: *BoringSSL.X509, globalObject: *JSGlobalObject) JSValue;
extern fn Bun__X509__toJS(cert: *BoringSSL.X509, globalObject: *JSGlobalObject) JSValue;

test "x509.isSafeAltName: plain ASCII letters are safe" {
    try std.testing.expect(isSafeAltName("example.com", false));
    try std.testing.expect(isSafeAltName("example.com", true));
}

test "x509.isSafeAltName: quotes and commas are unsafe" {
    try std.testing.expect(!isSafeAltName("a,b", false));
    try std.testing.expect(!isSafeAltName("a\"b", true));
    try std.testing.expect(!isSafeAltName("a\\b", false));
    try std.testing.expect(!isSafeAltName("a'b", true));
}

test "x509.isSafeAltName: ASCII control chars are unsafe in both modes" {
    try std.testing.expect(!isSafeAltName("a\x01b", false));
    try std.testing.expect(!isSafeAltName("a\x01b", true));
    try std.testing.expect(!isSafeAltName("a\x7fb", false));
    try std.testing.expect(!isSafeAltName("a\x7fb", true));
}

test "x509.isSafeAltName: non-ASCII bytes are unsafe in latin-1 mode and safe in utf8 mode" {
    // 0xC3 0xA9 is "é" in UTF-8; in non-utf8 mode the high bytes flunk the > '~' guard.
    try std.testing.expect(!isSafeAltName("caf\xC3\xA9", false));
    try std.testing.expect(isSafeAltName("caf\xC3\xA9", true));
}

test "x509.isSafeAltName: empty string is safe" {
    try std.testing.expect(isSafeAltName("", false));
    try std.testing.expect(isSafeAltName("", true));
}

test "x509: JSValue tag size matches i64" {
    try std.testing.expectEqual(@as(usize, @sizeOf(i64)), @sizeOf(JSValue));
}
