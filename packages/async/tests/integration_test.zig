const std = @import("std");
const testing = std.testing;

// Import async modules
const future_mod = @import("../src/future.zig");
const Future = future_mod.Future;
const Context = future_mod.Context;
const Waker = future_mod.Waker;

const runtime_mod = @import("../src/runtime.zig");
const Runtime = runtime_mod.Runtime;

const task_mod = @import("../src/task.zig");
const Task = task_mod.Task;
const JoinHandle = task_mod.JoinHandle;

const channel_mod = @import("../src/channel.zig");
const Channel = channel_mod.Channel;

const timer_mod = @import("../src/timer.zig");
const sleep = timer_mod.sleep;

// =================================================================================
//                           INTEGRATION TESTS
// =================================================================================

test "Integration - spawn and await simple task" {
    const allocator = testing.allocator;

    var runtime = try Runtime.init(allocator, 2);
    defer runtime.deinit();

    var fut = try future_mod.ready(i32, 42, allocator);
    const handle = try runtime.spawn(i32, fut);

    // Start runtime in background
    const rt_thread = try std.Thread.spawn(.{}, Runtime.run, .{&runtime});

    // Give it time to complete
    std.time.sleep(10 * std.time.ns_per_ms);

    runtime.shutdown.store(true, .Release);
    for (runtime.workers) |*worker| {
        worker.unpark();
    }
    rt_thread.join();

    // Get result
    if (handle.tryGet()) |result| {
        try testing.expectEqual(@as(i32, 42), result);
    }

    allocator.destroy(@as(*anyopaque, @ptrCast(fut.state)));
}

test "Integration - multiple concurrent tasks" {
    const allocator = testing.allocator;

    var runtime = try Runtime.init(allocator, 4);
    defer runtime.deinit();

    var handles = std.ArrayList(JoinHandle(i32)).init(allocator);
    defer handles.deinit();

    // Spawn 10 tasks
    var i: i32 = 0;
    while (i < 10) : (i += 1) {
        var fut = try future_mod.ready(i32, i * 10, allocator);
        const handle = try runtime.spawn(i32, fut);
        try handles.append(handle);
    }

    // Run runtime
    const rt_thread = try std.Thread.spawn(.{}, Runtime.run, .{&runtime});

    std.time.sleep(50 * std.time.ns_per_ms);

    runtime.shutdown.store(true, .Release);
    for (runtime.workers) |*worker| {
        worker.unpark();
    }
    rt_thread.join();

    // Cleanup
    i = 0;
    while (i < 10) : (i += 1) {
        const handle = handles.items[@intCast(i)];
        allocator.destroy(@as(*anyopaque, @ptrCast(handle.task.future.state)));
    }
}

test "Integration - future join" {
    const allocator = testing.allocator;

    var fut1 = try future_mod.ready(i32, 10, allocator);
    defer allocator.destroy(@as(*anyopaque, @ptrCast(fut1.state)));

    var fut2 = try future_mod.ready(i32, 20, allocator);
    defer allocator.destroy(@as(*anyopaque, @ptrCast(fut2.state)));

    var joined = try future_mod.join(i32, i32, allocator, fut1, fut2);
    defer allocator.destroy(@as(*anyopaque, @ptrCast(joined.state)));

    const waker = Waker{
        .data = undefined,
        .vtable = &.{
            .wake = struct {
                fn wake(_: *anyopaque) void {}
            }.wake,
            .wake_by_ref = struct {
                fn wake(_: *anyopaque) void {}
            }.wake,
            .clone = struct {
                fn clone(ptr: *anyopaque) *anyopaque {
                    return ptr;
                }
            }.clone,
            .drop = struct {
                fn drop(_: *anyopaque) void {}
            }.drop,
        },
    };

    var ctx = Context.init(waker);
    const result = joined.poll(&ctx);

    try testing.expect(result.isReady());
    try testing.expectEqual(@as(i32, 10), result.Ready[0]);
    try testing.expectEqual(@as(i32, 20), result.Ready[1]);
}

test "Integration - future select" {
    const allocator = testing.allocator;

    var fut1 = try future_mod.ready(i32, 42, allocator);
    defer allocator.destroy(@as(*anyopaque, @ptrCast(fut1.state)));

    var fut2 = try future_mod.pending(i32, allocator);
    defer allocator.destroy(@as(*anyopaque, @ptrCast(fut2.state)));

    var selected = try future_mod.select(i32, i32, allocator, fut1, fut2);
    defer allocator.destroy(@as(*anyopaque, @ptrCast(selected.state)));

    const waker = Waker{
        .data = undefined,
        .vtable = &.{
            .wake = struct {
                fn wake(_: *anyopaque) void {}
            }.wake,
            .wake_by_ref = struct {
                fn wake(_: *anyopaque) void {}
            }.wake,
            .clone = struct {
                fn clone(ptr: *anyopaque) *anyopaque {
                    return ptr;
                }
            }.clone,
            .drop = struct {
                fn drop(_: *anyopaque) void {}
            }.drop,
        },
    };

    var ctx = Context.init(waker);
    const result = selected.poll(&ctx);

    try testing.expect(result.isReady());
    try testing.expectEqual(@as(i32, 42), result.Ready.First);
}

test "Integration - channel send and receive" {
    const allocator = testing.allocator;

    var chan = try Channel(i32).init(allocator);
    defer chan.deinit();

    // Send some values
    try chan.trySend(10);
    try chan.trySend(20);
    try chan.trySend(30);

    // Receive them
    try testing.expectEqual(@as(i32, 10), try chan.tryRecv());
    try testing.expectEqual(@as(i32, 20), try chan.tryRecv());
    try testing.expectEqual(@as(i32, 30), try chan.tryRecv());
}

test "Integration - work stealing between workers" {
    const allocator = testing.allocator;

    // Create runtime with multiple workers
    var runtime = try Runtime.init(allocator, 4);
    defer runtime.deinit();

    var handles = std.ArrayList(JoinHandle(i32)).init(allocator);
    defer handles.deinit();

    // Spawn many tasks to trigger work stealing
    var i: i32 = 0;
    while (i < 100) : (i += 1) {
        var fut = try future_mod.ready(i32, i, allocator);
        const handle = try runtime.spawn(i32, fut);
        try handles.append(handle);
    }

    // Run runtime
    const rt_thread = try std.Thread.spawn(.{}, Runtime.run, .{&runtime});

    std.time.sleep(100 * std.time.ns_per_ms);

    runtime.shutdown.store(true, .Release);
    for (runtime.workers) |*worker| {
        worker.unpark();
    }
    rt_thread.join();

    // Verify all tasks ran
    var completed: usize = 0;
    for (handles.items) |handle| {
        if (handle.tryGet() != null) {
            completed += 1;
        }
    }

    // Most should have completed
    try testing.expect(completed > 90);

    // Cleanup
    i = 0;
    while (i < 100) : (i += 1) {
        const handle = handles.items[@intCast(i)];
        allocator.destroy(@as(*anyopaque, @ptrCast(handle.task.future.state)));
    }
}

// =================================================================================
//                             EXAMPLE USAGE
// =================================================================================

/// Example: Async computation
fn computeValue(value: i32, allocator: std.mem.Allocator) !Future(i32) {
    return future_mod.ready(i32, value * 2, allocator);
}

/// Example: Producer-consumer with channels
test "Example - producer consumer" {
    const allocator = testing.allocator;

    var chan = try Channel(i32).init(allocator);
    defer chan.deinit();

    const ProducerContext = struct {
        chan: *Channel(i32),
    };

    const ConsumerContext = struct {
        chan: *Channel(i32),
        sum: *i32,
    };

    // Producer function
    const producer = struct {
        fn run(ctx: *ProducerContext) void {
            var i: i32 = 1;
            while (i <= 10) : (i += 1) {
                ctx.chan.trySend(i) catch {};
                std.time.sleep(std.time.ns_per_ms);
            }
            ctx.chan.close();
        }
    }.run;

    // Consumer function
    const consumer = struct {
        fn run(ctx: *ConsumerContext) void {
            while (true) {
                if (ctx.chan.tryRecv()) |value| {
                    ctx.sum.* += value;
                } else |_| {
                    break;
                }
                std.time.sleep(std.time.ns_per_ms);
            }
        }
    }.run;

    var sum: i32 = 0;

    var prod_ctx = ProducerContext{ .chan = &chan };
    var cons_ctx = ConsumerContext{ .chan = &chan, .sum = &sum };

    const prod_thread = try std.Thread.spawn(.{}, producer, .{&prod_ctx});
    const cons_thread = try std.Thread.spawn(.{}, consumer, .{&cons_ctx});

    prod_thread.join();
    cons_thread.join();

    // Sum should be 1+2+...+10 = 55
    try testing.expectEqual(@as(i32, 55), sum);
}

/// Example: Concurrent task execution
test "Example - concurrent tasks" {
    const allocator = testing.allocator;

    var runtime = try Runtime.init(allocator, 4);
    defer runtime.deinit();

    // Create multiple computation tasks
    var fut1 = try computeValue(10, allocator);
    var fut2 = try computeValue(20, allocator);
    var fut3 = try computeValue(30, allocator);

    const handle1 = try runtime.spawn(i32, fut1);
    const handle2 = try runtime.spawn(i32, fut2);
    const handle3 = try runtime.spawn(i32, fut3);

    // Run runtime
    const rt_thread = try std.Thread.spawn(.{}, Runtime.run, .{&runtime});

    std.time.sleep(20 * std.time.ns_per_ms);

    runtime.shutdown.store(true, .Release);
    for (runtime.workers) |*worker| {
        worker.unpark();
    }
    rt_thread.join();

    // Get results
    if (handle1.tryGet()) |r1| {
        if (handle2.tryGet()) |r2| {
            if (handle3.tryGet()) |r3| {
                try testing.expectEqual(@as(i32, 20), r1);
                try testing.expectEqual(@as(i32, 40), r2);
                try testing.expectEqual(@as(i32, 60), r3);
            }
        }
    }

    allocator.destroy(@as(*anyopaque, @ptrCast(fut1.state)));
    allocator.destroy(@as(*anyopaque, @ptrCast(fut2.state)));
    allocator.destroy(@as(*anyopaque, @ptrCast(fut3.state)));
}
