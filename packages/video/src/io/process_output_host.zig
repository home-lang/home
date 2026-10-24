//! Standalone POSIX output supervisor. fd 0 is media, 1/2 are consumer output,
//! fd 3 is a private parent control socket. Never fork from a hosted camera
//! thread: compile this as its own executable. CLI: grace-ms -- command argv...
const std = @import("std");
const builtin = @import("builtin");
const wire = @import("../core/process_output_wire.zig");
const c = @cImport({
    @cInclude("sys/types.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/socket.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("signal.h");
    @cInclude("errno.h");
    if (builtin.os.tag == .linux) @cInclude("sys/prctl.h");
});
var interrupted = std.atomic.Value(bool).init(false);
fn interrupt(_: c_int) callconv(.c) void {
    interrupted.store(true, .monotonic);
}
fn installSignals() void {
    const action = std.posix.Sigaction{ .handler = .{ .handler = interrupt }, .mask = std.posix.sigemptyset(), .flags = 0 };
    for ([_]u8{ std.posix.SIG.TERM, std.posix.SIG.INT, std.posix.SIG.HUP, std.posix.SIG.USR1 }) |sig| std.posix.sigaction(sig, &action, null);
    const ignore = std.posix.Sigaction{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(std.posix.SIG.PIPE, &ignore, null);
    const default = std.posix.Sigaction{ .handler = .{ .handler = std.posix.SIG.DFL }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(std.posix.SIG.CHLD, &default, null);
}
fn notify(message: wire.Message) bool {
    const bytes = wire.encode(message) catch return false;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = std.posix.write(3, bytes[offset..]) catch return false;
        if (n == 0) return false;
        offset += n;
    }
    return true;
}
fn errnoValue(rc: anytype) u32 {
    return @intFromEnum(std.posix.errno(rc));
}
fn signalGroup(pid: std.posix.pid_t, signal: u8) void {
    std.posix.kill(-pid, signal) catch {};
}
fn childExited(pid: std.posix.pid_t) bool {
    var info = std.mem.zeroes(c.siginfo_t);
    const rc = c.waitid(c.P_PID, @intCast(pid), &info, c.WEXITED | c.WNOHANG | c.WNOWAIT);
    return rc == 0 and info.si_signo != 0;
}
fn statusCode(status: u32) u8 {
    return if (status & 127 == 0) @truncate(status >> 8) else @intCast(@as(u32, 128) + (status & 127));
}
fn childFailure(fd: std.posix.fd_t, code: u32) noreturn {
    _ = c.write(fd, &code, @sizeOf(u32));
    c._exit(127);
}
fn run(args: []const [:0]u8) !u8 {
    if (args.len < 4 or args.len > 68 or !std.mem.eql(u8, args[2], "--")) return error.InvalidArguments;
    const grace = try std.fmt.parseInt(u32, args[1], 10);
    if (grace == 0 or grace > 60000) return error.InvalidArguments;
    var arg_bytes: usize = 0;
    for (args[3..]) |arg| arg_bytes = try std.math.add(usize, arg_bytes, arg.len + 1);
    if (arg_bytes > 64 * 1024) return error.InvalidArguments;
    installSignals();
    var timer = try std.time.Timer.start();
    const flags = c.fcntl(3, c.F_GETFL);
    if (flags < 0 or c.fcntl(3, c.F_SETFL, flags | c.O_NONBLOCK) < 0) return error.InvalidControl;
    var socket_type: c_int = 0;
    var socket_type_size: c.socklen_t = @sizeOf(c_int);
    if (c.getsockopt(3, c.SOL_SOCKET, c.SO_TYPE, &socket_type, &socket_type_size) != 0 or socket_type != c.SOCK_STREAM) return error.InvalidControl;
    if (builtin.os.tag == .linux) {
        if (c.prctl(c.PR_SET_CHILD_SUBREAPER, @as(c_ulong, 1), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) != 0) return error.SubreaperFailed;
    }
    var argv: [65:null]?[*:0]const u8 = @splat(null);
    for (args[3..], 0..) |arg, i| argv[i] = arg.ptr;
    const supervisor: u32 = @intCast(c.getpid());
    var preflight = [_]std.posix.pollfd{.{ .fd = 3, .events = std.posix.POLL.IN, .revents = 0 }};
    _ = std.posix.poll(&preflight, 0) catch 0;
    var cancelled_before_spawn = interrupted.load(.monotonic);
    if (preflight[0].revents != 0) {
        var command: [16]u8 = undefined;
        if (std.posix.read(3, &command)) |_| {
            cancelled_before_spawn = true;
        } else |err| {
            if (err != error.WouldBlock) cancelled_before_spawn = true;
        }
    }
    if (cancelled_before_spawn) {
        _ = notify(.{ .kind = .problem, .status = c.ECANCELED, .supervisor = supervisor, .consumer = 0 });
        return 125;
    }
    const pipes = try std.posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
    var exec_fd: ?std.posix.fd_t = pipes[0];
    defer if (exec_fd) |fd| std.posix.close(fd);
    const child = std.posix.fork() catch |err| {
        std.posix.close(pipes[1]);
        return err;
    };
    if (child == 0) {
        std.posix.close(pipes[0]);
        std.posix.close(3);
        // Only async-signal-safe libc calls occur between fork and exec.
        const default = std.posix.Sigaction{ .handler = .{ .handler = std.posix.SIG.DFL }, .mask = std.posix.sigemptyset(), .flags = 0 };
        for ([_]u8{ std.posix.SIG.TERM, std.posix.SIG.INT, std.posix.SIG.HUP, std.posix.SIG.USR1, std.posix.SIG.PIPE }) |sig| std.posix.sigaction(sig, &default, null);
        if (c.setpgid(0, 0) != 0) childFailure(pipes[1], errnoValue(@as(c_int, -1)));
        if (builtin.os.tag == .linux) {
            if (c.prctl(c.PR_SET_PDEATHSIG, @as(c_ulong, c.SIGKILL), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) != 0) childFailure(pipes[1], errnoValue(@as(c_int, -1)));
            if (c.getppid() != supervisor) childFailure(pipes[1], c.ECHILD);
        }
        _ = c.execvp(argv[0].?, @ptrCast(&argv));
        childFailure(pipes[1], errnoValue(@as(c_int, -1)));
    }
    std.posix.close(pipes[1]);
    std.posix.close(0); // Consumer alone owns the inherited media read end.
    std.posix.setpgid(child, child) catch {}; // Child also sets it before exec.
    var cancelling = false;
    var killed = false;
    var kill_at: u64 = 0;
    var ready = false;
    var exec_status: [4]u8 = undefined;
    var exec_bytes: usize = 0;
    var control_read_open = true;
    while (true) {
        var fds = [_]std.posix.pollfd{
            .{ .fd = if (control_read_open) 3 else -1, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = exec_fd orelse -1, .events = std.posix.POLL.IN, .revents = 0 },
        };
        _ = std.posix.poll(&fds, 10) catch 0;
        if (fds[0].revents != 0) {
            var command: [16]u8 = undefined;
            if (std.posix.read(3, &command)) |count| {
                // Any explicit command or EOF cancels. This fd is never
                // media, so a stalled consumer cannot hide a dead parent.
                interrupted.store(true, .monotonic);
                // EOF stays readable forever. Stop polling that half while
                // keeping the write half for a final result after group join.
                if (count == 0) control_read_open = false;
            } else |err| {
                if (err != error.WouldBlock) {
                    interrupted.store(true, .monotonic);
                    control_read_open = false;
                }
            }
        }
        if (exec_fd) |fd| {
            if (fds[1].revents != 0) exec_read: {
                const count = std.posix.read(fd, exec_status[exec_bytes..]) catch |err| {
                    if (err != error.WouldBlock) {
                        interrupted.store(true, .monotonic);
                        std.posix.close(fd);
                        exec_fd = null;
                    }
                    break :exec_read;
                };
                exec_bytes += count;
                if (exec_bytes == 4) {
                    const code = std.mem.readInt(u32, &exec_status, if (builtin.cpu.arch.endian() == .little) .little else .big);
                    _ = notify(.{ .kind = .problem, .status = @min(@max(code, 1), 65535), .supervisor = supervisor, .consumer = @intCast(child) });
                    interrupted.store(true, .monotonic);
                    std.posix.close(fd);
                    exec_fd = null;
                } else if (count == 0) {
                    std.posix.close(fd);
                    exec_fd = null;
                    if (exec_bytes != 0 or childExited(child)) {
                        _ = notify(.{ .kind = .problem, .status = c.ECHILD, .supervisor = supervisor, .consumer = @intCast(child) });
                        interrupted.store(true, .monotonic);
                    } else ready = notify(.{ .kind = .ready, .supervisor = supervisor, .consumer = @intCast(child) });
                    if (!ready) interrupted.store(true, .monotonic);
                }
            }
        }
        if (interrupted.load(.monotonic) and !cancelling) {
            cancelling = true;
            signalGroup(child, std.posix.SIG.TERM);
            kill_at = timer.read() +| (@as(u64, grace) * std.time.ns_per_ms);
        }
        if (cancelling and !killed and timer.read() >= kill_at) {
            killed = true;
            signalGroup(child, std.posix.SIG.KILL);
        }
        if (childExited(child)) break;
    }
    // The leader remains an unreaped zombie until after the last group signal,
    // keeping its PID/PGID reserved and preventing a late kill of a reused ID.
    signalGroup(child, std.posix.SIG.KILL);
    const result = std.posix.waitpid(child, 0);
    if (builtin.os.tag == .linux) {
        // Adopted group descendants must be reaped as well. Do not use a
        // signal-sent flag as exit proof or signal any group after leader reap.
        var status: c_int = 0;
        while (true) {
            const pid = c.waitpid(-child, &status, 0);
            if (pid > 0) continue;
            if (pid < 0 and errnoValue(pid) == c.EINTR) continue;
            if (pid < 0 and errnoValue(pid) == c.ECHILD) break;
            _ = std.posix.poll(&.{}, 10) catch 0;
        }
    }
    const code = statusCode(result.status);
    _ = notify(.{ .kind = .result, .status = code, .supervisor = supervisor, .consumer = @intCast(child) });
    return if (cancelling) 125 else if (ready) code else 127;
}
pub fn main() void {
    const args = std.process.argsAlloc(std.heap.c_allocator) catch {
        _ = notify(.{ .kind = .problem, .status = c.ENOMEM, .supervisor = @intCast(c.getpid()), .consumer = 0 });
        std.process.exit(125);
    };
    defer std.process.argsFree(std.heap.c_allocator, args);
    // Every fallible return from run is before a successful fork. After that
    // point it always joins the owned child/group before returning a result.
    const result = run(args) catch |err| {
        _ = notify(.{ .kind = .problem, .status = if (err == error.InvalidArguments) c.EINVAL else c.EIO, .supervisor = @intCast(c.getpid()), .consumer = 0 });
        std.debug.print("process output host setup failed: {s}\n", .{@errorName(err)});
        std.process.exit(125);
    };
    std.process.exit(result);
}
