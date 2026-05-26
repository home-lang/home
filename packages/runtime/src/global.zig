// Home Runtime — process-level globals.
//
// Mirrors the small subset of Bun's `Global` namespace that the copied
// cli leaves need: `exit` for fatal error paths, `crash` for panics
// (no-op in tests).

const std = @import("std");

pub fn exit(code: u8) noreturn {
    std.process.exit(code);
}

pub fn crash() noreturn {
    @panic("home_rt: crash() called");
}

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
