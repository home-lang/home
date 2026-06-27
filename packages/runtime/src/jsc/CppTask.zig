// Copied from bun/src/jsc/CppTask.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// The original `bun.cpp.Bun__performTask`, `jsc.markBinding`, `jsc.WorkPool`,
// `jsc.VirtualMachine`, `bun.TrivialNew`, and `bun.destroy` are all not yet
// ported. We declare local opaque/struct stubs + minimal helpers so the public
// surface of `CppTask` / `ConcurrentCppTask` compiles. The real bridge
// re-attaches in Phase 12.2 alongside the JSC engine bring-up.

const std = @import("std");
const bun_rt = @import("bun");

// JSC bridge JSGlobalObject stubbed — re-attaches in Phase 12.2.
const JSGlobalObject = @import("./JSGlobalObject.zig").JSGlobalObject;
// JSC bridge JSError stubbed — re-attaches in Phase 12.2.
const JSError = error{JSError};

// JSC bridge VirtualMachine + event_loop stubbed — re-attaches in Phase 12.2.
const VirtualMachine = struct {
    event_loop: EventLoop = .{},

    const EventLoop = struct {
        pub fn refConcurrently(_: *EventLoop) void {}
        pub fn unrefConcurrently(_: *EventLoop) void {}
    };
};

// JSC bridge WorkPoolTask stubbed — re-attaches in Phase 12.2.
const WorkPoolTask = struct {
    callback: *const fn (*WorkPoolTask) void,
};

// JSC bridge WorkPool stubbed — re-attaches in Phase 12.2.
const WorkPool = struct {
    pub fn schedule(task: *WorkPoolTask) void {
        // No-op stub; the real implementation submits to a thread pool.
        _ = task;
    }
};

// JSC bridge markBinding stubbed — re-attaches in Phase 12.2.
fn markBinding(_: std.builtin.SourceLocation) void {}

// Re-attached (was a Phase-12 no-op): call the linked C++
// `EventLoopTask::performTask`. Without this, every cross-thread CppTask was
// silently discarded — e.g. a Worker's `'open'`/`postMessage`, which crosses
// to the parent via `Bun__queueTaskConcurrently` → the parent's concurrent
// queue → `Task` dispatch → `CppTask.run` → here. `bun_rt.cpp.Bun__performTask`
// is the generated wrapper over the real extern (`.generated/cpp.zig`).
fn Bun__performTask(global: *JSGlobalObject, this: *CppTask) JSError!void {
    return bun_rt.cpp.Bun__performTask(global, this);
}

// JSC bridge bun.destroy stubbed — re-attaches in Phase 12.2.
fn destroy(ptr: anytype) void {
    std.heap.smp_allocator.destroy(ptr);
}

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

/// A task created from C++ code, usually via ScriptExecutionContext.
pub const CppTask = opaque {
    pub fn run(this: *CppTask, global: *JSGlobalObject) JSError!void {
        markBinding(@src());
        return Bun__performTask(global, this);
    }
};

/// A task created from C++ code that runs inside the workpool, usually via ScriptExecutionContext.
pub const ConcurrentCppTask = struct {
    pub const new = TrivialNew(@This());

    cpp_task: *EventLoopTaskNoContext,
    workpool_task: WorkPoolTask = .{ .callback = &runFromWorkpool },

    const EventLoopTaskNoContext = opaque {
        extern fn Bun__EventLoopTaskNoContext__performTask(task: *EventLoopTaskNoContext) void;
        extern fn Bun__EventLoopTaskNoContext__createdInBunVm(task: *const EventLoopTaskNoContext) ?*VirtualMachine;

        /// Deallocates `this`
        pub fn run(this: *EventLoopTaskNoContext) void {
            Bun__EventLoopTaskNoContext__performTask(this);
        }

        /// Get the VM that created this task
        pub fn getVM(this: *const EventLoopTaskNoContext) ?*VirtualMachine {
            return Bun__EventLoopTaskNoContext__createdInBunVm(this);
        }
    };

    pub fn runFromWorkpool(task: *WorkPoolTask) void {
        const this: *ConcurrentCppTask = @fieldParentPtr("workpool_task", task);
        // Extract all the info we need from `this` and `cpp_task` before we call functions that
        // free them
        const cpp_task = this.cpp_task;
        const maybe_vm = cpp_task.getVM();
        destroy(this);
        cpp_task.run();
        if (maybe_vm) |vm| {
            vm.event_loop.unrefConcurrently();
        }
    }

    pub fn ConcurrentCppTask__createAndRun(cpp_task: *EventLoopTaskNoContext) callconv(.c) void {
        markBinding(@src());
        if (cpp_task.getVM()) |vm| {
            vm.event_loop.refConcurrently();
        }
        const cpp = ConcurrentCppTask.new(.{ .cpp_task = cpp_task });
        WorkPool.schedule(&cpp.workpool_task);
    }
};

test "CppTask is an opaque pointer-only type" {
    try std.testing.expect(@sizeOf(*CppTask) == @sizeOf(usize));
}

test "ConcurrentCppTask exposes the expected pub decls" {
    // Pure comptime existence check — does NOT take the address of any function
    // (taking `&runFromWorkpool` would force-compile the C++ extern symbols
    // `Bun__EventLoopTaskNoContext__performTask` et al., which only land in
    // Phase 12.2). `@hasDecl` is enough to assert API surface.
    try std.testing.expect(@hasDecl(ConcurrentCppTask, "new"));
    try std.testing.expect(@hasDecl(ConcurrentCppTask, "runFromWorkpool"));
    try std.testing.expect(@hasDecl(ConcurrentCppTask, "ConcurrentCppTask__createAndRun"));
}
