// Copied from bun/src/event_loop/AnyTaskWithExtraContext.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home"). The JSC `Task`
// type is a local stub — re-attaches in Phase 12.2. `callmod_inline`
// mirrors upstream Bun (Debug → .auto, otherwise → .always_inline).

//! This is AnyTask except it gives you two pointers instead of one.
//! Generally, prefer jsc.Task instead of this.

const AnyTaskWithExtraContext = @This();

ctx: ?*anyopaque = undefined,
callback: *const (fn (*anyopaque, *anyopaque) void) = undefined,
next: ?*AnyTaskWithExtraContext = null,

pub fn fromCallbackAutoDeinit(ptr: anytype, comptime fieldName: [:0]const u8) *AnyTaskWithExtraContext {
    const Ptr = std.meta.Child(@TypeOf(ptr));
    const Wrapper = struct {
        any_task: AnyTaskWithExtraContext,
        wrapped: *Ptr,
        pub fn function(this: *anyopaque, extra: *anyopaque) void {
            const that: *@This() = @ptrCast(@alignCast(this));
            defer home_rt.default_allocator.destroy(that);
            const ctx = that.wrapped;
            @field(Ptr, fieldName)(ctx, extra);
        }
    };
    const task = home_rt.handleOom(home_rt.default_allocator.create(Wrapper));
    task.* = Wrapper{
        .any_task = AnyTaskWithExtraContext{
            .callback = &Wrapper.function,
            .ctx = task,
        },
        .wrapped = ptr,
    };
    return &task.any_task;
}

pub fn from(this: *@This(), of: anytype, comptime field: []const u8) *@This() {
    const TheTask = New(std.meta.Child(@TypeOf(of)), void, @field(std.meta.Child(@TypeOf(of)), field));
    this.* = TheTask.init(of);
    return this;
}

pub fn run(this: *AnyTaskWithExtraContext, extra: *anyopaque) void {
    @setRuntimeSafety(false);
    const callback = this.callback;
    const ctx = this.ctx;
    callback(ctx.?, extra);
}

pub fn New(comptime Type: type, comptime ContextType: type, comptime Callback: anytype) type {
    return struct {
        pub fn init(ctx: *Type) AnyTaskWithExtraContext {
            return AnyTaskWithExtraContext{
                .callback = wrap,
                .ctx = ctx,
            };
        }

        pub fn wrap(this: ?*anyopaque, extra: ?*anyopaque) void {
            @call(
                callmod_inline,
                Callback,
                .{
                    @as(*Type, @ptrCast(@alignCast(this.?))),
                    @as(*ContextType, @ptrCast(@alignCast(extra.?))),
                },
            );
        }
    };
}

// ---- Local stubs ------------------------------------------------------
// callmod_inline mirrors upstream Bun. Will move to home_rt once the JSC
// bridge lands (Phase 12.2).
const builtin = @import("builtin");
pub const callmod_inline: std.builtin.CallModifier = if (builtin.mode == .Debug) .auto else .always_inline;

const home_rt = @import("home");
const std = @import("std");

// ---- Inline tests -----------------------------------------------------
const testing = std.testing;

const Ctx = struct { sum: u32 = 0 };
const Extra = struct { add: u32 = 0 };

fn addExtra(self: *Ctx, e: *Extra) void {
    self.sum += e.add;
}

test "AnyTaskWithExtraContext: New(...).init produces a non-null ctx" {
    var c = Ctx{};
    const W = AnyTaskWithExtraContext.New(Ctx, Extra, addExtra);
    const task = W.init(&c);
    try testing.expect(task.ctx != null);
    try testing.expect(task.next == null);
}

test "AnyTaskWithExtraContext: run dispatches with both pointers" {
    var c = Ctx{ .sum = 1 };
    var e = Extra{ .add = 41 };
    const W = AnyTaskWithExtraContext.New(Ctx, Extra, addExtra);
    var task = W.init(&c);
    task.run(@ptrCast(&e));
    try testing.expectEqual(@as(u32, 42), c.sum);
}

test "AnyTaskWithExtraContext: from() returns the same task pointer" {
    const Holder = struct {
        sum: u32 = 0,
        pub fn cb(self: *@This(), _: *void) void {
            self.sum += 1;
        }
    };
    var h = Holder{};
    var task: AnyTaskWithExtraContext = .{};
    const ret = task.from(&h, "cb");
    try testing.expect(ret == &task);
    try testing.expect(task.ctx != null);
}
