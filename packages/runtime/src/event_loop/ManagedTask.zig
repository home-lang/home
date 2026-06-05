// Copied from bun/src/event_loop/ManagedTask.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home"). The JSC `Task`
// type and `JSError` error set are local stubs — they re-attach to the
// real JSC bridge in Phase 12.2. `callmod_inline` mirrors upstream Bun.

//! This is a slow, dynamically-allocated one-off task
//! Use it when you can't add to jsc.Task directly and managing the lifetime of the Task struct is overly complex

const ManagedTask = @This();

ctx: ?*anyopaque,
callback: *const (fn (*anyopaque) JSError!void),

pub fn task(this: *ManagedTask) Task {
    // JSC bridge Task.init stubbed — re-attaches in Phase 12.2.
    return Task.init(this);
}

pub fn run(this: *ManagedTask) JSError!void {
    @setRuntimeSafety(false);
    defer home_rt.default_allocator.destroy(this);
    const callback = this.callback;
    const ctx = this.ctx;
    try callback(ctx.?);
}

pub fn cancel(this: *ManagedTask) void {
    this.callback = &struct {
        fn f(_: *anyopaque) JSError!void {}
    }.f;
}

pub fn New(comptime Type: type, comptime Callback: anytype) type {
    return struct {
        pub fn init(ctx: *Type) Task {
            var managed = home_rt.handleOom(home_rt.default_allocator.create(ManagedTask));
            managed.* = ManagedTask{
                .callback = wrap,
                .ctx = ctx,
            };
            return managed.task();
        }

        pub fn wrap(this: ?*anyopaque) JSError!void {
            return @call(callmod_inline, Callback, .{@as(*Type, @ptrCast(@alignCast(this.?)))});
        }
    };
}

// ---- Local stubs ------------------------------------------------------
// JSError + Task move to home_rt.jsc once the JSC bridge lands
// (Phase 12.2). callmod_inline mirrors upstream Bun.

pub const JSError = home_rt.JSError;

// Phase 12.2: re-attached to the real jsc.Task.
pub const Task = jsc.Task;

const builtin = @import("builtin");
pub const callmod_inline: std.builtin.CallModifier = if (builtin.mode == .Debug) .auto else .always_inline;

const home_rt = @import("home");
const jsc = home_rt.jsc;
const std = @import("std");
