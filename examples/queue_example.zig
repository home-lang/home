const std = @import("std");
const queue_mod = @import("queue");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create queue with default configuration
    const config = queue_mod.QueueConfig.default();
    var queue = queue_mod.Queue.init(allocator, config);
    defer queue.deinit();

    std.debug.print("\n=== Home Queue System Example ===\n\n", .{});

    // Example 1: Dispatch a simple job
    std.debug.print("1. Dispatching a simple job...\n", .{});
    const job1 = try queue.dispatch("default", "Send email to user@example.com");
    std.debug.print("   Job ID: {s}\n", .{job1.id});
    std.debug.print("   Queue: {s}\n", .{job1.queue});
    std.debug.print("   Payload: {s}\n", .{job1.payload});
    std.debug.print("   Status: {s}\n\n", .{@tagName(job1.status)});

    // Example 2: Dispatch with delay
    std.debug.print("2. Dispatching a delayed job (60 seconds)...\n", .{});
    const job2 = try queue.dispatchAfter(60, "emails", "Send weekly newsletter");
    std.debug.print("   Job ID: {s}\n", .{job2.id});
    std.debug.print("   Delay: {d} seconds\n\n", .{job2.delay.?});

    // Example 3: Dispatch synchronously
    std.debug.print("3. Dispatching synchronous job...\n", .{});
    try queue.dispatchSync("default", "Log analytics event");
    std.debug.print("   Job executed immediately\n\n", .{});

    // Example 4: Check queue status
    std.debug.print("4. Queue status:\n", .{});
    std.debug.print("   Pending jobs: {d}\n", .{queue.pendingCount()});
    std.debug.print("   Failed jobs: {d}\n\n", .{queue.failedCount()});

    // Example 5: Process a job
    std.debug.print("5. Processing next job...\n", .{});
    if (queue.getNextJob()) |job| {
        const handler = struct {
            fn process(j: *queue_mod.Job) !void {
                std.debug.print("   Processing: {s}\n", .{j.payload});
                // Simulate work (sleep removed for Zig 0.16 compatibility)
                std.debug.print("   Completed successfully!\n", .{});
            }
        }.process;

        try queue.processJob(job, handler);
        std.debug.print("   Job status: {s}\n\n", .{@tagName(job.status)});
    }

    // Example 6: Batch jobs
    std.debug.print("6. Creating batch of jobs...\n", .{});
    const batch = try queue_mod.Batch.init(allocator, "batch_001");
    defer batch.deinit();

    const batch_job1 = try queue_mod.Job.init(allocator, "batch", "Task 1");
    const batch_job2 = try queue_mod.Job.init(allocator, "batch", "Task 2");
    const batch_job3 = try queue_mod.Job.init(allocator, "batch", "Task 3");

    try batch.add(batch_job1);
    try batch.add(batch_job2);
    try batch.add(batch_job3);

    std.debug.print("   Batch ID: {s}\n", .{batch.id});
    std.debug.print("   Jobs in batch: {d}\n", .{batch.jobs.items.len});

    try batch.dispatch(&queue);
    std.debug.print("   Batch dispatched to queue\n", .{});
    std.debug.print("   Pending jobs: {d}\n\n", .{queue.pendingCount()});

    // Example 7: Process all pending jobs
    std.debug.print("7. Processing all pending jobs...\n", .{});
    const handler = struct {
        fn process(j: *queue_mod.Job) !void {
            std.debug.print("   [{s}] {s}\n", .{ j.queue, j.payload });
            // Sleep removed for Zig 0.16 compatibility
        }
    }.process;

    var processed: usize = 0;
    while (queue.getNextJob()) |job| {
        try queue.processJob(job, handler);
        processed += 1;
    }
    std.debug.print("   Processed {d} jobs\n", .{processed});
    std.debug.print("   Remaining pending: {d}\n\n", .{queue.pendingCount()});

    // Example 8: Handle failed jobs
    std.debug.print("8. Simulating failed job...\n", .{});
    const failing_job = try queue.dispatch("default", "This will fail");

    const failing_handler = struct {
        fn process(j: *queue_mod.Job) !void {
            _ = j;
            return error.ProcessingFailed;
        }
    }.process;

    _ = queue.getNextJob(); // Get the job
    _ = queue.processJob(failing_job, failing_handler) catch |err| {
        std.debug.print("   Job failed with error: {s}\n", .{@errorName(err)});
    };

    std.debug.print("   Job status: {s}\n", .{@tagName(failing_job.status)});
    std.debug.print("   Attempts: {d}/{d}\n", .{ failing_job.attempts, failing_job.max_attempts });
    std.debug.print("   Can retry: {}\n", .{failing_job.canRetry()});
    std.debug.print("   Failed jobs: {d}\n\n", .{queue.failedCount()});

    // Example 9: Retry failed jobs
    if (queue.failedCount() == 0) {
        std.debug.print("9. Retrying failed jobs...\n", .{});
        try queue.retryFailed();
        std.debug.print("   Failed jobs moved back to pending\n", .{});
        std.debug.print("   Pending: {d}, Failed: {d}\n\n", .{ queue.pendingCount(), queue.failedCount() });
    }

    std.debug.print("=== Example Complete ===\n\n", .{});
}
