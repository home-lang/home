// Copied from bun/src/jsc/ResolvedSource.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Upstream `pub const Tag = @import("ResolvedSourceTag").ResolvedSourceTag` is a
// build-system module (codegen → `build/*/codegen/ResolvedSourceTag.zig`). The
// codegen output contains both structural variants (`Javascript`,
// `PackageJsonTypeModule`, …) and an open-ended `(1 << 9) | id` half generated
// from the `HardcodedModule` enum.
//
// Home's port keeps the same `extern struct` shape so the C ABI matches the
// upstream `ResolvedSource` and reuses `Tag` as a `u32` newtype with the
// structural variants enumerated as constants. The hardcoded-module table
// re-attaches alongside `ModuleLoader` in Phase 12.2.
//
// `bun.String` and `jsc.JSValue` are not yet ported. Local stubs preserve
// the field shape and the C ABI; the JSC bridge re-attaches in Phase 12.2.

const std = @import("std");

// JSC bridge `bun.String` stubbed — re-attaches in Phase 12.2. Real upstream
// shape is a 24-byte tagged union (`{ tag: u8, padding: [3]u8, ptr: usize,
// len: usize }`); the stub matches sizeof/align so `ResolvedSource` round-trips
// through C++ unchanged.
const String = extern struct {
    tag: u8 = 0, // Dead = 0
    _padding: [3]u8 = .{ 0, 0, 0 },
    ptr: usize = 0,
    len: usize = 0,

    pub const empty: String = .{};
};

pub const JSValue = @import("home").jsc.JSValue;

/// Mirrors `build/*/codegen/ResolvedSourceTag.zig`. The full `(1 << 9) | id`
/// hardcoded-module half is generated at build time from `HardcodedModule`
/// and is omitted here — `Tag` round-trips as a plain `u32` so unknown
/// generator-supplied ids stay representable. Structural variants are kept
/// in lock-step with `src/jsc/bindings/headers-handwritten.h` and the Rust
/// mirror in `crate::resolved_source_tag`.
pub const Tag = enum(u32) {
    javascript = 0,
    package_json_type_module = 1,
    package_json_type_commonjs = 2,
    wasm = 3,
    object = 4,
    file = 5,
    esm = 6,
    json_for_object_loader = 7,
    /// Generate an object with `default` set to all the exports, including a
    /// `default` property.
    exports_object = 8,
    /// Generate a module that only exports `default` = the input JSValue.
    export_default_object = 9,
    /// Signal upwards that the matching value in `require.extensions`
    /// should be used.
    common_js_custom_extension = 10,
    _,
};

pub const ResolvedSource = extern struct {
    /// Specifier's lifetime is the caller from C++
    /// https://github.com/oven-sh/bun/issues/9521
    specifier: String = String.empty,
    source_code: String = String.empty,

    /// source_url is eventually deref'd on success
    source_url: String = String.empty,

    is_commonjs_module: bool = false,

    /// When .tag is .common_js_custom_extension, this is special-cased to hold
    /// the JSFunction extension. It is kept alive by
    /// - This structure is stored on the stack
    /// - There is a JSC::Strong reference to it
    cjs_custom_extension_index: JSValue = .zero,

    allocator: ?*anyopaque = null,

    jsvalue_for_export: JSValue = .zero,

    tag: Tag = .javascript,

    /// This is for source_code
    source_code_needs_deref: bool = true,
    already_bundled: bool = false,

    // -- Bytecode cache fields --
    bytecode_cache: ?[*]u8 = null,
    bytecode_cache_size: usize = 0,
    module_info: ?*anyopaque = null,
    /// The file path used as the source origin for bytecode cache validation.
    /// JSC validates bytecode by checking if the origin URL matches exactly what
    /// was used at build time. If empty, the origin is derived from source_url.
    /// This is converted to a file:// URL on the C++ side.
    bytecode_origin_path: String = String.empty,
};

test "ResolvedSource is an extern struct with default Javascript tag" {
    const rs: ResolvedSource = .{};
    try std.testing.expectEqual(Tag.javascript, rs.tag);
    try std.testing.expectEqual(JSValue.zero, rs.cjs_custom_extension_index);
    try std.testing.expectEqual(JSValue.zero, rs.jsvalue_for_export);
    try std.testing.expect(rs.source_code_needs_deref);
    try std.testing.expect(!rs.already_bundled);
    try std.testing.expect(rs.allocator == null);
    try std.testing.expect(rs.bytecode_cache == null);
    try std.testing.expect(rs.module_info == null);
}

test "Tag structural variants stay in lock-step with headers-handwritten.h" {
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(Tag.javascript));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(Tag.package_json_type_module));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(Tag.package_json_type_commonjs));
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(Tag.wasm));
    try std.testing.expectEqual(@as(u32, 4), @intFromEnum(Tag.object));
    try std.testing.expectEqual(@as(u32, 5), @intFromEnum(Tag.file));
    try std.testing.expectEqual(@as(u32, 6), @intFromEnum(Tag.esm));
    try std.testing.expectEqual(@as(u32, 7), @intFromEnum(Tag.json_for_object_loader));
    try std.testing.expectEqual(@as(u32, 8), @intFromEnum(Tag.exports_object));
    try std.testing.expectEqual(@as(u32, 9), @intFromEnum(Tag.export_default_object));
    try std.testing.expectEqual(@as(u32, 10), @intFromEnum(Tag.common_js_custom_extension));
}

test "String stub size matches the upstream BunString" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(String));
}
