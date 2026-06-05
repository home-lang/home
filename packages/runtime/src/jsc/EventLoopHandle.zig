// Copied from bun/src/jsc/EventLoopHandle.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// `EventLoopHandle` is a non-owning union over the JS event loop and the
// "mini" event loop. Almost every method in the upstream file reaches through
// `this.js.virtual_machine.rareData()`, `this.mini.env.?.map`, etc., which
// can't compile until `VirtualMachine`, `MiniEventLoop`, `Blob.Store`,
// `FilePoll`, `bun.DotEnv.Loader`, and `bun.uws.Loop` all land. We keep:
//   - the `EventLoopKind` discriminant tag enum (pure-Zig),
//   - the `EventLoopHandle` union shape pointing at opaque
//     `EventLoop` / `MiniEventLoop` placeholders,
//   - the `EventLoopTask` / `EventLoopTaskPtr` union shapes (placeholder
//     payloads — the actual `jsc.ConcurrentTask` and
//     `jsc.AnyTaskWithExtraContext` re-land alongside `Task.zig`).
// Method bodies re-attach in Phase 12.2.

const std = @import("std");
const home_rt = @import("home");

/// Discriminant for the `EventLoopHandle` union. Upstream lives in
/// `jsc.EventLoopKind`; we inline it here so this leaf compiles in
/// isolation. The tag values match upstream.
pub const EventLoopKind = enum(u8) {
    js,
    mini,
};

pub const EventLoop = @import("./event_loop.zig").EventLoop;
pub const MiniEventLoop = @import("../event_loop/MiniEventLoop.zig");

const ConcurrentTask = @import("./event_loop.zig").ConcurrentTask;
const AnyTaskWithExtraContext = @import("./event_loop.zig").AnyTaskWithExtraContext;

/// A non-owning reference to either the JS event loop or the mini event loop.
pub const EventLoopHandle = union(EventLoopKind) {
    js: *EventLoop,
    mini: *MiniEventLoop,

    pub fn globalObject(this: EventLoopHandle) ?*home_rt.jsc.JSGlobalObject {
        return switch (this) {
            .js => this.js.global,
            .mini => null,
        };
    }

    pub fn bunVM(this: EventLoopHandle) ?*home_rt.jsc.VirtualMachine {
        return switch (this) {
            .js => this.js.virtual_machine,
            .mini => null,
        };
    }

    pub fn cast(this: EventLoopHandle, comptime tag: EventLoopKind) switch (tag) {
        .js => *EventLoop,
        .mini => *MiniEventLoop,
    } {
        return @field(this, @tagName(tag));
    }

    pub fn loop(this: EventLoopHandle) *home_rt.jsc.PlatformEventLoop {
        return switch (this) {
            .js => this.js.usocketsLoop(),
            .mini => this.mini.loop,
        };
    }

    pub fn topLevelDir(this: EventLoopHandle) [:0]const u8 {
        _ = this;
        return home_rt.fs.FileSystem.instance.top_level_dir;
    }

    pub fn createNullDelimitedEnvMap(this: EventLoopHandle, alloc: std.mem.Allocator) error{OutOfMemory}![:null]?[*:0]const u8 {
        return this.bunVM().?.transpiler.env.map.createNullDelimitedEnvMap(alloc);
    }

    pub fn env(this: EventLoopHandle) *home_rt.DotEnv.Loader {
        return this.bunVM().?.transpiler.env;
    }

    pub inline fn allocator(this: EventLoopHandle) std.mem.Allocator {
        return switch (this) {
            .js => this.js.virtual_machine.allocator,
            .mini => this.mini.allocator,
        };
    }

    pub fn stdout(this: EventLoopHandle) *home_rt.jsc.WebCore.Blob.Store {
        return switch (this) {
            .js => this.js.virtual_machine.rareData().stdout(),
            .mini => this.mini.stdout(),
        };
    }

    pub fn stderr(this: EventLoopHandle) *home_rt.jsc.WebCore.Blob.Store {
        return switch (this) {
            .js => this.js.virtual_machine.rareData().stderr(),
            .mini => this.mini.stderr(),
        };
    }

    pub fn enter(this: EventLoopHandle) void {
        switch (this) {
            .js => this.js.enter(),
            .mini => {},
        }
    }

    pub fn exit(this: EventLoopHandle) void {
        switch (this) {
            .js => this.js.exit(),
            .mini => {},
        }
    }

    pub fn enqueueTaskConcurrent(this: EventLoopHandle, task: EventLoopTask) void {
        switch (this) {
            .js => this.js.enqueueTaskConcurrent(task.js),
            .mini => this.mini.enqueueTaskConcurrent(task.mini),
        }
    }

    pub fn init(context: anytype) EventLoopHandle {
        const Context = @TypeOf(context);
        return switch (Context) {
            *home_rt.jsc.VirtualMachine => .{ .js = context.eventLoop() },
            *EventLoop => .{ .js = context },
            *MiniEventLoop => .{ .mini = context },
            *home_rt.jsc.AnyEventLoop => switch (context.*) {
                .js => .{ .js = context.js },
                .mini => .{ .mini = &context.mini },
            },
            EventLoopHandle => context,
            else => @compileError("Invalid context type for EventLoopHandle.init " ++ @typeName(Context)),
        };
    }
};

pub const EventLoopTask = union(EventLoopKind) {
    js: *ConcurrentTask,
    mini: *AnyTaskWithExtraContext,

    pub fn init(kind: EventLoopKind) EventLoopTask {
        return switch (kind) {
            .js => .{ .js = @ptrFromInt(0xdead_bee0) },
            .mini => .{ .mini = @ptrFromInt(0xdead_bee8) },
        };
    }

    pub fn fromEventLoop(handle: EventLoopHandle) EventLoopTask {
        return init(std.meta.activeTag(handle));
    }
};

pub const EventLoopTaskPtr = union {
    js: *ConcurrentTask,
    mini: *AnyTaskWithExtraContext,
};

test "EventLoopKind tag values" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(EventLoopKind.js));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(EventLoopKind.mini));
}

test "EventLoopHandle.cast returns the right pointer" {
    // We can't materialize an opaque on the stack, but a dangling `*EventLoop`
    // is enough to prove the union round-trips and `cast()` dispatches.
    const fake: *EventLoop = @ptrFromInt(0xdead_b000);
    const h: EventLoopHandle = .{ .js = fake };
    try std.testing.expectEqual(fake, h.cast(.js));
}

test "EventLoopTask.init produces the right tag" {
    const t_js = EventLoopTask.init(.js);
    const t_mini = EventLoopTask.init(.mini);
    try std.testing.expect(t_js == .js);
    try std.testing.expect(t_mini == .mini);
}

comptime {
    _ = home_rt;
}
