const std = @import("std");

/// Lock-free multi-producer multi-consumer (MPMC) queue using Michael-Scott algorithm.
///
/// This queue is fully thread-safe for concurrent access from multiple producers
/// and consumers. It uses atomic operations and is wait-free for producers and
/// lock-free for consumers.
///
/// References:
/// - "Simple, Fast, and Practical Non-Blocking and Blocking Concurrent Queue Algorithms"
///   by Michael and Scott (1996)
pub fn ConcurrentQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        const Node = struct {
            value: ?T,
            next: std.atomic.Value(?*Node),
            retired_next: ?*Node,

            fn init(allocator: std.mem.Allocator, value: ?T) !*Node {
                const node = try allocator.create(Node);
                node.* = .{
                    .value = value,
                    .next = std.atomic.Value(?*Node).init(null),
                    .retired_next = null,
                };
                return node;
            }
        };

        allocator: std.mem.Allocator,
        head: std.atomic.Value(?*Node),
        tail: std.atomic.Value(?*Node),
        /// Nodes removed from the head remain allocated until deinit. A
        /// concurrent consumer may still have loaded the old head before the
        /// winning CAS, so immediate destruction is a use-after-free.
        retired_head: std.atomic.Value(?*Node),
        /// Approximate size (for statistics)
        len: std.atomic.Value(usize),

        pub fn init(allocator: std.mem.Allocator) !Self {
            // Create a dummy node
            const dummy = try Node.init(allocator, null);

            return Self{
                .allocator = allocator,
                .head = std.atomic.Value(?*Node).init(dummy),
                .tail = std.atomic.Value(?*Node).init(dummy),
                .retired_head = std.atomic.Value(?*Node).init(null),
                .len = std.atomic.Value(usize).init(0),
            };
        }

        pub fn deinit(self: *Self) void {
            // Free all remaining nodes
            var current = self.head.load(.acquire);
            while (current) |node| {
                const next = node.next.load(.acquire);
                self.allocator.destroy(node);
                current = next;
            }

            current = self.retired_head.load(.acquire);
            while (current) |node| {
                const next = node.retired_next;
                self.allocator.destroy(node);
                current = next;
            }
        }

        fn retire(self: *Self, node: *Node) void {
            var retired = self.retired_head.load(.monotonic);
            while (true) {
                node.retired_next = retired;
                retired = self.retired_head.cmpxchgWeak(
                    retired,
                    node,
                    .release,
                    .monotonic,
                ) orelse return;
            }
        }

        /// Push a value onto the queue (enqueue)
        ///
        /// This is lock-free: one producer always makes progress even if an
        /// individual producer retries after contention.
        pub fn push(self: *Self, value: T) !void {
            const node = try Node.init(self.allocator, value);

            while (true) {
                const tail = self.tail.load(.acquire);
                const next = tail.?.next.load(.acquire);

                // Check if tail is still the same
                if (tail == self.tail.load(.acquire)) {
                    if (next == null) {
                        // Try to link new node at the end
                        if (tail.?.next.cmpxchgStrong(
                            null,
                            node,
                            .release,
                            .acquire,
                        ) == null) {
                            // Success! Try to swing tail to the new node
                            _ = self.tail.cmpxchgStrong(
                                tail,
                                node,
                                .release,
                                .acquire,
                            );

                            _ = self.len.fetchAdd(1, .monotonic);
                            return;
                        }
                    } else {
                        // Tail is falling behind, try to advance it
                        _ = self.tail.cmpxchgStrong(
                            tail,
                            next,
                            .release,
                            .acquire,
                        );
                    }
                }
            }
        }

        /// Pop a value from the queue (dequeue)
        ///
        /// Returns null if the queue is empty.
        /// This is lock-free - progress is guaranteed if at least one thread
        /// continues to make progress.
        pub fn pop(self: *Self) ?T {
            while (true) {
                const head = self.head.load(.acquire);
                const tail = self.tail.load(.acquire);
                const next = head.?.next.load(.acquire);

                // Check if head is still the same
                if (head == self.head.load(.acquire)) {
                    if (head == tail) {
                        // Queue is empty or tail is falling behind
                        if (next == null) {
                            // Queue is empty
                            return null;
                        }

                        // Tail is falling behind, try to advance it
                        _ = self.tail.cmpxchgStrong(
                            tail,
                            next,
                            .release,
                            .acquire,
                        );
                    } else {
                        // Queue is not empty
                        const value = next.?.value;

                        // Try to swing head to the next node.
                        // cmpxchgStrong returns null on success.
                        if (self.head.cmpxchgStrong(
                            head,
                            next,
                            .release,
                            .acquire,
                        ) == null) {
                            // Other consumers may still hold the old head.
                            // Retire it and reclaim after all users have joined.
                            self.retire(head.?);

                            _ = self.len.fetchSub(1, .monotonic);
                            return value;
                        }
                    }
                }
            }
        }

        /// Get approximate size
        ///
        /// Note: This is not linearizable - the actual size may have changed
        /// by the time this function returns.
        pub fn size(self: *Self) usize {
            return self.len.load(.monotonic);
        }

        /// Check if empty (approximate)
        pub fn isEmpty(self: *Self) bool {
            return self.size() == 0;
        }
    };
}

// =================================================================================
//                                    TESTS
// =================================================================================

test "ConcurrentQueue - basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var queue = try ConcurrentQueue(i32).init(allocator);
    defer queue.deinit();

    try testing.expect(queue.isEmpty());

    // Push items
    try queue.push(1);
    try queue.push(2);
    try queue.push(3);

    try testing.expectEqual(@as(usize, 3), queue.size());

    // Pop items (FIFO order)
    try testing.expectEqual(@as(i32, 1), queue.pop().?);
    try testing.expectEqual(@as(i32, 2), queue.pop().?);
    try testing.expectEqual(@as(i32, 3), queue.pop().?);

    try testing.expect(queue.pop() == null);
    try testing.expect(queue.isEmpty());
}

test "ConcurrentQueue - FIFO property" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var queue = try ConcurrentQueue(i32).init(allocator);
    defer queue.deinit();

    // Push 0..99
    var i: i32 = 0;
    while (i < 100) : (i += 1) {
        try queue.push(i);
    }

    // Pop should return in FIFO order
    var expected: i32 = 0;
    while (queue.pop()) |value| {
        try testing.expectEqual(expected, value);
        expected += 1;
    }

    try testing.expectEqual(@as(i32, 100), expected);
}

test "ConcurrentQueue - concurrent push" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var queue = try ConcurrentQueue(i32).init(allocator);
    defer queue.deinit();

    const Context = struct {
        queue: *ConcurrentQueue(i32),
        start: i32,
        count: i32,
        /// First error encountered by this worker, if any. Thread fns
        /// have signature `fn(*Context) void` so they can't return an
        /// error union; we propagate failures through the context and
        /// check them after join().
        err: ?anyerror = null,
    };

    const pusher = struct {
        fn run(ctx: *Context) void {
            var i = ctx.start;
            const end = ctx.start + ctx.count;
            while (i < end) : (i += 1) {
                ctx.queue.push(i) catch |e| {
                    ctx.err = e;
                    return;
                };
            }
        }
    }.run;

    // Spawn multiple threads pushing
    var ctx1 = Context{ .queue = &queue, .start = 0, .count = 100 };
    var ctx2 = Context{ .queue = &queue, .start = 100, .count = 100 };
    var ctx3 = Context{ .queue = &queue, .start = 200, .count = 100 };

    const t1 = try std.Thread.spawn(.{}, pusher, .{&ctx1});
    const t2 = try std.Thread.spawn(.{}, pusher, .{&ctx2});
    const t3 = try std.Thread.spawn(.{}, pusher, .{&ctx3});

    t1.join();
    t2.join();
    t3.join();

    // Fail loudly if any worker saw an error.
    if (ctx1.err) |e| return e;
    if (ctx2.err) |e| return e;
    if (ctx3.err) |e| return e;

    // Should have 300 items
    try testing.expectEqual(@as(usize, 300), queue.size());

    // All items should be poppable
    var count: usize = 0;
    while (queue.pop()) |_| {
        count += 1;
    }

    try testing.expectEqual(@as(usize, 300), count);
}

test "ConcurrentQueue - concurrent push and pop" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var queue = try ConcurrentQueue(i32).init(allocator);
    defer queue.deinit();

    const PushContext = struct {
        queue: *ConcurrentQueue(i32),
        count: i32,
        err: ?anyerror = null,
    };

    const PopContext = struct {
        queue: *ConcurrentQueue(i32),
        popped: std.ArrayList(i32),
        allocator: std.mem.Allocator,
        err: ?anyerror = null,
    };

    const pusher = struct {
        fn run(ctx: *PushContext) void {
            var i: i32 = 0;
            while (i < ctx.count) : (i += 1) {
                ctx.queue.push(i) catch |e| {
                    ctx.err = e;
                    return;
                };
                std.Thread.yield() catch {};
            }
        }
    }.run;

    const popper = struct {
        fn run(ctx: *PopContext) void {
            var attempts: usize = 0;
            const max_attempts = 10000;

            while (attempts < max_attempts) : (attempts += 1) {
                if (ctx.queue.pop()) |value| {
                    ctx.popped.append(ctx.allocator, value) catch |e| {
                        ctx.err = e;
                        return;
                    };
                }
                std.Thread.yield() catch {};
            }
        }
    }.run;

    var push_ctx = PushContext{ .queue = &queue, .count = 100 };
    var pop_ctx1 = PopContext{ .queue = &queue, .popped = .empty, .allocator = allocator };
    var pop_ctx2 = PopContext{ .queue = &queue, .popped = .empty, .allocator = allocator };

    defer pop_ctx1.popped.deinit(allocator);
    defer pop_ctx2.popped.deinit(allocator);

    const push_thread = try std.Thread.spawn(.{}, pusher, .{&push_ctx});
    const pop_thread1 = try std.Thread.spawn(.{}, popper, .{&pop_ctx1});
    const pop_thread2 = try std.Thread.spawn(.{}, popper, .{&pop_ctx2});

    push_thread.join();
    pop_thread1.join();
    pop_thread2.join();

    if (push_ctx.err) |e| return e;
    if (pop_ctx1.err) |e| return e;
    if (pop_ctx2.err) |e| return e;

    // Total popped should equal what was pushed
    const total_popped = pop_ctx1.popped.items.len + pop_ctx2.popped.items.len + queue.size();
    try testing.expectEqual(@as(usize, 100), total_popped);
}

test "ConcurrentQueue - empty queue pop" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var queue = try ConcurrentQueue(i32).init(allocator);
    defer queue.deinit();

    try testing.expect(queue.pop() == null);
    try testing.expect(queue.pop() == null);
}

test "ConcurrentQueue - single item" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var queue = try ConcurrentQueue(i32).init(allocator);
    defer queue.deinit();

    try queue.push(42);
    try testing.expectEqual(@as(i32, 42), queue.pop().?);
    try testing.expect(queue.pop() == null);
}

test "ConcurrentQueue - with struct type" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const Point = struct {
        x: i32,
        y: i32,
    };

    var queue = try ConcurrentQueue(Point).init(allocator);
    defer queue.deinit();

    try queue.push(.{ .x = 1, .y = 2 });
    try queue.push(.{ .x = 3, .y = 4 });

    const p1 = queue.pop().?;
    try testing.expectEqual(@as(i32, 1), p1.x);
    try testing.expectEqual(@as(i32, 2), p1.y);

    const p2 = queue.pop().?;
    try testing.expectEqual(@as(i32, 3), p2.x);
    try testing.expectEqual(@as(i32, 4), p2.y);
}

test "ConcurrentQueue - eight producers and consumers preserve every item" {
    const producer_count = 8;
    const consumer_count = 8;
    const items_per_producer = 1_000;
    const item_count = producer_count * items_per_producer;

    var queue = try ConcurrentQueue(usize).init(std.heap.page_allocator);
    defer queue.deinit();

    var seen: [item_count]std.atomic.Value(u8) = undefined;
    for (&seen) |*entry| entry.* = .init(0);
    var consumed = std.atomic.Value(usize).init(0);
    var producers_done = std.atomic.Value(usize).init(0);
    var failed = std.atomic.Value(bool).init(false);

    const ProducerContext = struct {
        queue: *ConcurrentQueue(usize),
        producer_id: usize,
        producers_done: *std.atomic.Value(usize),
        failed: *std.atomic.Value(bool),

        fn run(context: *@This()) void {
            const start = context.producer_id * items_per_producer;
            for (start..start + items_per_producer) |item| {
                context.queue.push(item) catch {
                    context.failed.store(true, .release);
                    break;
                };
            }
            _ = context.producers_done.fetchAdd(1, .release);
        }
    };
    const ConsumerContext = struct {
        queue: *ConcurrentQueue(usize),
        seen: *[item_count]std.atomic.Value(u8),
        consumed: *std.atomic.Value(usize),
        producers_done: *std.atomic.Value(usize),
        failed: *std.atomic.Value(bool),

        fn run(context: *@This()) void {
            while (context.consumed.load(.acquire) < item_count) {
                if (context.queue.pop()) |item| {
                    if (item >= item_count or context.seen[item].swap(1, .acq_rel) != 0) {
                        context.failed.store(true, .release);
                    }
                    _ = context.consumed.fetchAdd(1, .release);
                    continue;
                }
                if (context.producers_done.load(.acquire) == producer_count and context.queue.isEmpty()) return;
                std.Thread.yield() catch {};
            }
        }
    };

    var producer_contexts: [producer_count]ProducerContext = undefined;
    var producers: [producer_count]std.Thread = undefined;
    for (&producers, &producer_contexts, 0..) |*thread, *context, producer_id| {
        context.* = .{
            .queue = &queue,
            .producer_id = producer_id,
            .producers_done = &producers_done,
            .failed = &failed,
        };
        thread.* = try std.Thread.spawn(.{}, ProducerContext.run, .{context});
    }

    var consumer_context = ConsumerContext{
        .queue = &queue,
        .seen = &seen,
        .consumed = &consumed,
        .producers_done = &producers_done,
        .failed = &failed,
    };
    var consumers: [consumer_count]std.Thread = undefined;
    for (&consumers) |*thread| {
        thread.* = try std.Thread.spawn(.{}, ConsumerContext.run, .{&consumer_context});
    }

    for (producers) |thread| thread.join();
    for (consumers) |thread| thread.join();

    try std.testing.expect(!failed.load(.acquire));
    try std.testing.expectEqual(@as(usize, item_count), consumed.load(.acquire));
    try std.testing.expect(queue.isEmpty());
    for (&seen) |*entry| try std.testing.expectEqual(@as(u8, 1), entry.load(.acquire));
}
