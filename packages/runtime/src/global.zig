// Home Runtime — process-level globals.
//
// Mirrors the small subset of Bun's `Global` namespace that the copied
// cli leaves need: `exit` for fatal error paths, `crash` for panics
// (no-op in tests).

const std = @import("std");

// Report the emulated pin version (Bun 1.3.14 @ git_sha fd0b6f1a27) rather than
// a "0.0.0" stub. Use the CLEAN release string (no "-debug" suffix that
// bun_core/Global.zig adds for Zig debug builds): Home is debug-built but
// emulates the RELEASE pin, and `isDebug = Bun.version.includes("debug")` in
// Bun's harness must stay false so version-gated tests match the pin.
pub const package_json_version = @import("environment.zig").version_string;
pub const package_json_version_with_sha = @import("environment.zig").version_string ++ " (" ++ @import("environment.zig").git_sha_short ++ ")";
pub const package_json_version_with_revision = @import("environment.zig").version_string ++ "+" ++ @import("environment.zig").git_sha_short;

/// The `Bun v<version> (<os> <arch>)` footer printed to stderr after a run that
/// left an unhandled error (mirrors Bun's `bun_core/Global.zig`). The native VM
/// runner in `src/main.zig` emits this; tests strip it (the last two output
/// lines), so the exact version is irrelevant — only that the line is present.
pub const unhandled_error_bun_version_string = @import("bun_core/Global.zig").unhandled_error_bun_version_string;

/// `Bun.Global.BunInfo` — used by the server's `/bun:info` route generator.
/// Full version embeds analytics platform info (not ported); Home returns a
/// minimal object so the route compiles. The endpoint isn't exercised by basic
/// Bun.serve({fetch}).
pub const BunInfo = struct {
    pub fn generate(comptime Bundler: type, _: Bundler, allocator: std.mem.Allocator) !@import("home").ast.Expr {
        _ = allocator;
        const home = @import("home");
        return home.ast.Expr.init(home.ast.E.Object, .{}, home.logger.Loc.Empty);
    }
};
// Pin-faithful UA ("Bun/<version>", bun_core/Global.zig): the wire
// User-Agent must equal navigator.userAgent ("Bun/" + version) — Bun's
// fetch tests assert the equality, and the "Home/0.0.0" rebrand broke
// every body-stream clone test at the first header assertion.
pub const user_agent = @import("bun_core/Global.zig").user_agent;
pub const os_name = @import("bun_core/Global.zig").os_name;
pub const arch_name = @import("bun_core/Global.zig").arch_name;

pub const ExitFn = *const fn () callconv(.c) void;
var exit_callbacks: std.ArrayListUnmanaged(ExitFn) = .empty;

pub fn addExitCallback(function: ExitFn) void {
    if (std.mem.indexOfScalar(ExitFn, exit_callbacks.items, function) == null) {
        exit_callbacks.append(std.heap.smp_allocator, function) catch {};
    }
}

pub fn runExitCallbacks() void {
    for (exit_callbacks.items) |callback| callback();
    exit_callbacks.items.len = 0;
}

pub fn exit(code: u8) noreturn {
    runExitCallbacks();
    std.process.exit(code);
}

pub fn crash() noreturn {
    @panic("home_rt: crash() called");
}

pub fn raiseIgnoringPanicHandler(signal: anytype) noreturn {
    std.process.exit(signal.toExitCode() orelse 1);
}

/// Mirrors Bun's `Global.mimalloc_cleanup` (upstream `bun_core/Global.rs`
/// line 778), which calls `mi_collect(force)` only when mimalloc is the
/// active allocator. Home links the libc-backed mimalloc shim, which has no
/// heap to collect, so this is a faithful no-op until the vendored
/// allocator re-attaches.
pub fn mimalloc_cleanup(force: bool) void {
    _ = force;
}

pub fn setThreadName(_: []const u8) void {}

/// Mirrors Bun's `bun.OOM` — an alias for `error{OutOfMemory}`. Many
/// copied files spell their fallible return type as `bun.OOM!T`.
pub const OOM = error{OutOfMemory};

/// Mirrors Bun's `bun.assert`. In Debug builds it routes to
/// `std.debug.assert`; in release builds it's a no-op so hot paths
/// don't pay for invariant checks. Use sparingly — invariants that
/// must hold in production should `Global.crash()` instead.
pub fn assert(ok: bool) void {
    if (@import("builtin").mode == .Debug) {
        std.debug.assert(ok);
    }
}

/// Mirrors Bun's `bun.handleOom`. Treats an allocation failure as
/// fatal — most copied paths can't recover from OOM. Returns the
/// success value unchanged so call sites read as
/// `const ptr = home_rt.handleOom(allocator.create(T));`.
fn HandleOomReturn(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .error_union => |info| info.payload,
        .error_set => noreturn,
        else => T,
    };
}

pub fn handleOom(result: anytype) HandleOomReturn(@TypeOf(result)) {
    return switch (@typeInfo(@TypeOf(result))) {
        .error_union => result catch {
            @panic("home_rt: out of memory");
        },
        .error_set => @panic("home_rt: out of memory"),
        else => result,
    };
}

test "exit and crash exist" {
    _ = exit;
    _ = crash;
}

test "OOM is the standard out-of-memory error" {
    const fail: OOM!u32 = error.OutOfMemory;
    try std.testing.expectError(error.OutOfMemory, fail);
}

test "assert no-ops on true" {
    assert(true);
    assert(1 + 1 == 2);
}

test "handleOom passes through success" {
    const allocator = std.testing.allocator;
    const ptr = handleOom(allocator.create(u32));
    defer allocator.destroy(ptr);
    ptr.* = 42;
    try std.testing.expectEqual(@as(u32, 42), ptr.*);
}
