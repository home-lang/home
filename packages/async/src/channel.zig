const std = @import("std");
const future_mod = @import("future.zig");
const Future = future_mod.Future;
const PollResult = future_mod.PollResult;
const Context = future_mod.Context;
const Waker = future_mod.Waker;

/// Errors that can occur when sending to a channel
pub const SendError = error{
    /// Channel is closed
    Closed,
    /// Channel is full (for bounded channels)
    Full,
};

/// Errors that can occur when receiving from a channel
pub const RecvError = error{
    /// Channel is closed and empty
    Closed,
};

/// An async multi-producer, multi-consumer channel
///
/// Allows sending values between async tasks without blocking.
pub fn Channel(comptime T: type) type {
    return struct {
        const Self = @This();

        const Node = struct {
            value: T,
            next: ?*Node,
        };

        allocator: std.mem.Allocator,
        /// Queue of values
        head: std.atomic.Atomic(?*Node),
        tail: std.atomic.Atomic(?*Node),
        /// List of waiting senders
        send_waiters: std.ArrayList(*Waker),
        /// List of waiting receivers
        recv_waiters: std.ArrayList(*Waker),
        /// Protects waiter lists
        mutex: std.Thread.Mutex,
        /// Is the channel closed?
        closed: std.atomic.Atomic(bool),

        pub fn init(allocator: std.mem.Allocator) !Self {
            return Self{
                .allocator = allocator,
                .head = std.atomic.Atomic(?*Node).init(null),
                .tail = std.atomic.Atomic(?*Node).init(null),
                .send_waiters = std.ArrayList(*Waker).init(allocator),
                .recv_waiters = std.ArrayList(*Waker).init(allocator),
                .mutex = .{},
                .closed = std.atomic.Atomic(bool).init(false),
            };
        }

        pub fn deinit(self: *Self) void {
            // Free remaining nodes
            var current = self.head.load(.Acquire);
            while (current) |node| {
                const next = node.next;
                self.allocator.destroy(node);
                current = next;
            }

            // Free waiters
            for (self.send_waiters.items) |waker| {
                waker.drop();
            }
            for (self.recv_waiters.items) |waker| {
                waker.drop();
            }

            self.send_waiters.deinit();
            self.recv_waiters.deinit();
        }

        /// Send a value through the channel
        pub fn send(self: *Self, value: T) SendFuture(T) {
            return SendFuture(T){
                .channel = self,
                .value = value,
                .registered = false,
            };
        }

        /// Receive a value from the channel
        pub fn recv(self: *Self) RecvFuture(T) {
            return RecvFuture(T){
                .channel = self,
                .registered = false,
            };
        }

        /// Try to send immediately without waiting
        pub fn trySend(self: *Self, value: T) !void {
            if (self.closed.load(.Acquire)) {
                return SendError.Closed;
            }

            const node = try self.allocator.create(Node);
            node.* = .{ .value = value, .next = null };

            // Add to queue
            const old_tail = self.tail.swap(node, .AcqRel);

            if (old_tail) |tail| {
                tail.next = node;
            } else {
                self.head.store(node, .Release);
            }

            // Wake a receiver
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.recv_waiters.items.len > 0) {
                const waker = self.recv_waiters.orderedRemove(0);
                waker.wake();
            }
        }

        /// Try to receive immediately without waiting
        pub fn tryRecv(self: *Self) !T {
            const head = self.head.load(.Acquire) orelse {
                if (self.closed.load(.Acquire)) {
                    return RecvError.Closed;
                }
                return error.Empty;
            };

            // Try to remove head
            const next = head.next;
            if (!self.head.cmpxchgStrong(
                head,
                next,
                .AcqRel,
                .Acquire,
            )) {
                return error.Empty;
            }

            const value = head.value;
            self.allocator.destroy(head);

            if (next == null) {
                _ = self.tail.cmpxchgStrong(head, null, .Release, .Acquire);
            }

            // Wake a sender
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.send_waiters.items.len > 0) {
                const waker = self.send_waiters.orderedRemove(0);
                waker.wake();
            }

            return value;
        }

        /// Close the channel
        pub fn close(self: *Self) void {
            self.closed.store(true, .Release);

            // Wake all waiters
            self.mutex.lock();
            defer self.mutex.unlock();

            for (self.send_waiters.items) |waker| {
                waker.wake();
            }

            for (self.recv_waiters.items) |waker| {
                waker.wake();
            }

            self.send_waiters.clearRetainingCapacity();
            self.recv_waiters.clearRetainingCapacity();
        }
    };
}

/// Future for sending a value
fn SendFuture(comptime T: type) type {
    return struct {
        const Self = @This();

        channel: *Channel(T),
        value: T,
        registered: bool,

        pub fn poll(self: *Self, ctx: *Context) PollResult(void) {
            // Try to send immediately
            self.channel.trySend(self.value) catch |err| switch (err) {
                SendError.Closed => return .{ .Ready = {} },
                else => {
                    // Register waker if not already registered
                    if (!self.registered) {
                        self.channel.mutex.lock();
                        defer self.channel.mutex.unlock();

                        self.channel.send_waiters.append(
                            &ctx.waker.*,
                        ) catch return .{ .Ready = {} };

                        self.registered = true;
                    }

                    return .Pending;
                },
            };

            return .{ .Ready = {} };
        }
    };
}

/// Future for receiving a value
fn RecvFuture(comptime T: type) type {
    return struct {
        const Self = @This();

        channel: *Channel(T),
        registered: bool,

        pub fn poll(self: *Self, ctx: *Context) PollResult(T) {
            // Try to receive immediately
            if (self.channel.tryRecv()) |value| {
                return .{ .Ready = value };
            } else |err| switch (err) {
                RecvError.Closed => {
                    // Channel closed, return error somehow
                    // For now, just pend forever
                    return .Pending;
                },
                else => {
                    // Register waker if not already registered
                    if (!self.registered) {
                        self.channel.mutex.lock();
                        defer self.channel.mutex.unlock();

                        self.channel.recv_waiters.append(
                            &ctx.waker.*,
                        ) catch return .Pending;

                        self.registered = true;
                    }

                    return .Pending;
                },
            }
        }
    };
}

/// Create a channel with sender and receiver handles
pub fn channel(comptime T: type, allocator: std.mem.Allocator) !struct {
    sender: Sender(T),
    receiver: Receiver(T),
} {
    const chan = try allocator.create(Channel(T));
    chan.* = try Channel(T).init(allocator);

    return .{
        .sender = Sender(T){ .channel = chan },
        .receiver = Receiver(T){ .channel = chan },
    };
}

/// Sender half of a channel
pub fn Sender(comptime T: type) type {
    return struct {
        channel: *Channel(T),

        pub fn send(self: *@This(), value: T) SendFuture(T) {
            return self.channel.send(value);
        }

        pub fn close(self: *@This()) void {
            self.channel.close();
        }
    };
}

/// Receiver half of a channel
pub fn Receiver(comptime T: type) type {
    return struct {
        channel: *Channel(T),

        pub fn recv(self: *@This()) RecvFuture(T) {
            return self.channel.recv();
        }
    };
}

// =================================================================================
//                                    TESTS
// =================================================================================

test "Channel - try send and recv" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var chan = try Channel(i32).init(allocator);
    defer chan.deinit();

    try chan.trySend(42);
    try chan.trySend(100);

    const val1 = try chan.tryRecv();
    try testing.expectEqual(@as(i32, 42), val1);

    const val2 = try chan.tryRecv();
    try testing.expectEqual(@as(i32, 100), val2);
}

test "Channel - close" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var chan = try Channel(i32).init(allocator);
    defer chan.deinit();

    chan.close();

    // Sending to closed channel should fail
    try testing.expectError(SendError.Closed, chan.trySend(42));
}

test "Channel - FIFO order" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var chan = try Channel(i32).init(allocator);
    defer chan.deinit();

    try chan.trySend(1);
    try chan.trySend(2);
    try chan.trySend(3);

    try testing.expectEqual(@as(i32, 1), try chan.tryRecv());
    try testing.expectEqual(@as(i32, 2), try chan.tryRecv());
    try testing.expectEqual(@as(i32, 3), try chan.tryRecv());
}

test "Channel - sender and receiver" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const pair = try channel(i32, allocator);
    defer pair.sender.channel.deinit();
    defer allocator.destroy(pair.sender.channel);

    try pair.sender.channel.trySend(99);

    const val = try pair.receiver.channel.tryRecv();
    try testing.expectEqual(@as(i32, 99), val);
}
