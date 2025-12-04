const std = @import("std");
const posix = std.posix;

/// Get current unix timestamp in seconds
fn getTimestamp() i64 {
    const ts = posix.clock_gettime(.REALTIME) catch return 0;
    return ts.sec;
}

/// Get nanosecond timestamp for jitter
fn getNanoTimestamp() i128 {
    const ts = posix.clock_gettime(.REALTIME) catch return 0;
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// Queue connection/driver types
pub const ConnectionType = enum {
    sync, // Execute immediately
    database, // Database-backed queue
    redis, // Redis queue
    memory, // In-memory queue
    sqs, // AWS SQS
};

/// Job status
pub const JobStatus = enum {
    pending,
    processing,
    completed,
    failed,
    retrying,
    cancelled,
};

/// Backoff strategy types
pub const BackoffStrategy = enum {
    none, // No backoff
    fixed, // Fixed delay between retries
    linear, // delay = base + (attempt * factor)
    exponential, // delay = base * (factor ^ attempt)
    custom, // Use custom backoff array
};

/// Backoff configuration
pub const BackoffConfig = struct {
    strategy: BackoffStrategy = .exponential,
    base_delay_ms: u64 = 1000,
    factor: f64 = 2.0,
    max_delay_ms: u64 = 60000,
    jitter: bool = false,
    custom_delays: ?[]const u64 = null, // Array of delays for custom strategy

    pub fn none() BackoffConfig {
        return .{ .strategy = .none };
    }

    pub fn fixed(delay_ms: u64) BackoffConfig {
        return .{
            .strategy = .fixed,
            .base_delay_ms = delay_ms,
        };
    }

    pub fn linear(base_ms: u64, increment_ms: u64) BackoffConfig {
        return .{
            .strategy = .linear,
            .base_delay_ms = base_ms,
            .factor = @floatFromInt(increment_ms),
        };
    }

    pub fn exponential(base_ms: u64, factor: f64) BackoffConfig {
        return .{
            .strategy = .exponential,
            .base_delay_ms = base_ms,
            .factor = factor,
        };
    }

    pub fn custom(delays: []const u64) BackoffConfig {
        return .{
            .strategy = .custom,
            .custom_delays = delays,
        };
    }

    pub fn withJitter(self: BackoffConfig) BackoffConfig {
        var config = self;
        config.jitter = true;
        return config;
    }

    pub fn withMaxDelay(self: BackoffConfig, max_ms: u64) BackoffConfig {
        var config = self;
        config.max_delay_ms = max_ms;
        return config;
    }

    /// Calculate delay for a given attempt number (0-indexed)
    pub fn calculateDelay(self: *const BackoffConfig, attempt: u32) u64 {
        var delay: u64 = switch (self.strategy) {
            .none => 0,
            .fixed => self.base_delay_ms,
            .linear => blk: {
                const increment: u64 = @intFromFloat(self.factor);
                break :blk self.base_delay_ms + (@as(u64, attempt) * increment);
            },
            .exponential => blk: {
                const multiplier = std.math.pow(f64, self.factor, @floatFromInt(attempt));
                const result = @as(f64, @floatFromInt(self.base_delay_ms)) * multiplier;
                break :blk @intFromFloat(@min(result, @as(f64, @floatFromInt(self.max_delay_ms))));
            },
            .custom => blk: {
                if (self.custom_delays) |delays| {
                    const idx = @min(attempt, @as(u32, @intCast(delays.len - 1)));
                    break :blk delays[idx];
                }
                break :blk self.base_delay_ms;
            },
        };

        // Cap at max delay
        delay = @min(delay, self.max_delay_ms);

        // Add jitter (0-25% of delay)
        if (self.jitter and delay > 0) {
            // Simple pseudo-random jitter based on current time
            const jitter_amount = delay / 4;
            const time_ns: u64 = @intCast(@mod(std.time.nanoTimestamp(), @as(i128, @intCast(jitter_amount + 1))));
            delay += time_ns;
        }

        return delay;
    }
};

/// Job context for passing additional data
pub const JobContext = struct {
    data: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) JobContext {
        return .{
            .data = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *JobContext) void {
        var it = self.data.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.data.deinit();
    }

    pub fn set(self: *JobContext, key: []const u8, value: []const u8) !void {
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        const owned_value = try self.allocator.dupe(u8, value);
        try self.data.put(owned_key, owned_value);
    }

    pub fn get(self: *const JobContext, key: []const u8) ?[]const u8 {
        return self.data.get(key);
    }
};

/// Enhanced Job structure with fluent API support
pub const Job = struct {
    id: []const u8,
    name: []const u8, // Job name/type (e.g., "SendWelcomeEmail")
    queue_name: []const u8,
    payload: []const u8,
    attempts: u32,
    max_attempts: u32,
    delay_until: ?i64, // Unix timestamp when job should run
    timeout_ms: u64, // Job execution timeout
    status: JobStatus,
    created_at: i64,
    started_at: ?i64,
    completed_at: ?i64,
    failed_at: ?i64,
    error_message: ?[]const u8,
    backoff: BackoffConfig,
    tags: ?[]const []const u8,
    priority: u8, // 0 = highest, 255 = lowest
    unique_key: ?[]const u8, // For preventing duplicate jobs
    context: ?*JobContext,
    allocator: std.mem.Allocator,

    // Callbacks (optional)
    on_success: ?*const fn (*Job) void,
    on_failure: ?*const fn (*Job, anyerror) void,
    on_finally: ?*const fn (*Job) void,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, name: []const u8, queue_name: []const u8, payload: []const u8) !*Self {
        const job = try allocator.create(Self);

        // Generate unique ID
        var buf: [32]u8 = undefined;
        const job_id = @intFromPtr(job);
        const id = try std.fmt.bufPrint(&buf, "job_{x}", .{job_id});

        job.* = Self{
            .id = try allocator.dupe(u8, id),
            .name = try allocator.dupe(u8, name),
            .queue_name = try allocator.dupe(u8, queue_name),
            .payload = try allocator.dupe(u8, payload),
            .attempts = 0,
            .max_attempts = 3,
            .delay_until = null,
            .timeout_ms = 60000, // 1 minute default
            .status = .pending,
            .created_at = std.time.timestamp(),
            .started_at = null,
            .completed_at = null,
            .failed_at = null,
            .error_message = null,
            .backoff = BackoffConfig.exponential(1000, 2.0),
            .tags = null,
            .priority = 128, // Normal priority
            .unique_key = null,
            .context = null,
            .allocator = allocator,
            .on_success = null,
            .on_failure = null,
            .on_finally = null,
        };

        return job;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.id);
        self.allocator.free(self.name);
        self.allocator.free(self.queue_name);
        self.allocator.free(self.payload);
        if (self.error_message) |msg| {
            self.allocator.free(msg);
        }
        if (self.unique_key) |key| {
            self.allocator.free(key);
        }
        if (self.context) |ctx| {
            ctx.deinit();
            self.allocator.destroy(ctx);
        }
        self.allocator.destroy(self);
    }

    // Fluent API methods

    /// Set the number of retry attempts
    pub fn tries(self: *Self, count: u32) *Self {
        self.max_attempts = count;
        return self;
    }

    /// Set execution timeout in milliseconds
    pub fn timeout(self: *Self, ms: u64) *Self {
        self.timeout_ms = ms;
        return self;
    }

    /// Set timeout in seconds
    pub fn timeoutSeconds(self: *Self, seconds: u64) *Self {
        self.timeout_ms = seconds * 1000;
        return self;
    }

    /// Delay execution by specified seconds
    pub fn delay(self: *Self, seconds: i64) *Self {
        self.delay_until = std.time.timestamp() + seconds;
        return self;
    }

    /// Delay execution until specific timestamp
    pub fn delayUntil(self: *Self, timestamp: i64) *Self {
        self.delay_until = timestamp;
        return self;
    }

    /// Set backoff strategy
    pub fn withBackoff(self: *Self, config: BackoffConfig) *Self {
        self.backoff = config;
        return self;
    }

    /// Set fixed backoff delays as array (e.g., [10, 30, 60] seconds)
    pub fn backoffArray(self: *Self, delays: []const u64) *Self {
        self.backoff = BackoffConfig.custom(delays);
        return self;
    }

    /// Set job priority (0 = highest, 255 = lowest)
    pub fn withPriority(self: *Self, priority: u8) *Self {
        self.priority = priority;
        return self;
    }

    /// High priority job
    pub fn highPriority(self: *Self) *Self {
        self.priority = 32;
        return self;
    }

    /// Low priority job
    pub fn lowPriority(self: *Self) *Self {
        self.priority = 224;
        return self;
    }

    /// Set unique key to prevent duplicate jobs
    pub fn unique(self: *Self, key: []const u8) !*Self {
        if (self.unique_key) |old| {
            self.allocator.free(old);
        }
        self.unique_key = try self.allocator.dupe(u8, key);
        return self;
    }

    /// Set job context
    pub fn withContext(self: *Self, ctx: *JobContext) *Self {
        self.context = ctx;
        return self;
    }

    /// Set success callback
    pub fn onSuccess(self: *Self, callback: *const fn (*Job) void) *Self {
        self.on_success = callback;
        return self;
    }

    /// Set failure callback
    pub fn onFailure(self: *Self, callback: *const fn (*Job, anyerror) void) *Self {
        self.on_failure = callback;
        return self;
    }

    /// Set finally callback (runs after success or failure)
    pub fn onFinally(self: *Self, callback: *const fn (*Job) void) *Self {
        self.on_finally = callback;
        return self;
    }

    // Status methods

    pub fn incrementAttempts(self: *Self) void {
        self.attempts += 1;
        if (self.attempts < self.max_attempts) {
            self.status = .retrying;
        } else {
            self.status = .failed;
            self.failed_at = std.time.timestamp();
        }
    }

    pub fn markAsProcessing(self: *Self) void {
        self.status = .processing;
        self.started_at = std.time.timestamp();
    }

    pub fn markAsCompleted(self: *Self) void {
        self.status = .completed;
        self.completed_at = std.time.timestamp();
        if (self.on_success) |callback| {
            callback(self);
        }
        if (self.on_finally) |callback| {
            callback(self);
        }
    }

    pub fn markAsFailed(self: *Self, err: anyerror) void {
        self.status = .failed;
        self.failed_at = std.time.timestamp();
        if (self.on_failure) |callback| {
            callback(self, err);
        }
        if (self.on_finally) |callback| {
            callback(self);
        }
    }

    pub fn markAsCancelled(self: *Self) void {
        self.status = .cancelled;
    }

    pub fn canRetry(self: *Self) bool {
        return self.attempts < self.max_attempts and self.status != .cancelled;
    }

    pub fn isReady(self: *Self) bool {
        if (self.delay_until) |until| {
            return std.time.timestamp() >= until;
        }
        return true;
    }

    /// Get the delay for next retry
    pub fn getRetryDelay(self: *Self) u64 {
        return self.backoff.calculateDelay(self.attempts);
    }

    pub fn setError(self: *Self, message: []const u8) !void {
        if (self.error_message) |old| {
            self.allocator.free(old);
        }
        self.error_message = try self.allocator.dupe(u8, message);
    }
};

/// Job builder for creating jobs with fluent API
pub const JobBuilder = struct {
    job: *Job,
    queue: *Queue,

    const Self = @This();

    pub fn init(queue: *Queue, name: []const u8, payload: []const u8) !Self {
        const job = try Job.init(queue.allocator, name, queue.config.default_queue, payload);
        return .{
            .job = job,
            .queue = queue,
        };
    }

    pub fn onQueue(self: *Self, queue_name: []const u8) !*Self {
        self.queue.allocator.free(self.job.queue_name);
        self.job.queue_name = try self.queue.allocator.dupe(u8, queue_name);
        return self;
    }

    pub fn tries(self: *Self, count: u32) *Self {
        _ = self.job.tries(count);
        return self;
    }

    pub fn timeout(self: *Self, ms: u64) *Self {
        _ = self.job.timeout(ms);
        return self;
    }

    pub fn timeoutSeconds(self: *Self, seconds: u64) *Self {
        _ = self.job.timeoutSeconds(seconds);
        return self;
    }

    pub fn delay(self: *Self, seconds: i64) *Self {
        _ = self.job.delay(seconds);
        return self;
    }

    pub fn delayUntil(self: *Self, timestamp: i64) *Self {
        _ = self.job.delayUntil(timestamp);
        return self;
    }

    pub fn withBackoff(self: *Self, config: BackoffConfig) *Self {
        _ = self.job.withBackoff(config);
        return self;
    }

    pub fn backoffArray(self: *Self, delays: []const u64) *Self {
        _ = self.job.backoffArray(delays);
        return self;
    }

    pub fn withPriority(self: *Self, priority: u8) *Self {
        _ = self.job.withPriority(priority);
        return self;
    }

    pub fn highPriority(self: *Self) *Self {
        _ = self.job.highPriority();
        return self;
    }

    pub fn lowPriority(self: *Self) *Self {
        _ = self.job.lowPriority();
        return self;
    }

    pub fn unique(self: *Self, key: []const u8) !*Self {
        _ = try self.job.unique(key);
        return self;
    }

    pub fn onSuccess(self: *Self, callback: *const fn (*Job) void) *Self {
        _ = self.job.onSuccess(callback);
        return self;
    }

    pub fn onFailure(self: *Self, callback: *const fn (*Job, anyerror) void) *Self {
        _ = self.job.onFailure(callback);
        return self;
    }

    pub fn onFinally(self: *Self, callback: *const fn (*Job) void) *Self {
        _ = self.job.onFinally(callback);
        return self;
    }

    /// Dispatch the job to the queue
    pub fn dispatch(self: *Self) !*Job {
        return try self.queue.addJob(self.job);
    }

    /// Execute the job immediately (synchronously)
    pub fn dispatchNow(self: *Self, handler: *const fn (*Job) anyerror!void) !void {
        defer self.job.deinit();
        self.job.markAsProcessing();
        handler(self.job) catch |err| {
            self.job.markAsFailed(err);
            return err;
        };
        self.job.markAsCompleted();
    }
};

/// Queue configuration
pub const QueueConfig = struct {
    connection: ConnectionType,
    default_queue: []const u8,
    retry_after: i64, // Seconds before a stale job is retried
    max_jobs: usize,
    poll_interval_ms: u64, // How often to poll for new jobs

    // Driver-specific configurations
    redis_url: ?[]const u8,
    database_table: ?[]const u8,
    sqs_queue_url: ?[]const u8,
    sqs_region: ?[]const u8,

    pub fn default() QueueConfig {
        return .{
            .connection = .memory,
            .default_queue = "default",
            .retry_after = 90,
            .max_jobs = 1000,
            .poll_interval_ms = 100,
            .redis_url = null,
            .database_table = null,
            .sqs_queue_url = null,
            .sqs_region = null,
        };
    }

    pub fn memory() QueueConfig {
        return default();
    }

    pub fn redis(url: []const u8) QueueConfig {
        var config = default();
        config.connection = .redis;
        config.redis_url = url;
        return config;
    }

    pub fn database(table: []const u8) QueueConfig {
        var config = default();
        config.connection = .database;
        config.database_table = table;
        return config;
    }

    pub fn sqs(queue_url: []const u8, region: []const u8) QueueConfig {
        var config = default();
        config.connection = .sqs;
        config.sqs_queue_url = queue_url;
        config.sqs_region = region;
        return config;
    }

    pub fn sync() QueueConfig {
        var config = default();
        config.connection = .sync;
        return config;
    }
};

/// Queue driver interface
pub const QueueDriver = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        push: *const fn (ptr: *anyopaque, job: *Job) anyerror!void,
        pop: *const fn (ptr: *anyopaque, queue_name: []const u8) ?*Job,
        size: *const fn (ptr: *anyopaque, queue_name: []const u8) usize,
        clear: *const fn (ptr: *anyopaque, queue_name: []const u8) void,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn push(self: *QueueDriver, job: *Job) !void {
        return self.vtable.push(self.ptr, job);
    }

    pub fn pop(self: *QueueDriver, queue_name: []const u8) ?*Job {
        return self.vtable.pop(self.ptr, queue_name);
    }

    pub fn size(self: *QueueDriver, queue_name: []const u8) usize {
        return self.vtable.size(self.ptr, queue_name);
    }

    pub fn clear(self: *QueueDriver, queue_name: []const u8) void {
        self.vtable.clear(self.ptr, queue_name);
    }

    pub fn deinit(self: *QueueDriver) void {
        self.vtable.deinit(self.ptr);
    }
};

/// In-memory queue driver (default)
pub const MemoryQueueDriver = struct {
    allocator: std.mem.Allocator,
    queues: std.StringHashMap(std.ArrayList(*Job)),
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .queues = std.StringHashMap(std.ArrayList(*Job)).init(allocator),
            .mutex = .{},
        };
        return self;
    }

    pub fn driver(self: *Self) QueueDriver {
        return .{
            .ptr = self,
            .vtable = &.{
                .push = push,
                .pop = pop,
                .size = size,
                .clear = clear,
                .deinit = deinit,
            },
        };
    }

    fn push(ptr: *anyopaque, job: *Job) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        const result = try self.queues.getOrPut(job.queue_name);
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(*Job).init(self.allocator);
        }

        // Insert by priority (lower priority number = higher priority)
        var insert_idx: usize = result.value_ptr.items.len;
        for (result.value_ptr.items, 0..) |existing_job, i| {
            if (job.priority < existing_job.priority) {
                insert_idx = i;
                break;
            }
        }

        try result.value_ptr.insert(insert_idx, job);
    }

    fn pop(ptr: *anyopaque, queue_name: []const u8) ?*Job {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.queues.get(queue_name)) |*queue_jobs| {
            // Find first ready job
            for (queue_jobs.items, 0..) |job, i| {
                if (job.isReady()) {
                    return queue_jobs.orderedRemove(i);
                }
            }
        }

        return null;
    }

    fn size(ptr: *anyopaque, queue_name: []const u8) usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.queues.get(queue_name)) |queue_jobs| {
            return queue_jobs.items.len;
        }
        return 0;
    }

    fn clear(ptr: *anyopaque, queue_name: []const u8) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.queues.getPtr(queue_name)) |queue_jobs| {
            for (queue_jobs.items) |job| {
                job.deinit();
            }
            queue_jobs.clearRetainingCapacity();
        }
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        var it = self.queues.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |job| {
                job.deinit();
            }
            entry.value_ptr.deinit();
        }
        self.queues.deinit();
        self.allocator.destroy(self);
    }
};

/// Queue manager
pub const Queue = struct {
    config: QueueConfig,
    driver: QueueDriver,
    failed_jobs: std.ArrayList(*Job),
    unique_keys: std.StringHashMap(void),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: QueueConfig) !Self {
        const mem_driver = try MemoryQueueDriver.init(allocator);
        return .{
            .config = config,
            .driver = mem_driver.driver(),
            .failed_jobs = std.ArrayList(*Job).init(allocator),
            .unique_keys = std.StringHashMap(void).init(allocator),
            .allocator = allocator,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.failed_jobs.items) |job| {
            job.deinit();
        }
        self.failed_jobs.deinit();
        self.unique_keys.deinit();
        self.driver.deinit();
    }

    /// Create a job builder
    pub fn job(self: *Self, name: []const u8, payload: []const u8) !JobBuilder {
        return JobBuilder.init(self, name, payload);
    }

    /// Add a job directly
    pub fn addJob(self: *Self, new_job: *Job) !*Job {
        // Check uniqueness
        if (new_job.unique_key) |key| {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.unique_keys.contains(key)) {
                new_job.deinit();
                return error.DuplicateJob;
            }
            try self.unique_keys.put(key, {});
        }

        try self.driver.push(new_job);
        return new_job;
    }

    /// Legacy dispatch method
    pub fn dispatch(self: *Self, queue_name: []const u8, payload: []const u8) !*Job {
        const new_job = try Job.init(self.allocator, "default", queue_name, payload);
        return try self.addJob(new_job);
    }

    /// Dispatch a job synchronously (execute immediately)
    pub fn dispatchSync(self: *Self, queue_name: []const u8, payload: []const u8, handler: *const fn (*Job) anyerror!void) !void {
        const new_job = try Job.init(self.allocator, "sync", queue_name, payload);
        defer new_job.deinit();

        new_job.markAsProcessing();
        handler(new_job) catch |err| {
            new_job.markAsFailed(err);
            return err;
        };
        new_job.markAsCompleted();
    }

    /// Dispatch a job with delay
    pub fn dispatchAfter(self: *Self, delay_seconds: i64, queue_name: []const u8, payload: []const u8) !*Job {
        const new_job = try Job.init(self.allocator, "delayed", queue_name, payload);
        _ = new_job.delay(delay_seconds);
        return try self.addJob(new_job);
    }

    /// Get next pending job
    pub fn getNextJob(self: *Self) ?*Job {
        return self.driver.pop(self.config.default_queue);
    }

    /// Get next job from specific queue
    pub fn getNextJobFrom(self: *Self, queue_name: []const u8) ?*Job {
        return self.driver.pop(queue_name);
    }

    /// Process a job with handler
    pub fn processJob(self: *Self, process_job: *Job, handler: *const fn (*Job) anyerror!void) !void {
        process_job.markAsProcessing();

        handler(process_job) catch |err| {
            process_job.incrementAttempts();

            if (process_job.canRetry()) {
                // Calculate retry delay and re-queue
                const delay_ms = process_job.getRetryDelay();
                process_job.delay_until = std.time.timestamp() + @as(i64, @intCast(delay_ms / 1000));
                try self.driver.push(process_job);
            } else {
                process_job.markAsFailed(err);
                self.mutex.lock();
                defer self.mutex.unlock();
                try self.failed_jobs.append(process_job);
                // Remove unique key if exists
                if (process_job.unique_key) |key| {
                    _ = self.unique_keys.remove(key);
                }
            }

            return err;
        };

        process_job.markAsCompleted();
        // Remove unique key if exists
        if (process_job.unique_key) |key| {
            self.mutex.lock();
            defer self.mutex.unlock();
            _ = self.unique_keys.remove(key);
        }
    }

    /// Get number of pending jobs
    pub fn pendingCount(self: *Self) usize {
        return self.driver.size(self.config.default_queue);
    }

    /// Get number of pending jobs in specific queue
    pub fn pendingCountIn(self: *Self, queue_name: []const u8) usize {
        return self.driver.size(queue_name);
    }

    /// Get number of failed jobs
    pub fn failedCount(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.failed_jobs.items.len;
    }

    /// Get failed jobs
    pub fn getFailedJobs(self: *Self) []const *Job {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.failed_jobs.items;
    }

    /// Clear failed jobs
    pub fn clearFailed(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.failed_jobs.items) |failed_job| {
            failed_job.deinit();
        }
        self.failed_jobs.clearRetainingCapacity();
    }

    /// Retry all failed jobs
    pub fn retryFailed(self: *Self) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.failed_jobs.items) |failed_job| {
            failed_job.status = .pending;
            failed_job.attempts = 0;
            failed_job.error_message = null;
            failed_job.delay_until = null;
            try self.driver.push(failed_job);
        }

        self.failed_jobs.clearRetainingCapacity();
    }

    /// Retry a specific failed job by ID
    pub fn retryFailedById(self: *Self, id: []const u8) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.failed_jobs.items, 0..) |failed_job, i| {
            if (std.mem.eql(u8, failed_job.id, id)) {
                failed_job.status = .pending;
                failed_job.attempts = 0;
                failed_job.error_message = null;
                try self.driver.push(failed_job);
                _ = self.failed_jobs.swapRemove(i);
                return true;
            }
        }

        return false;
    }

    /// Flush all jobs (for testing)
    pub fn flush(self: *Self) void {
        self.driver.clear(self.config.default_queue);
        self.clearFailed();
        self.unique_keys.clearRetainingCapacity();
    }
};

/// Job chain for running jobs in sequence
pub const JobChain = struct {
    jobs: std.ArrayList(*Job),
    allocator: std.mem.Allocator,
    current_index: usize,
    on_chain_complete: ?*const fn (*JobChain) void,
    on_chain_failure: ?*const fn (*JobChain, *Job, anyerror) void,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .jobs = std.ArrayList(*Job).init(allocator),
            .allocator = allocator,
            .current_index = 0,
            .on_chain_complete = null,
            .on_chain_failure = null,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.jobs.items) |chain_job| {
            chain_job.deinit();
        }
        self.jobs.deinit();
    }

    pub fn add(self: *Self, chain_job: *Job) !*Self {
        try self.jobs.append(chain_job);
        return self;
    }

    pub fn onComplete(self: *Self, callback: *const fn (*JobChain) void) *Self {
        self.on_chain_complete = callback;
        return self;
    }

    pub fn onFailure(self: *Self, callback: *const fn (*JobChain, *Job, anyerror) void) *Self {
        self.on_chain_failure = callback;
        return self;
    }

    /// Execute the chain
    pub fn execute(self: *Self, handler: *const fn (*Job) anyerror!void) !void {
        for (self.jobs.items) |chain_job| {
            chain_job.markAsProcessing();
            handler(chain_job) catch |err| {
                chain_job.markAsFailed(err);
                if (self.on_chain_failure) |callback| {
                    callback(self, chain_job, err);
                }
                return err;
            };
            chain_job.markAsCompleted();
            self.current_index += 1;
        }

        if (self.on_chain_complete) |callback| {
            callback(self);
        }
    }
};

/// Queue worker
pub const Worker = struct {
    queue: *Queue,
    queue_names: []const []const u8,
    running: std.atomic.Value(bool),
    allocator: std.mem.Allocator,
    sleep_ms: u64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, queue: *Queue) Self {
        return .{
            .queue = queue,
            .queue_names = &[_][]const u8{queue.config.default_queue},
            .running = std.atomic.Value(bool).init(false),
            .allocator = allocator,
            .sleep_ms = queue.config.poll_interval_ms,
        };
    }

    /// Set which queues to process
    pub fn watchQueues(self: *Self, queues: []const []const u8) *Self {
        self.queue_names = queues;
        return self;
    }

    /// Set poll interval
    pub fn pollEvery(self: *Self, ms: u64) *Self {
        self.sleep_ms = ms;
        return self;
    }

    /// Start processing jobs
    pub fn work(self: *Self, handler: *const fn (*Job) anyerror!void) !void {
        self.running.store(true, .release);

        while (self.running.load(.acquire)) {
            var found_job = false;

            for (self.queue_names) |queue_name| {
                if (self.queue.getNextJobFrom(queue_name)) |worker_job| {
                    found_job = true;
                    self.queue.processJob(worker_job, handler) catch {};
                }
            }

            if (!found_job) {
                std.time.sleep(self.sleep_ms * std.time.ns_per_ms);
            }
        }
    }

    /// Process a single batch of jobs
    pub fn workOnce(self: *Self, handler: *const fn (*Job) anyerror!void, max_jobs: usize) !usize {
        var processed: usize = 0;

        while (processed < max_jobs) {
            var found_job = false;

            for (self.queue_names) |queue_name| {
                if (self.queue.getNextJobFrom(queue_name)) |worker_job| {
                    found_job = true;
                    self.queue.processJob(worker_job, handler) catch {};
                    processed += 1;
                    break;
                }
            }

            if (!found_job) break;
        }

        return processed;
    }

    /// Stop the worker
    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
    }
};

/// Batch of jobs for batch operations
pub const Batch = struct {
    id: []const u8,
    jobs: std.ArrayList(*Job),
    allocator: std.mem.Allocator,
    on_complete: ?*const fn (*Batch) void,
    on_failure: ?*const fn (*Batch) void,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, id: []const u8) !*Self {
        const batch = try allocator.create(Self);
        batch.* = .{
            .id = try allocator.dupe(u8, id),
            .jobs = std.ArrayList(*Job).init(allocator),
            .allocator = allocator,
            .on_complete = null,
            .on_failure = null,
        };
        return batch;
    }

    pub fn deinit(self: *Self) void {
        for (self.jobs.items) |batch_job| {
            batch_job.deinit();
        }
        self.jobs.deinit();
        self.allocator.free(self.id);
        self.allocator.destroy(self);
    }

    pub fn add(self: *Self, batch_job: *Job) !*Self {
        try self.jobs.append(batch_job);
        return self;
    }

    pub fn onComplete(self: *Self, callback: *const fn (*Batch) void) *Self {
        self.on_complete = callback;
        return self;
    }

    pub fn onFailure(self: *Self, callback: *const fn (*Batch) void) *Self {
        self.on_failure = callback;
        return self;
    }

    pub fn dispatch(self: *Self, queue: *Queue) !void {
        for (self.jobs.items) |batch_job| {
            try queue.driver.push(batch_job);
        }
        // Transfer ownership - clear local list
        self.jobs.clearRetainingCapacity();
    }

    pub fn isComplete(self: *Self) bool {
        for (self.jobs.items) |batch_job| {
            if (batch_job.status != .completed) {
                return false;
            }
        }
        return true;
    }

    pub fn hasFailures(self: *Self) bool {
        for (self.jobs.items) |batch_job| {
            if (batch_job.status == .failed) {
                return true;
            }
        }
        return false;
    }

    pub fn completedCount(self: *Self) usize {
        var count: usize = 0;
        for (self.jobs.items) |batch_job| {
            if (batch_job.status == .completed) {
                count += 1;
            }
        }
        return count;
    }

    pub fn failedCount(self: *Self) usize {
        var count: usize = 0;
        for (self.jobs.items) |batch_job| {
            if (batch_job.status == .failed) {
                count += 1;
            }
        }
        return count;
    }
};

// Tests
test "job creation with fluent api" {
    const allocator = std.testing.allocator;
    const job_instance = try Job.init(allocator, "SendEmail", "emails", "{\"to\": \"test@example.com\"}");
    defer job_instance.deinit();

    _ = job_instance.tries(5).timeout(30000).delay(60).highPriority();

    try std.testing.expectEqual(@as(u32, 5), job_instance.max_attempts);
    try std.testing.expectEqual(@as(u64, 30000), job_instance.timeout_ms);
    try std.testing.expectEqual(@as(u8, 32), job_instance.priority);
    try std.testing.expect(job_instance.delay_until != null);
}

test "backoff strategy calculations" {
    const fixed = BackoffConfig.fixed(1000);
    try std.testing.expectEqual(@as(u64, 1000), fixed.calculateDelay(0));
    try std.testing.expectEqual(@as(u64, 1000), fixed.calculateDelay(5));

    const expo = BackoffConfig.exponential(1000, 2.0);
    try std.testing.expectEqual(@as(u64, 1000), expo.calculateDelay(0)); // 1000 * 2^0
    try std.testing.expectEqual(@as(u64, 2000), expo.calculateDelay(1)); // 1000 * 2^1
    try std.testing.expectEqual(@as(u64, 4000), expo.calculateDelay(2)); // 1000 * 2^2

    const custom_delays = [_]u64{ 1000, 5000, 10000 };
    const custom = BackoffConfig.custom(&custom_delays);
    try std.testing.expectEqual(@as(u64, 1000), custom.calculateDelay(0));
    try std.testing.expectEqual(@as(u64, 5000), custom.calculateDelay(1));
    try std.testing.expectEqual(@as(u64, 10000), custom.calculateDelay(2));
    try std.testing.expectEqual(@as(u64, 10000), custom.calculateDelay(5)); // Capped at last value
}

test "queue with job builder" {
    const allocator = std.testing.allocator;
    var queue = try Queue.init(allocator, QueueConfig.default());
    defer queue.deinit();

    var builder = try queue.job("ProcessPayment", "{\"amount\": 100}");
    _ = builder.tries(3).timeout(5000).highPriority();
    const created_job = try builder.dispatch();

    try std.testing.expectEqualStrings("ProcessPayment", created_job.name);
    try std.testing.expectEqual(@as(u32, 3), created_job.max_attempts);
    try std.testing.expectEqual(@as(usize, 1), queue.pendingCount());
}

test "unique job prevention" {
    const allocator = std.testing.allocator;
    var queue = try Queue.init(allocator, QueueConfig.default());
    defer queue.deinit();

    var builder1 = try queue.job("SendEmail", "{}");
    _ = try builder1.unique("email_user_123");
    _ = try builder1.dispatch();

    var builder2 = try queue.job("SendEmail", "{}");
    _ = try builder2.unique("email_user_123");

    const result = builder2.dispatch();
    try std.testing.expectError(error.DuplicateJob, result);
}

test "worker processes jobs" {
    const allocator = std.testing.allocator;
    var queue = try Queue.init(allocator, QueueConfig.default());
    defer queue.deinit();

    _ = try queue.dispatch("default", "job1");
    _ = try queue.dispatch("default", "job2");

    var worker = Worker.init(allocator, &queue);

    const Handler = struct {
        fn handle(_: *Job) anyerror!void {
            // Process job
        }
    };

    const processed = try worker.workOnce(Handler.handle, 10);
    try std.testing.expectEqual(@as(usize, 2), processed);
}
