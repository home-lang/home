// Home Runtime — compile-time environment flags.
//
// Mirrors Bun's `Environment` namespace. Used by copied source for
// `comptime` branches that pick platform-specific behavior (e.g. the
// `open` cli helper picks `xdg-open` / `start` / `/usr/bin/open`
// based on `Environment.isWindows`, etc.).

const builtin = @import("builtin");

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
// Wave-19 unmined-corner port (2026-05-19). CPU-arch flags pulled in to
// satisfy `bun/src/perf/hw_timer.zig`'s `Environment.isAarch64` /
// `Environment.isX64` predicates. Mirrors upstream `Environment.isAarch64`.
pub const isAarch64 = builtin.cpu.arch == .aarch64;
pub const isX64 = builtin.cpu.arch == .x86_64;
pub const isAndroid = false; // Home does not currently target Android.
pub const enable_fuzzilli = false; // Fuzzilli REPRL — re-attaches in a future phase.
pub const isDebug = builtin.mode == .Debug;
pub const isRelease = !isDebug;
pub const allow_assert = isDebug;
pub const enable_logs = false;
pub const is_canary = false;
pub const ci_assert = false;

// Wave-20 Tier-2 substrate (2026-05-19). Mirrors upstream
// `bun.Environment.os`, an `Os` enum used by comptime branches in copied
// source (e.g. `sys/coreutils_error_map.zig`'s per-platform strerror
// table). Bun maps every Zig OS tag down to one of `linux | mac | windows
// | wasm | freebsd`; preserve that bucketing so verbatim copies compile
// without semantic edits.
pub const Os = enum { linux, mac, windows, wasm, freebsd };
pub const os: Os = if (isWindows)
    .windows
else if (isMac)
    .mac
else if (isWasm)
    .wasm
else if (isFreeBSD)
    .freebsd
else
    .linux;

test "environment flags are mutually consistent" {
    const std = @import("std");
    var count: usize = 0;
    if (isWindows) count += 1;
    if (isMac) count += 1;
    if (isLinux) count += 1;
    if (isWasi) count += 1;
    // At least one OS tag must match (unless we're on something exotic).
    try std.testing.expect(count <= 1);
    try std.testing.expect(isPosix != isWindows);
}
