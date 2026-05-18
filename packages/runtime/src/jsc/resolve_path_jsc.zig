// Copied from bun/src/jsc/resolve_path_jsc.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
//! C++ export that joins a path against the VM's cwd. Lives in `jsc/`
//! because it reaches into `globalObject.bunVM().transpiler.fs`. The full
//! JSC bridge (`bun.jsc.JSGlobalObject`, `bun.String`, `bun.handleOom`,
//! `bun.path.joinAbsStringBuf`, `bun.default_allocator`) is not ported yet,
//! so the body is parked and the public extern symbol is preserved as an
//! opaque declaration so callers can name it. Re-attaches in Phase 12.2.
//
// Omitted (re-attach in Phase 12.2):
//   - the actual `joinAbsStringBuf(.auto)` call against
//     `globalObject.bunVM().transpiler.fs.top_level_dir`.
//   - `bun.String.cloneUTF8` for the result.

const std = @import("std");

// JSC bridge stubs — re-attach in Phase 12.2. The full shapes carry an
// opaque global pointer (so the C ABI is `*JSGlobalObject`) and the
// 5-variant tagged `bun.String` payload C++ uses; here we just preserve the
// extern name and a stand-in shape so callers can spell it.
const JSGlobalObject = opaque {};
const String = extern struct {
    tag: u8 = 0,
    _padding: [7]u8 = @splat(0),
    impl: ?*anyopaque = null,
};

pub extern fn ResolvePath__joinAbsStringBufCurrentPlatformBunString(
    globalObject: *JSGlobalObject,
    in: String,
) String;

test "resolve_path_jsc: extern symbol declared" {
    // The extern fn is provided by the C++ side. Here we only check the
    // type signature is what callers expect — we never take the address
    // (which would require the C++ symbol at link time).
    try std.testing.expectEqual(
        @TypeOf(ResolvePath__joinAbsStringBufCurrentPlatformBunString),
        fn (*JSGlobalObject, String) callconv(.c) String,
    );
}
