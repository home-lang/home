// Copied from bun/src/runtime/api/standalone_graph_jsc.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Rewrites:
//   - @import("bun") → @import("home_rt")
//
// Stubs (re-attach in Phase 12.2 when home_rt grows the matching surface):
//   - `bun.jsc.JSGlobalObject`, `bun.webcore.Blob`, `bun.webcore.Blob.Store`,
//     `bun.http.MimeType.byExtensionNoDefault`, `bun.PathString`, `bun.String`,
//     `bun.StandaloneModuleGraph.{File,base_public_path_with_default_suffix}`
//     — none are on home_rt yet. The `fileBlob` body is parked verbatim in a
//     comment; the local `File` stub mirrors only the field shape the bridge
//     reads so the function signature stays type-checked.

//! JSC bridges for `StandaloneModuleGraph.File`. The graph itself stays in
//! `standalone_graph/` (used by the bundler with no JS in the loop); only the
//! `Blob` accessor that needs a `*JSGlobalObject` lives here.

const std = @import("std");
const home_rt = @import("home_rt");

// JSC + webcore stubs — re-attach in Phase 12.2.
const JSGlobalObject = opaque {};
pub const Blob = opaque {};

/// Field shape mirrors `bun.StandaloneModuleGraph.File` only insofar as the
/// bridge touches it (name, contents, cached_blob). The graph type itself
/// will land alongside the bundler port.
pub const File = struct {
    name: []const u8,
    contents: []const u8,
    cached_blob: ?*Blob = null,
};

// Upstream `fileBlob`, parked verbatim:
//
//     pub fn fileBlob(this: *File, globalObject: *bun.jsc.JSGlobalObject) *bun.webcore.Blob {
//         if (this.cached_blob == null) {
//             const store = bun.webcore.Blob.Store.init(@constCast(this.contents), bun.default_allocator);
//             store.ref();
//             const b = bun.webcore.Blob.initWithStore(store, globalObject).new();
//             if (bun.http.MimeType.byExtensionNoDefault(bun.strings.trimLeadingChar(std.fs.path.extension(this.name), '.'))) |mime| {
//                 store.mime_type = mime;
//                 b.content_type = mime.value;
//                 b.content_type_was_set = true;
//                 b.content_type_allocated = false;
//             }
//             store.data.bytes.stored_name = bun.PathString.init(this.name);
//             if (strings.hasPrefixComptime(this.name, bun.StandaloneModuleGraph.base_public_path_with_default_suffix)) {
//                 b.name = bun.String.cloneUTF8(this.name[bun.StandaloneModuleGraph.base_public_path_with_default_suffix.len..]);
//             } else if (this.name.len > 0) {
//                 b.name = bun.String.cloneUTF8(this.name);
//             }
//             this.cached_blob = b;
//         }
//         return this.cached_blob.?;
//     }
pub fn fileBlob(this: *File, globalObject: *JSGlobalObject) ?*Blob {
    _ = globalObject;
    // Body parked — no Blob/Store/MimeType/String/PathString on home_rt yet.
    return this.cached_blob;
}

test "standalone_graph_jsc: fileBlob returns the cached blob if present" {
    var dummy_blob_byte: u8 = 0;
    const blob_ptr: *Blob = @ptrCast(&dummy_blob_byte);
    var f = File{ .name = "x.js", .contents = "", .cached_blob = blob_ptr };

    var dummy_global: u8 = 0;
    const g: *JSGlobalObject = @ptrCast(&dummy_global);

    try std.testing.expectEqual(@as(?*Blob, blob_ptr), fileBlob(&f, g));
}

test "standalone_graph_jsc: fileBlob returns null when no cache (body parked)" {
    var f = File{ .name = "x.js", .contents = "", .cached_blob = null };
    var dummy: u8 = 0;
    const g: *JSGlobalObject = @ptrCast(&dummy);
    try std.testing.expectEqual(@as(?*Blob, null), fileBlob(&f, g));
}

test "standalone_graph_jsc: File field shape preserved" {
    const f = File{ .name = "main.js", .contents = "console.log(1)", .cached_blob = null };
    try std.testing.expectEqualStrings("main.js", f.name);
    try std.testing.expectEqualStrings("console.log(1)", f.contents);
}

comptime {
    _ = &home_rt.upstream_sha;
}
