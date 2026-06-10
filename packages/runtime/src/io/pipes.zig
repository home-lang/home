// Copied (partial) from bun/src/io/pipes.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Subprocess-pipe primitives. Upstream defines three exports:
//   1. `PollOrFd` — union over `Async.FilePoll` / `bun.FD` / `closed`.
//   2. `FileType` — enum (file / pipe / nonblocking_pipe / socket).
//   3. `ReadState` — enum (progress / eof / drained).
// Only #2 and #3 are pure data; #1 calls into `Async.FilePoll.deinitForceUnregister`,
// `Async.Closer.close`, `bun.windows.libuv.Loop`, and `FD.closeAllowingBadFileDescriptor`,
// none of which are surfaced by `home_rt` yet. The union re-attaches alongside
// the full Async substrate. Until then this file is the enum portion only.

pub const PollOrFd = union(enum) {
    poll: *Async.FilePoll,
    fd: bun.FD,
    closed: void,

    pub fn setOwner(this: *const PollOrFd, owner: anytype) void {
        if (this.* == .poll) this.poll.owner.set(owner);
    }

    pub fn getFd(this: *const PollOrFd) bun.FD {
        return switch (this.*) {
            .closed => bun.invalid_fd,
            .fd => this.fd,
            .poll => this.poll.fd,
        };
    }

    pub fn getPoll(this: *const PollOrFd) ?*Async.FilePoll {
        return switch (this.*) {
            .closed, .fd => null,
            .poll => this.poll,
        };
    }

    // Faithful to upstream bun/src/io/pipes.zig. The previous version set
    // `.closed` and ran the callback but never unregistered the FilePoll nor
    // closed the fd — so after a subprocess pipe reader closed, its poll stayed
    // registered in the event loop and later fired `onPoll` on freed memory
    // (use-after-free → "switch on corrupt value" / segfault in the spawnSync
    // isolated-loop tick). The Windows libuv-loop close arg is dropped because
    // Home's `Async.Closer.close` ignores the loop parameter.
    pub fn closeImpl(this: *PollOrFd, ctx: ?*anyopaque, comptime onCloseFn: anytype, close_fd: bool) void {
        const fd = this.getFd();
        var close_async = true;
        if (this.* == .poll) {
            // Workaround a kqueue bug on macOS for non-blocking writable FIFOs:
            // closing the fd asynchronously after unregistering can wedge the
            // poll, so close it synchronously in that case.
            if (comptime Environment.isMac) {
                if (this.poll.flags.contains(.poll_writable) and this.poll.flags.contains(.nonblocking)) {
                    close_async = false;
                }
            }
            this.poll.deinitForceUnregister();
            this.* = .{ .closed = {} };
        }

        if (fd != bun.invalid_fd) {
            this.* = .{ .closed = {} };

            if (close_async and close_fd) {
                Async.Closer.close(fd, {});
            } else {
                if (close_fd) _ = fd.closeAllowingBadFileDescriptor(null);
            }
            if (comptime @TypeOf(onCloseFn) != void)
                onCloseFn(@ptrCast(@alignCast(ctx.?)));
        } else {
            this.* = .{ .closed = {} };
        }
    }

    pub fn close(this: *PollOrFd, ctx: ?*anyopaque, comptime onCloseFn: anytype) void {
        this.closeImpl(ctx, onCloseFn, true);
    }
};

pub const FileType = enum {
    file,
    pipe,
    nonblocking_pipe,
    socket,

    pub fn isPollable(this: FileType) bool {
        return this == .pipe or this == .nonblocking_pipe or this == .socket;
    }

    pub fn isBlocking(this: FileType) bool {
        return this == .pipe;
    }
};

pub const ReadState = enum {
    /// The most common scenario
    /// Neither EOF nor EAGAIN
    progress,

    /// Received a 0-byte read
    eof,

    /// Received an EAGAIN
    drained,
};

const bun = @import("bun");
const Async = bun.Async;
const Environment = bun.Environment;

test "FileType: pipe/nonblocking_pipe/socket are pollable, file is not" {
    const std = @import("std");
    try std.testing.expect(!FileType.file.isPollable());
    try std.testing.expect(FileType.pipe.isPollable());
    try std.testing.expect(FileType.nonblocking_pipe.isPollable());
    try std.testing.expect(FileType.socket.isPollable());
}

test "FileType: only the synchronous .pipe variant is reported as blocking" {
    const std = @import("std");
    try std.testing.expect(FileType.pipe.isBlocking());
    try std.testing.expect(!FileType.nonblocking_pipe.isBlocking());
    try std.testing.expect(!FileType.socket.isBlocking());
    try std.testing.expect(!FileType.file.isBlocking());
}

test "ReadState: variants are distinct" {
    const std = @import("std");
    try std.testing.expect(ReadState.progress != ReadState.eof);
    try std.testing.expect(ReadState.eof != ReadState.drained);
    try std.testing.expect(ReadState.progress != ReadState.drained);
}
