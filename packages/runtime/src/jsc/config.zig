// Copied from bun/src/jsc/config.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Upstream's `schema.api.TransformOptions` / `ResolveMode` / `Target` are
// not yet ported (they live in Rust under `src/options_types/schema.rs`).
// We declare local minimal stubs so the two `configureTransformOptions*`
// helpers compile against a known shape. Real schema re-attaches in
// Phase 12.5 alongside the bundler port. Bun-named symbols are renamed
// to their Home-native equivalents per the §12.x naming convention —
// upstream's `Target.bun` becomes `Target.home`, and the two functions
// drop the `*Bun*` suffix.

const std = @import("std");

// JSC bridge api.TransformOptions/ResolveMode/Target stubbed —
// re-attaches in Phase 12.2.
pub const api = struct {
    pub const ResolveMode = enum(u8) { disable, lazy, dev, bundle };
    pub const Target = enum(u8) { browser, home, home_macro, node };
    pub const TransformOptions = struct {
        write: bool = false,
        resolve: ResolveMode = .disable,
        target: Target = .browser,
    };
};

pub const DefaultHomeDefines = struct {
    pub const Keys = struct {
        const window = "window";
    };
    pub const Values = struct {
        const window = "undefined";
    };
};

pub fn configureTransformOptionsForHomeVM(allocator: std.mem.Allocator, _args: api.TransformOptions) !api.TransformOptions {
    var args = _args;

    args.write = false;
    args.resolve = api.ResolveMode.lazy;
    return try configureTransformOptionsForHome(allocator, args);
}

pub fn configureTransformOptionsForHome(_: std.mem.Allocator, _args: api.TransformOptions) !api.TransformOptions {
    var args = _args;
    args.target = api.Target.home;
    return args;
}

test "configureTransformOptionsForHome sets target to home" {
    const input: api.TransformOptions = .{};
    const out = try configureTransformOptionsForHome(std.testing.allocator, input);
    try std.testing.expectEqual(api.Target.home, out.target);
}

test "configureTransformOptionsForHomeVM disables write and sets lazy resolve" {
    const input: api.TransformOptions = .{ .write = true, .resolve = .disable };
    const out = try configureTransformOptionsForHomeVM(std.testing.allocator, input);
    try std.testing.expectEqual(false, out.write);
    try std.testing.expectEqual(api.ResolveMode.lazy, out.resolve);
    try std.testing.expectEqual(api.Target.home, out.target);
}

test "DefaultHomeDefines Keys.window equals string 'window'" {
    try std.testing.expectEqualStrings("window", DefaultHomeDefines.Keys.window);
    try std.testing.expectEqualStrings("undefined", DefaultHomeDefines.Values.window);
}
