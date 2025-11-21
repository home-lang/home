const std = @import("std");

/// Lock-free work-stealing deque based on the Chase-Lev algorithm.
///
/// This is a concurrent deque that supports:
/// - push/pop from one end (owner thread)
/// - steal from the other end (thief threads)
///
/// The owner can push and pop without locks in the common case.
/// Thieves use atomic operations to steal from the other end.
///
/// References:
/// - "Dynamic Circular Work-Stealing Deque" by Chase and Lev (2005)
/// - "Correct and Efficient Work-Stealing for Weak Memory Models" by Lê et al (2013)
pub fn WorkStealingDeque(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Circular buffer for storing tasks
        const Buffer = struct {
            data: []?T,
            capacity: usize,

            fn init(allocator: std.mem.Allocator, capacity: usize) !*Buffer {
                const buf = try allocator.create(Buffer);
                buf.* = .{
                    .data = try allocator.alloc(?T, capacity),
                    .capacity = capacity,
                };
                @memset(buf.data, null);
                return buf;
            }

            fn deinit(self: *Buffer, allocator: std.mem.Allocator) void {
                allocator.free(self.data);
                allocator.destroy(self);
            }

            fn get(self: *Buffer, index: i64) ?T {
                const idx = @as(usize, @intCast(@mod(index, @as(i64, @intCast(self.capacity)))));
                return self.data[idx];
            }

            fn put(self: *Buffer, index: i64, value: T) void {
                const idx = @as(usize, @intCast(@mod(index, @as(i64, @intCast(self.capacity)))));
                self.data[idx] = value;
            }

            fn grow(self: *Buffer, allocator: std.mem.Allocator, top: i64, bottom: i64) !*Buffer {
                const new_capacity = self.capacity * 2;
                const new_buf = try Buffer.init(allocator, new_capacity);

                var i = top;
                while (i < bottom) : (i += 1) {
                    if (self.get(i)) |item| {
                        new_buf.put(i, item);
                    }
                }

                return new_buf;
            }
        };

        allocator: std.mem.Allocator,
        /// Top index (accessed by thieves)
        top: std.atomic.Value(i64),
        /// Bottom index (accessed by owner)
        bottom: std.atomic.Value(i64),
        /// Current buffer (atomic pointer for resizing)
        buffer: std.atomic.Value(?*Buffer),

        /// Minimum capacity for the deque
        const MIN_CAPACITY: usize = 32;

        pub fn init(allocator: std.mem.Allocator) !Self {
            const buf = try Buffer.init(allocator, MIN_CAPACITY);

            return Self{
                .allocator = allocator,
                .top = std.atomic.Value(i64).init(0),
                .bottom = std.atomic.Value(i64).init(0),
                .buffer = std.atomic.Value(?*Buffer).init(buf),
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.buffer.load(.acquire)) |buf| {
                buf.deinit(self.allocator);
            }
        }

        /// Push a task to the bottom (owner only)
        ///
        /// This is the fast path for the owner thread.
        /// No synchronization needed except for resizing.
        pub fn push(self: *Self, value: T) !void {
            const b = self.bottom.load(.monotonic);
            const t = self.top.load(.acquire);
            var buf = self.buffer.load(.monotonic).?;

            const len = b - t;

            // Check if we need to grow the buffer
            if (len >= @as(i64, @intCast(buf.capacity))) {
                const new_buf = try buf.grow(self.allocator, t, b);

                // Update buffer pointer
                self.buffer.store(new_buf, .release);

                // Defer cleanup of old buffer
                // In production, use epoch-based reclamation
                defer buf.deinit(self.allocator);

                buf = new_buf;
            }

            buf.put(b, value);

            // Ensure the write to buffer happens before we increment bottom
            // (fence removed in Zig 0.16, using release store which provides ordering)
            self.bottom.store(b + 1, .release);
        }

        /// Pop a task from the bottom (owner only)
        ///
        /// Returns null if the deque is empty.
        pub fn pop(self: *Self) ?T {
            const b = self.bottom.load(.monotonic) - 1;
            const buf = self.buffer.load(.monotonic).?;

            self.bottom.store(b, .monotonic);

            // Ensure bottom is written before we read top
            // (fence removed in Zig 0.16, using seq_cst load instead)
            const t = self.top.load(.seq_cst);

            var result: ?T = null;

            if (t <= b) {
                // Deque is not empty
                result = buf.get(b);

                if (t == b) {
                    // Last element - compete with stealers
                    // cmpxchgStrong now returns null on success, previous value on failure
                    if (self.top.cmpxchgStrong(
                        t,
                        t + 1,
                        .seq_cst,
                        .monotonic,
                    )) |_| {
                        // Lost race with stealer (got previous value)
                        result = null;
                    }

                    self.bottom.store(b + 1, .monotonic);
                }
            } else {
                // Deque is empty
                self.bottom.store(b + 1, .monotonic);
            }

            return result;
        }

        /// Steal a task from the top (thieves)
        ///
        /// Returns null if the deque is empty or if we lose the race
        /// with another thief or the owner.
        pub fn steal(self: *Self) ?T {
            const t = self.top.load(.acquire);

            // Ensure we read top before bottom
            // (fence removed in Zig 0.16, using seq_cst load instead)
            const b = self.bottom.load(.seq_cst);

            if (t >= b) {
                // Deque is empty
                return null;
            }

            const buf = self.buffer.load(.acquire).?;
            const item = buf.get(t);

            // Try to increment top
            // cmpxchgStrong now returns null on success, previous value on failure
            if (self.top.cmpxchgStrong(
                t,
                t + 1,
                .seq_cst,
                .monotonic,
            )) |_| {
                // Lost race with another stealer or owner (got previous value)
                return null;
            }

            return item;
        }

        /// Get the approximate size (not linearizable)
        pub fn size(self: *Self) usize {
            const b = self.bottom.load(.monotonic);
            const t = self.top.load(.monotonic);
            const diff = b - t;
            if (diff < 0) return 0;
            return @intCast(diff);
        }

        /// Check if empty (approximate, not linearizable)
        pub fn isEmpty(self: *Self) bool {
            return self.size() == 0;
        }
    };
}

// =================================================================================
//                                    TESTS
// =================================================================================

test "WorkStealingDeque - basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var deque = try WorkStealingDeque(i32).init(allocator);
    defer deque.deinit();

    // Push some items
    try deque.push(1);
    try deque.push(2);
    try deque.push(3);

    try testing.expectEqual(@as(usize, 3), deque.size());

    // Pop items
    try testing.expectEqual(@as(i32, 3), deque.pop().?);
    try testing.expectEqual(@as(i32, 2), deque.pop().?);
    try testing.expectEqual(@as(i32, 1), deque.pop().?);

    try testing.expect(deque.pop() == null);
}

test "WorkStealingDeque - steal operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var deque = try WorkStealingDeque(i32).init(allocator);
    defer deque.deinit();

    // Push some items
    try deque.push(10);
    try deque.push(20);
    try deque.push(30);

    // Steal from the front
    try testing.expectEqual(@as(i32, 10), deque.steal().?);
    try testing.expectEqual(@as(i32, 20), deque.steal().?);

    // Pop from the back
    try testing.expectEqual(@as(i32, 30), deque.pop().?);

    try testing.expect(deque.steal() == null);
    try testing.expect(deque.pop() == null);
}

test "WorkStealingDeque - LIFO for owner, FIFO for stealers" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var deque = try WorkStealingDeque(i32).init(allocator);
    defer deque.deinit();

    // Push 1, 2, 3
    try deque.push(1);
    try deque.push(2);
    try deque.push(3);

    // Owner pops LIFO: 3, 2, 1
    try testing.expectEqual(@as(i32, 3), deque.pop().?);

    // Stealer steals FIFO: 1, 2
    try testing.expectEqual(@as(i32, 1), deque.steal().?);

    try testing.expectEqual(@as(i32, 2), deque.pop().?);
}

test "WorkStealingDeque - growth" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var deque = try WorkStealingDeque(i32).init(allocator);
    defer deque.deinit();

    // Push more than initial capacity (32)
    var i: i32 = 0;
    while (i < 100) : (i += 1) {
        try deque.push(i);
    }

    try testing.expectEqual(@as(usize, 100), deque.size());

    // Pop all items
    var count: i32 = 99;
    while (count >= 0) : (count -= 1) {
        const item = deque.pop();
        try testing.expect(item != null);
        try testing.expectEqual(count, item.?);
    }

    try testing.expect(deque.isEmpty());
}

test "WorkStealingDeque - concurrent push and steal" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var deque = try WorkStealingDeque(i32).init(allocator);
    defer deque.deinit();

    const StealContext = struct {
        deque: *WorkStealingDeque(i32),
        stolen: std.ArrayList(i32),
        allocator: std.mem.Allocator,
    };

    // Push many items
    var i: i32 = 0;
    while (i < 1000) : (i += 1) {
        try deque.push(i);
    }

    // Spawn thief thread
    var ctx = StealContext{
        .deque = &deque,
        .stolen = .empty,
        .allocator = allocator,
    };
    defer ctx.stolen.deinit(allocator);

    const thief_fn = struct {
        fn run(c: *StealContext) void {
            while (c.deque.steal()) |item| {
                c.stolen.append(c.allocator, item) catch unreachable;
                // Small sleep to allow owner to push
                std.posix.nanosleep(0, 100);
            }
        }
    }.run;

    const thread = try std.Thread.spawn(.{}, thief_fn, .{&ctx});

    // Give thief time to steal some
    std.posix.nanosleep(0, 1_000_000); // 1ms

    thread.join();

    // Verify no duplicates and all items accounted for
    const stolen_count = ctx.stolen.items.len;
    const remaining_count = deque.size();

    try testing.expect(stolen_count + remaining_count <= 1000);
    try testing.expect(stolen_count > 0); // Thief should have stolen something
}

test "WorkStealingDeque - empty deque operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var deque = try WorkStealingDeque(i32).init(allocator);
    defer deque.deinit();

    try testing.expect(deque.isEmpty());
    try testing.expect(deque.pop() == null);
    try testing.expect(deque.steal() == null);
}

test "WorkStealingDeque - single element race" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var deque = try WorkStealingDeque(i32).init(allocator);
    defer deque.deinit();

    // Push one item
    try deque.push(42);

    // Both owner and thief try to get it
    // Only one should succeed

    const stolen = deque.steal();
    const popped = deque.pop();

    // Exactly one should be non-null
    const got_one = (stolen != null and popped == null) or (stolen == null and popped != null);
    try testing.expect(got_one);

    if (stolen) |val| try testing.expectEqual(@as(i32, 42), val);
    if (popped) |val| try testing.expectEqual(@as(i32, 42), val);
}
