// Platform dispatcher for the `errno` table — re-exports the right per-OS
// `SystemErrno` / `E` / `UV_E` / `getErrno` so downstream files can name
// `home_rt.errno.SystemErrno` without caring which platform they're on.
//
// Mirrors upstream `bun/src/sys/sys.zig`'s `platform_defs` switch
// (SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6) but lives in
// `errno/errno.zig` instead of `sys/sys.zig` because the full sys substrate
// (syscall wrappers, FD/PathBuffer/Maybe, JSC bridge) is not yet ported.
// Windows is not yet implemented because `bun/src/errno/windows_errno.zig`
// pulls in `bun.windows.{NTSTATUS, translateNTStatusToErrno, WSAGetLastError,
// Win32Error, libuv}`.

const std = @import("std");
const builtin = @import("builtin");

const platform_defs = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos => @import("darwin_errno.zig"),
    .linux => @import("linux_errno.zig"),
    .freebsd => @import("freebsd_errno.zig"),
    .windows => @compileError("windows_errno.zig not ported yet — pull in bun.windows substrate first"),
    else => @compileError("errno table not implemented for this OS yet"),
};

/// Enum of `errno` values for the current platform.
pub const SystemErrno = platform_defs.SystemErrno;
/// `std.posix.E` mirror (`platform_defs.E == std.posix.E` on all three POSIX
/// targets, but this preserves Bun's indirection point so a future Windows
/// port can swap in a non-`std.posix.E` table).
pub const E = platform_defs.E;
pub const S = platform_defs.S;
pub const Mode = platform_defs.Mode;
/// libuv-style positive `UV_E*` integer constants (negative `UV_E*` codes
/// are libuv-internal; `UV_E` here stores `-UV__E*` so consumers don't have
/// to negate again).
pub const UV_E = platform_defs.UV_E;
/// Translate a raw syscall return code (rc) into an `E` errno value.
pub const getErrno = platform_defs.getErrno;

test "errno dispatcher exposes a non-empty SystemErrno table for this OS" {
    // ENOENT must always be 2 (POSIX universal), regardless of which
    // platform_defs file we resolved.
    try std.testing.expectEqual(@as(c_int, 2), @intFromEnum(SystemErrno.ENOENT));
    try std.testing.expect(SystemErrno.max > 2);
}

test "errno.getErrno reports SUCCESS for nonzero rc" {
    try std.testing.expectEqual(E.SUCCESS, getErrno(@as(c_int, 0)));
    try std.testing.expectEqual(E.SUCCESS, getErrno(@as(c_int, 42)));
}

test "errno.UV_E.NOENT round-trips through SystemErrno" {
    try std.testing.expectEqual(@as(i32, 2), UV_E.NOENT);
}
