// Copied from bun/src/jsc/ConcurrentPromiseTask.zig at upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// `jsc.EventLoop`, `jsc.JSGlobalObject`, `jsc.JSPromise`, `jsc.ConcurrentTask`,
// `Async.KeepAlive`, `WorkPool`, `WorkPoolTask`, `VirtualMachine`,
// `bun.TrivialNew`, `bun.destroy`, and `bun.JSTerminated` are all not yet
// ported. We declare local stubs in a `jsc` mini-namespace so the upstream
// spelling stays verbatim. The generic type is checked at definition time
// against the stubs; the real bridge re-attaches in Phase 12.2.

const std = @import("std");

// JSC bridge JSGlobalObject stubbed — re-attaches in Phase 12.2.
const JSGlobalObject = @import("./JSGlobalObject.zig").JSGlobalObject;
// JSC bridge bun.JSTerminated stubbed — re-attaches in Phase 12.2.
const JSTerminated = error{JSTerminated};

// JSC bridge WorkPoolTask stubbed — re-attaches in Phase 12.2.
const WorkPoolTask = struct {
    callback: *const fn (*WorkPoolTask) void,
};

const JSPromise = @import("./JSPromise.zig").JSPromise;

// JSC bridge VirtualMachine stubbed — re-attaches in Phase 12.2.
const VirtualMachine = opaque {
    pub fn get() *VirtualMachine {
        unreachable; // stub
    }
};

// JSC bridge ConcurrentTask stubbed — re-attaches in Phase 12.2.
const ConcurrentTask = struct {
    pub fn from(_: *ConcurrentTask, _: *anyopaque, _: enum { manual_deinit }) *ConcurrentTask {
        unreachable; // stub
    }
};

// JSC bridge EventLoop stubbed — re-attaches in Phase 12.2.
const EventLoop = struct {
    virtual_machine: *VirtualMachine,

    pub fn enqueueTaskConcurrent(_: *EventLoop, _: *ConcurrentTask) void {}
};

// Local `jsc.*` mini-namespace so upstream spellings stay verbatim.
const jsc = struct {
    pub const EventLoop = @import("ConcurrentPromiseTask.zig").EventLoop;
    pub const JSGlobalObject = @import("ConcurrentPromiseTask.zig").JSGlobalObject;
    pub const JSPromise = @import("ConcurrentPromiseTask.zig").JSPromise;
    pub const ConcurrentTask = @import("ConcurrentPromiseTask.zig").ConcurrentTask;
};

// JSC bridge Async.KeepAlive stubbed — re-attaches in Phase 12.2.
const Async = struct {
    pub const KeepAlive = struct {
        pub fn ref(_: *KeepAlive, _: *VirtualMachine) void {}
        pub fn unref(_: *KeepAlive, _: *VirtualMachine) void {}
    };
};

// JSC bridge WorkPool stubbed — re-attaches in Phase 12.2.
const WorkPool = struct {
    pub fn schedule(_: *WorkPoolTask) void {}
};

// JSC bridge bun.TrivialNew stubbed — re-attaches in Phase 12.2.
fn TrivialNew(comptime T: type) fn (T) *T {
    return struct {
        fn new(init: T) *T {
            const ptr = std.heap.smp_allocator.create(T) catch @panic("OOM in TrivialNew stub");
            ptr.* = init;
            return ptr;
        }
    }.new;
}

// JSC bridge bun.destroy stubbed — re-attaches in Phase 12.2.
fn destroy(ptr: anytype) void {
    std.heap.smp_allocator.destroy(ptr);
}

/// A generic task that runs work on a thread pool and resolves a JavaScript Promise with the result.
/// This allows CPU-intensive operations to be performed off the main JavaScript thread while
/// maintaining a Promise-based API for JavaScript consumers.
///
/// The Context type must implement:
/// - `run(*Context)` - performs the work on the thread pool
/// - `then(*Context, jsc.JSPromise)` - resolves the promise with the result on the JS thread
pub fn ConcurrentPromiseTask(comptime Context: type) type {
    return struct {
        const This = @This();
        ctx: *Context,
        task: WorkPoolTask = .{ .callback = &runFromThreadPool },
        event_loop: *jsc.EventLoop,
        allocator: std.mem.Allocator,
        promise: jsc.JSPromise.Strong = .{},
        globalThis: *jsc.JSGlobalObject,
        concurrent_task: jsc.ConcurrentTask = .{},

        // This is a poll because we want it to enter the uSockets loop
        ref: Async.KeepAlive = .{},

        pub const new = TrivialNew(@This());

        pub fn createOnJSThread(allocator: std.mem.Allocator, globalThis: *jsc.JSGlobalObject, value: *Context) *This {
            var this = This.new(.{
                .event_loop = undefined, // VirtualMachine.get().event_loop in real impl
                .ctx = value,
                .allocator = allocator,
                .globalThis = globalThis,
            });
            this.promise = jsc.JSPromise.Strong.init(globalThis);
            this.ref.ref(this.event_loop.virtual_machine);
            return this;
        }

        pub fn runFromThreadPool(task: *WorkPoolTask) void {
            const this: *This = @fieldParentPtr("task", task);
            Context.run(this.ctx);
            this.onFinish();
        }

        pub fn runFromJS(this: *This) JSTerminated!void {
            const promise = this.promise.swap();
            this.ref.unref(this.event_loop.virtual_machine);

            const ctx = this.ctx;

            return ctx.then(promise);
        }

        pub fn schedule(this: *This) void {
            WorkPool.schedule(&this.task);
        }

        pub fn onFinish(this: *This) void {
            this.event_loop.enqueueTaskConcurrent(jsc.ConcurrentTask.from(&this.concurrent_task, this, .manual_deinit));
        }

        pub fn deinit(this: *This) void {
            this.promise.deinit();
            destroy(this);
        }
    };
}

test "ConcurrentPromiseTask is a generic returning a struct type" {
    const Ctx = struct {
        pub fn run(_: *@This()) void {}
        pub fn then(_: *@This(), _: *JSPromise) JSTerminated!void {}
    };
    const Task = ConcurrentPromiseTask(Ctx);
    try std.testing.expect(@hasDecl(Task, "createOnJSThread"));
    try std.testing.expect(@hasDecl(Task, "runFromThreadPool"));
    try std.testing.expect(@hasDecl(Task, "runFromJS"));
    try std.testing.expect(@hasDecl(Task, "schedule"));
    try std.testing.expect(@hasDecl(Task, "onFinish"));
    try std.testing.expect(@hasDecl(Task, "deinit"));
}
