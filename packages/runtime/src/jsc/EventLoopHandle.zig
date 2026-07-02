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

    pub fn enter(_: EventLoopHandle) void {}

    pub fn exit(_: EventLoopHandle) void {}

    // Faithful to upstream EventLoopHandle.{ref,unref,filePolls,putFilePoll}:
    // the FilePoll/KeepAlive machinery refs the loop and stores polls per-VM.
    pub fn ref(this: EventLoopHandle) void {
        this.loop().ref();
    }

    pub fn unref(this: EventLoopHandle) void {
        this.loop().unref();
    }

    pub fn filePolls(this: EventLoopHandle) *home_rt.Async.FilePoll.Store {
        return switch (this) {
            .js => this.js.virtual_machine.rareData().filePolls(this.js.virtual_machine),
            .mini => this.mini.filePolls(),
        };
    }

    pub fn putFilePoll(this: *EventLoopHandle, poll: *home_rt.Async.FilePoll) void {
        switch (this.*) {
            .js => this.js.virtual_machine.rareData().filePolls(this.js.virtual_machine).put(poll, this.js.virtual_machine, poll.flags.contains(.was_ever_registered)),
            .mini => this.mini.filePolls().put(poll, &this.mini, poll.flags.contains(.was_ever_registered)),
        }
    }

    // Faithful to upstream EventLoopHandle.pipeReadBuffer: the BufferedReader's
    // streaming read path borrows a per-VM 256KB scratch buffer.
    pub fn pipeReadBuffer(this: EventLoopHandle) []u8 {
        return switch (this) {
            .js => this.js.pipeReadBuffer(),
            .mini => this.mini.pipeReadBuffer(),
        };
    }

    pub fn topLevelDir(this: EventLoopHandle) [:0]const u8 {
        _ = this;
        return home_rt.fs.FileSystem.instance.top_level_dir;
    }

    pub fn allocator(this: EventLoopHandle) std.mem.Allocator {
        _ = this;
        return home_rt.default_allocator;
    }

    pub fn createNullDelimitedEnvMap(this: EventLoopHandle, alloc: std.mem.Allocator) error{OutOfMemory}![:null]?[*:0]const u8 {
        return this.bunVM().?.transpiler.env.map.createNullDelimitedEnvMap(alloc);
    }

    pub fn env(this: EventLoopHandle) *home_rt.DotEnv.Loader {
        return this.bunVM().?.transpiler.env;
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

    pub fn enqueueTaskConcurrent(this: EventLoopHandle, context: EventLoopTaskPtr) void {
        switch (this) {
            .js => this.js.enqueueTaskConcurrent(context.js),
            .mini => this.mini.enqueueTaskConcurrent(context.mini),
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
    // These are embedded *values*, not pointers: callers (e.g. the shell)
    // fill them in place via `task.js.from(ctx, ...)`, which takes the address
    // of the embedded task. Storing a bare `*ConcurrentTask` here (initialized
    // to a `0xdead_bee0` poison sentinel) made `from()` write to the sentinel
    // address on the WorkPool thread — the external-command shell UAF. Mirror
    // upstream and hold the task by value.
    js: ConcurrentTask,
    mini: AnyTaskWithExtraContext,

    pub fn init(kind: EventLoopKind) EventLoopTask {
        return switch (kind) {
            .js => .{ .js = .{} },
            .mini => .{ .mini = .{} },
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
    var fake: EventLoop = undefined;
    const h: EventLoopHandle = .{ .js = &fake };
    try std.testing.expectEqual(&fake, h.cast(.js));
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
