const std = @import("std");

/// Queue connection types
pub const ConnectionType = enum {
    sync,
    database,
    redis,
    memory,
};

/// Job status
pub const JobStatus = enum {
    pending,
    processing,
    completed,
    failed,
    retrying,
};

/// Job structure
pub const Job = struct {
    id: []const u8,
    queue: []const u8,
    payload: []const u8,
    attempts: u32,
    max_attempts: u32,
    delay: ?i64, // Delay in seconds
    status: JobStatus,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, queue: []const u8, payload: []const u8) !*Job {
        const job = try allocator.create(Job);

        // Generate simple ID
        var buf: [32]u8 = undefined;
        const timestamp = std.time.timestamp();
        const id = try std.fmt.bufPrint(&buf, "job_{d}", .{timestamp});

        job.* = Job{
            .id = try allocator.dupe(u8, id),
            .queue = try allocator.dupe(u8, queue),
            .payload = try allocator.dupe(u8, payload),
            .attempts = 0,
            .max_attempts = 3,
            .delay = null,
            .status = .pending,
            .allocator = allocator,
        };

        return job;
    }

    pub fn deinit(self: *Job) void {
        self.allocator.free(self.id);
        self.allocator.free(self.queue);
        self.allocator.free(self.payload);
        self.allocator.destroy(self);
    }

    pub fn incrementAttempts(self: *Job) void {
        self.attempts += 1;
        if (self.attempts < self.max_attempts) {
            self.status = .retrying;
        } else {
            self.status = .failed;
        }
    }

    pub fn markAsProcessing(self: *Job) void {
        self.status = .processing;
    }

    pub fn markAsCompleted(self: *Job) void {
        self.status = .completed;
    }

    pub fn markAsFailed(self: *Job) void {
        self.status = .failed;
    }

    pub fn canRetry(self: *Job) bool {
        return self.attempts < self.max_attempts;
    }
};

/// Queue configuration
pub const QueueConfig = struct {
    connection: ConnectionType,
    default_queue: []const u8,
    retry_after: i64, // Seconds
    max_jobs: usize,

    pub fn default() QueueConfig {
        return QueueConfig{
            .connection = .memory,
            .default_queue = "default",
            .retry_after = 90,
            .max_jobs = 1000,
        };
    }
};

/// Queue manager
pub const Queue = struct {
    config: QueueConfig,
    jobs: std.ArrayList(*Job),
    pending_jobs: std.ArrayList(*Job),
    failed_jobs: std.ArrayList(*Job),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, config: QueueConfig) Queue {
        return Queue{
            .config = config,
            .jobs = std.ArrayList(*Job){},
            .pending_jobs = std.ArrayList(*Job){},
            .failed_jobs = std.ArrayList(*Job){},
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *Queue) void {
        // Clean up all jobs from the master list only
        // (pending_jobs and failed_jobs contain pointers to the same jobs)
        for (self.jobs.items) |job| {
            job.deinit();
        }

        self.jobs.deinit(self.allocator);
        self.pending_jobs.deinit(self.allocator);
        self.failed_jobs.deinit(self.allocator);
    }

    /// Dispatch a job to the queue
    pub fn dispatch(self: *Queue, queue_name: []const u8, payload: []const u8) !*Job {
        self.mutex.lock();
        defer self.mutex.unlock();

        const job = try Job.init(self.allocator, queue_name, payload);
        try self.jobs.append(self.allocator, job);
        try self.pending_jobs.append(self.allocator, job);

        return job;
    }

    /// Dispatch a job synchronously (execute immediately)
    pub fn dispatchSync(self: *Queue, queue_name: []const u8, payload: []const u8) !void {
        const job = try Job.init(self.allocator, queue_name, payload);
        defer job.deinit();

        job.markAsProcessing();
        // Execute immediately
        job.markAsCompleted();
    }

    /// Dispatch a job with delay
    pub fn dispatchAfter(self: *Queue, delay_seconds: i64, queue_name: []const u8, payload: []const u8) !*Job {
        self.mutex.lock();
        defer self.mutex.unlock();

        const job = try Job.init(self.allocator, queue_name, payload);
        job.delay = delay_seconds;

        try self.jobs.append(self.allocator, job);
        try self.pending_jobs.append(self.allocator, job);

        return job;
    }

    /// Get next pending job
    pub fn getNextJob(self: *Queue) ?*Job {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.pending_jobs.items.len == 0) {
            return null;
        }

        const current_time = std.time.timestamp();

        // Find first job that's ready to process
        for (self.pending_jobs.items, 0..) |job, i| {
            if (job.delay) |delay| {
                // Check if delay has passed (simplified - would need job creation time)
                if (current_time < delay) {
                    continue;
                }
            }

            _ = self.pending_jobs.orderedRemove(i);
            return job;
        }

        return null;
    }

    /// Process a job
    pub fn processJob(self: *Queue, job: *Job, handler: *const fn (*Job) anyerror!void) !void {
        job.markAsProcessing();

        handler(job) catch |err| {
            job.incrementAttempts();

            // Acquire mutex once for both branches
            self.mutex.lock();
            defer self.mutex.unlock();

            if (job.canRetry()) {
                // Re-queue for retry
                try self.pending_jobs.append(self.allocator, job);
            } else {
                // Mark as failed and move to failed jobs
                job.markAsFailed();
                try self.failed_jobs.append(self.allocator, job);
            }

            return err;
        };

        job.markAsCompleted();
    }

    /// Get number of pending jobs
    pub fn pendingCount(self: *Queue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.pending_jobs.items.len;
    }

    /// Get number of failed jobs
    pub fn failedCount(self: *Queue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.failed_jobs.items.len;
    }

    /// Clear failed jobs
    pub fn clearFailed(self: *Queue) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Remove failed jobs from master jobs list and deinit them
        for (self.failed_jobs.items) |job| {
            // Find and remove from master jobs list
            for (self.jobs.items, 0..) |master_job, i| {
                if (master_job == job) {
                    _ = self.jobs.swapRemove(i);
                    break;
                }
            }
            job.deinit();
        }
        self.failed_jobs.clearRetainingCapacity();
    }

    /// Retry all failed jobs
    pub fn retryFailed(self: *Queue) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.failed_jobs.items) |job| {
            job.status = .pending;
            job.attempts = 0;
            try self.pending_jobs.append(self.allocator, job);
        }

        self.failed_jobs.clearRetainingCapacity();
    }

    /// Flush all jobs (for testing)
    pub fn flush(self: *Queue) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.jobs.items) |job| {
            job.deinit();
        }

        self.jobs.clearRetainingCapacity();
        self.pending_jobs.clearRetainingCapacity();
        self.failed_jobs.clearRetainingCapacity();
    }
};

/// Queue worker
pub const Worker = struct {
    queue: *Queue,
    running: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, queue: *Queue) Worker {
        return Worker{
            .queue = queue,
            .running = false,
            .allocator = allocator,
        };
    }

    /// Start processing jobs
    pub fn work(self: *Worker, handler: *const fn (*Job) anyerror!void) !void {
        self.running = true;

        while (self.running) {
            if (self.queue.getNextJob()) |job| {
                try self.queue.processJob(job, handler);
            } else {
                // No jobs available, sleep briefly
                std.time.sleep(100 * std.time.ns_per_ms);
            }
        }
    }

    /// Stop the worker
    pub fn stop(self: *Worker) void {
        self.running = false;
    }
};

/// Batch of jobs
pub const Batch = struct {
    id: []const u8,
    jobs: std.ArrayList(*Job),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id: []const u8) !*Batch {
        const batch = try allocator.create(Batch);
        batch.* = Batch{
            .id = try allocator.dupe(u8, id),
            .jobs = std.ArrayList(*Job){},
            .allocator = allocator,
        };
        return batch;
    }

    pub fn deinit(self: *Batch) void {
        for (self.jobs.items) |job| {
            job.deinit();
        }
        self.jobs.deinit(self.allocator);
        self.allocator.free(self.id);
        self.allocator.destroy(self);
    }

    pub fn add(self: *Batch, job: *Job) !void {
        try self.jobs.append(self.allocator, job);
    }

    pub fn dispatch(self: *Batch, queue: *Queue) !void {
        queue.mutex.lock();
        defer queue.mutex.unlock();

        for (self.jobs.items) |job| {
            try queue.jobs.append(queue.allocator, job);
            try queue.pending_jobs.append(queue.allocator, job);
        }

        // Transfer ownership to queue - clear batch's job list
        self.jobs.clearRetainingCapacity();
    }

    pub fn isComplete(self: *Batch) bool {
        for (self.jobs.items) |job| {
            if (job.status != .completed) {
                return false;
            }
        }
        return true;
    }

    pub fn hasFailures(self: *Batch) bool {
        for (self.jobs.items) |job| {
            if (job.status == .failed) {
                return true;
            }
        }
        return false;
    }
};
