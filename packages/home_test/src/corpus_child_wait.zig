//! Observe child exit without reaping it, so the caller retains ownership for
//! timeout termination and the final std.process.Child.wait resource cleanup.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
// waitid's libc ABI is not declared by the current Zig std.c module.
// P_PID = 1 on Darwin/Linux; Darwin's sys/wait.h supplies the flags below.
extern "c" fn waitid(kind: c_uint, id: c_uint, info: *std.c.siginfo_t, options: c_int) c_int;

pub fn waitForExitBefore(io: Io, child: *const std.process.Child, deadline: Io.Clock.Timestamp) !bool {
    while (true) {
        if (try hasExited(child)) return true;
        const remaining = deadline.durationFromNow(io).raw.nanoseconds;
        if (remaining <= 0) return false;
        // The absolute deadline is never restarted. WNOWAIT leaves even an
        // exited child owned and unreaped, preventing PID reuse before a signal.
        try Io.sleep(io, .fromNanoseconds(@min(remaining, 10 * std.time.ns_per_ms)), deadline.clock);
    }
}

fn hasExited(child: *const std.process.Child) !bool {
    const id = child.id orelse return error.ChildAlreadyReaped;
    if (comptime builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const immediate: windows.LARGE_INTEGER = 0;
        return switch (windows.ntdll.NtWaitForSingleObject(id, .FALSE, &immediate)) {
            .WAIT_0 => true,
            .TIMEOUT => false,
            else => |status| windows.unexpectedStatus(status),
        };
    } else {
        const flags: c_int = switch (builtin.os.tag) {
            .macos => 0x00000004 | 0x00000001 | 0x00000020,
            .linux => std.c.W.EXITED | std.c.W.NOHANG | std.c.W.NOWAIT,
            else => return error.UnsupportedPlatform,
        };
        var info: std.c.siginfo_t = undefined;
        @memset(std.mem.asBytes(&info), 0);
        const result = waitid(1, @intCast(id), &info, flags);
        return switch (std.posix.errno(result)) {
            .SUCCESS => @backingInt(info.signo) != 0,
            .INTR => false,
            else => |err| std.posix.unexpectedErrno(err),
        };
    }
}

test "child exit observation keeps exit status available for the owning waiter" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{ .argv = &.{ "/bin/sh", "-c", "exit 19" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    defer child.kill(io);
    const deadline = Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromSeconds(3), .clock = .awake });
    try std.testing.expect(try waitForExitBefore(io, &child, deadline));
    try std.testing.expect(child.id != null);
    try std.testing.expect(try waitForExitBefore(io, &child, deadline));
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 19 }, try child.wait(io));
}

test "child deadline observes a live child without reaping or extending the deadline" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{ .argv = &.{ "/bin/sleep", "30" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    defer child.kill(io);
    const deadline = Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromMilliseconds(30), .clock = .awake });
    try std.testing.expect(!try waitForExitBefore(io, &child, deadline));
    try std.testing.expect(child.id != null);
    try std.testing.expect(!try waitForExitBefore(io, &child, deadline));
}
