// Copied verbatim from bun/src/core/tty.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.

pub const Mode = enum(c_int) {
    normal = 0,
    raw = 1,
    io = 2,
};

pub fn setMode(fd: c_int, mode: Mode) c_int {
    return Bun__ttySetMode(fd, @intFromEnum(mode));
}

extern fn Bun__ttySetMode(fd: c_int, mode: c_int) c_int;
