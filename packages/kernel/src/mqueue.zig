// Home Programming Language - POSIX Message Queues
// IPC mechanism for passing messages between processes

const Basics = @import("basics");
const process = @import("process.zig");
const sync = @import("sync.zig");
const atomic = @import("atomic.zig");

// ============================================================================
// Message Queue Attributes
// ============================================================================

pub const MqAttr = extern struct {
    /// Flags (O_NONBLOCK)
    mq_flags: i32,
    /// Maximum number of messages
    mq_maxmsg: i32,
    /// Maximum message size (bytes)
    mq_msgsize: i32,
    /// Current number of messages
    mq_curmsgs: i32,

    pub fn init(maxmsg: i32, msgsize: i32) MqAttr {
        return .{
            .mq_flags = 0,
            .mq_maxmsg = maxmsg,
            .mq_msgsize = msgsize,
            .mq_curmsgs = 0,
        };
    }
};

// ============================================================================
// Message Structure
// ============================================================================

const Message = struct {
    /// Message priority (0-31, higher = more urgent)
    priority: u32,
    /// Message data
    data: []u8,
    /// Next message in queue
    next: ?*Message,

    pub fn init(allocator: Basics.Allocator, data: []const u8, priority: u32) !*Message {
        const msg = try allocator.create(Message);
        errdefer allocator.destroy(msg);

        msg.data = try allocator.alloc(u8, data.len);
        @memcpy(msg.data, data);

        msg.priority = priority;
        msg.next = null;

        return msg;
    }

    pub fn deinit(self: *Message, allocator: Basics.Allocator) void {
        allocator.free(self.data);
        allocator.destroy(self);
    }
};

// ============================================================================
// Message Queue
// ============================================================================

pub const MessageQueue = struct {
    /// Queue name
    name: []const u8,
    /// Queue attributes
    attr: MqAttr,
    /// Lock for queue access
    lock: sync.SpinLock,
    /// Condition variable for waiting receivers
    recv_cond: sync.ConditionVariable,
    /// Condition variable for waiting senders
    send_cond: sync.ConditionVariable,
    /// Head of message list (highest priority first)
    head: ?*Message,
    /// Tail of message list
    tail: ?*Message,
    /// Number of processes with queue open
    ref_count: atomic.AtomicU32,
    /// Allocator for messages
    allocator: Basics.Allocator,
    /// Owner UID
    uid: u32,
    /// Owner GID
    gid: u32,
    /// Permissions (mode_t)
    mode: u32,

    pub fn init(allocator: Basics.Allocator, name: []const u8, attr: MqAttr, uid: u32, gid: u32, mode: u32) !*MessageQueue {
        const mq = try allocator.create(MessageQueue);
        errdefer allocator.destroy(mq);

        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);

        mq.* = .{
            .name = name_copy,
            .attr = attr,
            .lock = sync.SpinLock.init(),
            .recv_cond = sync.ConditionVariable.init(),
            .send_cond = sync.ConditionVariable.init(),
            .head = null,
            .tail = null,
            .ref_count = atomic.AtomicU32.init(1),
            .allocator = allocator,
            .uid = uid,
            .gid = gid,
            .mode = mode,
        };

        return mq;
    }

    pub fn deinit(self: *MessageQueue) void {
        // Free all remaining messages
        var current = self.head;
        while (current) |msg| {
            const next = msg.next;
            msg.deinit(self.allocator);
            current = next;
        }

        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    /// Send a message to the queue
    pub fn send(self: *MessageQueue, data: []const u8, priority: u32, timeout_ns: ?u64) !void {
        self.lock.lock();
        defer self.lock.unlock();

        const O_NONBLOCK = 0x800;

        // Check if queue is full
        while (self.attr.mq_curmsgs >= self.attr.mq_maxmsg) {
            // Non-blocking mode?
            if ((self.attr.mq_flags & O_NONBLOCK) != 0) {
                return error.WouldBlock;
            }

            // Wait for space (with optional timeout)
            if (timeout_ns) |timeout| {
                if (!try self.send_cond.waitTimeout(&self.lock, timeout)) {
                    return error.TimedOut;
                }
            } else {
                try self.send_cond.wait(&self.lock);
            }
        }

        // Check message size
        if (data.len > @as(usize, @intCast(self.attr.mq_msgsize))) {
            return error.MessageTooLarge;
        }

        // Create message
        const msg = try Message.init(self.allocator, data, priority);
        errdefer msg.deinit(self.allocator);

        // Insert message in priority order (higher priority first)
        if (self.head == null) {
            // Empty queue
            self.head = msg;
            self.tail = msg;
        } else if (priority > self.head.?.priority) {
            // Insert at head
            msg.next = self.head;
            self.head = msg;
        } else {
            // Find insertion point
            var prev = self.head;
            var current = prev.?.next;

            while (current) |curr| {
                if (priority > curr.priority) {
                    break;
                }
                prev = current;
                current = curr.next;
            }

            // Insert after prev
            msg.next = current;
            prev.?.next = msg;

            if (current == null) {
                self.tail = msg;
            }
        }

        self.attr.mq_curmsgs += 1;

        // Wake up a waiting receiver
        self.recv_cond.signal();
    }

    /// Receive a message from the queue
    pub fn receive(self: *MessageQueue, buffer: []u8, priority: ?*u32, timeout_ns: ?u64) !usize {
        self.lock.lock();
        defer self.lock.unlock();

        const O_NONBLOCK = 0x800;

        // Wait for a message
        while (self.head == null) {
            // Non-blocking mode?
            if ((self.attr.mq_flags & O_NONBLOCK) != 0) {
                return error.WouldBlock;
            }

            // Wait for message (with optional timeout)
            if (timeout_ns) |timeout| {
                if (!try self.recv_cond.waitTimeout(&self.lock, timeout)) {
                    return error.TimedOut;
                }
            } else {
                try self.recv_cond.wait(&self.lock);
            }
        }

        // Remove message from head
        const msg = self.head.?;
        self.head = msg.next;

        if (self.head == null) {
            self.tail = null;
        }

        self.attr.mq_curmsgs -= 1;

        // Check buffer size
        if (buffer.len < msg.data.len) {
            msg.deinit(self.allocator);
            return error.BufferTooSmall;
        }

        // Copy message data
        @memcpy(buffer[0..msg.data.len], msg.data);
        const len = msg.data.len;

        // Return priority if requested
        if (priority) |prio| {
            prio.* = msg.priority;
        }

        // Free message
        msg.deinit(self.allocator);

        // Wake up a waiting sender
        self.send_cond.signal();

        return len;
    }

    /// Get queue attributes
    pub fn getAttr(self: *MessageQueue) MqAttr {
        self.lock.lock();
        defer self.lock.unlock();
        return self.attr;
    }

    /// Set queue attributes (only mq_flags can be changed)
    pub fn setAttr(self: *MessageQueue, new_attr: *const MqAttr, old_attr: ?*MqAttr) void {
        self.lock.lock();
        defer self.lock.unlock();

        if (old_attr) |old| {
            old.* = self.attr;
        }

        // Only mq_flags can be modified
        self.attr.mq_flags = new_attr.mq_flags;
    }

    /// Increment reference count
    pub fn ref(self: *MessageQueue) void {
        _ = self.ref_count.fetchAdd(1, .Monotonic);
    }

    /// Decrement reference count and destroy if zero
    pub fn unref(self: *MessageQueue) void {
        const old_count = self.ref_count.fetchSub(1, .Release);
        if (old_count == 1) {
            @atomicStore(u32, &self.ref_count.value, 0, .Acquire);
            self.deinit();
        }
    }
};

// ============================================================================
// Global Message Queue Registry
// ============================================================================

const MAX_QUEUES = 256;

var mqueue_registry: [MAX_QUEUES]?*MessageQueue = [_]?*MessageQueue{null} ** MAX_QUEUES;
var mqueue_lock = sync.SpinLock.init();

/// Open or create a message queue
pub fn mqOpen(
    allocator: Basics.Allocator,
    name: []const u8,
    flags: i32,
    mode: u32,
    attr: ?*const MqAttr,
) !*MessageQueue {
    const O_CREAT = 0x40;
    const O_EXCL = 0x80;

    mqueue_lock.lock();
    defer mqueue_lock.unlock();

    // Look for existing queue
    for (mqueue_registry) |maybe_mq| {
        if (maybe_mq) |mq| {
            if (Basics.mem.eql(u8, mq.name, name)) {
                // Queue exists
                if ((flags & O_CREAT) != 0 and (flags & O_EXCL) != 0) {
                    return error.AlreadyExists;
                }
                mq.ref();
                return mq;
            }
        }
    }

    // Queue doesn't exist
    if ((flags & O_CREAT) == 0) {
        return error.NotFound;
    }

    // Create new queue
    const current = process.getCurrent() orelse return error.NoCurrentProcess;

    const queue_attr = if (attr) |a| a.* else MqAttr.init(10, 8192); // Default: 10 messages, 8KB each

    const mq = try MessageQueue.init(
        allocator,
        name,
        queue_attr,
        current.uid,
        current.gid,
        mode,
    );

    // Find free slot
    for (&mqueue_registry) |*slot| {
        if (slot.* == null) {
            slot.* = mq;
            return mq;
        }
    }

    // No free slots
    mq.deinit();
    return error.TooManyQueues;
}

/// Close a message queue
pub fn mqClose(mq: *MessageQueue) void {
    mq.unref();
}

/// Unlink (delete) a message queue
pub fn mqUnlink(name: []const u8) !void {
    mqueue_lock.lock();
    defer mqueue_lock.unlock();

    for (&mqueue_registry) |*slot| {
        if (slot.*) |mq| {
            if (Basics.mem.eql(u8, mq.name, name)) {
                slot.* = null;
                mq.unref();
                return;
            }
        }
    }

    return error.NotFound;
}

// ============================================================================
// File Descriptor Mapping
// ============================================================================

const MAX_MQ_FDS = 1024;
var mq_fd_map: [MAX_MQ_FDS]?*MessageQueue = [_]?*MessageQueue{null} ** MAX_MQ_FDS;
var mq_fd_lock = sync.SpinLock.init();
var next_mq_fd = atomic.AtomicI32.init(1000); // Start at 1000 to avoid conflicts

fn allocateMqFd(mq: *MessageQueue) !i32 {
    mq_fd_lock.lock();
    defer mq_fd_lock.unlock();

    const fd = next_mq_fd.fetchAdd(1, .Monotonic);
    const idx = @as(usize, @intCast(fd % MAX_MQ_FDS));

    if (mq_fd_map[idx] == null) {
        mq.ref();
        mq_fd_map[idx] = mq;
        return fd;
    }

    return error.TooManyOpenFiles;
}

fn getMqFromFd(fd: i32) ?*MessageQueue {
    mq_fd_lock.lock();
    defer mq_fd_lock.unlock();

    const idx = @as(usize, @intCast(fd % MAX_MQ_FDS));
    return mq_fd_map[idx];
}

fn releaseMqFd(fd: i32) void {
    mq_fd_lock.lock();
    defer mq_fd_lock.unlock();

    const idx = @as(usize, @intCast(fd % MAX_MQ_FDS));
    if (mq_fd_map[idx]) |mq| {
        mq.unref();
        mq_fd_map[idx] = null;
    }
}

// ============================================================================
// System Calls
// ============================================================================

/// Open message queue (mq_open syscall)
pub fn sysMqOpen(
    name: [*:0]const u8,
    flags: i32,
    mode: u32,
    attr: ?*const MqAttr,
) !i32 {
    const allocator = Basics.heap.page_allocator;

    const name_slice = Basics.mem.span(name);
    const mq = try mqOpen(allocator, name_slice, flags, mode, attr);

    return try allocateMqFd(mq);
}

/// Close message queue (mq_close syscall)
pub fn sysMqClose(mqdes: i32) !void {
    releaseMqFd(mqdes);
}

/// Unlink message queue (mq_unlink syscall)
pub fn sysMqUnlink(name: [*:0]const u8) !void {
    const name_slice = Basics.mem.span(name);
    try mqUnlink(name_slice);
}

/// Send message (mq_send syscall)
pub fn sysMqSend(
    mqdes: i32,
    msg_ptr: [*]const u8,
    msg_len: usize,
    msg_prio: u32,
) !void {
    const mq = getMqFromFd(mqdes) orelse return error.BadFileDescriptor;
    const msg_data = msg_ptr[0..msg_len];
    try mq.send(msg_data, msg_prio, null);
}

/// Send message with timeout (mq_timedsend syscall)
pub fn sysMqTimedsend(
    mqdes: i32,
    msg_ptr: [*]const u8,
    msg_len: usize,
    msg_prio: u32,
    timeout_ns: u64,
) !void {
    const mq = getMqFromFd(mqdes) orelse return error.BadFileDescriptor;
    const msg_data = msg_ptr[0..msg_len];
    try mq.send(msg_data, msg_prio, timeout_ns);
}

/// Receive message (mq_receive syscall)
pub fn sysMqReceive(
    mqdes: i32,
    msg_ptr: [*]u8,
    msg_len: usize,
    msg_prio: ?*u32,
) !isize {
    const mq = getMqFromFd(mqdes) orelse return error.BadFileDescriptor;
    const buffer = msg_ptr[0..msg_len];
    const bytes_read = try mq.receive(buffer, msg_prio, null);
    return @intCast(bytes_read);
}

/// Receive message with timeout (mq_timedreceive syscall)
pub fn sysMqTimedreceive(
    mqdes: i32,
    msg_ptr: [*]u8,
    msg_len: usize,
    msg_prio: ?*u32,
    timeout_ns: u64,
) !isize {
    const mq = getMqFromFd(mqdes) orelse return error.BadFileDescriptor;
    const buffer = msg_ptr[0..msg_len];
    const bytes_read = try mq.receive(buffer, msg_prio, timeout_ns);
    return @intCast(bytes_read);
}

/// Get queue attributes (mq_getattr syscall)
pub fn sysMqGetattr(mqdes: i32, attr: *MqAttr) !void {
    const mq = getMqFromFd(mqdes) orelse return error.BadFileDescriptor;
    attr.* = mq.getAttr();
}

/// Set queue attributes (mq_setattr syscall)
pub fn sysMqSetattr(
    mqdes: i32,
    new_attr: *const MqAttr,
    old_attr: ?*MqAttr,
) !void {
    const mq = getMqFromFd(mqdes) orelse return error.BadFileDescriptor;
    mq.setAttr(new_attr, old_attr);
}

// ============================================================================
// Tests
// ============================================================================

test "message queue - create and destroy" {
    const testing = Basics.testing;
    const allocator = testing.allocator;

    const attr = MqAttr.init(10, 1024);
    var mq = try MessageQueue.init(allocator, "/test", attr, 1000, 1000, 0o644);
    defer mq.unref();

    try testing.expectEqual(@as(i32, 0), mq.attr.mq_curmsgs);
    try testing.expectEqual(@as(i32, 10), mq.attr.mq_maxmsg);
}

test "message queue - send and receive" {
    const testing = Basics.testing;
    const allocator = testing.allocator;

    const attr = MqAttr.init(10, 1024);
    var mq = try MessageQueue.init(allocator, "/test", attr, 1000, 1000, 0o644);
    defer mq.unref();

    // Send a message
    const msg = "Hello, World!";
    try mq.send(msg, 0, null);

    try testing.expectEqual(@as(i32, 1), mq.attr.mq_curmsgs);

    // Receive the message
    var buffer: [1024]u8 = undefined;
    const len = try mq.receive(&buffer, null, null);

    try testing.expectEqual(msg.len, len);
    try testing.expectEqualStrings(msg, buffer[0..len]);
    try testing.expectEqual(@as(i32, 0), mq.attr.mq_curmsgs);
}

test "message queue - priority ordering" {
    const testing = Basics.testing;
    const allocator = testing.allocator;

    const attr = MqAttr.init(10, 1024);
    var mq = try MessageQueue.init(allocator, "/test", attr, 1000, 1000, 0o644);
    defer mq.unref();

    // Send messages with different priorities
    try mq.send("Low", 1, null);
    try mq.send("High", 10, null);
    try mq.send("Medium", 5, null);

    // Should receive in priority order: High, Medium, Low
    var buffer: [1024]u8 = undefined;
    var prio: u32 = undefined;

    _ = try mq.receive(&buffer, &prio, null);
    try testing.expectEqual(@as(u32, 10), prio);

    _ = try mq.receive(&buffer, &prio, null);
    try testing.expectEqual(@as(u32, 5), prio);

    _ = try mq.receive(&buffer, &prio, null);
    try testing.expectEqual(@as(u32, 1), prio);
}

test "message queue - open and close" {
    const testing = Basics.testing;
    const allocator = testing.allocator;

    // Open/create queue
    const mq = try mqOpen(allocator, "/testq", 0x40, 0o644, null); // O_CREAT
    defer mqClose(mq);

    try testing.expectEqualStrings("/testq", mq.name);

    // Open existing queue
    const mq2 = try mqOpen(allocator, "/testq", 0, 0o644, null);
    defer mqClose(mq2);

    try testing.expectEqual(mq, mq2);
}
