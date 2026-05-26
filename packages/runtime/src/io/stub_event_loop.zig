// Copied verbatim from bun/src/io/stub_event_loop.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.

pub const Loop = struct {};
pub const KeepAlive = struct {
    ref_count: usize = 0,

    pub fn ref(this: *KeepAlive) void {
        this.ref_count += 1;
    }

    pub fn unref(this: *KeepAlive) void {
        if (this.ref_count > 0) this.ref_count -= 1;
    }
};
pub const FilePoll = struct {};
