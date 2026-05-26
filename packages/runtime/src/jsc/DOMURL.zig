// Copied from bun/src/jsc/DOMURL.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Thin Zig wrapper around `WebCore::DOMURL*`. The C++ side gives us
// extern getters that take `ZigString*` out-params and a tagged-union
// `bun.String` for the file-system-path conversion.
//
// The JSC bridge re-attaches in Phase 12.2. Until then, `cast(JSValue)`
// remains a non-throwing stub for copied callers that probe URL wrappers.

const std = @import("std");
const bun = @import("home_rt");

const JSValue = bun.jsc.JSValue;
const VM = bun.jsc.VirtualMachine;
const String = bun.String;

// `ZigString` C ABI stub: `{ptr, len}` view. Real ZigString uses the high
// bit of len to flag UTF-16. We don't need that bit here.
const ZigString = extern struct {
    _ptr: ?[*]const u8 = null,
    _len: usize = 0,

    pub const Empty: ZigString = .{};
};

pub const DOMURL = opaque {
    pub extern fn WebCore__DOMURL__cast_(JSValue0: JSValue, arg1: *VM) ?*DOMURL;

    pub fn cast_(value: JSValue, vm: *VM) ?*DOMURL {
        return WebCore__DOMURL__cast_(value, vm);
    }

    pub fn cast(_: JSValue) ?*DOMURL {
        return null;
    }

    extern fn WebCore__DOMURL__href_(this: *DOMURL, out: *ZigString) void;
    pub fn href_(this: *DOMURL, out: *ZigString) void {
        return WebCore__DOMURL__href_(this, out);
    }

    pub fn href(this: *DOMURL) ZigString {
        var out: ZigString = .Empty;
        this.href_(&out);
        return out;
    }

    extern fn WebCore__DOMURL__fileSystemPath(arg0: *DOMURL, error_code: *c_int) String;
    pub const ToFileSystemPathError = error{
        NotFileUrl,
        InvalidPath,
        InvalidHost,
    };
    pub fn fileSystemPath(this: *DOMURL) ToFileSystemPathError!String {
        var error_code: c_int = 0;
        const path = WebCore__DOMURL__fileSystemPath(this, &error_code);
        switch (error_code) {
            1 => return ToFileSystemPathError.InvalidHost,
            2 => return ToFileSystemPathError.InvalidPath,
            3 => return ToFileSystemPathError.NotFileUrl,
            else => {},
        }
        std.debug.assert(!path.isEmpty());
        return path;
    }

    extern fn WebCore__DOMURL__pathname_(this: *DOMURL, out: *ZigString) void;
    pub fn pathname_(this: *DOMURL, out: *ZigString) void {
        return WebCore__DOMURL__pathname_(this, out);
    }

    pub fn pathname(this: *DOMURL) ZigString {
        var out: ZigString = .Empty;
        this.pathname_(&out);
        return out;
    }
};

test "DOMURL is an opaque pointer-only type" {
    try std.testing.expect(@sizeOf(*DOMURL) == @sizeOf(usize));
}

test "DOMURL exposes the expected entrypoints" {
    try std.testing.expect(@hasDecl(DOMURL, "cast_"));
    try std.testing.expect(@hasDecl(DOMURL, "cast"));
    try std.testing.expect(@hasDecl(DOMURL, "href_"));
    try std.testing.expect(@hasDecl(DOMURL, "href"));
    try std.testing.expect(@hasDecl(DOMURL, "fileSystemPath"));
    try std.testing.expect(@hasDecl(DOMURL, "pathname_"));
    try std.testing.expect(@hasDecl(DOMURL, "pathname"));
}

test "ToFileSystemPathError enumerates the three failure modes" {
    const E = DOMURL.ToFileSystemPathError;
    const a: E = error.NotFileUrl;
    const b: E = error.InvalidPath;
    const c: E = error.InvalidHost;
    try std.testing.expect(a != b);
    try std.testing.expect(b != c);
}
