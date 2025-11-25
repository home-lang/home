// Home Programming Language - Message Queues
// POSIX message queue implementation for IPC

const Basics = @import("basics");
const sync = @import("sync.zig");
const process = @import("process.zig");
const timer = @import("timer.zig");

// ============================================================================
// Message Queue Configuration
// ============================================================================

pub const MQ_PRIO_MAX = 32768;
pub const MQ_DEFAULT_MAXMSG = 10;
pub const MQ_DEFAULT_MSGSIZE = 8192;

// ============================================================================
// Message Structure
// ============================================================================

pub const Message = struct {
    data: []u8,
    priority: u32,
    allocator: Basics.Allocator,

    pub fn init(allocator: Basics.Allocator, data: []const u8, priority: u32) !*Message {
        const msg = try allocator.create(Message);
        errdefer allocator.destroy(msg);

        msg.* = .{
            .data = try allocator.dupe(u8, data),
            .priority = priority,
            .allocator = allocator,
        };

        return msg;
    }

    pub fn deinit(self: *Message) void {
        self.allocator.free(self.data);
        self.allocator.destroy(self);
    }
};

// ============================================================================
// Message Queue Attributes
// ============================================================================

pub const MqAttr = struct {
    flags: u64,
    maxmsg: u64,
    msgsize: u64,
    curmsgs: u64,

    pub fn init(maxmsg: u64, msgsize: u64) MqAttr {
        return .{
            .flags = 0,
            .maxmsg = maxmsg,
            .msgsize = msgsize,
            .curmsgs = 0,
        };
    }
};

// ============================================================================
// Message Queue
// ============================================================================

pub const MessageQueue = struct {
    name: []const u8,
    attr: MqAttr,
    messages: Basics.ArrayList(*Message),
    lock: sync.RwLock,
    read_wait: sync.WaitQueue,
    write_wait: sync.WaitQueue,
    allocator: Basics.Allocator,
    refcount: u32,
    permissions: u16,
    uid: u32,
    gid: u32,

    pub fn init(
        allocator: Basics.Allocator,
        name: []const u8,
        attr: MqAttr,
        permissions: u16,
        uid: u32,
        gid: u32,
    ) !*MessageQueue {
        const mq = try allocator.create(MessageQueue);
        errdefer allocator.destroy(mq);

        mq.* = .{
            .name = try allocator.dupe(u8, name),
            .attr = attr,
            .messages = Basics.ArrayList(*Message).init(allocator),
            .lock = sync.RwLock.init(),
            .read_wait = sync.WaitQueue.init(),
            .write_wait = sync.WaitQueue.init(),
            .allocator = allocator,
            .refcount = 1,
            .permissions = permissions,
            .uid = uid,
            .gid = gid,
        };

        return mq;
    }

    pub fn deinit(self: *MessageQueue) void {
        // Free all pending messages
        for (self.messages.items) |msg| {
            msg.deinit();
        }
        self.messages.deinit();
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    /// Send a message to the queue
    pub fn send(self: *MessageQueue, data: []const u8, priority: u32, timeout_ns: ?u64) !void {
        if (data.len > self.attr.msgsize) {
            return error.MessageTooLarge;
        }

        if (priority >= MQ_PRIO_MAX) {
            return error.InvalidPriority;
        }

        // Calculate deadline if timeout specified
        const deadline_ms: ?u64 = if (timeout_ns) |ns|
            timer.getTicks() + (ns / 1_000_000) // Convert ns to ms
        else
            null;

        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        // Check if queue is full
        while (self.messages.items.len >= self.attr.maxmsg) {
            // Check timeout before waiting
            if (deadline_ms) |deadline| {
                if (timer.getTicks() >= deadline) {
                    return error.TimedOut;
                }
            }
            self.lock.releaseWrite();
            self.write_wait.wait();
            self.lock.acquireWrite();
        }

        // Create and insert message in priority order
        const msg = try Message.init(self.allocator, data, priority);
        errdefer msg.deinit();

        try self.insertByPriority(msg);
        self.attr.curmsgs = self.messages.items.len;

        // Wake up any waiting readers
        self.read_wait.wakeOne();
    }

    /// Receive a message from the queue
    pub fn receive(self: *MessageQueue, buffer: []u8, priority: ?*u32, timeout_ns: ?u64) !usize {
        // Calculate deadline if timeout specified
        const deadline_ms: ?u64 = if (timeout_ns) |ns|
            timer.getTicks() + (ns / 1_000_000) // Convert ns to ms
        else
            null;

        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        // Wait for messages
        while (self.messages.items.len == 0) {
            // Check timeout before waiting
            if (deadline_ms) |deadline| {
                if (timer.getTicks() >= deadline) {
                    return error.TimedOut;
                }
            }
            self.lock.releaseWrite();
            self.read_wait.wait();
            self.lock.acquireWrite();
        }

        // Get highest priority message (first in list)
        const msg = self.messages.orderedRemove(0);
        defer msg.deinit();

        self.attr.curmsgs = self.messages.items.len;

        if (buffer.len < msg.data.len) {
            return error.BufferTooSmall;
        }

        @memcpy(buffer[0..msg.data.len], msg.data);

        if (priority) |prio| {
            prio.* = msg.priority;
        }

        // Wake up any waiting writers
        self.write_wait.wakeOne();

        return msg.data.len;
    }

    /// Insert message in priority order (highest priority first)
    fn insertByPriority(self: *MessageQueue, msg: *Message) !void {
        var insert_pos: usize = 0;

        for (self.messages.items, 0..) |existing, i| {
            if (msg.priority > existing.priority) {
                insert_pos = i;
                break;
            }
            insert_pos = i + 1;
        }

        try self.messages.insert(insert_pos, msg);
    }

    /// Get queue attributes
    pub fn getAttr(self: *MessageQueue) MqAttr {
        self.lock.acquireRead();
        defer self.lock.releaseRead();

        return self.attr;
    }

    /// Set queue attributes
    pub fn setAttr(self: *MessageQueue, new_attr: MqAttr, old_attr: ?*MqAttr) void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        if (old_attr) |old| {
            old.* = self.attr;
        }

        // Only flags can be changed
        self.attr.flags = new_attr.flags;
    }

    /// Check permissions
    pub fn canRead(self: *MessageQueue, uid: u32, gid: u32) bool {
        if (uid == 0) return true; // Root can do anything
        if (uid == self.uid) return (self.permissions & 0o400) != 0;
        if (gid == self.gid) return (self.permissions & 0o040) != 0;
        return (self.permissions & 0o004) != 0;
    }

    pub fn canWrite(self: *MessageQueue, uid: u32, gid: u32) bool {
        if (uid == 0) return true;
        if (uid == self.uid) return (self.permissions & 0o200) != 0;
        if (gid == self.gid) return (self.permissions & 0o020) != 0;
        return (self.permissions & 0o002) != 0;
    }
};

// ============================================================================
// Message Queue Manager
// ============================================================================

pub const MqManager = struct {
    queues: Basics.StringHashMap(*MessageQueue),
    lock: sync.RwLock,
    allocator: Basics.Allocator,

    pub fn init(allocator: Basics.Allocator) MqManager {
        return .{
            .queues = Basics.StringHashMap(*MessageQueue).init(allocator),
            .lock = sync.RwLock.init(),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MqManager) void {
        var it = self.queues.valueIterator();
        while (it.next()) |mq| {
            mq.*.deinit();
        }
        self.queues.deinit();
    }

    /// Open or create a message queue
    pub fn open(
        self: *MqManager,
        name: []const u8,
        flags: u32,
        mode: u16,
        attr: ?*const MqAttr,
        uid: u32,
        gid: u32,
    ) !*MessageQueue {
        const O_CREAT = 0o100;
        const O_EXCL = 0o200;

        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        // Check if queue exists
        if (self.queues.get(name)) |mq| {
            if ((flags & O_EXCL) != 0) {
                return error.AlreadyExists;
            }

            // Check permissions
            if (!mq.canRead(uid, gid) and !mq.canWrite(uid, gid)) {
                return error.PermissionDenied;
            }

            mq.refcount += 1;
            return mq;
        }

        // Create new queue if O_CREAT is set
        if ((flags & O_CREAT) == 0) {
            return error.NoSuchQueue;
        }

        const queue_attr = if (attr) |a|
            a.*
        else
            MqAttr.init(MQ_DEFAULT_MAXMSG, MQ_DEFAULT_MSGSIZE);

        const mq = try MessageQueue.init(
            self.allocator,
            name,
            queue_attr,
            mode,
            uid,
            gid,
        );
        errdefer mq.deinit();

        try self.queues.put(name, mq);
        return mq;
    }

    /// Close a message queue
    pub fn close(self: *MqManager, mq: *MessageQueue) void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        mq.refcount -= 1;
        if (mq.refcount == 0) {
            _ = self.queues.remove(mq.name);
            mq.deinit();
        }
    }

    /// Unlink (delete) a message queue
    pub fn unlink(self: *MqManager, name: []const u8) !void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        const mq = self.queues.get(name) orelse return error.NoSuchQueue;

        _ = self.queues.remove(name);

        if (mq.refcount == 0) {
            mq.deinit();
        }
        // Otherwise it will be freed when last reference is closed
    }
};

// ============================================================================
// Global Manager
// ============================================================================

var global_manager: ?MqManager = null;
var manager_lock = sync.Spinlock.init();

pub fn getManager() *MqManager {
    manager_lock.acquire();
    defer manager_lock.release();

    if (global_manager == null) {
        global_manager = MqManager.init(Basics.heap.page_allocator);
    }

    return &global_manager.?;
}

// ============================================================================
// System Call Interface
// ============================================================================

/// sys_mq_open - Open a message queue
pub fn sysMqOpen(name: [*:0]const u8, flags: i32, mode: u32, attr: ?*const MqAttr) !i32 {
    const proc = process.current() orelse return error.NoProcess;
    const manager = getManager();

    const name_slice = Basics.mem.span(name);
    const mq = try manager.open(
        name_slice,
        @intCast(flags),
        @intCast(mode),
        attr,
        proc.uid,
        proc.gid,
    );

    // Add to process's file descriptor table
    const fd = try proc.addMessageQueue(mq);
    return @intCast(fd);
}

/// sys_mq_close - Close a message queue
pub fn sysMqClose(mqdes: i32) !void {
    const proc = process.current() orelse return error.NoProcess;
    const mq = proc.getMessageQueue(mqdes) orelse return error.InvalidDescriptor;

    const manager = getManager();
    manager.close(mq);

    proc.removeMessageQueue(mqdes);
}

/// sys_mq_unlink - Remove a message queue
pub fn sysMqUnlink(name: [*:0]const u8) !void {
    const manager = getManager();
    const name_slice = Basics.mem.span(name);

    try manager.unlink(name_slice);
}

/// sys_mq_send - Send a message
pub fn sysMqSend(mqdes: i32, msg: [*]const u8, msg_len: usize, msg_prio: u32) !void {
    const proc = process.current() orelse return error.NoProcess;
    const mq = proc.getMessageQueue(mqdes) orelse return error.InvalidDescriptor;

    if (!mq.canWrite(proc.uid, proc.gid)) {
        return error.PermissionDenied;
    }

    try mq.send(msg[0..msg_len], msg_prio, null);
}

/// sys_mq_receive - Receive a message
pub fn sysMqReceive(mqdes: i32, msg: [*]u8, msg_len: usize, msg_prio: ?*u32) !usize {
    const proc = process.current() orelse return error.NoProcess;
    const mq = proc.getMessageQueue(mqdes) orelse return error.InvalidDescriptor;

    if (!mq.canRead(proc.uid, proc.gid)) {
        return error.PermissionDenied;
    }

    return try mq.receive(msg[0..msg_len], msg_prio, null);
}

/// sys_mq_getsetattr - Get/set queue attributes
pub fn sysMqGetsetattr(mqdes: i32, new_attr: ?*const MqAttr, old_attr: ?*MqAttr) !void {
    const proc = process.current() orelse return error.NoProcess;
    const mq = proc.getMessageQueue(mqdes) orelse return error.InvalidDescriptor;

    if (new_attr) |new| {
        mq.setAttr(new.*, old_attr);
    } else if (old_attr) |old| {
        old.* = mq.getAttr();
    }
}

// ============================================================================
// Tests
// ============================================================================

test "message priority" {
    const allocator = Basics.testing.allocator;
    var manager = MqManager.init(allocator);
    defer manager.deinit();

    const attr = MqAttr.init(10, 100);
    const mq = try manager.open("/test", 0o100, 0o644, &attr, 1000, 1000);

    try mq.send("low", 1, null);
    try mq.send("high", 10, null);
    try mq.send("medium", 5, null);

    var buffer: [100]u8 = undefined;
    var prio: u32 = 0;

    // Should receive in priority order: high, medium, low
    const len1 = try mq.receive(&buffer, &prio, null);
    try Basics.testing.expectEqual(@as(u32, 10), prio);
    try Basics.testing.expectEqualSlices(u8, "high", buffer[0..len1]);

    const len2 = try mq.receive(&buffer, &prio, null);
    try Basics.testing.expectEqual(@as(u32, 5), prio);
    try Basics.testing.expectEqualSlices(u8, "medium", buffer[0..len2]);

    const len3 = try mq.receive(&buffer, &prio, null);
    try Basics.testing.expectEqual(@as(u32, 1), prio);
    try Basics.testing.expectEqualSlices(u8, "low", buffer[0..len3]);
}

test "message queue manager" {
    const allocator = Basics.testing.allocator;
    var manager = MqManager.init(allocator);
    defer manager.deinit();

    const attr = MqAttr.init(5, 50);
    const mq1 = try manager.open("/queue1", 0o100, 0o644, &attr, 1000, 1000);
    const mq2 = try manager.open("/queue1", 0o000, 0o644, &attr, 1000, 1000);

    try Basics.testing.expect(mq1 == mq2); // Same queue
    try Basics.testing.expectEqual(@as(u32, 2), mq1.refcount);
}
