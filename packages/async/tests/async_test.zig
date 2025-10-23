const std = @import("std");
const testing = std.testing;

// Import will be provided by build.zig
const async_runtime = @import("async_runtime");

// Test Future initialization
test "Future - initialization" {
    const future = async_runtime.Future(i32).init();

    try testing.expect(future.state == .Pending);
    try testing.expect(future.result == null);
    try testing.expect(future.error_value == null);
}

// Test Future completion
test "Future - complete with value" {
    var future = async_runtime.Future(i32).init();

    future.complete(42);

    try testing.expect(future.state == .Completed);
    try testing.expect(future.result.? == 42);

    const result = try future.poll();
    try testing.expect(result.? == 42);
}

// Test Future failure
test "Future - fail with error" {
    var future = async_runtime.Future(i32).init();

    future.fail(error.TestError);

    try testing.expect(future.state == .Failed);
    try testing.expect(future.error_value.? == error.TestError);

    const result = future.poll();
    try testing.expectError(error.TestError, result);
}

// Test Future poll before completion
test "Future - poll pending returns null" {
    var future = async_runtime.Future(i32).init();

    const result = try future.poll();
    try testing.expect(result == null);
}

// Test AsyncRuntime initialization
test "AsyncRuntime - initialization" {
    const allocator = testing.allocator;

    var runtime = async_runtime.AsyncRuntime.init(allocator);
    defer runtime.deinit();

    try testing.expect(runtime.tasks.items.len == 0);
    try testing.expect(runtime.next_task_id == 0);
    try testing.expect(runtime.running == false);
}

// Test Task state transitions
test "Task - state transitions" {
    const allocator = testing.allocator;

    // Create a simple task
    const task = try allocator.create(async_runtime.Task);
    defer allocator.destroy(task);

    task.* = .{
        .id = 1,
        .state = .Pending,
        .poll_fn = struct {
            fn poll(t: *async_runtime.Task) anyerror!void {
                t.state = .Completed;
            }
        }.poll,
        .data = null,
    };

    try testing.expect(task.state == .Pending);

    try task.poll();

    try testing.expect(task.state == .Completed);
}

// Test multiple futures
test "Future - multiple concurrent futures" {
    var future1 = async_runtime.Future(i32).init();
    var future2 = async_runtime.Future([]const u8).init();
    var future3 = async_runtime.Future(bool).init();

    future1.complete(10);
    future2.complete("hello");
    future3.complete(true);

    const result1 = try future1.poll();
    const result2 = try future2.poll();
    const result3 = try future3.poll();

    try testing.expect(result1.? == 10);
    try testing.expectEqualStrings("hello", result2.?);
    try testing.expect(result3.? == true);
}

// Test Future with struct type
test "Future - with struct type" {
    const Point = struct {
        x: i32,
        y: i32,
    };

    var future = async_runtime.Future(Point).init();

    future.complete(.{ .x = 5, .y = 10 });

    const result = try future.poll();
    try testing.expect(result.?.x == 5);
    try testing.expect(result.?.y == 10);
}

// Test Waker mechanism
test "Waker - basic wake functionality" {
    var wake_called = false;

    const wake_fn = struct {
        fn wake(waker: *async_runtime.Waker) void {
            const called = @as(*bool, @ptrCast(@alignCast(waker.data.?)));
            called.* = true;
        }
    }.wake;

    var waker = async_runtime.Waker{
        .wake_fn = wake_fn,
        .data = @ptrCast(&wake_called),
    };

    waker.wake();

    try testing.expect(wake_called);
}

// Test Future with waker
test "Future - complete triggers waker" {
    var wake_called = false;

    const wake_fn = struct {
        fn wake(waker: *async_runtime.Waker) void {
            const called = @as(*bool, @ptrCast(@alignCast(waker.data.?)));
            called.* = true;
        }
    }.wake;

    var waker = async_runtime.Waker{
        .wake_fn = wake_fn,
        .data = @ptrCast(&wake_called),
    };

    var future = async_runtime.Future(i32).init();
    future.waker = &waker;

    future.complete(42);

    try testing.expect(wake_called);
    try testing.expect(future.result.? == 42);
}

// Test Future fail triggers waker
test "Future - fail triggers waker" {
    var wake_called = false;

    const wake_fn = struct {
        fn wake(waker: *async_runtime.Waker) void {
            const called = @as(*bool, @ptrCast(@alignCast(waker.data.?)));
            called.* = true;
        }
    }.wake;

    var waker = async_runtime.Waker{
        .wake_fn = wake_fn,
        .data = @ptrCast(&wake_called),
    };

    var future = async_runtime.Future(i32).init();
    future.waker = &waker;

    future.fail(error.TestFailed);

    try testing.expect(wake_called);
    try testing.expectError(error.TestFailed, future.poll());
}

// Test Task polling already completed task
test "Task - polling completed task does nothing" {
    const allocator = testing.allocator;

    const task = try allocator.create(async_runtime.Task);
    defer allocator.destroy(task);

    var poll_count: usize = 0;

    task.* = .{
        .id = 1,
        .state = .Completed,
        .poll_fn = struct {
            fn poll(t: *async_runtime.Task) anyerror!void {
                const count = @as(*usize, @ptrCast(@alignCast(t.data.?)));
                count.* += 1;
                _ = t.state;
            }
        }.poll,
        .data = @ptrCast(&poll_count),
    };

    try task.poll();

    // Poll count should be 0 because task was already completed
    try testing.expect(poll_count == 0);
}
