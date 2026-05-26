// Copied verbatim from bun/src/io/stub_event_loop.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.

pub const Loop = struct {
    pub fn get() *Loop {
        return undefined;
    }

    pub fn schedule(_: *Loop, _: anytype) void {}
};
pub const KeepAlive = struct {};
pub const FilePoll = opaque {};
