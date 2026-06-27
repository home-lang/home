// Home Runtime — compile-time environment flags.
//
// Mirrors Bun's `Environment` namespace. Used by copied source for
// `comptime` branches that pick platform-specific behavior (e.g. the
// `open` cli helper picks `xdg-open` / `start` / `/usr/bin/open`
// based on `Environment.isWindows`, etc.).

const builtin = @import("builtin");
const std = @import("std");
const build_options = @import("build_options");

pub const isWindows = builtin.os.tag == .windows;
pub const isMac = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos => true,
    else => false,
};
pub const isLinux = builtin.os.tag == .linux;
pub const isFreeBSD = builtin.os.tag == .freebsd;
pub const isPosix = !isWindows;
pub const isWasi = builtin.os.tag == .wasi;
pub const isWasm = switch (builtin.cpu.arch) {
    .wasm32, .wasm64 => true,
    else => false,
};
pub const isNative = !isWasm;
pub const isBrowser = false;
// Wave-19 unmined-corner port (2026-05-19). CPU-arch flags pulled in to
// satisfy `bun/src/perf/hw_timer.zig`'s `Environment.isAarch64` /
// `Environment.isX64` predicates. Mirrors upstream `Environment.isAarch64`.
pub const isAarch64 = builtin.cpu.arch == .aarch64;
pub const isX64 = builtin.cpu.arch == .x86_64;
pub const isMusl = false;
pub const isAndroid = false; // Home does not currently target Android.
pub const enable_fuzzilli = false; // Fuzzilli REPRL — re-attaches in a future phase.
pub const isDebug = builtin.mode == .Debug;
pub const isRelease = !isDebug;
pub const allow_assert = isDebug;
pub const enable_asan = false;
/// Upstream `bun_core/env.zig:60` ties this to `build_options.enable_tinycc`.
/// On — `bun:ffi` cc()/dlopen(). Bun's release build compiles TinyCC
/// (vendor/tinycc/*.o, linked via native_vendor_roots in build.zig).
pub const enable_tinycc = true;
pub const dump_source = false;
pub const isKqueue = isMac or isFreeBSD;

pub inline fn onlyMac() void {
    if (comptime !isMac) unreachable;
}

pub inline fn onlyLinux() void {
    if (comptime !isLinux) unreachable;
}

pub inline fn onlyWindows() void {
    if (comptime !isWindows) unreachable;
}
/// Upstream `bun_core/env.zig:39` ties this to `isDebug or enable_asan`, but the
/// alloc-scope tracking is a debug-only *diagnostic* (it inlines a tracking
/// allocator that grows struct layouts, e.g. PackedMap 40→48). Home's gate
/// locks the non-tracking (release) layout via the existing `@sizeOf`
/// assertions, so this stays off here; it does not change ported behavior.
pub const enableAllocScopes = false;
pub const export_cpp_apis = if (build_options.override_no_export_cpp_apis) false else (builtin.output_mode == .Obj or builtin.is_test);
/// Upstream sets `git_sha = build_options.sha` (the build's git commit). Home
/// has no per-build SHA injected, and an EMPTY `git_sha` is not harmless: the
/// bun:test harness's `normalizeBunSnapshot` does `replaceAll(Bun.revision,
/// "<revision>")`, and `String.replaceAll("", x)` inserts `x` between every
/// character — corrupting EVERY snapshot that goes through it. Use a stable,
/// non-empty revision: the pinned Bun engine SHA Home is built against (the
/// objects linked from `$HOME_BUN_OBJ_ROOT`). Stable → no per-commit rebuild
/// churn; a valid 40-hex revision; never appears in test snapshot content.
/// Short/shorter mirror upstream's `sha[0..9]` / `sha[0..6]`.
pub const git_sha: [:0]const u8 = "fd0b6f1a271fca0b8124b69f230b100f4d636af6";
pub const git_sha_short: [:0]const u8 = "fd0b6f1a2";
pub const git_sha_shorter: [:0]const u8 = "fd0b6f";
pub const enable_logs = false;
pub const is_canary = false;
pub const ci_assert = false;
pub const enableSIMD = false;
pub const show_crash_trace = false;
/// Bun build flag used by generated-runtime call sites. Home's temporary
/// native parser probe reads source files from disk instead of embedding them.
pub const codegen_embed = false;

// Wave-20 Tier-2 substrate (2026-05-19). Mirrors upstream
// `bun.Environment.os`, an `Os` enum used by comptime branches in copied
// source (e.g. `sys/coreutils_error_map.zig`'s per-platform strerror
// table). Bun maps every Zig OS tag down to one of `linux | mac | windows
// | wasm | freebsd`; preserve that bucketing so verbatim copies compile
// without semantic edits.
pub const OperatingSystem = enum {
    linux,
    mac,
    windows,
    wasm,
    freebsd,

    pub const names = std.StaticStringMap(OperatingSystem).initComptime(.{
        .{ "linux", .linux },
        .{ "darwin", .mac },
        .{ "mac", .mac },
        .{ "windows", .windows },
        .{ "win32", .windows },
        .{ "wasm", .wasm },
        .{ "freebsd", .freebsd },
    });

    pub fn displayString(this: OperatingSystem) []const u8 {
        return switch (this) {
            .linux => "Linux",
            .mac => "macOS",
            .windows => "Windows",
            .wasm => "WASM",
            .freebsd => "FreeBSD",
        };
    }

    pub fn nameString(this: OperatingSystem) []const u8 {
        return switch (this) {
            .linux => "linux",
            .mac => "darwin",
            .windows => "win32",
            .wasm => "wasm",
            .freebsd => "freebsd",
        };
    }

    pub fn stdOSTag(this: OperatingSystem) std.Target.Os.Tag {
        return switch (this) {
            .linux => .linux,
            .mac => .macos,
            .windows => .windows,
            .freebsd => .freebsd,
            .wasm => unreachable,
        };
    }

    pub fn npmName(this: OperatingSystem) []const u8 {
        return switch (this) {
            .linux => "linux",
            .mac => "darwin",
            .windows => "windows",
            .wasm => "wasm",
            .freebsd => "freebsd",
        };
    }
};
pub const Os = OperatingSystem;
pub const os: OperatingSystem = if (isWindows)
    .windows
else if (isMac)
    .mac
else if (isWasm)
    .wasm
else if (isFreeBSD)
    .freebsd
else
    .linux;

pub const Architecture = enum {
    x64,
    arm64,
    wasm,

    pub const names = std.StaticStringMap(Architecture).initComptime(.{
        .{ "x64", .x64 },
        .{ "arm64", .arm64 },
        .{ "wasm", .wasm },
    });

    pub fn npmName(this: Architecture) []const u8 {
        return switch (this) {
            .x64 => "x64",
            .arm64 => "aarch64",
            .wasm => "wasm",
        };
    }
};
pub const arch: Architecture = if (isWasm)
    .wasm
else if (isX64)
    .x64
else if (isAarch64)
    .arm64
else
    @compileError("Please add your architecture to Environment.Architecture");

// Home emulates Bun's engine pinned at git_sha fd0b6f1a27 (= Bun 1.3.14). Report
// that version so `Bun.version`/`process.versions.bun`/the `bun test` header and
// version-gated tests match the pin; "0.0.0" made literal `v1.` checks fail and
// version-gated `it.if` blocks behave differently than upstream.
pub const version: std.SemanticVersion = .{
    .major = 1,
    .minor = 3,
    .patch = 14,
};
pub const version_string = "1.3.14";
pub const reported_nodejs_version = "20.0.0";

test "environment flags are mutually consistent" {
    var count: usize = 0;
    if (isWindows) count += 1;
    if (isMac) count += 1;
    if (isLinux) count += 1;
    if (isWasi) count += 1;
    // At least one OS tag must match (unless we're on something exotic).
    try std.testing.expect(count <= 1);
    try std.testing.expect(isPosix != isWindows);
}
