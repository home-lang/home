//! Independent exec'd consumer: require exclusive process-group ownership,
//! then echo bounded input through real EOF. No camera or codec dependency.
const std = @import("std");
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
});
fn write(bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = std.posix.write(1, bytes[offset..]) catch |err| {
            if (err != error.WouldBlock) return err;
            var fds = [_]std.posix.pollfd{.{ .fd = 1, .events = std.posix.POLL.OUT, .revents = 0 }};
            _ = try std.posix.poll(&fds, -1);
            continue;
        };
        if (count == 0) return error.Closed;
        offset += count;
    }
}
pub fn main() !void {
    if (c.getpgrp() != c.getpid()) return error.UnownedGroup;
    if (c.fcntl(3, c.F_GETFD) >= 0 or c.fcntl(4, c.F_GETFD) >= 0) return error.PrivateDescriptorLeak;
    try write("owned-group\n");
    var bytes: [4096]u8 = undefined;
    while (true) {
        const count = std.posix.read(0, &bytes) catch |err| {
            if (err != error.WouldBlock) return err;
            var fds = [_]std.posix.pollfd{.{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }};
            _ = try std.posix.poll(&fds, -1);
            continue;
        };
        if (count == 0) return;
        try write(bytes[0..count]);
    }
}
