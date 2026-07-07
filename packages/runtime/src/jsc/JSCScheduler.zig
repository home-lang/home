// Copied from bun/src/jsc/JSCScheduler.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// This is the delivery path for JSC's DeferredWorkTimer jobs — most
// importantly FinalizationRegistry cleanup callbacks. The C++ side
// (JSCTaskScheduler.cpp, hooks installed in BunClientData.cpp) wraps each
// job in a heap JSCDeferredWorkTask and hands it to
// Bun__queueJSCDeferredWorkTaskConcurrently; Task.zig dispatches it back
// into run() → Bun__runDeferredWork. While this file was a no-op
// placeholder, FinalizationRegistry callbacks never fired at all
// (node:util aborted() gc-cleanup hung forever) and every task leaked.
//
// The exports are comptime-gated on `-Denable_jsc`: without the linked
// C++ objects nothing provides Bun__runDeferredWork or calls the exports,
// and the non-JSC test targets must not analyze VirtualMachine.

const JSCScheduler = @This();

pub const JSCDeferredWorkTask = opaque {
    extern fn Bun__runDeferredWork(task: *JSCScheduler.JSCDeferredWorkTask) void;
    pub fn run(task: *JSCScheduler.JSCDeferredWorkTask) bun.JSTerminated!void {
        const globalThis = bun.jsc.VirtualMachine.get().global;
        var scope: bun.jsc.ExceptionValidationScope = undefined;
        scope.init(globalThis, @src());
        defer scope.deinit();
        Bun__runDeferredWork(task);
        try scope.assertNoExceptionExceptTermination();
    }
};

fn Bun__eventLoop__incrementRefConcurrently(jsc_vm: *VirtualMachine, delta: c_int) callconv(.c) void {
    jsc.markBinding(@src());

    if (delta > 0) {
        jsc_vm.event_loop.refConcurrently();
    } else {
        jsc_vm.event_loop.unrefConcurrently();
    }
}

fn Bun__queueJSCDeferredWorkTaskConcurrently(jsc_vm: *VirtualMachine, task: *JSCScheduler.JSCDeferredWorkTask) callconv(.c) void {
    jsc.markBinding(@src());
    var loop = jsc_vm.eventLoop();
    loop.enqueueTaskConcurrent(ConcurrentTask.new(.{
        .task = Task.init(task),
        .next = .auto_delete,
    }));
}

fn Bun__tickWhilePaused(paused: *bool) callconv(.c) void {
    jsc.markBinding(@src());
    VirtualMachine.get().eventLoop().tickWhilePaused(paused);
}

comptime {
    if (@import("build_options").enable_jsc) {
        @export(&Bun__eventLoop__incrementRefConcurrently, .{ .name = "Bun__eventLoop__incrementRefConcurrently" });
        @export(&Bun__queueJSCDeferredWorkTaskConcurrently, .{ .name = "Bun__queueJSCDeferredWorkTaskConcurrently" });
        @export(&Bun__tickWhilePaused, .{ .name = "Bun__tickWhilePaused" });
    }
}

const bun = @import("bun");

const jsc = bun.jsc;
const ConcurrentTask = jsc.ConcurrentTask;
const Task = jsc.Task;
const VirtualMachine = jsc.VirtualMachine;
