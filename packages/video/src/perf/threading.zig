// Home Video Library - Multi-threading Support
// Thread pool and parallel processing for video operations

const std = @import("std");
const core = @import("../core.zig");

/// Thread pool for video processing
pub const ThreadPool = struct {
    threads: []std.Thread,
    allocator: std.mem.Allocator,
    work_queue: WorkQueue,
    shutdown: std.atomic.Value(bool),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, thread_count: ?usize) !Self {
        const count = thread_count orelse std.Thread.getCpuCount() catch 4;

        var threads = try allocator.alloc(std.Thread, count);
        errdefer allocator.free(threads);

        var work_queue = try WorkQueue.init(allocator);
        errdefer work_queue.deinit();

        var shutdown = std.atomic.Value(bool).init(false);

        // Start worker threads
        for (threads, 0..) |*thread, i| {
            thread.* = try std.Thread.spawn(.{}, workerThread, .{ &work_queue, &shutdown });
            _ = i;
        }

        return .{
            .threads = threads,
            .allocator = allocator,
            .work_queue = work_queue,
            .shutdown = shutdown,
        };
    }

    pub fn deinit(self: *Self) void {
        // Signal shutdown
        self.shutdown.store(true, .release);

        // Wake all threads
        self.work_queue.notifyAll();

        // Join all threads
        for (self.threads) |thread| {
            thread.join();
        }

        self.allocator.free(self.threads);
        self.work_queue.deinit();
    }

    pub fn submit(self: *Self, work: WorkItem) !void {
        try self.work_queue.push(work);
    }

    pub fn wait(self: *Self) void {
        self.work_queue.waitEmpty();
    }

    fn workerThread(queue: *WorkQueue, shutdown: *std.atomic.Value(bool)) void {
        while (!shutdown.load(.acquire)) {
            if (queue.pop()) |work| {
                work.execute();
            } else {
                // Queue is empty, wait for work
                queue.wait();
            }
        }
    }
};

/// Work queue for thread pool
const WorkQueue = struct {
    items: std.ArrayList(WorkItem),
    mutex: std.Thread.Mutex,
    condition: std.Thread.Condition,
    allocator: std.mem.Allocator,

    const Self = @This();

    fn init(allocator: std.mem.Allocator) !Self {
        return .{
            .items = std.ArrayList(WorkItem).init(allocator),
            .mutex = .{},
            .condition = .{},
            .allocator = allocator,
        };
    }

    fn deinit(self: *Self) void {
        self.items.deinit();
    }

    fn push(self: *Self, item: WorkItem) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.items.append(item);
        self.condition.signal();
    }

    fn pop(self: *Self) ?WorkItem {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.items.items.len > 0) {
            return self.items.orderedRemove(0);
        }

        return null;
    }

    fn wait(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.condition.wait(&self.mutex);
    }

    fn notifyAll(self: *Self) void {
        self.condition.broadcast();
    }

    fn waitEmpty(self: *Self) void {
        while (true) {
            self.mutex.lock();
            const is_empty = self.items.items.len == 0;
            self.mutex.unlock();

            if (is_empty) break;

            std.time.sleep(1_000_000); // 1ms
        }
    }
};

/// Work item for thread pool
pub const WorkItem = struct {
    function: *const fn (*anyopaque) void,
    context: *anyopaque,

    pub fn execute(self: WorkItem) void {
        self.function(self.context);
    }
};

/// Parallel frame processor
pub const ParallelFrameProcessor = struct {
    pool: *ThreadPool,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, pool: *ThreadPool) Self {
        return .{
            .allocator = allocator,
            .pool = pool,
        };
    }

    pub fn processRows(self: *Self, frame: *core.VideoFrame, row_func: *const fn ([]u8, usize) void) !void {
        const height = frame.height;
        const rows_per_thread = @max(1, height / self.pool.threads.len);

        var tasks_submitted: usize = 0;
        var row: usize = 0;

        while (row < height) : (row += rows_per_thread) {
            const end_row = @min(row + rows_per_thread, height);

            const ctx = try self.allocator.create(RowContext);
            ctx.* = .{
                .frame = frame,
                .start_row = row,
                .end_row = end_row,
                .row_func = row_func,
            };

            try self.pool.submit(.{
                .function = processRowRange,
                .context = ctx,
            });

            tasks_submitted += 1;
        }

        self.pool.wait();
    }

    const RowContext = struct {
        frame: *core.VideoFrame,
        start_row: usize,
        end_row: usize,
        row_func: *const fn ([]u8, usize) void,
    };

    fn processRowRange(ctx_ptr: *anyopaque) void {
        const ctx: *RowContext = @ptrCast(@alignCast(ctx_ptr));
        defer ctx.frame.allocator.destroy(ctx);

        var y = ctx.start_row;
        while (y < ctx.end_row) : (y += 1) {
            const row_start = y * ctx.frame.width;
            const row_end = row_start + ctx.frame.width;
            ctx.row_func(ctx.frame.data[0][row_start..row_end], y);
        }
    }
};

/// Parallel batch processor for multiple frames
pub const BatchProcessor = struct {
    pool: *ThreadPool,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, pool: *ThreadPool) Self {
        return .{
            .allocator = allocator,
            .pool = pool,
        };
    }

    pub fn processFrames(
        self: *Self,
        frames: []*core.VideoFrame,
        frame_func: *const fn (*core.VideoFrame, usize) anyerror!void,
    ) !void {
        for (frames, 0..) |frame, idx| {
            const ctx = try self.allocator.create(FrameContext);
            ctx.* = .{
                .frame = frame,
                .index = idx,
                .frame_func = frame_func,
                .allocator = self.allocator,
            };

            try self.pool.submit(.{
                .function = processFrame,
                .context = ctx,
            });
        }

        self.pool.wait();
    }

    const FrameContext = struct {
        frame: *core.VideoFrame,
        index: usize,
        frame_func: *const fn (*core.VideoFrame, usize) anyerror!void,
        allocator: std.mem.Allocator,
    };

    fn processFrame(ctx_ptr: *anyopaque) void {
        const ctx: *FrameContext = @ptrCast(@alignCast(ctx_ptr));
        defer ctx.allocator.destroy(ctx);

        ctx.frame_func(ctx.frame, ctx.index) catch |err| {
            std.debug.print("Error processing frame {}: {}\n", .{ ctx.index, err });
        };
    }
};

/// Lock-free ring buffer for producer-consumer pattern
pub fn RingBuffer(comptime T: type, comptime size: usize) type {
    return struct {
        buffer: [size]T,
        read_pos: std.atomic.Value(usize),
        write_pos: std.atomic.Value(usize),

        const Self = @This();

        pub fn init() Self {
            return .{
                .buffer = undefined,
                .read_pos = std.atomic.Value(usize).init(0),
                .write_pos = std.atomic.Value(usize).init(0),
            };
        }

        pub fn push(self: *Self, item: T) bool {
            const write_pos = self.write_pos.load(.acquire);
            const next_write = (write_pos + 1) % size;

            if (next_write == self.read_pos.load(.acquire)) {
                return false; // Buffer full
            }

            self.buffer[write_pos] = item;
            self.write_pos.store(next_write, .release);
            return true;
        }

        pub fn pop(self: *Self) ?T {
            const read_pos = self.read_pos.load(.acquire);

            if (read_pos == self.write_pos.load(.acquire)) {
                return null; // Buffer empty
            }

            const item = self.buffer[read_pos];
            const next_read = (read_pos + 1) % size;
            self.read_pos.store(next_read, .release);
            return item;
        }

        pub fn isEmpty(self: *Self) bool {
            return self.read_pos.load(.acquire) == self.write_pos.load(.acquire);
        }

        pub fn isFull(self: *Self) bool {
            const write_pos = self.write_pos.load(.acquire);
            const next_write = (write_pos + 1) % size;
            return next_write == self.read_pos.load(.acquire);
        }
    };
}

/// Parallel pipeline for video processing
pub const Pipeline = struct {
    stages: std.ArrayList(Stage),
    pool: *ThreadPool,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub const Stage = struct {
        name: []const u8,
        process: *const fn (*core.VideoFrame) anyerror!void,
    };

    pub fn init(allocator: std.mem.Allocator, pool: *ThreadPool) Self {
        return .{
            .stages = std.ArrayList(Stage).init(allocator),
            .pool = pool,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stages.deinit();
    }

    pub fn addStage(self: *Self, stage: Stage) !void {
        try self.stages.append(stage);
    }

    pub fn execute(self: *Self, frame: *core.VideoFrame) !void {
        for (self.stages.items) |stage| {
            try stage.process(frame);
        }
    }
};
