const std = @import("std");
const builtin = @import("builtin");

/// Build task representing a single compilation unit
pub const BuildTask = struct {
    module_name: []const u8,
    file_path: []const u8,
    dependencies: []const []const u8,
    status: TaskStatus,
    start_time: i64 = 0,
    end_time: i64 = 0,
    worker_id: ?usize = null,

    pub const TaskStatus = enum {
        Pending,
        InProgress,
        Completed,
        Failed,
    };

    pub fn duration(self: BuildTask) i64 {
        return self.end_time - self.start_time;
    }
};

/// Build statistics for benchmarking
pub const BuildStats = struct {
    total_tasks: usize,
    completed_tasks: usize,
    failed_tasks: usize,
    cached_tasks: usize,
    total_time_ms: i64,
    parallel_speedup: f64,
    worker_utilization: []f64, // Per-worker utilization

    pub fn deinit(self: *BuildStats, allocator: std.mem.Allocator) void {
        allocator.free(self.worker_utilization);
    }

    pub fn print(self: BuildStats) void {
        std.debug.print("\n", .{});
        std.debug.print("╔════════════════════════════════════════════════╗\n", .{});
        std.debug.print("║          Parallel Build Statistics            ║\n", .{});
        std.debug.print("╠════════════════════════════════════════════════╣\n", .{});
        std.debug.print("║ Total tasks:        {d:>5}                      ║\n", .{self.total_tasks});
        std.debug.print("║ Completed:          {d:>5}                      ║\n", .{self.completed_tasks});
        std.debug.print("║ Failed:             {d:>5}                      ║\n", .{self.failed_tasks});
        std.debug.print("║ From cache:         {d:>5}                      ║\n", .{self.cached_tasks});
        std.debug.print("║ Total time:         {d:>5} ms                  ║\n", .{self.total_time_ms});
        std.debug.print("║ Parallel speedup:   {d:>5.2}x                   ║\n", .{self.parallel_speedup});
        std.debug.print("╠════════════════════════════════════════════════╣\n", .{});
        std.debug.print("║ Worker Utilization:                            ║\n", .{});
        for (self.worker_utilization, 0..) |util, i| {
            std.debug.print("║   Worker {d}:         {d:>5.1}%                      ║\n", .{ i, util * 100 });
        }
        std.debug.print("╚════════════════════════════════════════════════╝\n", .{});
    }
};

/// Work-stealing deque for load balancing
pub const WorkDeque = struct {
    tasks: std.ArrayList(*BuildTask),
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) WorkDeque {
        return .{
            .tasks = std.ArrayList(*BuildTask).init(allocator),
            .mutex = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WorkDeque) void {
        self.tasks.deinit();
    }

    /// Push task to the end (owner's side)
    pub fn push(self: *WorkDeque, task: *BuildTask) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.tasks.append(task);
    }

    /// Pop task from the end (owner's side)
    pub fn pop(self: *WorkDeque) ?*BuildTask {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.tasks.items.len == 0) return null;
        return self.tasks.pop();
    }

    /// Steal task from the front (thief's side)
    pub fn steal(self: *WorkDeque) ?*BuildTask {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.tasks.items.len == 0) return null;
        return self.tasks.orderedRemove(0);
    }

    pub fn len(self: *WorkDeque) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.tasks.items.len;
    }
};

/// Worker thread context
const WorkerContext = struct {
    worker_id: usize,
    builder: *ParallelBuilder,
    deque: *WorkDeque,
    all_deques: []*WorkDeque,
    work_time_ns: std.atomic.Value(u64),
};

/// Parallel build system for compiling multiple modules
pub const ParallelBuilder = struct {
    allocator: std.mem.Allocator,
    tasks: std.ArrayList(*BuildTask),
    num_threads: usize,
    work_deques: []WorkDeque,
    stats: BuildStats,
    verbose: bool = false,
    benchmark: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        num_threads: ?usize,
    ) !ParallelBuilder {
        const threads = num_threads orelse @max(1, std.Thread.getCpuCount() catch 4);

        const deques = try allocator.alloc(WorkDeque, threads);
        for (deques) |*deque| {
            deque.* = WorkDeque.init(allocator);
        }

        const worker_util = try allocator.alloc(f64, threads);
        @memset(worker_util, 0.0);

        return .{
            .allocator = allocator,
            .tasks = std.ArrayList(*BuildTask).init(allocator),
            .num_threads = threads,
            .work_deques = deques,
            .stats = .{
                .total_tasks = 0,
                .completed_tasks = 0,
                .failed_tasks = 0,
                .cached_tasks = 0,
                .total_time_ms = 0,
                .parallel_speedup = 1.0,
                .worker_utilization = worker_util,
            },
        };
    }

    pub fn deinit(self: *ParallelBuilder) void {
        for (self.tasks.items) |task| {
            self.allocator.free(task.module_name);
            self.allocator.free(task.file_path);
            for (task.dependencies) |dep| {
                self.allocator.free(dep);
            }
            self.allocator.free(task.dependencies);
            self.allocator.destroy(task);
        }
        self.tasks.deinit();

        for (self.work_deques) |*deque| {
            deque.deinit();
        }
        self.allocator.free(self.work_deques);

        self.stats.deinit(self.allocator);
    }

    /// Add a build task
    pub fn addTask(
        self: *ParallelBuilder,
        module_name: []const u8,
        file_path: []const u8,
        dependencies: []const []const u8,
    ) !void {
        const task = try self.allocator.create(BuildTask);

        const deps_copy = try self.allocator.alloc([]const u8, dependencies.len);
        for (dependencies, 0..) |dep, i| {
            deps_copy[i] = try self.allocator.dupe(u8, dep);
        }

        task.* = .{
            .module_name = try self.allocator.dupe(u8, module_name),
            .file_path = try self.allocator.dupe(u8, file_path),
            .dependencies = deps_copy,
            .status = .Pending,
        };

        try self.tasks.append(task);
    }

    /// Build all tasks in parallel with work stealing
    pub fn build(self: *ParallelBuilder) !void {
        if (self.tasks.items.len == 0) return;

        const start_time = std.time.milliTimestamp();

        if (self.verbose) {
            std.debug.print("Building {d} modules with {d} threads...\n", .{
                self.tasks.items.len,
                self.num_threads,
            });
        }

        self.stats.total_tasks = self.tasks.items.len;

        // Process all tasks in waves (by dependency level)
        var wave: usize = 0;
        while (self.hasPendingTasks()) {
            wave += 1;

            // Get ready tasks for this wave
            const ready_tasks = try self.getReadyTasks();
            defer self.allocator.free(ready_tasks);

            if (ready_tasks.len == 0) {
                // Circular dependency detected
                return error.CircularDependency;
            }

            if (self.verbose) {
                std.debug.print("Wave {d}: {d} tasks ready\n", .{ wave, ready_tasks.len });
            }

            // Distribute tasks to worker deques (round-robin)
            for (ready_tasks, 0..) |task, i| {
                const worker_id = i % self.num_threads;
                try self.work_deques[worker_id].push(task);
            }

            // Run parallel build for this wave
            try self.buildWaveParallel();
        }

        const end_time = std.time.milliTimestamp();
        self.stats.total_time_ms = end_time - start_time;

        // Calculate parallel speedup (estimate)
        var sequential_time: i64 = 0;
        for (self.tasks.items) |task| {
            sequential_time += task.duration();
        }
        if (self.stats.total_time_ms > 0) {
            self.stats.parallel_speedup = @as(f64, @floatFromInt(sequential_time)) / @as(f64, @floatFromInt(self.stats.total_time_ms));
        }

        // Check for failures
        for (self.tasks.items) |task| {
            if (task.status == .Failed) {
                self.stats.failed_tasks += 1;
            }
        }

        if (self.stats.failed_tasks > 0) {
            return error.BuildFailed;
        }

        if (self.verbose or self.benchmark) {
            self.stats.print();
        } else {
            std.debug.print("Built {d} modules in {d}ms ({d:.2}x speedup)\n", .{
                self.stats.completed_tasks,
                self.stats.total_time_ms,
                self.stats.parallel_speedup,
            });
        }
    }

    /// Build one wave of tasks in parallel
    fn buildWaveParallel(self: *ParallelBuilder) !void {
        const thread_count = self.num_threads;
        const threads = try self.allocator.alloc(std.Thread, thread_count);
        defer self.allocator.free(threads);

        var contexts = try self.allocator.alloc(WorkerContext, thread_count);
        defer self.allocator.free(contexts);

        // Create deque pointer array for work stealing
        var deque_ptrs = try self.allocator.alloc(*WorkDeque, thread_count);
        defer self.allocator.free(deque_ptrs);

        for (self.work_deques, 0..) |*deque, i| {
            deque_ptrs[i] = deque;
        }

        const wave_start = std.time.nanoTimestamp();

        // Spawn worker threads
        for (0..thread_count) |i| {
            contexts[i] = .{
                .worker_id = i,
                .builder = self,
                .deque = &self.work_deques[i],
                .all_deques = deque_ptrs,
                .work_time_ns = std.atomic.Value(u64).init(0),
            };
            threads[i] = try std.Thread.spawn(.{}, workerThread, .{&contexts[i]});
        }

        // Wait for all threads to complete
        for (threads) |thread| {
            thread.join();
        }

        const wave_end = std.time.nanoTimestamp();
        const wave_duration_ns = @as(u64, @intCast(wave_end - wave_start));

        // Calculate worker utilization
        for (contexts, 0..) |context, i| {
            const work_time = context.work_time_ns.load(.seq_cst);
            if (wave_duration_ns > 0) {
                self.stats.worker_utilization[i] = @as(f64, @floatFromInt(work_time)) / @as(f64, @floatFromInt(wave_duration_ns));
            }
        }
    }

    /// Worker thread function
    fn workerThread(context: *WorkerContext) void {
        const worker_id = context.worker_id;
        var work_time: u64 = 0;

        while (true) {
            // Try to get task from own deque
            const task = context.deque.pop() orelse blk: {
                // Try to steal from other workers
                var stolen: ?*BuildTask = null;
                for (context.all_deques, 0..) |other_deque, i| {
                    if (i == worker_id) continue; // Skip own deque
                    stolen = other_deque.steal();
                    if (stolen != null) break;
                }
                break :blk stolen orelse break; // No more work
            };

            const task_start = std.time.nanoTimestamp();

            // Build the task
            task.worker_id = worker_id;
            context.builder.buildTask(task) catch {
                task.status = .Failed;
            };

            const task_end = std.time.nanoTimestamp();
            work_time += @intCast(task_end - task_start);
        }

        context.work_time_ns.store(work_time, .seq_cst);
    }

    fn hasPendingTasks(self: *ParallelBuilder) bool {
        for (self.tasks.items) |task| {
            if (task.status == .Pending or task.status == .InProgress) {
                return true;
            }
        }
        return false;
    }

    fn getReadyTasks(self: *ParallelBuilder) ![]const *BuildTask {
        var ready = std.ArrayList(*BuildTask).init(self.allocator);
        defer ready.deinit();

        for (self.tasks.items) |task| {
            if (task.status != .Pending) continue;

            var dependencies_met = true;
            for (task.dependencies) |dep| {
                if (!self.isDependencyCompleted(dep)) {
                    dependencies_met = false;
                    break;
                }
            }

            if (dependencies_met) {
                try ready.append(task);
            }
        }

        return ready.toOwnedSlice();
    }

    fn isDependencyCompleted(self: *ParallelBuilder, dep_name: []const u8) bool {
        for (self.tasks.items) |task| {
            if (std.mem.eql(u8, task.module_name, dep_name)) {
                return task.status == .Completed;
            }
        }
        return true; // Not in task list, assume external/completed
    }

    fn buildTask(self: *ParallelBuilder, task: *BuildTask) !void {
        task.status = .InProgress;
        task.start_time = std.time.milliTimestamp();

        if (self.verbose) {
            std.debug.print("  [Worker {d}] Compiling {s}...\n", .{ task.worker_id orelse 0, task.module_name });
        }

        // Simulate compilation work
        // In a real implementation, this would:
        // 1. Check IR cache
        // 2. Lex and parse source file
        // 3. Type check
        // 4. Generate IR
        // 5. Optimize
        // 6. Generate machine code
        // 7. Cache result

        const file = std.fs.cwd().openFile(task.file_path, .{}) catch |err| {
            if (self.verbose) {
                std.debug.print("    [31m✗ Failed to open file: {any}[0m\n", .{err});
            }
            task.status = .Failed;
            task.end_time = std.time.milliTimestamp();
            return err;
        };
        defer file.close();

        const source = file.readToEndAlloc(self.allocator, 1024 * 1024 * 10) catch |err| {
            if (self.verbose) {
                std.debug.print("    [31m✗ Failed to read file: {any}[0m\n", .{err});
            }
            task.status = .Failed;
            task.end_time = std.time.milliTimestamp();
            return err;
        };
        defer self.allocator.free(source);

        // Simulate work (remove in real implementation)
        std.time.sleep(1_000_000); // 1ms per task

        task.status = .Completed;
        task.end_time = std.time.milliTimestamp();
        self.stats.completed_tasks += 1;

        if (self.verbose) {
            std.debug.print("    [32m✓ Compiled in {d}ms[0m\n", .{task.duration()});
        }
    }

    /// Analyze dependencies across all tasks
    pub fn analyzeDependencies(self: *ParallelBuilder) !void {
        std.debug.print("[1mDependency graph:[0m\n", .{});
        for (self.tasks.items) |task| {
            std.debug.print("  {s}", .{task.module_name});
            if (task.dependencies.len > 0) {
                std.debug.print(" -> ", .{});
                for (task.dependencies, 0..) |dep, i| {
                    if (i > 0) std.debug.print(", ", .{});
                    std.debug.print("{s}", .{dep});
                }
            }
            std.debug.print("\n", .{});
        }
    }
};
