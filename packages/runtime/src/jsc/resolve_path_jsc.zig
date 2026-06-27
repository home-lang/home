// Copied from bun/src/jsc/resolve_path_jsc.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
//! C++ export that joins a path against the VM's cwd. Lives in `jsc/` because
//! it reaches into `globalObject.bunVM().transpiler.fs`. Referenced from the
//! pinned C++ `PathInlines.h` (`pathResolveWTFString` → this), which backs
//! `Bun.pathToFileURL` (and node:url's `pathToFileURL`) when resolving a
//! RELATIVE path. This was a no-op stub (native_stubs.zig), so relative
//! `pathToFileURL("foo/bar")` collapsed to `file:///` instead of
//! `file:///<cwd>/foo/bar`.

export fn ResolvePath__joinAbsStringBufCurrentPlatformBunString(
    globalObject: *bun.jsc.JSGlobalObject,
    in: bun.String,
) bun.String {
    const str = in.toUTF8WithoutRef(bun.default_allocator);
    defer str.deinit();

    const cwd = globalObject.bunVM().transpiler.fs.top_level_dir;

    // The input is user-controlled and may be arbitrarily long (longer than
    // PATH_MAX), so heap-allocate the join buffer rather than using the
    // 4096-byte threadlocal join buffer.
    const alloc = bun.default_allocator;
    const buf = bun.handleOom(alloc.alloc(u8, cwd.len + str.slice().len + 2));
    defer alloc.free(buf);

    const out_slice = bun.path.joinAbsStringBuf(cwd, buf, &.{str.slice()}, .auto);
    return bun.String.cloneUTF8(out_slice);
}

const bun = @import("bun");
