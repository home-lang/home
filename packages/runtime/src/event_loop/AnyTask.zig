// Copied from bun/src/event_loop/AnyTask.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home"). The JSC `Task`
// type and `JSError` error set are local stubs here — they re-attach to
// the real JSC bridge in Phase 12.2. `callmod_inline` mirrors upstream
// Bun (Debug → .auto, otherwise → .always_inline).

//! This is a slower wrapper around a function pointer.
//! Prefer adding a task type directly to `Task` instead of using this.

const AnyTask = @This();

ctx: ?*anyopaque,
callback: *const (fn (*anyopaque) JSError!void),

pub fn task(this: *AnyTask) Task {
    // JSC bridge Task.init stubbed — re-attaches in Phase 12.2.
    return Task.init(this);
}

pub fn run(this: *AnyTask) JSError!void {
    @setRuntimeSafety(false);
    const callback = this.callback;
    const ctx = this.ctx;
    try callback(ctx.?);
}

pub fn New(comptime Type: type, comptime Callback: anytype) type {
    return struct {
        pub fn init(ctx: *Type) AnyTask {
            return AnyTask{
                .callback = wrap,
                .ctx = ctx,
            };
        }

        pub fn wrap(this: ?*anyopaque) JSError!void {
            return @call(callmod_inline, Callback, .{@as(*Type, @ptrCast(@alignCast(this.?)))});
        }
    };
}

// ---- Local stubs ------------------------------------------------------
// These will move to home_rt.jsc / home_rt.* once the JSC bridge lands
// (Phase 12.2). Keeping them inline here avoids polluting the aggregator
// before the rest of the JSC surface is in place.

pub const JSError = home_rt.JSError;

// JSC bridge Task stubbed — re-attaches in Phase 12.2.
pub const Task = struct {
    ptr: ?*anyopaque,

    pub fn init(ctx: anytype) Task {
        return .{ .ptr = @ptrCast(ctx) };
    }
};

// callmod_inline mirrors upstream Bun: Debug → .auto so stack traces
// stay readable, otherwise force inline so the wrap thunk is a single
// indirect call away from the user callback.
const builtin = @import("builtin");
pub const callmod_inline: std.builtin.CallModifier = if (builtin.mode == .Debug) .auto else .always_inline;

const home_rt = @import("home");
const std = @import("std");

// ---- Inline tests -----------------------------------------------------
const testing = std.testing;

const Counter = struct {
    runs: u32 = 0,
    fn bump(self: *Counter) JSError!void {
        self.runs += 1;
    }
};

test "AnyTask: wrap-init produces a runnable task with non-null ctx" {
    var counter = Counter{};
    const Wrapped = AnyTask.New(Counter, Counter.bump);
    var any = Wrapped.init(&counter);
    try testing.expect(any.ctx != null);

    try any.run();
    try testing.expectEqual(@as(u32, 1), counter.runs);

    try any.run();
    try testing.expectEqual(@as(u32, 2), counter.runs);
}

test "AnyTask: task() returns a non-null Task wrapper" {
    var counter = Counter{};
    const Wrapped = AnyTask.New(Counter, Counter.bump);
    var any = Wrapped.init(&counter);
    const t = any.task();
    try testing.expect(t.ptr != null);
}
