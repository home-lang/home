const std = @import("std");
const testing = std.testing;
const queue = @import("queue");

test "queue: create job" {
    const allocator = testing.allocator;

    const job = try queue.Job.create(allocator, "test_job", "default", "test payload");
    defer job.deinit();

    try testing.expectEqual(queue.JobStatus.pending, job.status);
    try testing.expectEqual(@as(u32, 0), job.attempts);
    try testing.expectEqual(@as(u32, 3), job.max_attempts);
    try testing.expectEqualStrings("default", job.queue_name);
    try testing.expectEqualStrings("test payload", job.payload);
}

test "queue: job attempts and retry" {
    const allocator = testing.allocator;

    const job = try queue.Job.create(allocator, "test_job", "default", "test");
    defer job.deinit();

    try testing.expect(job.canRetry());

    job.incrementAttempts();
    try testing.expectEqual(@as(u32, 1), job.attempts);
    try testing.expectEqual(queue.JobStatus.retrying, job.status);
    try testing.expect(job.canRetry());

    job.incrementAttempts();
    try testing.expectEqual(@as(u32, 2), job.attempts);
    try testing.expect(job.canRetry());

    job.incrementAttempts();
    try testing.expectEqual(@as(u32, 3), job.attempts);
    try testing.expectEqual(queue.JobStatus.failed, job.status);
    try testing.expect(!job.canRetry());
}

test "queue: job status transitions" {
    const allocator = testing.allocator;

    const job = try queue.Job.create(allocator, "test_job", "default", "test");
    defer job.deinit();

    try testing.expectEqual(queue.JobStatus.pending, job.status);

    job.markAsProcessing();
    try testing.expectEqual(queue.JobStatus.processing, job.status);

    job.markAsCompleted();
    try testing.expectEqual(queue.JobStatus.completed, job.status);
}

test "queue: initialize queue" {
    const allocator = testing.allocator;

    const config = queue.QueueConfig.default();
    var q = try queue.Queue.init(allocator, config);
    defer q.deinit();

    try testing.expectEqual(@as(usize, 0), q.pendingCount());
    try testing.expectEqual(@as(usize, 0), q.failedCount());
}

test "queue: dispatch job" {
    const allocator = testing.allocator;

    const config = queue.QueueConfig.default();
    var q = try queue.Queue.init(allocator, config);
    defer q.deinit();

    const job = try q.dispatch("default", "test payload");

    try testing.expectEqual(@as(usize, 1), q.pendingCount());
    try testing.expectEqualStrings("default", job.queue_name);
    try testing.expectEqualStrings("test payload", job.payload);
}

test "queue: dispatch sync" {
    const allocator = testing.allocator;

    const config = queue.QueueConfig.default();
    var q = try queue.Queue.init(allocator, config);
    defer q.deinit();

    const handler = struct {
        fn handle(j: *queue.Job) !void {
            _ = j;
            // Sync handler
        }
    }.handle;

    try q.dispatchSync("default", "sync payload", handler);

    // Sync jobs execute immediately and don't stay in queue
    try testing.expectEqual(@as(usize, 0), q.pendingCount());
}

test "queue: dispatch after delay" {
    const allocator = testing.allocator;

    const config = queue.QueueConfig.default();
    var q = try queue.Queue.init(allocator, config);
    defer q.deinit();

    const job = try q.dispatchAfter(60, "default", "delayed payload");

    try testing.expectEqual(@as(usize, 1), q.pendingCount());
    try testing.expect(job.delay_until != null);
}

test "queue: get next job" {
    const allocator = testing.allocator;

    const config = queue.QueueConfig.default();
    var q = try queue.Queue.init(allocator, config);
    defer q.deinit();

    _ = try q.dispatch("default", "job 1");
    _ = try q.dispatch("default", "job 2");

    try testing.expectEqual(@as(usize, 2), q.pendingCount());

    const job1 = q.getNextJob();
    try testing.expect(job1 != null);
    defer job1.?.deinit();
    try testing.expectEqual(@as(usize, 1), q.pendingCount());

    const job2 = q.getNextJob();
    try testing.expect(job2 != null);
    defer job2.?.deinit();
    try testing.expectEqual(@as(usize, 0), q.pendingCount());

    const job3 = q.getNextJob();
    try testing.expect(job3 == null);
}

test "queue: process job success" {
    const allocator = testing.allocator;

    const config = queue.QueueConfig.default();
    var q = try queue.Queue.init(allocator, config);
    defer q.deinit();

    const job = try q.dispatch("default", "test");
    defer job.deinit(); // Job must be freed after successful processing

    const handler = struct {
        fn handle(j: *queue.Job) !void {
            _ = j;
            // Successful processing
        }
    }.handle;

    _ = q.getNextJob(); // Remove from pending
    try q.processJob(job, handler);

    try testing.expectEqual(queue.JobStatus.completed, job.status);
    try testing.expectEqual(@as(usize, 0), q.failedCount());
}

test "queue: process job failure with retry" {
    const allocator = testing.allocator;

    const config = queue.QueueConfig.default();
    var q = try queue.Queue.init(allocator, config);
    defer q.deinit();

    const job = try q.dispatch("default", "test");
    _ = q.getNextJob(); // Remove from pending

    const handler = struct {
        fn handle(j: *queue.Job) !void {
            _ = j;
            return error.ProcessingFailed;
        }
    }.handle;

    const result = q.processJob(job, handler);
    try testing.expectError(error.ProcessingFailed, result);

    try testing.expectEqual(queue.JobStatus.retrying, job.status);
    try testing.expectEqual(@as(u32, 1), job.attempts);
    try testing.expectEqual(@as(usize, 1), q.pendingCount()); // Re-queued
}

test "queue: process job failure max attempts" {
    const allocator = testing.allocator;

    const config = queue.QueueConfig.default();
    var q = try queue.Queue.init(allocator, config);
    defer q.deinit();

    const job = try q.dispatch("default", "test");
    job.attempts = 2; // Set to 2, next failure will be 3rd attempt
    _ = q.getNextJob(); // Remove from pending

    const handler = struct {
        fn handle(j: *queue.Job) !void {
            _ = j;
            return error.ProcessingFailed;
        }
    }.handle;

    const result = q.processJob(job, handler);
    try testing.expectError(error.ProcessingFailed, result);

    try testing.expectEqual(queue.JobStatus.failed, job.status);
    try testing.expectEqual(@as(u32, 3), job.attempts);
    try testing.expectEqual(@as(usize, 1), q.failedCount());
}

test "queue: retry failed jobs" {
    const allocator = testing.allocator;

    const config = queue.QueueConfig.default();
    var q = try queue.Queue.init(allocator, config);
    defer q.deinit();

    const job1 = try q.dispatch("default", "job 1");
    const job2 = try q.dispatch("default", "job 2");

    job1.markAsFailed(error.ProcessingFailed);
    job2.markAsFailed(error.ProcessingFailed);
    job1.attempts = 3;
    job2.attempts = 3;

    // Manually move to failed queue for testing
    _ = q.getNextJob();
    _ = q.getNextJob();
    try q.failed_jobs.append(q.allocator, job1);
    try q.failed_jobs.append(q.allocator, job2);

    try testing.expectEqual(@as(usize, 2), q.failedCount());
    try testing.expectEqual(@as(usize, 0), q.pendingCount());

    try q.retryFailed();

    try testing.expectEqual(@as(usize, 0), q.failedCount());
    try testing.expectEqual(@as(usize, 2), q.pendingCount());
    try testing.expectEqual(@as(u32, 0), job1.attempts);
    try testing.expectEqual(@as(u32, 0), job2.attempts);
    try testing.expectEqual(queue.JobStatus.pending, job1.status);
}

test "queue: clear failed jobs" {
    const allocator = testing.allocator;

    const config = queue.QueueConfig.default();
    var q = try queue.Queue.init(allocator, config);
    defer q.deinit();

    const job = try q.dispatch("default", "test");
    job.markAsFailed(error.ProcessingFailed);

    _ = q.getNextJob();
    try q.failed_jobs.append(q.allocator, job);

    try testing.expectEqual(@as(usize, 1), q.failedCount());

    q.clearFailed();

    try testing.expectEqual(@as(usize, 0), q.failedCount());
}

test "queue: flush all jobs" {
    const allocator = testing.allocator;

    const config = queue.QueueConfig.default();
    var q = try queue.Queue.init(allocator, config);
    defer q.deinit();

    _ = try q.dispatch("default", "job 1");
    _ = try q.dispatch("default", "job 2");
    _ = try q.dispatch("default", "job 3");

    try testing.expectEqual(@as(usize, 3), q.pendingCount());

    q.flush();

    try testing.expectEqual(@as(usize, 0), q.pendingCount());
    try testing.expectEqual(@as(usize, 0), q.failedCount());
}

test "queue: batch initialization" {
    const allocator = testing.allocator;

    const batch = try queue.Batch.create(allocator, "batch_123");
    defer batch.deinit();

    try testing.expectEqualStrings("batch_123", batch.id);
    try testing.expectEqual(@as(usize, 0), batch.jobs.items.len);
}

test "queue: batch add jobs" {
    const allocator = testing.allocator;

    const batch = try queue.Batch.create(allocator, "batch_123");
    defer batch.deinit();

    const job1 = try queue.Job.create(allocator, "job1", "default", "job 1");
    const job2 = try queue.Job.create(allocator, "job2", "default", "job 2");

    _ = try batch.add(job1);
    _ = try batch.add(job2);

    try testing.expectEqual(@as(usize, 2), batch.jobs.items.len);
}

test "queue: batch dispatch" {
    const allocator = testing.allocator;

    const config = queue.QueueConfig.default();
    var q = try queue.Queue.init(allocator, config);
    defer q.deinit();

    const batch = try queue.Batch.create(allocator, "batch_123");
    defer batch.deinit();

    const job1 = try queue.Job.create(allocator, "job1", "default", "job 1");
    const job2 = try queue.Job.create(allocator, "job2", "default", "job 2");

    _ = try batch.add(job1);
    _ = try batch.add(job2);

    try batch.dispatch(&q);

    try testing.expectEqual(@as(usize, 2), q.pendingCount());
}

test "queue: batch completion check" {
    const allocator = testing.allocator;

    const batch = try queue.Batch.create(allocator, "batch_123");
    defer batch.deinit();

    const job1 = try queue.Job.create(allocator, "job1", "default", "job 1");
    const job2 = try queue.Job.create(allocator, "job2", "default", "job 2");

    _ = try batch.add(job1);
    _ = try batch.add(job2);

    try testing.expect(!batch.isComplete());

    job1.markAsCompleted();
    try testing.expect(!batch.isComplete());

    job2.markAsCompleted();
    try testing.expect(batch.isComplete());
}

test "queue: batch failure check" {
    const allocator = testing.allocator;

    const batch = try queue.Batch.create(allocator, "batch_123");
    defer batch.deinit();

    const job1 = try queue.Job.create(allocator, "job1", "default", "job 1");
    const job2 = try queue.Job.create(allocator, "job2", "default", "job 2");

    _ = try batch.add(job1);
    _ = try batch.add(job2);

    try testing.expect(!batch.hasFailures());

    job1.markAsFailed(error.ProcessingFailed);
    try testing.expect(batch.hasFailures());
}
