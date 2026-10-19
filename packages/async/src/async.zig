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
    _ = @import("preparation_gate.zig");
    _ = @import("completion_watermark.zig");
    _ = @import("completion_gate.zig");
    _ = future;
    _ = task;
    _ = runtime;
    _ = concurrent_queue;
    _ = work_stealing_deque;
    _ = parker;
}

/// Revision-aware event job gate; caller owns synchronization.
pub const CompletionGate = @import("completion_gate.zig").Gate;
/// Fixed-prefix FIFO completion; caller owns synchronization and storage.
pub const CompletionWatermark = @import("completion_watermark.zig").Watermark;
/// Cooperative preparation with cleanup before terminal cancellation.
pub const PreparationGate = @import("preparation_gate.zig").Gate;
