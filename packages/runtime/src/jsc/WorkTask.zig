/// A generic task that runs work on a thread pool and executes a callback on the main JavaScript thread.
/// Unlike ConcurrentPromiseTask which automatically resolves a Promise, WorkTask provides more flexibility
/// by allowing the Context to handle the result however it wants (e.g., calling callbacks, emitting events, etc.).
///
/// The Context type must implement:
/// - `run(*Context, *WorkTask)` - performs the work on the thread pool
/// - `then(*jsc.JSGlobalObject)` - handles the result on the JS thread (no automatic Promise resolution)
///
/// Key differences from ConcurrentPromiseTask:
/// - No automatic Promise creation or resolution
/// - Includes async task tracking for debugging
/// - More flexible result handling via the `then` callback
/// - Context receives a reference to the WorkTask itself in the `run` method
pub fn WorkTask(comptime Context: type) type {
    return struct {
        const TaskType = WorkPoolTask;

        const This = @This();
        ctx: *Context,
        task: TaskType = .{ .callback = &runFromThreadPool },
        event_loop: *jsc.EventLoop,
        allocator: std.mem.Allocator,
        globalThis: *jsc.JSGlobalObject,
        concurrent_task: ConcurrentTask = .{},
        async_task_tracker: jsc.Debugger.AsyncTaskTracker,
        native_job_admitted: bool = false,

        // This is a poll because we want it to enter the uSockets loop
        ref: Async.KeepAlive = .{},

        pub fn createOnJSThread(allocator: std.mem.Allocator, globalThis: *jsc.JSGlobalObject, value: *Context) *This {
            var vm = globalThis.bunVM();
            var this = bun.new(This, .{
                .event_loop = vm.eventLoop(),
                .ctx = value,
                .allocator = allocator,
                .globalThis = globalThis,
                .async_task_tracker = jsc.Debugger.AsyncTaskTracker.init(vm),
            });
            this.ref.ref(this.event_loop.virtual_machine);

            return this;
        }

        pub fn deinit(this: *This) void {
            this.ref.unref(this.event_loop.virtual_machine);
            bun.destroy(this);
        }

        pub fn runFromThreadPool(task: *TaskType) void {
            jsc.markBinding(@src());
            const this: *This = @fieldParentPtr("task", task);
            Context.run(this.ctx, this);
        }

        pub fn runFromJS(this: *This) bun.JSTerminated!void {
            var ctx = this.ctx;
            const tracker = this.async_task_tracker;
            const vm = this.event_loop.virtual_machine;
            const globalThis = this.globalThis;
            this.ref.unref(vm);

            tracker.willDispatch(globalThis);
            defer tracker.didDispatch(globalThis);
            return ctx.then(globalThis);
        }

        pub fn schedule(this: *This) void {
            const vm = this.event_loop.virtual_machine;
            this.ref.ref(vm);
            this.async_task_tracker.didSchedule(this.globalThis);
            WorkPool.schedule(&this.task);
        }

        pub fn scheduleWithShutdown(this: *This) bool {
            const vm = this.event_loop.virtual_machine;
            this.ref.ref(vm);
            this.async_task_tracker.didSchedule(this.globalThis);
            if (!vm.native_work_pool_jobs.tryAdd()) return false;
            this.native_job_admitted = true;
            WorkPool.schedule(&this.task);
            return true;
        }

        pub fn onFinish(this: *This) void {
            const vm = this.event_loop.virtual_machine;
            const native_job_admitted = this.native_job_admitted;
            this.native_job_admitted = false;
            this.event_loop.enqueueTaskConcurrent(this.concurrent_task.from(this, .manual_deinit));
            if (native_job_admitted) vm.native_work_pool_jobs.complete();
        }

        pub fn cancelForShutdown(this: *This) void {
            comptime {
                if (!@hasDecl(Context, "cancelForShutdown"))
                    @compileError(@typeName(Context) ++ " must implement cancelForShutdown");
            }
            bun.assert(!this.native_job_admitted);
            this.async_task_tracker.didCancel(this.globalThis);
            this.ref.unref(this.event_loop.virtual_machine);
            Context.cancelForShutdown(this.ctx);
            this.deinit();
            _ = shutdown_cancellation_count.fetchAdd(1, .seq_cst);
        }
    };
}

var shutdown_cancellation_count = std.atomic.Value(u64).init(0);

pub fn shutdownCancellationCount() u64 {
    return shutdown_cancellation_count.load(.seq_cst);
}

const std = @import("std");

const bun = @import("bun");
const Async = bun.Async;

const jsc = bun.jsc;
const ConcurrentTask = jsc.ConcurrentTask;
const WorkPool = jsc.WorkPool;
const WorkPoolTask = jsc.WorkPoolTask;
