// Home Runtime - native TTY substrate.
//
// Bun's upstream `bun_core/tty.zig` forwards to `Bun__ttySetMode` in
// `wtf-bindings.cpp`. Home keeps the same public mode enum but implements the
// POSIX core in Zig so `node:tty` and future stdio wrappers do not depend on
// the JSC C++ bridge.

const std = @import("std");
const builtin = @import("builtin");

pub const Mode = enum(c_int) {
    normal = 0,
    raw = 1,
    io = 2,
};

pub const WindowSize = struct {
    columns: u16,
    rows: u16,
};

var original_termios_fd: c_int = -1;
var original_termios: std.posix.termios = undefined;
var current_tty_mode: Mode = .normal;
var original_tty_termios: std.posix.termios = undefined;
var termios_lock = std.atomic.Value(bool).init(false);

const TermiosResult = union(enum) {
    ok: std.posix.termios,
    err: c_int,
};

pub fn isatty(fd: c_int) bool {
    if (fd < 0) return false;
    return std.c.isatty(@intCast(fd)) == 1;
}

pub fn getWindowSize(fd: c_int) ?WindowSize {
    if (fd < 0 or !isPosix()) return null;

    var size: std.posix.winsize = undefined;
    if (std.posix.system.ioctl(@intCast(fd), std.posix.T.IOCGWINSZ, @intFromPtr(&size)) != 0) {
        return null;
    }
    if (size.col == 0 or size.row == 0) return null;
    return .{ .columns = size.col, .rows = size.row };
}

pub fn setMode(fd: c_int, mode: Mode) c_int {
    if (fd < 0) return 9; // EBADF
    if (!isPosix()) return 0;
    if (current_tty_mode == mode) return 0;

    if (current_tty_mode == .normal and mode != .normal) {
        switch (tcgetattr(fd)) {
            .ok => |termios| {
                original_tty_termios = termios;
                lockTermios();
                defer unlockTermios();
                if (original_termios_fd == -1) {
                    original_termios = termios;
                    original_termios_fd = fd;
                }
            },
            .err => |err| return err,
        }
    }

    var next = original_tty_termios;
    switch (mode) {
        .normal => {},
        .raw => makeBunRaw(&next),
        .io => makeCfRaw(&next),
    }

    const rc = tcsetattr(fd, .DRAIN, next);
    if (rc == 0) current_tty_mode = mode;
    return rc;
}

pub fn resetMode() c_int {
    if (!isPosix()) return 0;
    lockTermios();
    defer unlockTermios();
    if (original_termios_fd == -1) return 0;
    return tcsetattr(original_termios_fd, .NOW, original_termios);
}

fn isPosix() bool {
    return switch (builtin.os.tag) {
        .windows, .wasi => false,
        else => true,
    };
}

fn lockTermios() void {
    while (termios_lock.swap(true, .acquire)) {
        std.atomic.spinLoopHint();
    }
}

fn unlockTermios() void {
    termios_lock.store(false, .release);
}

fn tcgetattr(fd: c_int) TermiosResult {
    while (true) {
        var term: std.posix.termios = undefined;
        const err = std.c.errno(std.posix.system.tcgetattr(@intCast(fd), &term));
        switch (err) {
            .SUCCESS => return .{ .ok = term },
            .INTR => continue,
            else => return .{ .err = @intCast(@intFromEnum(err)) },
        }
    }
}

fn tcsetattr(fd: c_int, action: std.posix.TCSA, termios: std.posix.termios) c_int {
    while (true) {
        const err = std.c.errno(std.posix.system.tcsetattr(@intCast(fd), action, &termios));
        switch (err) {
            .SUCCESS => return 0,
            .INTR => continue,
            else => return @intCast(@intFromEnum(err)),
        }
    }
}

fn makeBunRaw(term: *std.posix.termios) void {
    term.iflag.BRKINT = false;
    term.iflag.ICRNL = false;
    term.iflag.INPCK = false;
    term.iflag.ISTRIP = false;
    term.iflag.IXON = false;
    term.oflag.ONLCR = true;
    term.cflag.CSIZE = .CS8;
    term.lflag.ECHO = false;
    term.lflag.ICANON = false;
    term.lflag.IEXTEN = false;
    term.lflag.ISIG = false;
    setControlChar(term, .MIN, 1);
    setControlChar(term, .TIME, 0);
}

fn makeCfRaw(term: *std.posix.termios) void {
    makeBunRaw(term);
    term.oflag.OPOST = false;
    if (comptime @hasField(@TypeOf(term.iflag), "IMAXBEL")) term.iflag.IMAXBEL = false;
    if (comptime @hasField(@TypeOf(term.iflag), "IGNBRK")) term.iflag.IGNBRK = false;
    if (comptime @hasField(@TypeOf(term.iflag), "PARMRK")) term.iflag.PARMRK = false;
    if (comptime @hasField(@TypeOf(term.iflag), "INLCR")) term.iflag.INLCR = false;
    if (comptime @hasField(@TypeOf(term.iflag), "IGNCR")) term.iflag.IGNCR = false;
    if (comptime @hasField(@TypeOf(term.cflag), "PARENB")) term.cflag.PARENB = false;
}

fn setControlChar(term: *std.posix.termios, comptime slot: std.posix.V, value: u8) void {
    term.cc[@intFromEnum(slot)] = value;
}

const testing = std.testing;

test "tty invalid fd behavior is non-throwing" {
    try testing.expect(!isatty(-1));
    try testing.expectEqual(@as(?WindowSize, null), getWindowSize(-1));
    try testing.expect(setMode(-1, .raw) != 0);
}

test "tty stdio isatty calls are stable" {
    _ = isatty(0);
    _ = isatty(1);
    _ = isatty(2);
}
