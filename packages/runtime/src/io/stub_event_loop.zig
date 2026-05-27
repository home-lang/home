// Copied verbatim from bun/src/io/stub_event_loop.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.

pub const Loop = struct {
    pub fn get() *Loop {
        return undefined;
    }

    pub fn schedule(_: *Loop, _: anytype) void {}
};
// Parked placeholder for `Async.KeepAlive` (`io/posix_event_loop.zig`). The
// real type pins the uSockets/libuv loop alive while async work is pending.
// The stub tracks active state so callers' ref/unref bookkeeping stays
// internally consistent; loop/VM arguments are accepted but ignored until the
// event-loop bridge lands in Phase 12.2.
pub const KeepAlive = struct {
    status: enum { inactive, active, done } = .inactive,

    pub fn init() KeepAlive {
        return .{};
    }

    pub fn deinit(_: *KeepAlive) void {}

    pub fn isActive(this: *const KeepAlive) bool {
        return this.status == .active;
    }

    pub fn disable(this: *KeepAlive) void {
        this.status = .done;
    }

    pub fn ref(this: *KeepAlive, _: anytype) void {
        this.status = .active;
    }

    pub fn unref(this: *KeepAlive, _: anytype) void {
        this.status = .inactive;
    }

    pub fn unrefOnNextTick(this: *KeepAlive, _: anytype) void {
        this.status = .inactive;
    }

    pub fn refConcurrentlyFromEventLoop(this: *KeepAlive, _: anytype) void {
        this.status = .active;
    }

    pub fn unrefConcurrentlyFromEventLoop(this: *KeepAlive, _: anytype) void {
        this.status = .inactive;
    }
};
pub const FilePoll = opaque {};
