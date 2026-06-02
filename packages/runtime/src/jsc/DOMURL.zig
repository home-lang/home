// Copied from bun/src/jsc/DOMURL.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Thin Zig wrapper around `WebCore::DOMURL*`. The C++ side gives us
// extern getters that take `ZigString*` out-params and a tagged-union
// `bun.String` for the file-system-path conversion.
//
// `JSValue`, `JSGlobalObject`, `VM`, `ZigString`, and `bun.String` are not
// yet ported. Local stubs preserve the C ABI. The JSC bridge re-attaches
// in Phase 12.2.
//
// Omitted:
//   - `cast(JSValue)` — needs `jsc.VirtualMachine.get().global.vm()`; the
//     `cast_(JSValue, *VM)` two-arg form stays, callers pass the VM in.
//   - `bun.cpp.WebCore__DOMURL__*` re-references — we declare the externs
//     locally (they live in the same shared lib).

const std = @import("std");

// JSC bridge stubs — re-attach in Phase 12.2.
const JSValue = @import("home_rt").jsc.JSValue;
const VM = @import("./VM.zig").VM;

// `bun.String` C ABI stub. Real layout `{tag: u8, _padding: 7 bytes, impl: *anyopaque}`.
// We expose just enough surface (the `tag` field — callers check it against
// the `.Dead` sentinel) to keep the FS-path path callable later.
const String = extern struct {
    tag: u8 = 0,
    _padding: [7]u8 = @splat(0),
    impl: ?*anyopaque = null,

    pub const Tag = enum(u8) {
        Dead = 0,
        // Real tags re-attach in Phase 12.2; we only name `Dead` because
        // upstream's `fileSystemPath` checks for it explicitly.
        _,
    };
};

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

    // `cast(JSValue)` upstream goes through `jsc.VirtualMachine.get().global.vm()`.
    // Callers can use `cast_(value, vm)` directly once they hold the VM.

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
        // Upstream: `bun.assert(path.tag != .Dead)`. With our stubbed String
        // the assertion is structurally meaningful but `.Dead` re-attaches
        // in Phase 12.2 — we keep the shape for now.
        std.debug.assert(path.tag != @intFromEnum(String.Tag.Dead));
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
