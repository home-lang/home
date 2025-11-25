const std = @import("std");
const runtime = @import("runtime.zig");
const task_mod = @import("task.zig");
const future_mod = @import("future.zig");

/// Structured concurrency primitives
///
/// Ensures tasks have clear lifetime and cannot outlive their scope.
/// Inspired by Swift's Task Groups and Kotlin's coroutineScope.

/// Task scope for structured concurrency
pub fn TaskScope(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        runtime: *runtime.Runtime,
        tasks: std.ArrayList(task_mod.JoinHandle(T)),
        cancelled: std.atomic.Value(bool),
        errors: std.ArrayList(anyerror),
        mutex: std.Thread.Mutex,

        pub fn init(allocator: std.mem.Allocator, rt: *runtime.Runtime) Self {
            return .{
                .allocator = allocator,
                .runtime = rt,
                .tasks = std.ArrayList(task_mod.JoinHandle(T)).init(allocator),
                .cancelled = std.atomic.Value(bool).init(false),
                .errors = std.ArrayList(anyerror).init(allocator),
                .mutex = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.tasks.deinit();
            self.errors.deinit();
        }

        /// Spawn a task within this scope
        pub fn spawn(self: *Self, fut: future_mod.Future(T)) !void {
            if (self.cancelled.load(.acquire)) {
                return error.ScopeCancelled;
            }

            const handle = try self.runtime.spawn(T, fut);

            self.mutex.lock();
            defer self.mutex.unlock();

            try self.tasks.append(handle);
        }

        /// Wait for all tasks to complete
        pub fn join(self: *Self) ![]T {
            var results = try self.allocator.alloc(T, self.tasks.items.len);
            errdefer self.allocator.free(results);

            for (self.tasks.items, 0..) |handle, i| {
                results[i] = handle.await() catch |err| {
                    self.mutex.lock();
                    defer self.mutex.unlock();
                    try self.errors.append(err);
                    continue;
                };
            }

            if (self.errors.items.len > 0) {
                return error.TaskFailed;
            }

            return results;
        }

        /// Wait for first task to complete
        pub fn raceAll(self: *Self) !T {
            while (true) {
                for (self.tasks.items) |handle| {
                    if (handle.tryGet()) |result| {
                        // Cancel remaining tasks
                        self.cancelAll();
                        return result;
                    }
                }

                // Brief sleep before retrying
                std.time.sleep(1 * std.time.ns_per_ms);
            }
        }

        /// Cancel all tasks in the scope
        pub fn cancelAll(self: *Self) void {
            self.cancelled.store(true, .release);

            for (self.tasks.items) |*handle| {
                handle.cancel();
            }
        }
    };
}

/// Nursery for spawning child tasks
///
/// All tasks must complete before the nursery closes.
/// If any task fails, all tasks are cancelled.
pub const Nursery = struct {
    allocator: std.mem.Allocator,
    runtime: *runtime.Runtime,
    tasks: std.ArrayList(AnyJoinHandle),
    cancelled: std.atomic.Value(bool),
    mutex: std.Thread.Mutex,

    const AnyJoinHandle = struct {
        cancel_fn: *const fn (*anyopaque) void,
        is_done_fn: *const fn (*const anyopaque) bool,
        ptr: *anyopaque,
    };

    pub fn init(allocator: std.mem.Allocator, rt: *runtime.Runtime) Nursery {
        return .{
            .allocator = allocator,
            .runtime = rt,
            .tasks = std.ArrayList(AnyJoinHandle).init(allocator),
            .cancelled = std.atomic.Value(bool).init(false),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Nursery) void {
        self.tasks.deinit();
    }

    /// Spawn a task in the nursery
    pub fn spawn(self: *Nursery, comptime T: type, fut: future_mod.Future(T)) !*task_mod.JoinHandle(T) {
        if (self.cancelled.load(.acquire)) {
            return error.NurseryCancelled;
        }

        const handle = try self.allocator.create(task_mod.JoinHandle(T));
        handle.* = try self.runtime.spawn(T, fut);

        const any_handle = AnyJoinHandle{
            .cancel_fn = struct {
                fn cancel(ptr: *anyopaque) void {
                    const h = @as(*task_mod.JoinHandle(T), @ptrCast(@alignCast(ptr)));
                    h.cancel();
                }
            }.cancel,
            .is_done_fn = struct {
                fn is_done(ptr: *const anyopaque) bool {
                    const h = @as(*const task_mod.JoinHandle(T), @ptrCast(@alignCast(ptr)));
                    return h.tryGet() != null;
                }
            }.is_done,
            .ptr = @ptrCast(handle),
        };

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.tasks.append(any_handle);

        return handle;
    }

    /// Wait for all tasks to complete
    pub fn wait(self: *Nursery) !void {
        while (true) {
            var all_done = true;

            self.mutex.lock();
            defer self.mutex.unlock();

            for (self.tasks.items) |handle| {
                if (!handle.is_done_fn(handle.ptr)) {
                    all_done = false;
                    break;
                }
            }

            if (all_done) {
                break;
            }

            std.time.sleep(1 * std.time.ns_per_ms);
        }
    }

    /// Cancel all tasks
    pub fn cancel(self: *Nursery) void {
        self.cancelled.store(true, .release);

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.tasks.items) |handle| {
            handle.cancel_fn(handle.ptr);
        }
    }
};

/// Scope function for automatic cleanup
pub fn withScope(
    comptime T: type,
    allocator: std.mem.Allocator,
    rt: *runtime.Runtime,
    func: *const fn (*TaskScope(T)) anyerror![]T,
) ![]T {
    var scope = TaskScope(T).init(allocator, rt);
    defer scope.deinit();

    return func(&scope);
}

/// Nursery scope with automatic cleanup
pub fn withNursery(
    allocator: std.mem.Allocator,
    rt: *runtime.Runtime,
    func: *const fn (*Nursery) anyerror!void,
) !void {
    var nursery = Nursery.init(allocator, rt);
    defer nursery.deinit();

    func(&nursery) catch |err| {
        nursery.cancel();
        return err;
    };

    try nursery.wait();
}

/// Task group for parallel operations
pub fn TaskGroup(comptime T: type) type {
    return struct {
        const Self = @This();

        scope: TaskScope(T),
        results: std.ArrayList(T),

        pub fn init(allocator: std.mem.Allocator, rt: *runtime.Runtime) Self {
            return .{
                .scope = TaskScope(T).init(allocator, rt),
                .results = std.ArrayList(T).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.scope.deinit();
            self.results.deinit();
        }

        /// Add a task to the group
        pub fn add(self: *Self, fut: future_mod.Future(T)) !void {
            try self.scope.spawn(fut);
        }

        /// Add multiple tasks
        pub fn addAll(self: *Self, futures: []future_mod.Future(T)) !void {
            for (futures) |fut| {
                try self.add(fut);
            }
        }

        /// Wait for all and collect results
        pub fn waitAll(self: *Self) ![]T {
            return self.scope.join();
        }

        /// Wait for first result
        pub fn waitAny(self: *Self) !T {
            return self.scope.raceAll();
        }

        /// Process results as they complete
        pub fn forEach(self: *Self, processor: *const fn (T) void) !void {
            const results = try self.waitAll();
            defer self.scope.allocator.free(results);

            for (results) |result| {
                processor(result);
            }
        }
    };
}

/// Parallel map operation
pub fn parallelMap(
    comptime T: type,
    comptime R: type,
    allocator: std.mem.Allocator,
    rt: *runtime.Runtime,
    items: []const T,
    mapper: *const fn (T) R,
) ![]R {
    var group = TaskGroup(R).init(allocator, rt);
    defer group.deinit();

    for (items) |item| {
        const mapped_fut = future_mod.ready(R, mapper(item), allocator) catch unreachable;
        try group.add(mapped_fut);
    }

    return group.waitAll();
}

/// Parallel filter operation
pub fn parallelFilter(
    comptime T: type,
    allocator: std.mem.Allocator,
    rt: *runtime.Runtime,
    items: []const T,
    predicate: *const fn (T) bool,
) ![]T {
    var group = TaskGroup(bool).init(allocator, rt);
    defer group.deinit();

    for (items) |item| {
        const pred_fut = future_mod.ready(bool, predicate(item), allocator) catch unreachable;
        try group.add(pred_fut);
    }

    const results = try group.waitAll();
    defer allocator.free(results);

    var filtered = std.ArrayList(T).init(allocator);
    for (items, results) |item, keep| {
        if (keep) {
            try filtered.append(item);
        }
    }

    return filtered.toOwnedSlice();
}

/// Timeout wrapper for futures
pub fn timeout(
    comptime T: type,
    allocator: std.mem.Allocator,
    rt: *runtime.Runtime,
    duration_ms: i64,
    fut: future_mod.Future(T),
) !T {
    var scope = TaskScope(T).init(allocator, rt);
    defer scope.deinit();

    // Spawn the actual future
    try scope.spawn(fut);

    // Spawn timeout future
    const timeout_fut = future_mod.delay(T, @as(T, undefined), duration_ms, allocator) catch unreachable;
    try scope.spawn(timeout_fut);

    // Race them
    return scope.raceAll() catch error.Timeout;
}

/// Retry wrapper with exponential backoff
pub fn retry(
    comptime T: type,
    allocator: std.mem.Allocator,
    rt: *runtime.Runtime,
    max_attempts: usize,
    initial_delay_ms: i64,
    create_future: *const fn () anyerror!future_mod.Future(T),
) !T {
    var attempt: usize = 0;
    var delay = initial_delay_ms;

    while (attempt < max_attempts) : (attempt += 1) {
        const fut = create_future() catch |err| {
            if (attempt + 1 == max_attempts) return err;
            continue;
        };

        const handle = rt.spawn(T, fut) catch |err| {
            if (attempt + 1 == max_attempts) return err;

            // Wait before retry
            std.time.sleep(@intCast(delay * std.time.ns_per_ms));
            delay *= 2; // Exponential backoff

            continue;
        };

        const result = handle.await() catch |err| {
            if (attempt + 1 == max_attempts) return err;

            // Wait before retry
            std.time.sleep(@intCast(delay * std.time.ns_per_ms));
            delay *= 2; // Exponential backoff

            continue;
        };

        return result;
    }

    return error.MaxAttemptsReached;
}

/// Select between multiple futures
pub fn select(
    comptime T: type,
    allocator: std.mem.Allocator,
    rt: *runtime.Runtime,
    futures: []future_mod.Future(T),
) !T {
    var scope = TaskScope(T).init(allocator, rt);
    defer scope.deinit();

    for (futures) |fut| {
        try scope.spawn(fut);
    }

    return scope.raceAll();
}
