//! Controlled protocol peer: join a real failed child, send the problem record,
//! wait for a late cancel WITHOUT consuming it, then send final exit proof.
//! Closing the cancellation socket with unread data must not damage proofs.
const std = @import("std");
const wire = @import("wire");
const c = @cImport({
    @cInclude("unistd.h");
});
fn send(message: wire.Message) !void {
    const bytes = try wire.encode(message);
    var at: usize = 0;
    while (at < bytes.len) at += try std.posix.write(3, bytes[at..]);
}
pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.c_allocator);
    defer std.process.argsFree(std.heap.c_allocator, args);
    const separate = args.len > 2 and std.mem.eql(u8, args[2], "--control-fd4");
    const control_fd: std.posix.fd_t = if (separate) 4 else 3;
    const child = try std.posix.fork();
    if (child == 0) c._exit(127);
    const result = std.posix.waitpid(child, 0);
    if (result.status != 127 << 8) return error.UnexpectedChildExit;
    const supervisor: u32 = @intCast(c.getpid());
    try send(.{ .kind = .problem, .status = 2, .supervisor = supervisor, .consumer = @intCast(child) });
    var fds = [_]std.posix.pollfd{.{ .fd = control_fd, .events = std.posix.POLL.IN, .revents = 0 }};
    if (try std.posix.poll(&fds, 2000) == 0 or fds[0].revents & std.posix.POLL.IN == 0) return error.ExpectedLateCancellation;
    // Intentionally leave that byte unread. There are no live child owners.
    try send(.{ .kind = .result, .status = 127, .supervisor = supervisor, .consumer = @intCast(child) });
    std.process.exit(125);
}
