//! Work-stealing async executor and its core future/task primitives.

pub const future = @import("future.zig");
pub const task = @import("task.zig");
pub const runtime = @import("runtime.zig");
pub const concurrent_queue = @import("concurrent_queue.zig");
pub const work_stealing_deque = @import("work_stealing_deque.zig");
pub const parker = @import("parker.zig");

pub const Context = future.Context;
pub const Future = future.Future;
pub const PollResult = future.PollResult;
pub const Waker = future.Waker;
pub const JoinHandle = task.JoinHandle;
pub const RawTask = task.RawTask;
pub const Runtime = runtime.Runtime;

test {
    _ = future;
    _ = task;
    _ = runtime;
    _ = concurrent_queue;
    _ = work_stealing_deque;
    _ = parker;
}
