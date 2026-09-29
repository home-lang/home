const std = @import("std");
const async = @import("async");

const AtomicBool = std.atomic.Value(bool);
const AtomicU64 = std.atomic.Value(u64);
const AtomicUsize = std.atomic.Value(usize);

const Probe = struct {
    runtime: *async.Runtime,
    seen_words: []AtomicU64,
    workers_seen: []AtomicBool,
    completed: AtomicUsize = .init(0),
    duplicates: AtomicUsize = .init(0),
};

const ProbeState = struct {
    probe: *Probe,
    task_index: usize,
};

const SpawnerState = struct {
    runtime: *async.Runtime,
    probe: *Probe,
    first_task: usize,
    states: []ProbeState,
    handles: []async.JoinHandle(usize),
    spawned: usize = 0,
    spawn_error: ?anyerror = null,
};

fn pollProbe(ptr: *anyopaque, _: *async.Context) async.PollResult(usize) {
    const state: *ProbeState = @ptrCast(@alignCast(ptr));
    const probe = state.probe;

    const word_index = state.task_index / 64;
    const mask = @as(u64, 1) << @intCast(state.task_index % 64);
    const previous = probe.seen_words[word_index].fetchOr(mask, .acq_rel);
    if (previous & mask != 0) _ = probe.duplicates.fetchAdd(1, .acq_rel);
    if (probe.runtime.currentWorkerIndex()) |worker_index| {
        probe.workers_seen[worker_index].store(true, .release);
    }
    _ = probe.completed.fetchAdd(1, .acq_rel);

    return .{ .Ready = state.task_index };
}

fn probeFuture(state: *ProbeState) async.Future(usize) {
    return .{
        .poll_fn = pollProbe,
        .state = @ptrCast(state),
    };
}

fn pollSpawner(ptr: *anyopaque, _: *async.Context) async.PollResult(usize) {
    const state: *SpawnerState = @ptrCast(@alignCast(ptr));

    for (state.states, state.handles, 0..) |*probe_state, *handle, offset| {
        probe_state.* = .{
            .probe = state.probe,
            .task_index = state.first_task + offset,
        };
        handle.* = state.runtime.spawn(usize, probeFuture(probe_state)) catch |err| {
            state.spawn_error = err;
            return .{ .Ready = state.spawned };
        };
        state.spawned += 1;
    }

    return .{ .Ready = state.spawned };
}

fn spawnerFuture(state: *SpawnerState) async.Future(usize) {
    return .{
        .poll_fn = pollSpawner,
        .state = @ptrCast(state),
    };
}

fn positiveEnv(allocator: std.mem.Allocator, name: []const u8, default_value: usize) !usize {
    const value = std.testing.environ.getAlloc(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return default_value,
        else => return err,
    };
    defer allocator.free(value);

    const parsed = try std.fmt.parseInt(usize, value, 10);
    if (parsed == 0) return error.ValueMustBePositive;
    return parsed;
}

test "runtime executes every stress task exactly once across every worker" {
    const allocator = std.testing.allocator;
    const task_count = try positiveEnv(allocator, "HOME_ASYNC_STRESS_TASKS", 1_000_000);
    const requested_batch_size = try positiveEnv(allocator, "HOME_ASYNC_STRESS_BATCH", 4_096);
    const batch_size = @min(task_count, requested_batch_size);

    const Task = async.task.Task(usize);
    const task_slot_size = @sizeOf(Task) + @alignOf(Task) - 1;
    const task_slots = try std.math.add(usize, batch_size, 1);
    const task_storage_len = try std.math.mul(usize, task_slots, task_slot_size);
    const task_storage = try allocator.alloc(u8, task_storage_len);
    defer allocator.free(task_storage);
    var task_pool = std.heap.FixedBufferAllocator.init(task_storage);

    var runtime = try async.Runtime.initWithTaskAllocator(
        allocator,
        task_pool.threadSafeAllocator(),
        0,
    );
    defer runtime.deinit();

    const rounded_task_count = try std.math.add(usize, task_count, 63);
    const seen_word_count = rounded_task_count / 64;
    const seen_words = try allocator.alloc(AtomicU64, seen_word_count);
    defer allocator.free(seen_words);
    for (seen_words) |*word| word.* = .init(0);

    const workers_seen = try allocator.alloc(AtomicBool, runtime.workerCount());
    defer allocator.free(workers_seen);
    for (workers_seen) |*seen| seen.* = .init(false);

    var probe = Probe{
        .runtime = &runtime,
        .seen_words = seen_words,
        .workers_seen = workers_seen,
    };

    const states = try allocator.alloc(ProbeState, batch_size);
    defer allocator.free(states);
    const handles = try allocator.alloc(async.JoinHandle(usize), batch_size);
    defer allocator.free(handles);

    const runtime_thread = try std.Thread.spawn(.{}, async.Runtime.run, .{&runtime});
    var runtime_joined = false;
    defer if (!runtime_joined) {
        runtime.requestShutdown();
        runtime_thread.join();
    };

    var base: usize = 0;
    while (base < task_count) {
        const count = @min(batch_size, task_count - base);
        var spawner_state = SpawnerState{
            .runtime = &runtime,
            .probe = &probe,
            .first_task = base,
            .states = states[0..count],
            .handles = handles[0..count],
        };
        const spawner_handle = try runtime.spawn(usize, spawnerFuture(&spawner_state));
        const spawned = try spawner_handle.await();
        spawner_handle.deinit();

        for (handles[0..spawned], 0..) |handle, offset| {
            const result = try handle.await();
            handle.deinit();
            try std.testing.expectEqual(base + offset, result);
        }
        if (spawner_state.spawn_error) |err| return err;
        try std.testing.expectEqual(count, spawned);

        // Every task and waker in this batch is gone, so the next batch can
        // reuse the same addresses. TSan still observes every access while
        // allocator metadata remains bounded by the in-flight window.
        task_pool.end_index = 0;
        base += count;
    }

    runtime.requestShutdown();
    runtime_thread.join();
    runtime_joined = true;

    try std.testing.expectEqual(task_count, probe.completed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), probe.duplicates.load(.acquire));
    for (seen_words, 0..) |*word, word_index| {
        const first_task = word_index * 64;
        const remaining = task_count - first_task;
        const expected = if (remaining >= 64)
            std.math.maxInt(u64)
        else
            (@as(u64, 1) << @intCast(remaining)) - 1;
        try std.testing.expectEqual(expected, word.load(.acquire));
    }
    for (workers_seen) |*seen| try std.testing.expect(seen.load(.acquire));

    std.debug.print(
        "async-runtime-stress: tasks={d} workers={d} batch={d}\n",
        .{ task_count, runtime.workerCount(), batch_size },
    );
}
