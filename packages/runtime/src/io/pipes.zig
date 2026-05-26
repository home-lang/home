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

// stubbed: PollOrFd re-attaches when home_rt.io.FilePoll / Async.Closer
// / bun.windows.libuv / FD.closeAllowingBadFileDescriptor land.
const bun = @import("bun");

pub const PollOrFd = union(enum) {
    poll: *bun.Async.FilePoll,
    fd: bun.FD,
    closed: void,

    pub fn getPoll(_: *const PollOrFd) ?*bun.Async.FilePoll {
        return null;
    }

    pub fn getFd(this: *const PollOrFd) bun.FD {
        return switch (this.*) {
            .fd => |fd| fd,
            else => bun.invalid_fd,
        };
    }

    pub fn close(this: *PollOrFd, _: anytype, _: anytype) void {
        this.* = .{ .closed = {} };
    }

    pub fn closeImpl(this: *PollOrFd, _: anytype, _: anytype, _: bool) void {
        this.* = .{ .closed = {} };
    }

    pub fn setOwner(_: *PollOrFd, _: anytype) void {}
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
