// Copied from bun/src/jsc/CppTask.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Home keeps the small allocation/markBinding helpers local, while the task
// execution, VM lifetime accounting, and work-pool scheduling paths are wired
// to the real runtime. Concurrent C++ jobs must never be represented by no-op
// placeholders: WebCrypto and other native APIs rely on them to settle their
// promises.

const std = @import("std");
const bun_rt = @import("bun");

// JSC bridge JSGlobalObject stubbed — re-attaches in Phase 12.2.
const JSGlobalObject = @import("./JSGlobalObject.zig").JSGlobalObject;
// JSC bridge JSError stubbed — re-attaches in Phase 12.2.
const JSError = error{JSError};

const VirtualMachine = @import("./VirtualMachine.zig");
const WorkPoolTask = @import("../threading/work_pool.zig").Task;
const WorkPool = @import("../threading/work_pool.zig").WorkPool;

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

    pub export fn ConcurrentCppTask__createAndRun(cpp_task: *EventLoopTaskNoContext) void {
        markBinding(@src());
        if (cpp_task.getVM()) |vm| {
            vm.event_loop.refConcurrently();
        }
        const cpp = ConcurrentCppTask.new(.{ .cpp_task = cpp_task });
        WorkPool.schedule(&cpp.workpool_task);
    }
};

comptime {
    _ = ConcurrentCppTask.ConcurrentCppTask__createAndRun;
}

test "CppTask is an opaque pointer-only type" {
    try std.testing.expect(@sizeOf(*CppTask) == @sizeOf(usize));
}

test "ConcurrentCppTask exposes the real work-pool bridge" {
    try std.testing.expect(@hasDecl(ConcurrentCppTask, "new"));
    try std.testing.expect(@hasDecl(ConcurrentCppTask, "runFromWorkpool"));
    try std.testing.expect(@hasDecl(ConcurrentCppTask, "ConcurrentCppTask__createAndRun"));
    try std.testing.expect(WorkPoolTask == @import("../threading/work_pool.zig").Task);
}
