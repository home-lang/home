// Copied from bun/src/jsc/resolver_jsc.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
//! Host fns / C++ exports for `node:module` `_nodeModulePaths`. Extracted
//! from `resolver/resolver.zig` so `resolver/` has no JSC references.
//
// Upstream wires up three symbols:
//   * `nodeModulePathsForJS` — host fn taking a path string and returning
//     an array of resolved `node_modules` paths.
//   * `Resolver__propForRequireMainPaths` — equivalent for `require.main`.
//   * `nodeModulePathsJSValue` — the core helper both call into.
//
// The body needs `bun.jsc.JSGlobalObject`, `bun.jsc.JSValue`, `bun.jsc.CallFrame`,
// `bun.String.toJSArray`, `bun.path_buffer_pool`, `bun.fs.FileSystem.instance`,
// `bun.path.joinAbsStringBuf`, and the `markBinding`/`@export` codegen
// glue. None of that has landed yet, so the implementations are parked.
// We expose extern declarations of the C++-visible symbols so callers can
// spell them; the Zig-side host fn wrapper re-attaches in Phase 12.2.

const std = @import("std");

// JSC bridge stubs — re-attach in Phase 12.2.
const JSGlobalObject = @import("./JSGlobalObject.zig").JSGlobalObject;
const JSValue = enum(i64) { zero = 0, _ };
const String = extern struct {
    tag: u8 = 0,
    _padding: [7]u8 = @splat(0),
    impl: ?*anyopaque = null,
};

// C++-visible export: returns a JS array of resolved `node_modules`
// search paths for `require.main`.
pub extern fn Resolver__propForRequireMainPaths(globalThis: *JSGlobalObject) callconv(.c) JSValue;

// C++-visible export: the core helper. Takes the input string + global +
// whether to take dirname of the input. Both `nodeModulePathsForJS` and
// `Resolver__propForRequireMainPaths` route through this in the real impl.
pub extern fn Resolver__nodeModulePathsJSValue(
    in_str: String,
    globalObject: *JSGlobalObject,
    use_dirname: bool,
) callconv(.c) JSValue;

// C++-visible export: host fn shape (takes a *CallFrame, returns a
// JSValue, may throw). The Zig wrapper around this re-attaches with
// `jsc.toJSHostFn` in Phase 12.2.
const CallFrame = opaque {};
pub extern fn Resolver__nodeModulePathsForJS(
    globalThis: *JSGlobalObject,
    callframe: *CallFrame,
) callconv(.c) JSValue;

test "resolver_jsc: extern signatures match upstream shape" {
    try std.testing.expectEqual(
        @TypeOf(Resolver__propForRequireMainPaths),
        fn (*JSGlobalObject) callconv(.c) JSValue,
    );
    try std.testing.expectEqual(
        @TypeOf(Resolver__nodeModulePathsJSValue),
        fn (String, *JSGlobalObject, bool) callconv(.c) JSValue,
    );
    try std.testing.expectEqual(
        @TypeOf(Resolver__nodeModulePathsForJS),
        fn (*JSGlobalObject, *CallFrame) callconv(.c) JSValue,
    );
}
