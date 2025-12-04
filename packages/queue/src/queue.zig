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
    custom_delays: ?[]const u64 = null,

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

        delay = @min(delay, self.max_delay_ms);

        if (self.jitter and delay > 0) {
            const jitter_amount = delay / 4;
            const time_ns: u64 = @intCast(@mod(getNanoTimestamp(), @as(i128, @intCast(jitter_amount + 1))));
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
    name: []const u8,
    queue_name: []const u8,
    payload: []const u8,
    attempts: u32,
    max_attempts: u32,
    delay_until: ?i64,
    timeout_ms: u64,
    status: JobStatus,
    created_at: i64,
    started_at: ?i64,
    completed_at: ?i64,
    failed_at: ?i64,
    error_message: ?[]const u8,
    backoff: BackoffConfig,
    tags: ?[]const []const u8,
    priority: u8,
    unique_key: ?[]const u8,
    context: ?*JobContext,
    allocator: std.mem.Allocator,

    on_success: ?*const fn (*Job) void,
    on_failure: ?*const fn (*Job, anyerror) void,
    on_finally: ?*const fn (*Job) void,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, name: []const u8, queue_name: []const u8, payload: []const u8) !*Self {
        const self = try allocator.create(Self);

        var buf: [32]u8 = undefined;
        const job_id = @intFromPtr(self);
        const id = try std.fmt.bufPrint(&buf, "job_{x}", .{job_id});

        self.* = Self{
            .id = try allocator.dupe(u8, id),
            .name = try allocator.dupe(u8, name),
            .queue_name = try allocator.dupe(u8, queue_name),
            .payload = try allocator.dupe(u8, payload),
            .attempts = 0,
            .max_attempts = 3,
            .delay_until = null,
            .timeout_ms = 60000,
            .status = .pending,
            .created_at = getTimestamp(),
            .started_at = null,
            .completed_at = null,
            .failed_at = null,
            .error_message = null,
            .backoff = BackoffConfig.exponential(1000, 2.0),
            .tags = null,
            .priority = 128,
            .unique_key = null,
            .context = null,
            .allocator = allocator,
            .on_success = null,
            .on_failure = null,
            .on_finally = null,
        };

        return self;
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

    pub fn tries(self: *Self, count: u32) *Self {
        self.max_attempts = count;
        return self;
    }

    pub fn timeout(self: *Self, ms: u64) *Self {
        self.timeout_ms = ms;
        return self;
    }

    pub fn timeoutSeconds(self: *Self, seconds: u64) *Self {
        self.timeout_ms = seconds * 1000;
        return self;
    }

    pub fn delay(self: *Self, seconds: i64) *Self {
        self.delay_until = getTimestamp() + seconds;
        return self;
    }

    pub fn delayUntil(self: *Self, timestamp: i64) *Self {
        self.delay_until = timestamp;
        return self;
    }

    pub fn withBackoff(self: *Self, config: BackoffConfig) *Self {
        self.backoff = config;
        return self;
    }

    pub fn backoffArray(self: *Self, delays: []const u64) *Self {
        self.backoff = BackoffConfig.custom(delays);
        return self;
    }

    pub fn withPriority(self: *Self, prio: u8) *Self {
        self.priority = prio;
        return self;
    }

    pub fn highPriority(self: *Self) *Self {
        self.priority = 32;
        return self;
    }

    pub fn lowPriority(self: *Self) *Self {
        self.priority = 224;
        return self;
    }

    pub fn unique(self: *Self, key: []const u8) !*Self {
        if (self.unique_key) |old| {
            self.allocator.free(old);
        }
        self.unique_key = try self.allocator.dupe(u8, key);
        return self;
    }

    pub fn withContext(self: *Self, ctx: *JobContext) *Self {
        self.context = ctx;
        return self;
    }

    pub fn onSuccess(self: *Self, callback: *const fn (*Job) void) *Self {
        self.on_success = callback;
        return self;
    }

    pub fn onFailure(self: *Self, callback: *const fn (*Job, anyerror) void) *Self {
        self.on_failure = callback;
        return self;
    }

    pub fn onFinally(self: *Self, callback: *const fn (*Job) void) *Self {
        self.on_finally = callback;
        return self;
    }

    pub fn incrementAttempts(self: *Self) void {
        self.attempts += 1;
        if (self.attempts < self.max_attempts) {
            self.status = .retrying;
        } else {
            self.status = .failed;
            self.failed_at = getTimestamp();
        }
    }

    pub fn markAsProcessing(self: *Self) void {
        self.status = .processing;
        self.started_at = getTimestamp();
    }

    pub fn markAsCompleted(self: *Self) void {
        self.status = .completed;
        self.completed_at = getTimestamp();
        if (self.on_success) |callback| {
            callback(self);
        }
        if (self.on_finally) |callback| {
            callback(self);
        }
    }

    pub fn markAsFailed(self: *Self, err: anyerror) void {
        self.status = .failed;
        self.failed_at = getTimestamp();
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
            return getTimestamp() >= until;
        }
        return true;
    }

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
    built_job: *Job,
    queue_ref: *Queue,

    const Self = @This();

    pub fn init(q: *Queue, name: []const u8, payload: []const u8) !Self {
        const j = try Job.create(q.allocator, name, q.config.default_queue, payload);
        return .{
            .built_job = j,
            .queue_ref = q,
        };
    }

    pub fn onQueue(self: *Self, queue_name: []const u8) !*Self {
        self.queue_ref.allocator.free(self.built_job.queue_name);
        self.built_job.queue_name = try self.queue_ref.allocator.dupe(u8, queue_name);
        return self;
    }

    pub fn tries(self: *Self, count: u32) *Self {
        _ = self.built_job.tries(count);
        return self;
    }

    pub fn timeout(self: *Self, ms: u64) *Self {
        _ = self.built_job.timeout(ms);
        return self;
    }

    pub fn timeoutSeconds(self: *Self, seconds: u64) *Self {
        _ = self.built_job.timeoutSeconds(seconds);
        return self;
    }

    pub fn delay(self: *Self, seconds: i64) *Self {
        _ = self.built_job.delay(seconds);
        return self;
    }

    pub fn delayUntil(self: *Self, timestamp: i64) *Self {
        _ = self.built_job.delayUntil(timestamp);
        return self;
    }

    pub fn withBackoff(self: *Self, config: BackoffConfig) *Self {
        _ = self.built_job.withBackoff(config);
        return self;
    }

    pub fn backoffArray(self: *Self, delays: []const u64) *Self {
        _ = self.built_job.backoffArray(delays);
        return self;
    }

    pub fn withPriority(self: *Self, prio: u8) *Self {
        _ = self.built_job.withPriority(prio);
        return self;
    }

    pub fn highPriority(self: *Self) *Self {
        _ = self.built_job.highPriority();
        return self;
    }

    pub fn lowPriority(self: *Self) *Self {
        _ = self.built_job.lowPriority();
        return self;
    }

    pub fn unique(self: *Self, key: []const u8) !*Self {
        _ = try self.built_job.unique(key);
        return self;
    }

    pub fn onSuccess(self: *Self, callback: *const fn (*Job) void) *Self {
        _ = self.built_job.onSuccess(callback);
        return self;
    }

    pub fn onFailure(self: *Self, callback: *const fn (*Job, anyerror) void) *Self {
        _ = self.built_job.onFailure(callback);
        return self;
    }

    pub fn onFinally(self: *Self, callback: *const fn (*Job) void) *Self {
        _ = self.built_job.onFinally(callback);
        return self;
    }

    pub fn dispatch(self: *Self) !*Job {
        return try self.queue_ref.addJob(self.built_job);
    }

    pub fn dispatchNow(self: *Self, handler: *const fn (*Job) anyerror!void) !void {
        defer self.built_job.deinit();
        self.built_job.markAsProcessing();
        handler(self.built_job) catch |err| {
            self.built_job.markAsFailed(err);
            return err;
        };
        self.built_job.markAsCompleted();
    }
};

/// Queue configuration
pub const QueueConfig = struct {
    connection: ConnectionType,
    default_queue: []const u8,
    retry_after: i64,
    max_jobs: usize,
    poll_interval_ms: u64,

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
        push: *const fn (ptr: *anyopaque, j: *Job) anyerror!void,
        pop: *const fn (ptr: *anyopaque, queue_name: []const u8) ?*Job,
        size: *const fn (ptr: *anyopaque, queue_name: []const u8) usize,
        clear: *const fn (ptr: *anyopaque, queue_name: []const u8) void,
        deinitFn: *const fn (ptr: *anyopaque) void,
    };

    pub fn push(self: *QueueDriver, j: *Job) !void {
        return self.vtable.push(self.ptr, j);
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

    pub fn deinitDriver(self: *QueueDriver) void {
        self.vtable.deinitFn(self.ptr);
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
                .push = pushFn,
                .pop = popFn,
                .size = sizeFn,
                .clear = clearFn,
                .deinitFn = deinitFn,
            },
        };
    }

    fn pushFn(ptr: *anyopaque, j: *Job) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        const result = try self.queues.getOrPut(j.queue_name);
        if (!result.found_existing) {
            result.value_ptr.* = .empty;
        }

        // Insert by priority (lower priority number = higher priority)
        var insert_idx: usize = result.value_ptr.items.len;
        for (result.value_ptr.items, 0..) |existing_job, i| {
            if (j.priority < existing_job.priority) {
                insert_idx = i;
                break;
            }
        }

        try result.value_ptr.insert(self.allocator, insert_idx, j);
    }

    fn popFn(ptr: *anyopaque, queue_name: []const u8) ?*Job {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.queues.getPtr(queue_name)) |queue_jobs| {
            for (queue_jobs.items, 0..) |j, i| {
                if (j.isReady()) {
                    return queue_jobs.orderedRemove(i);
                }
            }
        }

        return null;
    }

    fn sizeFn(ptr: *anyopaque, queue_name: []const u8) usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.queues.get(queue_name)) |queue_jobs| {
            return queue_jobs.items.len;
        }
        return 0;
    }

    fn clearFn(ptr: *anyopaque, queue_name: []const u8) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.queues.getPtr(queue_name)) |queue_jobs| {
            for (queue_jobs.items) |j| {
                j.deinit();
            }
            queue_jobs.clearRetainingCapacity();
        }
    }

    fn deinitFn(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        var it = self.queues.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |j| {
                j.deinit();
            }
            entry.value_ptr.deinit(self.allocator);
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
            .failed_jobs = .empty,
            .unique_keys = std.StringHashMap(void).init(allocator),
            .allocator = allocator,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.failed_jobs.items) |j| {
            j.deinit();
        }
        self.failed_jobs.deinit(self.allocator);
        self.unique_keys.deinit();
        self.driver.deinitDriver();
    }

    pub fn job(self: *Self, name: []const u8, payload: []const u8) !JobBuilder {
        return JobBuilder.init(self, name, payload);
    }

    pub fn addJob(self: *Self, new_job: *Job) !*Job {
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

    pub fn dispatch(self: *Self, queue_name: []const u8, payload: []const u8) !*Job {
        const new_job = try Job.create(self.allocator, "default", queue_name, payload);
        return try self.addJob(new_job);
    }

    pub fn dispatchSync(self: *Self, queue_name: []const u8, payload: []const u8, handler: *const fn (*Job) anyerror!void) !void {
        const new_job = try Job.create(self.allocator, "sync", queue_name, payload);
        defer new_job.deinit();

        new_job.markAsProcessing();
        handler(new_job) catch |err| {
            new_job.markAsFailed(err);
            return err;
        };
        new_job.markAsCompleted();
    }

    pub fn dispatchAfter(self: *Self, delay_seconds: i64, queue_name: []const u8, payload: []const u8) !*Job {
        const new_job = try Job.create(self.allocator, "delayed", queue_name, payload);
        _ = new_job.delay(delay_seconds);
        return try self.addJob(new_job);
    }

    pub fn getNextJob(self: *Self) ?*Job {
        return self.driver.pop(self.config.default_queue);
    }

    pub fn getNextJobFrom(self: *Self, queue_name: []const u8) ?*Job {
        return self.driver.pop(queue_name);
    }

    pub fn processJob(self: *Self, process_job: *Job, handler: *const fn (*Job) anyerror!void) !void {
        process_job.markAsProcessing();

        handler(process_job) catch |err| {
            process_job.incrementAttempts();

            if (process_job.canRetry()) {
                const delay_ms = process_job.getRetryDelay();
                process_job.delay_until = getTimestamp() + @as(i64, @intCast(delay_ms / 1000));
                try self.driver.push(process_job);
            } else {
                process_job.markAsFailed(err);
                self.mutex.lock();
                defer self.mutex.unlock();
                try self.failed_jobs.append(self.allocator, process_job);
                if (process_job.unique_key) |key| {
                    _ = self.unique_keys.remove(key);
                }
            }

            return err;
        };

        process_job.markAsCompleted();
        if (process_job.unique_key) |key| {
            self.mutex.lock();
            defer self.mutex.unlock();
            _ = self.unique_keys.remove(key);
        }
    }

    pub fn pendingCount(self: *Self) usize {
        return self.driver.size(self.config.default_queue);
    }

    pub fn pendingCountIn(self: *Self, queue_name: []const u8) usize {
        return self.driver.size(queue_name);
    }

    pub fn failedCount(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.failed_jobs.items.len;
    }

    pub fn getFailedJobs(self: *Self) []const *Job {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.failed_jobs.items;
    }

    pub fn clearFailed(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.failed_jobs.items) |j| {
            j.deinit();
        }
        self.failed_jobs.clearRetainingCapacity();
    }

    pub fn retryFailed(self: *Self) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.failed_jobs.items) |j| {
            j.status = .pending;
            j.attempts = 0;
            j.error_message = null;
            j.delay_until = null;
            try self.driver.push(j);
        }

        self.failed_jobs.clearRetainingCapacity();
    }

    pub fn retryFailedById(self: *Self, id: []const u8) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.failed_jobs.items, 0..) |j, i| {
            if (std.mem.eql(u8, j.id, id)) {
                j.status = .pending;
                j.attempts = 0;
                j.error_message = null;
                try self.driver.push(j);
                _ = self.failed_jobs.swapRemove(i);
                return true;
            }
        }

        return false;
    }

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
            .jobs = .empty,
            .allocator = allocator,
            .current_index = 0,
            .on_chain_complete = null,
            .on_chain_failure = null,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.jobs.items) |j| {
            j.deinit();
        }
        self.jobs.deinit(self.allocator);
    }

    pub fn add(self: *Self, j: *Job) !*Self {
        try self.jobs.append(self.allocator, j);
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

    pub fn execute(self: *Self, handler: *const fn (*Job) anyerror!void) !void {
        for (self.jobs.items) |j| {
            j.markAsProcessing();
            handler(j) catch |err| {
                j.markAsFailed(err);
                if (self.on_chain_failure) |callback| {
                    callback(self, j, err);
                }
                return err;
            };
            j.markAsCompleted();
            self.current_index += 1;
        }

        if (self.on_chain_complete) |callback| {
            callback(self);
        }
    }
};

/// Queue worker
pub const Worker = struct {
    queue_ref: *Queue,
    queue_names: []const []const u8,
    running: std.atomic.Value(bool),
    allocator: std.mem.Allocator,
    sleep_ms: u64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, q: *Queue) Self {
        return .{
            .queue_ref = q,
            .queue_names = &[_][]const u8{q.config.default_queue},
            .running = std.atomic.Value(bool).init(false),
            .allocator = allocator,
            .sleep_ms = q.config.poll_interval_ms,
        };
    }

    pub fn watchQueues(self: *Self, queues: []const []const u8) *Self {
        self.queue_names = queues;
        return self;
    }

    pub fn pollEvery(self: *Self, ms: u64) *Self {
        self.sleep_ms = ms;
        return self;
    }

    pub fn work(self: *Self, handler: *const fn (*Job) anyerror!void) !void {
        self.running.store(true, .release);

        while (self.running.load(.acquire)) {
            var found_job = false;

            for (self.queue_names) |queue_name| {
                if (self.queue_ref.getNextJobFrom(queue_name)) |j| {
                    found_job = true;
                    self.queue_ref.processJob(j, handler) catch {};
                }
            }

            if (!found_job) {
                std.time.sleep(self.sleep_ms * std.time.ns_per_ms);
            }
        }
    }

    pub fn workOnce(self: *Self, handler: *const fn (*Job) anyerror!void, max_jobs: usize) !usize {
        var processed: usize = 0;

        while (processed < max_jobs) {
            var found_job = false;

            for (self.queue_names) |queue_name| {
                if (self.queue_ref.getNextJobFrom(queue_name)) |j| {
                    found_job = true;
                    self.queue_ref.processJob(j, handler) catch {};
                    processed += 1;
                    break;
                }
            }

            if (!found_job) break;
        }

        return processed;
    }

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

    pub fn create(allocator: std.mem.Allocator, id: []const u8) !*Self {
        const batch = try allocator.create(Self);
        batch.* = .{
            .id = try allocator.dupe(u8, id),
            .jobs = .empty,
            .allocator = allocator,
            .on_complete = null,
            .on_failure = null,
        };
        return batch;
    }

    pub fn deinit(self: *Self) void {
        for (self.jobs.items) |j| {
            j.deinit();
        }
        self.jobs.deinit(self.allocator);
        self.allocator.free(self.id);
        self.allocator.destroy(self);
    }

    pub fn add(self: *Self, j: *Job) !*Self {
        try self.jobs.append(self.allocator, j);
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

    pub fn dispatch(self: *Self, q: *Queue) !void {
        for (self.jobs.items) |j| {
            try q.driver.push(j);
        }
        self.jobs.clearRetainingCapacity();
    }

    pub fn isComplete(self: *Self) bool {
        for (self.jobs.items) |j| {
            if (j.status != .completed) {
                return false;
            }
        }
        return true;
    }

    pub fn hasFailures(self: *Self) bool {
        for (self.jobs.items) |j| {
            if (j.status == .failed) {
                return true;
            }
        }
        return false;
    }

    pub fn completedCount(self: *Self) usize {
        var count: usize = 0;
        for (self.jobs.items) |j| {
            if (j.status == .completed) {
                count += 1;
            }
        }
        return count;
    }

    pub fn failedCountBatch(self: *Self) usize {
        var count: usize = 0;
        for (self.jobs.items) |j| {
            if (j.status == .failed) {
                count += 1;
            }
        }
        return count;
    }
};

// Tests
test "job creation with fluent api" {
    const allocator = std.testing.allocator;
    const j = try Job.create(allocator, "SendEmail", "emails", "{\"to\": \"test@example.com\"}");
    defer j.deinit();

    _ = j.tries(5).timeout(30000).delay(60).highPriority();

    try std.testing.expectEqual(@as(u32, 5), j.max_attempts);
    try std.testing.expectEqual(@as(u64, 30000), j.timeout_ms);
    try std.testing.expectEqual(@as(u8, 32), j.priority);
    try std.testing.expect(j.delay_until != null);
}

test "backoff strategy calculations" {
    const fixed = BackoffConfig.fixed(1000);
    try std.testing.expectEqual(@as(u64, 1000), fixed.calculateDelay(0));
    try std.testing.expectEqual(@as(u64, 1000), fixed.calculateDelay(5));

    const expo = BackoffConfig.exponential(1000, 2.0);
    try std.testing.expectEqual(@as(u64, 1000), expo.calculateDelay(0));
    try std.testing.expectEqual(@as(u64, 2000), expo.calculateDelay(1));
    try std.testing.expectEqual(@as(u64, 4000), expo.calculateDelay(2));

    const custom_delays = [_]u64{ 1000, 5000, 10000 };
    const custom = BackoffConfig.custom(&custom_delays);
    try std.testing.expectEqual(@as(u64, 1000), custom.calculateDelay(0));
    try std.testing.expectEqual(@as(u64, 5000), custom.calculateDelay(1));
    try std.testing.expectEqual(@as(u64, 10000), custom.calculateDelay(2));
    try std.testing.expectEqual(@as(u64, 10000), custom.calculateDelay(5));
}

test "queue with job builder" {
    const allocator = std.testing.allocator;
    var q = try Queue.init(allocator, QueueConfig.default());
    defer q.deinit();

    var builder = try q.job("ProcessPayment", "{\"amount\": 100}");
    _ = builder.tries(3).timeout(5000).highPriority();
    const created_job = try builder.dispatch();

    try std.testing.expectEqualStrings("ProcessPayment", created_job.name);
    try std.testing.expectEqual(@as(u32, 3), created_job.max_attempts);
    try std.testing.expectEqual(@as(usize, 1), q.pendingCount());
}

test "unique job prevention" {
    const allocator = std.testing.allocator;
    var q = try Queue.init(allocator, QueueConfig.default());
    defer q.deinit();

    var builder1 = try q.job("SendEmail", "{}");
    _ = try builder1.unique("email_user_123");
    _ = try builder1.dispatch();

    var builder2 = try q.job("SendEmail", "{}");
    _ = try builder2.unique("email_user_123");

    const result = builder2.dispatch();
    try std.testing.expectError(error.DuplicateJob, result);
}

test "worker processes jobs" {
    const allocator = std.testing.allocator;
    var q = try Queue.init(allocator, QueueConfig.default());
    defer q.deinit();

    _ = try q.dispatch("default", "job1");
    _ = try q.dispatch("default", "job2");

    var worker = Worker.init(allocator, &q);

    const Handler = struct {
        fn handle(_: *Job) anyerror!void {}
    };

    const processed = try worker.workOnce(Handler.handle, 10);
    try std.testing.expectEqual(@as(usize, 2), processed);
}
