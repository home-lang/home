// Copied from bun/src/jsc/config.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// `bun.schema.api.TransformOptions` / `ResolveMode` / `Target` are not yet
// ported (they live in Rust under `src/options_types/schema.rs` upstream).
// We declare local minimal stubs so the two `configureTransformOptionsForBun*`
// helpers compile against a known shape. Real schema re-attaches in Phase 12.5
// alongside the bundler port.

const std = @import("std");

// JSC bridge api.TransformOptions/ResolveMode/Target stubbed — re-attaches in Phase 12.2.
pub const api = struct {
    pub const ResolveMode = enum(u8) { disable, lazy, dev, bundle };
    pub const Target = enum(u8) { browser, bun, bun_macro, node };
    pub const TransformOptions = struct {
        write: bool = false,
        resolve: ResolveMode = .disable,
        target: Target = .browser,
    };
};

pub const DefaultBunDefines = struct {
    pub const Keys = struct {
        const window = "window";
    };
    pub const Values = struct {
        const window = "undefined";
    };
};

pub fn configureTransformOptionsForBunVM(allocator: std.mem.Allocator, _args: api.TransformOptions) !api.TransformOptions {
    var args = _args;

    args.write = false;
    args.resolve = api.ResolveMode.lazy;
    return try configureTransformOptionsForBun(allocator, args);
}

pub fn configureTransformOptionsForBun(_: std.mem.Allocator, _args: api.TransformOptions) !api.TransformOptions {
    var args = _args;
    args.target = api.Target.bun;
    return args;
}

test "configureTransformOptionsForBun sets target to bun" {
    const input: api.TransformOptions = .{};
    const out = try configureTransformOptionsForBun(std.testing.allocator, input);
    try std.testing.expectEqual(api.Target.bun, out.target);
}

test "configureTransformOptionsForBunVM disables write and sets lazy resolve" {
    const input: api.TransformOptions = .{ .write = true, .resolve = .disable };
    const out = try configureTransformOptionsForBunVM(std.testing.allocator, input);
    try std.testing.expectEqual(false, out.write);
    try std.testing.expectEqual(api.ResolveMode.lazy, out.resolve);
    try std.testing.expectEqual(api.Target.bun, out.target);
}

test "DefaultBunDefines Keys.window equals string 'window'" {
    try std.testing.expectEqualStrings("window", DefaultBunDefines.Keys.window);
    try std.testing.expectEqualStrings("undefined", DefaultBunDefines.Values.window);
}
