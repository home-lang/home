// Copied from bun/src/bun_core/feature_flags.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6.
//
// Imports rewritten: @import("bun") → @import("home"); local
// `./env.zig` references replaced by `home_rt.Environment`.
//
// Deviations from upstream:
//   * `isLibdeflateEnabled()` and `bake()` upstream consult
//     `bun.feature_flag.BUN_FEATURE_FLAG_*.get()` — the typed env-var
//     surface is not yet ported here. Until env_var.zig is brought across
//     in full, these fns return their static fallback (no env-var probe).
//   * Removed `env.is_canary` / `env.enable_asan` / `env.isBrowser` /
//     `env.isWasi` / `env.isWasm` references (those constants live in
//     bun's `env.zig` which we have not duplicated wholesale). Adapted
//     using `home_rt.Environment` instead.
//
//! If you are adding feature-flags to this file, you are in the wrong spot. Go to env_var.zig
//! instead.

const home_rt = @import("home");
const std = @import("std");
const build_options = @import("build_options");
const env = home_rt.Environment;

/// Enable breaking changes for the next major release of Bun
// TODO: Make this a CLI flag / runtime var so that we can verify disabled code paths can compile
pub const breaking_changes_1_4 = false;

/// Store and reuse file descriptors during module resolution
/// This was a ~5% performance improvement
pub const store_file_descriptors = true; // Home does not target a browser build today.

pub const tracing = true;

pub const css_supports_fence = true;

pub const enable_entry_cache = true;

// TODO: remove this flag, it should use home_rt.Output.scoped
pub const verbose_fs = false;

pub const watch_directories = true;

// This feature flag exists so when you have defines inside package.json, you can use single quotes in nested strings.
pub const allow_json_single_quotes = true;

// Faithful default is `!env.isWasi` (true on native targets). The
// `enable_macros` build option (default true) additionally lets the
// transpile path comptime-eliminate the macro -> resolver -> package
// manager -> network -> event-loop -> bake cone via `-Denable_macros=false`.
pub const is_macro_enabled = build_options.enable_macros and !env.isWasi;

pub const disable_compression_in_http_client = false;

pub const enable_keepalive = true;

pub const atomic_file_watcher = env.isLinux;

pub const http_buffer_pooling = true;

pub const disable_lolhtml = false;

/// There is, what I think is, a bug in getaddrinfo()
/// on macOS that specifically impacts localhost and not
/// other ipv4 hosts. This is a workaround for that.
/// "localhost" fails to connect.
pub const hardcode_localhost_to_127_0_0_1 = false;

/// React will issue warnings in development if there are multiple children
/// without keys and "jsxs" is not used.
/// https://github.com/oven-sh/bun/issues/10733
pub const support_jsxs_in_jsx_transform = true;

// Native targets get SIMD; Home does not currently support a wasm build.
pub const use_simdutf = !env.isWasi;

pub const inline_properties_in_transpiler = true;

pub const same_target_becomes_destructuring = true;

// Home does not (yet) compile with ASAN; tie this to debug builds only.
pub const help_catch_memory_issues = env.isDebug;

/// This performs similar transforms as https://github.com/rollup/plugins/tree/master/packages/commonjs
///
/// Though, not exactly the same.
///
/// There are two scenarios where this kicks in:
///
/// 1) You import a CommonJS module using ESM.
///
/// Semantically, CommonJS expects us to wrap everything in a closure. That
/// bloats the code. We want to make the generated code as small as we can.
///
/// To avoid that, we attempt to unwrap the CommonJS module into ESM.
///
/// But, we can't always do that. When you have cyclical require() or directly
/// mutate exported bindings, we can't unwrap it.
///
/// However, in the simple case, where you do something like
///
///     exports.foo = 123;
///     exports.bar = 456;
///
/// We can unwrap it into
///
///    export const foo = 123;
///    export const bar = 456;
///
/// 2) You import a CommonJS module using CommonJS.
///
/// This is a bit more complicated. We want to avoid the closure wrapper, but
/// it's really difficult to track down all the places where you mutate the
/// exports object. `require.cache` makes it even more complicated.
/// So, we just wrap the entire module in a closure.
///
/// But what if we previously unwrapped it?
///
/// In that case, we wrap it again in the printer.
pub const unwrap_commonjs_to_esm = true;

/// https://sentry.engineering/blog/the-case-for-debug-ids
/// https://github.com/mitsuhiko/source-map-rfc/blob/proposals/debug-id/proposals/debug-id.md
/// https://github.com/source-map/source-map-rfc/pull/20
pub const source_map_debug_id = true;

pub const export_star_redirect = false;

pub const streaming_file_uploads_for_http_client = true;

pub const concurrent_transpiler = true;

// https://github.com/oven-sh/bun/issues/5426#issuecomment-1813865316
pub const disable_auto_js_to_ts_in_node_modules = true;

pub const runtime_transpiler_cache = true;

/// On Windows, node_modules/.bin uses pairs of '.exe' + '.bunx' files.  The
/// fast path is to load the .bunx file within `bun.exe` instead of
/// `bun_shim_impl.exe` by using `bun_shim_impl.tryStartupFromBunJS`
///
/// When debugging weird script runner issues, it may be worth disabling this in
/// order to isolate your bug.
pub const windows_bunx_fast_path = true;

// TODO: fix Windows-only test failures in fetch-preconnect.test.ts
pub const is_fetch_preconnect_supported = env.isPosix;

pub const libdeflate_supported = !env.isWasi;

// Mostly exists as a way to turn it off later, if necessary.
pub fn isLibdeflateEnabled() bool {
    // Upstream additionally checks the BUN_FEATURE_FLAG_NO_LIBDEFLATE env
    // var. Until env_var.zig lands, we honour just the compile-time flag.
    return libdeflate_supported;
}

/// Enable the "app" option in Bun.serve. This option will likely be removed
/// in favor of HTML loaders and configuring framework options in bunfig.toml
pub fn bake() bool {
    // Upstream additionally consults `env.is_canary` and
    // `BUN_FEATURE_FLAG_EXPERIMENTAL_BAKE`. For now: debug builds only.
    return env.isDebug;
}

/// Additional debugging features for bake.DevServer, such as the incremental visualizer.
/// To use them, extra flags are passed in addition to this one.
pub const bake_debugging_features = env.isDebug;

test "feature_flags: compile-time invariants" {
    try std.testing.expect(!breaking_changes_1_4);
    try std.testing.expect(tracing);
    try std.testing.expect(use_simdutf == !env.isWasi);
    try std.testing.expect(atomic_file_watcher == env.isLinux);
    try std.testing.expect(is_fetch_preconnect_supported == env.isPosix);
}

test "feature_flags: isLibdeflateEnabled mirrors libdeflate_supported" {
    try std.testing.expectEqual(libdeflate_supported, isLibdeflateEnabled());
}

test "feature_flags: bake follows debug mode" {
    try std.testing.expectEqual(env.isDebug, bake());
    try std.testing.expectEqual(env.isDebug, bake_debugging_features);
}
