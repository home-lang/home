// Home OS Kernel - IPC Security
// Access control and auditing for inter-process communication

const Basics = @import("basics");
const sync = @import("sync.zig");
const atomic = @import("atomic.zig");
const audit = @import("audit.zig");
const capabilities = @import("capabilities.zig");

// ============================================================================
// IPC Permissions
// ============================================================================

pub const IpcPermission = packed struct(u32) {
    /// Owner read permission
    owner_read: bool = false,
    /// Owner write permission
    owner_write: bool = false,
    /// Owner execute/access permission
    owner_exec: bool = false,
    /// Group read permission
    group_read: bool = false,
    /// Group write permission
    group_write: bool = false,
    /// Group execute/access permission
    group_exec: bool = false,
    /// Other read permission
    other_read: bool = false,
    /// Other write permission
    other_write: bool = false,
    /// Other execute/access permission
    other_exec: bool = false,

    _padding: u23 = 0,

    pub const OWNER_RWX: u32 = 0b111;
    pub const GROUP_RWX: u32 = 0b111000;
    pub const OTHER_RWX: u32 = 0b111000000;
    pub const ALL_RWX: u32 = 0b111111111;

    pub fn init(mode: u32) IpcPermission {
        return @bitCast(mode & ALL_RWX);
    }

    pub fn toMode(self: IpcPermission) u32 {
        return @bitCast(self);
    }

    /// Check if permission allows operation
    pub fn allows(self: IpcPermission, uid: u32, gid: u32, owner_uid: u32, owner_gid: u32, op: Operation) bool {
        // Owner permissions
        if (uid == owner_uid) {
            return switch (op) {
                .Read => self.owner_read,
                .Write => self.owner_write,
                .Execute => self.owner_exec,
            };
        }

        // Group permissions
        if (gid == owner_gid) {
            return switch (op) {
                .Read => self.group_read,
                .Write => self.group_write,
                .Execute => self.group_exec,
            };
        }

        // Other permissions
        return switch (op) {
            .Read => self.other_read,
            .Write => self.other_write,
            .Execute => self.other_exec,
        };
    }
};

pub const Operation = enum {
    Read,
    Write,
    Execute,
};

// ============================================================================
// IPC Object Base Structure
// ============================================================================

pub const IpcObject = struct {
    /// Unique IPC object ID
    id: u64,
    /// Owner UID
    owner_uid: u32,
    /// Owner GID
    owner_gid: u32,
    /// Creator UID
    creator_uid: u32,
    /// Permissions
    permissions: IpcPermission,
    /// Creation time (monotonic)
    creation_time: u64,
    /// Last access time
    last_access_time: atomic.AtomicU64,
    /// Reference count
    refcount: atomic.AtomicU32,
    /// Lock for modifications
    lock: sync.RwLock,

    pub fn init(id: u64, uid: u32, gid: u32, mode: u32, creation_time: u64) IpcObject {
        return .{
            .id = id,
            .owner_uid = uid,
            .owner_gid = gid,
            .creator_uid = uid,
            .permissions = IpcPermission.init(mode),
            .creation_time = creation_time,
            .last_access_time = atomic.AtomicU64.init(creation_time),
            .refcount = atomic.AtomicU32.init(1),
            .lock = sync.RwLock.init(),
        };
    }

    /// Check if current process can perform operation
    pub fn checkAccess(self: *IpcObject, uid: u32, gid: u32, op: Operation) !void {
        self.lock.acquireRead();
        defer self.lock.releaseRead();

        // Root bypasses permission checks
        if (uid == 0) {
            return;
        }

        if (!self.permissions.allows(uid, gid, self.owner_uid, self.owner_gid, op)) {
            audit.logSecurityViolation("IPC access denied");
            return error.PermissionDenied;
        }

        // Update access time
        const now = @as(u64, @intCast(@as(u128, @bitCast(Basics.time.nanoTimestamp()))));
        self.last_access_time.store(now, .Release);
    }

    /// Change ownership (requires CAP_CHOWN or owner)
    pub fn chown(self: *IpcObject, caller_uid: u32, new_uid: u32, new_gid: u32) !void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        // Must be owner or have CAP_CHOWN
        if (caller_uid != self.owner_uid and !capabilities.hasCapability(.CAP_CHOWN)) {
            return error.PermissionDenied;
        }

        self.owner_uid = new_uid;
        self.owner_gid = new_gid;

        var buf: [128]u8 = undefined;
        const msg = Basics.fmt.bufPrint(&buf, "IPC object {} ownership changed to {}:{}", .{ self.id, new_uid, new_gid }) catch "ipc_chown";
        audit.logSecurityViolation(msg);
    }

    /// Change permissions (requires owner or CAP_FOWNER)
    pub fn chmod(self: *IpcObject, caller_uid: u32, new_mode: u32) !void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        if (caller_uid != self.owner_uid and !capabilities.hasCapability(.CAP_FOWNER)) {
            return error.PermissionDenied;
        }

        self.permissions = IpcPermission.init(new_mode);
    }

    /// Acquire reference
    pub fn acquire(self: *IpcObject) void {
        _ = self.refcount.fetchAdd(1, .Acquire);
    }

    /// Release reference, returns true if last reference
    pub fn release(self: *IpcObject) bool {
        const old = self.refcount.fetchSub(1, .Release);
        return old == 1;
    }
};

// ============================================================================
// Shared Memory Security
// ============================================================================

pub const ShmSegment = struct {
    base: IpcObject,
    /// Size in bytes
    size: usize,
    /// Number of current attaches
    attach_count: atomic.AtomicU32,
    /// Maximum number of attaches allowed
    max_attaches: u32,
    /// Memory locked (prevents swapping)
    locked: bool,

    pub fn init(id: u64, uid: u32, gid: u32, mode: u32, size: usize, creation_time: u64) ShmSegment {
        return .{
            .base = IpcObject.init(id, uid, gid, mode, creation_time),
            .size = size,
            .attach_count = atomic.AtomicU32.init(0),
            .max_attaches = 100, // Default limit
            .locked = false,
        };
    }

    /// Attach to shared memory
    pub fn attach(self: *ShmSegment, uid: u32, gid: u32) !void {
        // Check read or write permission
        try self.base.checkAccess(uid, gid, .Read);

        const current = self.attach_count.fetchAdd(1, .Acquire);
        if (current >= self.max_attaches) {
            _ = self.attach_count.fetchSub(1, .Release);
            return error.TooManyAttaches;
        }
    }

    /// Detach from shared memory
    pub fn detach(self: *ShmSegment) void {
        _ = self.attach_count.fetchSub(1, .Release);
    }

    /// Lock memory (prevent swapping, requires CAP_IPC_LOCK)
    pub fn lock(self: *ShmSegment) !void {
        if (!capabilities.hasCapability(.CAP_IPC_LOCK)) {
            return error.PermissionDenied;
        }

        self.base.lock.acquireWrite();
        defer self.base.lock.releaseWrite();

        self.locked = true;
    }
};

// ============================================================================
// Message Queue Security
// ============================================================================

pub const MessageQueue = struct {
    base: IpcObject,
    /// Maximum message size
    max_msg_size: usize,
    /// Maximum messages in queue
    max_messages: usize,
    /// Current message count
    message_count: atomic.AtomicU32,
    /// Total bytes in queue
    total_bytes: atomic.AtomicU64,

    pub fn init(id: u64, uid: u32, gid: u32, mode: u32, creation_time: u64) MessageQueue {
        return .{
            .base = IpcObject.init(id, uid, gid, mode, creation_time),
            .max_msg_size = 8192, // 8KB default
            .max_messages = 256,
            .message_count = atomic.AtomicU32.init(0),
            .total_bytes = atomic.AtomicU64.init(0),
        };
    }

    /// Send message
    pub fn send(self: *MessageQueue, uid: u32, gid: u32, msg_size: usize) !void {
        // Check write permission
        try self.base.checkAccess(uid, gid, .Write);

        if (msg_size > self.max_msg_size) {
            return error.MessageTooLarge;
        }

        const current = self.message_count.fetchAdd(1, .Acquire);
        if (current >= self.max_messages) {
            _ = self.message_count.fetchSub(1, .Release);
            return error.QueueFull;
        }

        _ = self.total_bytes.fetchAdd(msg_size, .Release);
    }

    /// Receive message
    pub fn receive(self: *MessageQueue, uid: u32, gid: u32, msg_size: usize) !void {
        // Check read permission
        try self.base.checkAccess(uid, gid, .Read);

        _ = self.message_count.fetchSub(1, .Release);
        _ = self.total_bytes.fetchSub(msg_size, .Release);
    }

    /// Get queue statistics
    pub fn getStats(self: *const MessageQueue) MessageQueueStats {
        return .{
            .message_count = self.message_count.load(.Acquire),
            .total_bytes = self.total_bytes.load(.Acquire),
            .max_messages = self.max_messages,
            .max_msg_size = self.max_msg_size,
        };
    }
};

pub const MessageQueueStats = struct {
    message_count: u32,
    total_bytes: u64,
    max_messages: usize,
    max_msg_size: usize,
};

// ============================================================================
// Semaphore Security
// ============================================================================

pub const Semaphore = struct {
    base: IpcObject,
    /// Current value
    value: atomic.AtomicI32,
    /// Maximum value
    max_value: i32,
    /// Operation count
    op_count: atomic.AtomicU64,

    pub fn init(id: u64, uid: u32, gid: u32, mode: u32, initial_value: i32, creation_time: u64) Semaphore {
        return .{
            .base = IpcObject.init(id, uid, gid, mode, creation_time),
            .value = atomic.AtomicI32.init(initial_value),
            .max_value = 32767,
            .op_count = atomic.AtomicU64.init(0),
        };
    }

    /// Increment semaphore (V operation)
    pub fn increment(self: *Semaphore, uid: u32, gid: u32, amount: i32) !void {
        // Check write permission
        try self.base.checkAccess(uid, gid, .Write);

        const current = self.value.load(.Acquire);
        if (current + amount > self.max_value) {
            return error.SemaphoreOverflow;
        }

        _ = self.value.fetchAdd(amount, .Release);
        _ = self.op_count.fetchAdd(1, .Release);
    }

    /// Decrement semaphore (P operation)
    pub fn decrement(self: *Semaphore, uid: u32, gid: u32, amount: i32) !void {
        // Check write permission
        try self.base.checkAccess(uid, gid, .Write);

        const current = self.value.load(.Acquire);
        if (current - amount < 0) {
            return error.WouldBlock;
        }

        _ = self.value.fetchSub(amount, .Release);
        _ = self.op_count.fetchAdd(1, .Release);
    }

    /// Get current value
    pub fn getValue(self: *const Semaphore, uid: u32, gid: u32) !i32 {
        try self.base.checkAccess(uid, gid, .Read);
        return self.value.load(.Acquire);
    }
};

// ============================================================================
// Pipe Security
// ============================================================================

pub const PipeEnd = enum {
    Read,
    Write,
    Both,
};

pub const Pipe = struct {
    base: IpcObject,
    /// Read end open
    read_open: atomic.AtomicBool,
    /// Write end open
    write_open: atomic.AtomicBool,
    /// Buffer size
    buffer_size: usize,
    /// Current data size
    data_size: atomic.AtomicU64,
    /// Readers count
    reader_count: atomic.AtomicU32,
    /// Writers count
    writer_count: atomic.AtomicU32,

    pub fn init(id: u64, uid: u32, gid: u32, mode: u32, creation_time: u64) Pipe {
        return .{
            .base = IpcObject.init(id, uid, gid, mode, creation_time),
            .read_open = atomic.AtomicBool.init(true),
            .write_open = atomic.AtomicBool.init(true),
            .buffer_size = 65536, // 64KB default pipe buffer
            .data_size = atomic.AtomicU64.init(0),
            .reader_count = atomic.AtomicU32.init(0),
            .writer_count = atomic.AtomicU32.init(0),
        };
    }

    /// Open pipe end
    pub fn open(self: *Pipe, uid: u32, gid: u32, end: PipeEnd) !void {
        switch (end) {
            .Read => {
                try self.base.checkAccess(uid, gid, .Read);
                _ = self.reader_count.fetchAdd(1, .Acquire);
            },
            .Write => {
                try self.base.checkAccess(uid, gid, .Write);
                _ = self.writer_count.fetchAdd(1, .Acquire);
            },
            .Both => {
                try self.base.checkAccess(uid, gid, .Read);
                try self.base.checkAccess(uid, gid, .Write);
                _ = self.reader_count.fetchAdd(1, .Acquire);
                _ = self.writer_count.fetchAdd(1, .Acquire);
            },
        }
    }

    /// Close pipe end
    pub fn close(self: *Pipe, end: PipeEnd) void {
        switch (end) {
            .Read => {
                if (self.reader_count.fetchSub(1, .Release) == 1) {
                    self.read_open.store(false, .Release);
                }
            },
            .Write => {
                if (self.writer_count.fetchSub(1, .Release) == 1) {
                    self.write_open.store(false, .Release);
                }
            },
            .Both => {
                if (self.reader_count.fetchSub(1, .Release) == 1) {
                    self.read_open.store(false, .Release);
                }
                if (self.writer_count.fetchSub(1, .Release) == 1) {
                    self.write_open.store(false, .Release);
                }
            },
        }
    }

    /// Check if pipe is broken
    pub fn isBroken(self: *const Pipe, end: PipeEnd) bool {
        return switch (end) {
            .Read => !self.write_open.load(.Acquire),
            .Write => !self.read_open.load(.Acquire),
            .Both => !self.read_open.load(.Acquire) and !self.write_open.load(.Acquire),
        };
    }
};

// ============================================================================
// IPC Namespace Isolation
// ============================================================================

pub const IpcNamespace = struct {
    /// Namespace ID
    id: u64,
    /// Shared memory segments
    shm_count: atomic.AtomicU32,
    /// Message queues
    mq_count: atomic.AtomicU32,
    /// Semaphores
    sem_count: atomic.AtomicU32,
    /// Maximum IPC objects
    max_objects: u32,

    pub fn init(id: u64) IpcNamespace {
        return .{
            .id = id,
            .shm_count = atomic.AtomicU32.init(0),
            .mq_count = atomic.AtomicU32.init(0),
            .sem_count = atomic.AtomicU32.init(0),
            .max_objects = 1024,
        };
    }

    /// Check if can create new IPC object
    pub fn canCreate(self: *const IpcNamespace) bool {
        const total = self.shm_count.load(.Acquire) +
            self.mq_count.load(.Acquire) +
            self.sem_count.load(.Acquire);
        return total < self.max_objects;
    }

    /// Register new object
    pub fn registerObject(self: *IpcNamespace, obj_type: IpcType) !void {
        if (!self.canCreate()) {
            return error.TooManyIpcObjects;
        }

        switch (obj_type) {
            .SharedMemory => _ = self.shm_count.fetchAdd(1, .Release),
            .MessageQueue => _ = self.mq_count.fetchAdd(1, .Release),
            .Semaphore => _ = self.sem_count.fetchAdd(1, .Release),
        }
    }

    /// Unregister object
    pub fn unregisterObject(self: *IpcNamespace, obj_type: IpcType) void {
        switch (obj_type) {
            .SharedMemory => _ = self.shm_count.fetchSub(1, .Release),
            .MessageQueue => _ = self.mq_count.fetchSub(1, .Release),
            .Semaphore => _ = self.sem_count.fetchSub(1, .Release),
        }
    }
};

pub const IpcType = enum {
    SharedMemory,
    MessageQueue,
    Semaphore,
};

// ============================================================================
// Tests
// ============================================================================

test "ipc permission checking" {
    const perm = IpcPermission.init(0o640); // Owner: rw, Group: r, Other: none

    // Owner can read and write
    try Basics.testing.expect(perm.allows(1000, 100, 1000, 100, .Read));
    try Basics.testing.expect(perm.allows(1000, 100, 1000, 100, .Write));

    // Group can read only
    try Basics.testing.expect(perm.allows(1001, 100, 1000, 100, .Read));
    try Basics.testing.expect(!perm.allows(1001, 100, 1000, 100, .Write));

    // Other cannot access
    try Basics.testing.expect(!perm.allows(1001, 101, 1000, 100, .Read));
}

test "ipc object access control" {
    var obj = IpcObject.init(1, 1000, 100, 0o640, 1000);

    // Owner can access
    try obj.checkAccess(1000, 100, .Read);
    try obj.checkAccess(1000, 100, .Write);

    // Root can always access
    try obj.checkAccess(0, 0, .Read);
}

test "shared memory attach limits" {
    var shm = ShmSegment.init(1, 1000, 100, 0o640, 4096, 1000);
    shm.max_attaches = 2;

    try shm.attach(1000, 100);
    try shm.attach(1000, 100);

    // Should fail - too many attaches
    const result = shm.attach(1000, 100);
    try Basics.testing.expect(result == error.TooManyAttaches);
}

test "message queue limits" {
    var mq = MessageQueue.init(1, 1000, 100, 0o640, 1000);
    mq.max_messages = 2;

    try mq.send(1000, 100, 100);
    try mq.send(1000, 100, 100);

    // Should fail - queue full
    const result = mq.send(1000, 100, 100);
    try Basics.testing.expect(result == error.QueueFull);
}

test "semaphore operations" {
    var sem = Semaphore.init(1, 1000, 100, 0o640, 5, 1000);

    try sem.increment(1000, 100, 3);
    try Basics.testing.expect(sem.value.load(.Acquire) == 8);

    try sem.decrement(1000, 100, 2);
    try Basics.testing.expect(sem.value.load(.Acquire) == 6);

    // Should fail - would go negative
    const result = sem.decrement(1000, 100, 10);
    try Basics.testing.expect(result == error.WouldBlock);
}

test "pipe broken detection" {
    var pipe = Pipe.init(1, 1000, 100, 0o640, 1000);

    try pipe.open(1000, 100, .Read);
    try pipe.open(1000, 100, .Write);

    try Basics.testing.expect(!pipe.isBroken(.Read));
    try Basics.testing.expect(!pipe.isBroken(.Write));

    pipe.close(.Write);
    pipe.close(.Write);

    try Basics.testing.expect(pipe.isBroken(.Write));
}

test "ipc namespace limits" {
    var ns = IpcNamespace.init(1);
    ns.max_objects = 3;

    try ns.registerObject(.SharedMemory);
    try ns.registerObject(.MessageQueue);
    try ns.registerObject(.Semaphore);

    // Should fail - too many objects
    const result = ns.registerObject(.SharedMemory);
    try Basics.testing.expect(result == error.TooManyIpcObjects);
}
