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
        const PollableState = enum(u8) {
            idle,
            worker,
            parking,
            parked,
            resume_pending,
            published,
            cancelling,
        };

        ctx: *Context,
        task: TaskType = .{ .callback = &runFromThreadPool },
        event_loop: *jsc.EventLoop,
        allocator: std.mem.Allocator,
        globalThis: *jsc.JSGlobalObject,
        concurrent_task: ConcurrentTask = .{},
        async_task_tracker: jsc.Debugger.AsyncTaskTracker,
        native_job_admitted: bool = false,
        pollable_job: jsc.VirtualMachine.NativePollableWorkPoolJob = .{},
        pollable_state: std.atomic.Value(PollableState) = std.atomic.Value(PollableState).init(.idle),
        poll_resume_task: ?*WorkPoolTask = null,
        poll_close_lock: bun.Mutex = .{},
        poll_close_condition: bun.threading.Condition = .{},
        poll_close_complete: bool = false,

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

        /// Schedule a job which may temporarily leave the work pool and park
        /// on the process-wide I/O poller. The VM registry owns the job while
        /// it is parked; each actual work-pool hop separately joins the normal
        /// shutdown barrier.
        pub fn schedulePollableWithShutdown(this: *This) bool {
            const vm = this.event_loop.virtual_machine;
            this.ref.ref(vm);
            this.async_task_tracker.didSchedule(this.globalThis);
            this.pollable_job.cancel_for_shutdown = &cancelPollableJobForShutdown;
            if (!vm.native_pollable_work_pool_jobs.tryAdd(&this.pollable_job)) return false;
            if (!vm.native_work_pool_jobs.tryAdd()) {
                vm.native_pollable_work_pool_jobs.remove(&this.pollable_job);
                return false;
            }
            this.native_job_admitted = true;
            this.pollable_state.store(.worker, .release);
            WorkPool.schedule(&this.task);
            return true;
        }

        /// Begin the handoff from a running WorkPool callback to `io.Loop`.
        /// A readiness notification which wins this race records the task and
        /// lets `finishPollWait` schedule it only after the current callback is
        /// done touching the context.
        pub fn beginPollWait(this: *This) void {
            const previous = this.pollable_state.cmpxchgStrong(.worker, .parking, .acq_rel, .acquire);
            bun.assert(previous == null);
        }

        pub fn finishPollWait(this: *This) void {
            if (this.pollable_state.cmpxchgStrong(.parking, .parked, .acq_rel, .acquire) == null) {
                bun.assert(this.native_job_admitted);
                this.native_job_admitted = false;
                this.event_loop.virtual_machine.native_work_pool_jobs.complete();
                return;
            }

            bun.assert(this.pollable_state.load(.acquire) == .resume_pending);
            const resume_task = this.poll_resume_task orelse @panic("poll resume task missing");
            this.poll_resume_task = null;
            this.pollable_state.store(.worker, .release);
            // The original work-pool admission remains held until this resumed
            // hop either parks again or publishes its owner-thread completion.
            WorkPool.schedule(resume_task);
        }

        /// Called by the process-wide I/O thread. Returns true only when the
        /// caller should enqueue `resume_task` on the WorkPool itself.
        pub fn resumeFromPoll(this: *This, resume_task: *WorkPoolTask) bool {
            while (true) {
                switch (this.pollable_state.load(.acquire)) {
                    .parking => {
                        this.poll_resume_task = resume_task;
                        if (this.pollable_state.cmpxchgWeak(.parking, .resume_pending, .acq_rel, .acquire) == null)
                            return false;
                    },
                    .parked => {
                        const vm = this.event_loop.virtual_machine;
                        if (!vm.native_work_pool_jobs.tryAdd()) return false;
                        if (this.pollable_state.cmpxchgStrong(.parked, .worker, .acq_rel, .acquire) == null) {
                            this.native_job_admitted = true;
                            return true;
                        }
                        vm.native_work_pool_jobs.complete();
                    },
                    .resume_pending, .cancelling, .published => return false,
                    .idle, .worker => unreachable,
                }
            }
        }

        pub fn pollClosedForShutdown(this: *This) void {
            this.poll_close_lock.lock();
            this.poll_close_complete = true;
            this.poll_close_condition.broadcast();
            this.poll_close_lock.unlock();
        }

        pub fn waitForPollClose(this: *This) void {
            this.poll_close_lock.lock();
            defer this.poll_close_lock.unlock();
            while (!this.poll_close_complete) this.poll_close_condition.wait(&this.poll_close_lock);
        }

        pub fn onFinish(this: *This) void {
            const vm = this.event_loop.virtual_machine;
            const native_job_admitted = this.native_job_admitted;
            this.native_job_admitted = false;
            if (this.pollable_job.registered) {
                const previous = this.pollable_state.swap(.published, .acq_rel);
                bun.assert(previous == .worker);
                vm.native_pollable_work_pool_jobs.remove(&this.pollable_job);
            }
            this.event_loop.enqueueTaskConcurrent(this.concurrent_task.from(this, .manual_deinit));
            if (native_job_admitted) vm.native_work_pool_jobs.complete();
        }

        fn cancelPollableJobForShutdown(job: *jsc.VirtualMachine.NativePollableWorkPoolJob) void {
            const this: *This = @fieldParentPtr("pollable_job", job);
            const previous = this.pollable_state.cmpxchgStrong(.parked, .cancelling, .acq_rel, .acquire);
            bun.assert(previous == null);
            Context.cancelPollForShutdown(this.ctx, this);
            this.cancelForShutdown();
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
