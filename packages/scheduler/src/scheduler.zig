const std = @import("std");
const posix = std.posix;

/// Cron-like expression for scheduling
pub const CronExpr = struct {
    minute: FieldSpec = .{ .any = {} },
    hour: FieldSpec = .{ .any = {} },
    day_of_month: FieldSpec = .{ .any = {} },
    month: FieldSpec = .{ .any = {} },
    day_of_week: FieldSpec = .{ .any = {} },

    pub const FieldSpec = union(enum) {
        any: void,
        value: u8,
        range: struct { start: u8, end: u8 },
        step: struct { base: u8, step: u8 },
        list: []const u8,
    };

    /// Parse a cron expression string
    /// Format: "minute hour day-of-month month day-of-week"
    /// Supports: * (any), specific values, ranges (1-5), steps (*/5)
    pub fn parse(expr: []const u8) !CronExpr {
        var result = CronExpr{};
        var field_idx: usize = 0;
        var iter = std.mem.splitScalar(u8, expr, ' ');

        while (iter.next()) |field| {
            if (field.len == 0) continue;
            const spec = try parseField(field);

            switch (field_idx) {
                0 => result.minute = spec,
                1 => result.hour = spec,
                2 => result.day_of_month = spec,
                3 => result.month = spec,
                4 => result.day_of_week = spec,
                else => return error.TooManyFields,
            }
            field_idx += 1;
        }

        if (field_idx < 5) return error.NotEnoughFields;
        return result;
    }

    fn parseField(field: []const u8) !FieldSpec {
        if (std.mem.eql(u8, field, "*")) {
            return .{ .any = {} };
        }

        // Check for step (*/5 or 0-59/5)
        if (std.mem.indexOfScalar(u8, field, '/')) |slash_pos| {
            const base_part = field[0..slash_pos];
            const step_part = field[slash_pos + 1 ..];
            const step_val = try std.fmt.parseInt(u8, step_part, 10);

            if (std.mem.eql(u8, base_part, "*")) {
                return .{ .step = .{ .base = 0, .step = step_val } };
            } else if (std.mem.indexOfScalar(u8, base_part, '-')) |dash_pos| {
                const start = try std.fmt.parseInt(u8, base_part[0..dash_pos], 10);
                return .{ .step = .{ .base = start, .step = step_val } };
            } else {
                const base = try std.fmt.parseInt(u8, base_part, 10);
                return .{ .step = .{ .base = base, .step = step_val } };
            }
        }

        // Check for range (1-5)
        if (std.mem.indexOfScalar(u8, field, '-')) |dash_pos| {
            const start = try std.fmt.parseInt(u8, field[0..dash_pos], 10);
            const end = try std.fmt.parseInt(u8, field[dash_pos + 1 ..], 10);
            return .{ .range = .{ .start = start, .end = end } };
        }

        // Single value
        const val = try std.fmt.parseInt(u8, field, 10);
        return .{ .value = val };
    }

    /// Check if a given time matches this cron expression
    pub fn matches(self: CronExpr, time: DateTime) bool {
        return matchesField(self.minute, time.minute) and
            matchesField(self.hour, time.hour) and
            matchesField(self.day_of_month, time.day) and
            matchesField(self.month, time.month) and
            matchesField(self.day_of_week, time.weekday);
    }

    fn matchesField(spec: FieldSpec, value: u8) bool {
        return switch (spec) {
            .any => true,
            .value => |v| v == value,
            .range => |r| value >= r.start and value <= r.end,
            .step => |s| (value >= s.base) and (@mod(value - s.base, s.step) == 0),
            .list => |l| std.mem.indexOfScalar(u8, l, value) != null,
        };
    }

    // Preset schedules
    pub fn everyMinute() CronExpr {
        return .{};
    }

    pub fn hourly() CronExpr {
        return .{ .minute = .{ .value = 0 } };
    }

    pub fn daily(hour: u8, minute: u8) CronExpr {
        return .{
            .minute = .{ .value = minute },
            .hour = .{ .value = hour },
        };
    }

    pub fn weekly(day: u8, hour: u8, minute: u8) CronExpr {
        return .{
            .minute = .{ .value = minute },
            .hour = .{ .value = hour },
            .day_of_week = .{ .value = day },
        };
    }

    pub fn monthly(day: u8, hour: u8, minute: u8) CronExpr {
        return .{
            .minute = .{ .value = minute },
            .hour = .{ .value = hour },
            .day_of_month = .{ .value = day },
        };
    }
};

/// Simple DateTime representation
pub const DateTime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    weekday: u8, // 0 = Sunday, 6 = Saturday

    pub fn now() DateTime {
        return fromTimestamp(getTimestamp());
    }

    pub fn fromTimestamp(timestamp: i64) DateTime {
        // Convert Unix timestamp to DateTime components
        var remaining = timestamp;

        // Calculate seconds, minutes, hours
        const second: u8 = @intCast(@mod(remaining, 60));
        remaining = @divTrunc(remaining, 60);
        const minute: u8 = @intCast(@mod(remaining, 60));
        remaining = @divTrunc(remaining, 60);
        const hour: u8 = @intCast(@mod(remaining, 24));
        remaining = @divTrunc(remaining, 24);

        // Days since epoch (Jan 1, 1970)
        var days = remaining;

        // Calculate weekday (Jan 1, 1970 was Thursday = 4)
        const weekday: u8 = @intCast(@mod(days + 4, 7));

        // Calculate year
        var year: u16 = 1970;
        while (true) {
            const days_in_year: i64 = if (isLeapYear(year)) 366 else 365;
            if (days < days_in_year) break;
            days -= days_in_year;
            year += 1;
        }

        // Calculate month and day
        const days_in_months = if (isLeapYear(year))
            [_]u8{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
        else
            [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

        var month: u8 = 1;
        for (days_in_months) |dim| {
            if (days < dim) break;
            days -= dim;
            month += 1;
        }

        const day: u8 = @intCast(days + 1);

        return .{
            .year = year,
            .month = month,
            .day = day,
            .hour = hour,
            .minute = minute,
            .second = second,
            .weekday = weekday,
        };
    }

    pub fn toTimestamp(self: DateTime) i64 {
        var days: i64 = 0;

        // Add days for years since 1970
        var y: u16 = 1970;
        while (y < self.year) : (y += 1) {
            days += if (isLeapYear(y)) 366 else 365;
        }

        // Add days for months
        const days_in_months = if (isLeapYear(self.year))
            [_]u8{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
        else
            [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

        var m: u8 = 1;
        while (m < self.month) : (m += 1) {
            days += days_in_months[m - 1];
        }

        // Add days
        days += self.day - 1;

        // Convert to seconds and add time
        return days * 86400 + @as(i64, self.hour) * 3600 + @as(i64, self.minute) * 60 + self.second;
    }

    fn isLeapYear(year: u16) bool {
        return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
    }
};

/// Get current timestamp
fn getTimestamp() i64 {
    const ts = posix.clock_gettime(.REALTIME) catch return 0;
    return ts.sec;
}

/// Scheduled task definition
pub const Task = struct {
    name: []const u8,
    schedule: CronExpr,
    callback: *const fn (*TaskContext) void,
    timezone_offset: i16 = 0, // Offset from UTC in minutes
    enabled: bool = true,
    last_run: ?i64 = null,
    next_run: ?i64 = null,
    run_count: u64 = 0,
    error_count: u64 = 0,
    max_retries: u8 = 3,
    retry_delay_seconds: u32 = 60,
};

/// Context passed to task callbacks
pub const TaskContext = struct {
    task_name: []const u8,
    scheduled_time: i64,
    actual_time: i64,
    run_count: u64,
    allocator: std.mem.Allocator,
    user_data: ?*anyopaque = null,
};

/// Task Scheduler
pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    tasks: std.StringHashMap(Task),
    running: bool,
    mutex: std.Thread.Mutex,
    check_interval_ms: u64 = 1000, // Check every second by default

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .tasks = std.StringHashMap(Task).init(allocator),
            .running = false,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        var iter = self.tasks.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.tasks.deinit();
    }

    /// Register a new scheduled task
    pub fn register(self: *Self, name: []const u8, schedule: CronExpr, callback: *const fn (*TaskContext) void) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);

        try self.tasks.put(key, Task{
            .name = key,
            .schedule = schedule,
            .callback = callback,
        });
    }

    /// Register task with options
    pub fn registerWithOptions(self: *Self, name: []const u8, task: Task) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);

        var t = task;
        t.name = key;
        try self.tasks.put(key, t);
    }

    /// Unregister a task
    pub fn unregister(self: *Self, name: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.tasks.fetchRemove(name)) |removed| {
            self.allocator.free(removed.key);
        }
    }

    /// Enable a task
    pub fn enable(self: *Self, name: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.tasks.getPtr(name)) |task| {
            task.enabled = true;
        }
    }

    /// Disable a task
    pub fn disable(self: *Self, name: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.tasks.getPtr(name)) |task| {
            task.enabled = false;
        }
    }

    /// Get task info
    pub fn getTask(self: *Self, name: []const u8) ?Task {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.tasks.get(name);
    }

    /// List all registered tasks
    pub fn listTasks(self: *Self, allocator: std.mem.Allocator) ![]const Task {
        self.mutex.lock();
        defer self.mutex.unlock();

        var list: std.ArrayListUnmanaged(Task) = .empty;
        errdefer list.deinit(allocator);

        var iter = self.tasks.iterator();
        while (iter.next()) |entry| {
            try list.append(allocator, entry.value_ptr.*);
        }

        return list.toOwnedSlice(allocator);
    }

    /// Check and run due tasks (call this periodically)
    pub fn tick(self: *Self) void {
        const now = getTimestamp();
        const dt = DateTime.fromTimestamp(now);

        self.mutex.lock();
        defer self.mutex.unlock();

        var iter = self.tasks.iterator();
        while (iter.next()) |entry| {
            const task = entry.value_ptr;
            if (!task.enabled) continue;

            // Check if task should run
            if (task.schedule.matches(dt)) {
                // Avoid running multiple times in same minute
                if (task.last_run) |last| {
                    const last_dt = DateTime.fromTimestamp(last);
                    if (last_dt.minute == dt.minute and
                        last_dt.hour == dt.hour and
                        last_dt.day == dt.day)
                    {
                        continue;
                    }
                }

                // Run the task
                var ctx = TaskContext{
                    .task_name = task.name,
                    .scheduled_time = now,
                    .actual_time = now,
                    .run_count = task.run_count,
                    .allocator = self.allocator,
                };

                task.callback(&ctx);
                task.last_run = now;
                task.run_count += 1;
            }
        }
    }

    /// Start the scheduler loop (blocking)
    pub fn start(self: *Self) void {
        self.running = true;
        while (self.running) {
            self.tick();
            std.time.sleep(self.check_interval_ms * std.time.ns_per_ms);
        }
    }

    /// Stop the scheduler
    pub fn stop(self: *Self) void {
        self.running = false;
    }

    /// Run a specific task immediately
    pub fn runNow(self: *Self, name: []const u8) !void {
        self.mutex.lock();

        const task = self.tasks.getPtr(name) orelse {
            self.mutex.unlock();
            return error.TaskNotFound;
        };

        const now = getTimestamp();
        var ctx = TaskContext{
            .task_name = task.name,
            .scheduled_time = now,
            .actual_time = now,
            .run_count = task.run_count,
            .allocator = self.allocator,
        };

        self.mutex.unlock();

        task.callback(&ctx);

        self.mutex.lock();
        task.last_run = now;
        task.run_count += 1;
        self.mutex.unlock();
    }
};

/// Job queue for one-off delayed tasks
pub const JobQueue = struct {
    allocator: std.mem.Allocator,
    jobs: std.ArrayListUnmanaged(Job),
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub const Job = struct {
        id: u64,
        run_at: i64,
        callback: *const fn (*JobContext) void,
        data: ?*anyopaque = null,
        completed: bool = false,
    };

    pub const JobContext = struct {
        job_id: u64,
        scheduled_time: i64,
        actual_time: i64,
        data: ?*anyopaque,
        allocator: std.mem.Allocator,
    };

    var next_id: u64 = 0;

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .jobs = .empty,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.jobs.deinit(self.allocator);
    }

    /// Schedule a job to run after a delay
    pub fn scheduleAfter(self: *Self, delay_seconds: i64, callback: *const fn (*JobContext) void) !u64 {
        return self.scheduleAt(getTimestamp() + delay_seconds, callback);
    }

    /// Schedule a job to run at a specific time
    pub fn scheduleAt(self: *Self, run_at: i64, callback: *const fn (*JobContext) void) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const id = next_id;
        next_id += 1;

        try self.jobs.append(self.allocator, .{
            .id = id,
            .run_at = run_at,
            .callback = callback,
        });

        return id;
    }

    /// Cancel a scheduled job
    pub fn cancel(self: *Self, job_id: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.jobs.items, 0..) |job, i| {
            if (job.id == job_id and !job.completed) {
                _ = self.jobs.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Process due jobs
    pub fn tick(self: *Self) void {
        const now = getTimestamp();

        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 0;
        while (i < self.jobs.items.len) {
            var job = &self.jobs.items[i];
            if (!job.completed and job.run_at <= now) {
                var ctx = JobContext{
                    .job_id = job.id,
                    .scheduled_time = job.run_at,
                    .actual_time = now,
                    .data = job.data,
                    .allocator = self.allocator,
                };
                job.callback(&ctx);
                job.completed = true;
            }
            i += 1;
        }

        // Clean up completed jobs
        var j: usize = 0;
        while (j < self.jobs.items.len) {
            if (self.jobs.items[j].completed) {
                _ = self.jobs.orderedRemove(j);
            } else {
                j += 1;
            }
        }
    }

    /// Get pending job count
    pub fn pendingCount(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var count: usize = 0;
        for (self.jobs.items) |job| {
            if (!job.completed) count += 1;
        }
        return count;
    }
};

/// Timezone utilities
pub const Timezone = struct {
    /// Common timezone offsets (in minutes from UTC)
    pub const UTC: i16 = 0;
    pub const EST: i16 = -5 * 60; // Eastern Standard
    pub const EDT: i16 = -4 * 60; // Eastern Daylight
    pub const CST: i16 = -6 * 60; // Central Standard
    pub const CDT: i16 = -5 * 60; // Central Daylight
    pub const MST: i16 = -7 * 60; // Mountain Standard
    pub const MDT: i16 = -6 * 60; // Mountain Daylight
    pub const PST: i16 = -8 * 60; // Pacific Standard
    pub const PDT: i16 = -7 * 60; // Pacific Daylight
    pub const GMT: i16 = 0;
    pub const CET: i16 = 1 * 60; // Central European
    pub const EET: i16 = 2 * 60; // Eastern European
    pub const JST: i16 = 9 * 60; // Japan Standard
    pub const AEST: i16 = 10 * 60; // Australian Eastern Standard

    /// Convert timestamp from one timezone to another
    pub fn convert(timestamp: i64, from_offset: i16, to_offset: i16) i64 {
        const diff = @as(i64, to_offset - from_offset) * 60;
        return timestamp + diff;
    }

    /// Get timestamp in specific timezone
    pub fn inTimezone(offset: i16) i64 {
        return getTimestamp() + @as(i64, offset) * 60;
    }
};

// Tests
test "cron expression parsing" {
    // Every minute
    const every_min = try CronExpr.parse("* * * * *");
    try std.testing.expect(every_min.minute == .any);

    // Specific time
    const specific = try CronExpr.parse("30 14 * * *");
    try std.testing.expectEqual(@as(u8, 30), specific.minute.value);
    try std.testing.expectEqual(@as(u8, 14), specific.hour.value);

    // Range
    const range = try CronExpr.parse("0-30 * * * *");
    try std.testing.expectEqual(@as(u8, 0), range.minute.range.start);
    try std.testing.expectEqual(@as(u8, 30), range.minute.range.end);

    // Step
    const step = try CronExpr.parse("*/15 * * * *");
    try std.testing.expectEqual(@as(u8, 0), step.minute.step.base);
    try std.testing.expectEqual(@as(u8, 15), step.minute.step.step);
}

test "cron matching" {
    const schedule = CronExpr.daily(14, 30); // 2:30 PM daily

    const match_time = DateTime{
        .year = 2024,
        .month = 6,
        .day = 15,
        .hour = 14,
        .minute = 30,
        .second = 0,
        .weekday = 6,
    };

    const no_match_time = DateTime{
        .year = 2024,
        .month = 6,
        .day = 15,
        .hour = 15,
        .minute = 30,
        .second = 0,
        .weekday = 6,
    };

    try std.testing.expect(schedule.matches(match_time));
    try std.testing.expect(!schedule.matches(no_match_time));
}

test "preset schedules" {
    const hourly = CronExpr.hourly();
    try std.testing.expectEqual(@as(u8, 0), hourly.minute.value);

    const weekly = CronExpr.weekly(1, 9, 0); // Monday 9:00 AM
    try std.testing.expectEqual(@as(u8, 0), weekly.minute.value);
    try std.testing.expectEqual(@as(u8, 9), weekly.hour.value);
    try std.testing.expectEqual(@as(u8, 1), weekly.day_of_week.value);
}

test "datetime conversion" {
    // Test a known timestamp: Jan 1, 2024 00:00:00 UTC = 1704067200
    const dt = DateTime.fromTimestamp(1704067200);
    try std.testing.expectEqual(@as(u16, 2024), dt.year);
    try std.testing.expectEqual(@as(u8, 1), dt.month);
    try std.testing.expectEqual(@as(u8, 1), dt.day);
    try std.testing.expectEqual(@as(u8, 0), dt.hour);
    try std.testing.expectEqual(@as(u8, 0), dt.minute);

    // Round-trip test
    const ts = dt.toTimestamp();
    try std.testing.expectEqual(@as(i64, 1704067200), ts);
}

test "scheduler registration" {
    const allocator = std.testing.allocator;

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    const dummy_callback = struct {
        fn callback(_: *TaskContext) void {}
    }.callback;

    try scheduler.register("test-task", CronExpr.everyMinute(), dummy_callback);

    const task = scheduler.getTask("test-task");
    try std.testing.expect(task != null);
    try std.testing.expectEqualStrings("test-task", task.?.name);
    try std.testing.expect(task.?.enabled);

    scheduler.disable("test-task");
    const disabled_task = scheduler.getTask("test-task");
    try std.testing.expect(!disabled_task.?.enabled);

    scheduler.unregister("test-task");
    try std.testing.expect(scheduler.getTask("test-task") == null);
}

test "job queue scheduling" {
    const allocator = std.testing.allocator;

    var queue = JobQueue.init(allocator);
    defer queue.deinit();

    const dummy_callback = struct {
        fn callback(_: *JobQueue.JobContext) void {}
    }.callback;

    const job_id = try queue.scheduleAfter(60, dummy_callback);
    try std.testing.expectEqual(@as(usize, 1), queue.pendingCount());

    const cancelled = queue.cancel(job_id);
    try std.testing.expect(cancelled);
    try std.testing.expectEqual(@as(usize, 0), queue.pendingCount());
}

test "timezone conversion" {
    // EST to PST (3 hours difference)
    const est_time: i64 = 1704067200;
    const pst_time = Timezone.convert(est_time, Timezone.EST, Timezone.PST);
    try std.testing.expectEqual(est_time - 3 * 3600, pst_time);
}
