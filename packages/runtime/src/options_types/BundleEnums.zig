// Copied from bun/src/options_types/BundleEnums.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home"). The JSC-bridge
// reference `Format.fromJS` (re-exported from `bundler_jsc/options_jsc.zig`)
// is intentionally omitted — it re-lands under `src/bundler_jsc/` once JSC
// bindings exist (Phase 12.2). `BundlePackage.Map` uses `std`'s
// `StringArrayHashMapUnmanaged` directly since `bun.StringArrayHashMapUnmanaged`
// is just a re-export of the std type.

//! Pure enum/struct option types extracted from `bundler/options.zig` so
//! `cli/` and other tiers can reference them without depending on `bundler/`.
//! Aliased back at original locations — call sites unchanged.

pub const Format = enum {
    /// ES module format
    /// This is the default format
    esm,

    /// Immediately-invoked function expression
    /// (function(){
    ///     ...
    /// })();
    iife,

    /// CommonJS
    cjs,

    /// Bake uses a special module format for Hot-module-reloading. It includes a
    /// runtime payload, sourced from src/bake/hmr-runtime-{side}.ts.
    ///
    /// ((unloadedModuleRegistry, config) => {
    ///   ... runtime code ...
    /// })({
    ///   "module1.ts": ...,
    ///   "module2.ts": ...,
    /// }, { ...metadata... });
    internal_bake_dev,

    pub fn keepES6ImportExportSyntax(this: Format) bool {
        return this == .esm;
    }

    pub inline fn isESM(this: Format) bool {
        return this == .esm;
    }

    pub inline fn isAlwaysStrictMode(this: Format) bool {
        return this == .esm;
    }

    pub const Map = home_rt.ComptimeStringMap(Format, .{
        .{ "esm", .esm },
        .{ "cjs", .cjs },
        .{ "iife", .iife },

        // TODO: Disable this outside of debug builds
        .{ "internal_bake_dev", .internal_bake_dev },
    });

    // JSC-bridge Format.fromJS omitted — re-lands in Phase 12.2.

    pub fn fromString(slice: []const u8) ?Format {
        // Upstream calls `Map.getWithEql(slice, bun.strings.eqlComptime)` —
        // Home's `ComptimeStringMap` already routes `.get` through
        // `eqlComptimeCheckLenWithType`, so the additional `eql` parameter is
        // unnecessary here.
        return Map.get(slice);
    }
};

pub const WindowsOptions = struct {
    hide_console: bool = false,
    icon: ?[]const u8 = null,
    title: ?[]const u8 = null,
    publisher: ?[]const u8 = null,
    version: ?[]const u8 = null,
    description: ?[]const u8 = null,
    copyright: ?[]const u8 = null,
};

pub const BundlePackage = enum {
    always,
    never,

    pub const Map = std.StringArrayHashMapUnmanaged(BundlePackage);
};

test "Format.Map maps canonical names" {
    const testing = std.testing;
    try testing.expectEqual(Format.esm, Format.Map.get("esm").?);
    try testing.expectEqual(Format.cjs, Format.Map.get("cjs").?);
    try testing.expectEqual(Format.iife, Format.Map.get("iife").?);
    try testing.expect(Format.Map.get("amd") == null);
}

test "Format.fromString matches Format.Map" {
    const testing = std.testing;
    try testing.expectEqual(Format.esm, Format.fromString("esm").?);
    try testing.expect(Format.fromString("nope") == null);
}

test "Format.isESM / isAlwaysStrictMode / keepES6 only hold for esm" {
    const testing = std.testing;
    try testing.expect(Format.esm.isESM());
    try testing.expect(Format.esm.isAlwaysStrictMode());
    try testing.expect(Format.esm.keepES6ImportExportSyntax());
    try testing.expect(!Format.cjs.isESM());
    try testing.expect(!Format.iife.isAlwaysStrictMode());
    try testing.expect(!Format.internal_bake_dev.keepES6ImportExportSyntax());
}

test "BundlePackage.Map is constructible and usable" {
    const testing = std.testing;
    var map: BundlePackage.Map = .{};
    defer map.deinit(testing.allocator);
    try map.put(testing.allocator, "react", .always);
    try map.put(testing.allocator, "lodash", .never);
    try testing.expectEqual(BundlePackage.always, map.get("react").?);
    try testing.expectEqual(BundlePackage.never, map.get("lodash").?);
    try testing.expect(map.get("vue") == null);
}

test "WindowsOptions defaults are all unset" {
    const testing = std.testing;
    const opts: WindowsOptions = .{};
    try testing.expect(!opts.hide_console);
    try testing.expect(opts.icon == null);
    try testing.expect(opts.title == null);
    try testing.expect(opts.publisher == null);
    try testing.expect(opts.version == null);
    try testing.expect(opts.description == null);
    try testing.expect(opts.copyright == null);
}

const std = @import("std");
const home_rt = @import("home");
