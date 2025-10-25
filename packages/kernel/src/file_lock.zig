// Home OS Kernel - File Locking (flock/fcntl)
// Prevents concurrent file corruption

const Basics = @import("basics");
const sync = @import("sync.zig");
const atomic = @import("atomic.zig");
const process = @import("process.zig");

// ============================================================================
// Lock Types
// ============================================================================

pub const LockType = enum(u8) {
    /// No lock
    UNLOCK = 0,
    /// Shared (read) lock
    SHARED = 1,
    /// Exclusive (write) lock
    EXCLUSIVE = 2,
};

pub const LockMode = enum(u8) {
    /// Advisory locking (processes cooperate)
    ADVISORY = 0,
    /// Mandatory locking (enforced by kernel)
    MANDATORY = 1,
};

// ============================================================================
// File Lock Structure
// ============================================================================

pub const FileLock = struct {
    /// Lock type
    lock_type: LockType,
    /// Lock mode
    mode: LockMode,
    /// Owner process ID
    owner_pid: u32,
    /// Start offset (for range locks)
    start: u64,
    /// Length (0 = whole file)
    length: u64,
    /// Wait queue for blocked processes
    waiters: u32,

    pub fn init(lock_type: LockType, mode: LockMode, pid: u32) FileLock {
        return .{
            .lock_type = lock_type,
            .mode = mode,
            .owner_pid = pid,
            .start = 0,
            .length = 0, // Whole file
            .waiters = 0,
        };
    }

    /// Check if lock conflicts with another
    pub fn conflicts(self: *const FileLock, other: *const FileLock) bool {
        // No lock never conflicts
        if (self.lock_type == .UNLOCK or other.lock_type == .UNLOCK) {
            return false;
        }

        // Shared locks don't conflict with each other
        if (self.lock_type == .SHARED and other.lock_type == .SHARED) {
            return false;
        }

        // Check range overlap
        if (self.length > 0 and other.length > 0) {
            const self_end = self.start + self.length;
            const other_end = other.start + other.length;

            // No overlap
            if (self_end <= other.start or other_end <= self.start) {
                return false;
            }
        }

        // Exclusive locks conflict with everything
        return true;
    }
};

// ============================================================================
// File Lock Table
// ============================================================================

const MAX_LOCKS_PER_FILE = 16;

pub const FileLockTable = struct {
    /// Active locks
    locks: [MAX_LOCKS_PER_FILE]?FileLock,
    /// Number of active locks
    count: usize,
    /// Lock for this table
    lock: sync.Spinlock,

    pub fn init() FileLockTable {
        return .{
            .locks = [_]?FileLock{null} ** MAX_LOCKS_PER_FILE,
            .count = 0,
            .lock = sync.Spinlock.init(),
        };
    }

    /// Try to acquire a lock
    pub fn acquireLock(self: *FileLockTable, new_lock: FileLock) !void {
        self.lock.acquire();
        defer self.lock.release();

        // Check for conflicts
        for (self.locks) |maybe_lock| {
            if (maybe_lock) |existing_lock| {
                if (new_lock.conflicts(&existing_lock)) {
                    return error.LockConflict;
                }
            }
        }

        // No conflicts, add the lock
        if (self.count >= MAX_LOCKS_PER_FILE) {
            return error.TooManyLocks;
        }

        // Find empty slot
        for (&self.locks) |*slot| {
            if (slot.* == null) {
                slot.* = new_lock;
                self.count += 1;
                return;
            }
        }

        return error.TooManyLocks;
    }

    /// Release a lock
    pub fn releaseLock(self: *FileLockTable, pid: u32, start: u64, length: u64) void {
        self.lock.acquire();
        defer self.lock.release();

        for (&self.locks) |*slot| {
            if (slot.*) |lock| {
                if (lock.owner_pid == pid and lock.start == start and lock.length == length) {
                    slot.* = null;
                    self.count -= 1;
                    return;
                }
            }
        }
    }

    /// Release all locks owned by a process
    pub fn releaseAllForProcess(self: *FileLockTable, pid: u32) void {
        self.lock.acquire();
        defer self.lock.release();

        for (&self.locks) |*slot| {
            if (slot.*) |lock| {
                if (lock.owner_pid == pid) {
                    slot.* = null;
                    self.count -= 1;
                }
            }
        }
    }

    /// Check if lock would conflict
    pub fn wouldConflict(self: *FileLockTable, new_lock: *const FileLock) bool {
        self.lock.acquire();
        defer self.lock.release();

        for (self.locks) |maybe_lock| {
            if (maybe_lock) |existing_lock| {
                if (new_lock.conflicts(&existing_lock)) {
                    return true;
                }
            }
        }

        return false;
    }
};

// ============================================================================
// Global Lock Registry
// ============================================================================

const MAX_LOCKED_FILES = 256;

const LockedFile = struct {
    /// File inode number (unique identifier)
    inode: u64,
    /// Lock table for this file
    lock_table: FileLockTable,
};

var locked_files: [MAX_LOCKED_FILES]?LockedFile = [_]?LockedFile{null} ** MAX_LOCKED_FILES;
var global_lock = sync.RwLock.init();

/// Get or create lock table for a file
fn getLockTable(inode: u64) !*FileLockTable {
    global_lock.acquireWrite();
    defer global_lock.releaseWrite();

    // Find existing table
    for (&locked_files) |*slot| {
        if (slot.*) |*file| {
            if (file.inode == inode) {
                return &file.lock_table;
            }
        }
    }

    // Create new table
    for (&locked_files) |*slot| {
        if (slot.* == null) {
            slot.* = LockedFile{
                .inode = inode,
                .lock_table = FileLockTable.init(),
            };
            return &slot.*.?.lock_table;
        }
    }

    return error.TooManyLockedFiles;
}

// ============================================================================
// Public API
// ============================================================================

/// Acquire file lock (flock syscall)
pub fn flock(inode: u64, lock_type: LockType, mode: LockMode) !void {
    const current = process.getCurrentProcess() orelse return error.NoProcess;

    const lock_table = try getLockTable(inode);

    const new_lock = FileLock.init(lock_type, mode, current.pid);
    try lock_table.acquireLock(new_lock);
}

/// Release file lock
pub fn funlock(inode: u64) !void {
    const current = process.getCurrentProcess() orelse return error.NoProcess;

    const lock_table = try getLockTable(inode);
    lock_table.releaseAllForProcess(current.pid);
}

/// Acquire range lock (fcntl F_SETLK)
pub fn lockRange(inode: u64, lock_type: LockType, start: u64, length: u64) !void {
    const current = process.getCurrentProcess() orelse return error.NoProcess;

    const lock_table = try getLockTable(inode);

    var new_lock = FileLock.init(lock_type, .ADVISORY, current.pid);
    new_lock.start = start;
    new_lock.length = length;

    try lock_table.acquireLock(new_lock);
}

/// Release range lock
pub fn unlockRange(inode: u64, start: u64, length: u64) !void {
    const current = process.getCurrentProcess() orelse return error.NoProcess;

    const lock_table = try getLockTable(inode);
    lock_table.releaseLock(current.pid, start, length);
}

/// Check if file is locked
pub fn isLocked(inode: u64, lock_type: LockType) bool {
    const current = process.getCurrentProcess() orelse return false;

    const lock_table = getLockTable(inode) catch return false;

    const test_lock = FileLock.init(lock_type, .ADVISORY, current.pid);
    return lock_table.wouldConflict(&test_lock);
}

/// Release all locks for a process (called on exit)
pub fn releaseAllLocksForProcess(pid: u32) void {
    global_lock.acquireRead();
    defer global_lock.releaseRead();

    for (&locked_files) |*slot| {
        if (slot.*) |*file| {
            file.lock_table.releaseAllForProcess(pid);
        }
    }
}

// ============================================================================
// fcntl/flock constants
// ============================================================================

pub const F_RDLCK: i32 = 0; // Shared lock
pub const F_WRLCK: i32 = 1; // Exclusive lock
pub const F_UNLCK: i32 = 2; // Unlock

pub const LOCK_SH: i32 = 1; // Shared lock
pub const LOCK_EX: i32 = 2; // Exclusive lock
pub const LOCK_UN: i32 = 8; // Unlock
pub const LOCK_NB: i32 = 4; // Non-blocking

// ============================================================================
// Tests
// ============================================================================

test "file lock creation" {
    const lock = FileLock.init(.SHARED, .ADVISORY, 123);

    try Basics.testing.expect(lock.lock_type == .SHARED);
    try Basics.testing.expect(lock.owner_pid == 123);
}

test "lock conflict detection" {
    const shared1 = FileLock.init(.SHARED, .ADVISORY, 1);
    const shared2 = FileLock.init(.SHARED, .ADVISORY, 2);
    const exclusive = FileLock.init(.EXCLUSIVE, .ADVISORY, 3);

    // Shared locks don't conflict
    try Basics.testing.expect(!shared1.conflicts(&shared2));

    // Exclusive conflicts with shared
    try Basics.testing.expect(exclusive.conflicts(&shared1));
    try Basics.testing.expect(shared1.conflicts(&exclusive));

    // Exclusive conflicts with exclusive
    const exclusive2 = FileLock.init(.EXCLUSIVE, .ADVISORY, 4);
    try Basics.testing.expect(exclusive.conflicts(&exclusive2));
}

test "file lock table" {
    var table = FileLockTable.init();

    const lock1 = FileLock.init(.SHARED, .ADVISORY, 1);
    try table.acquireLock(lock1);

    try Basics.testing.expect(table.count == 1);

    // Another shared lock should succeed
    const lock2 = FileLock.init(.SHARED, .ADVISORY, 2);
    try table.acquireLock(lock2);

    try Basics.testing.expect(table.count == 2);

    // Exclusive lock should fail
    const lock3 = FileLock.init(.EXCLUSIVE, .ADVISORY, 3);
    const result = table.acquireLock(lock3);
    try Basics.testing.expectError(error.LockConflict, result);
}

test "range lock conflicts" {
    var lock1 = FileLock.init(.EXCLUSIVE, .ADVISORY, 1);
    lock1.start = 0;
    lock1.length = 100;

    var lock2 = FileLock.init(.EXCLUSIVE, .ADVISORY, 2);
    lock2.start = 50;
    lock2.length = 100;

    // Overlapping ranges should conflict
    try Basics.testing.expect(lock1.conflicts(&lock2));

    // Non-overlapping ranges should not conflict
    var lock3 = FileLock.init(.EXCLUSIVE, .ADVISORY, 3);
    lock3.start = 200;
    lock3.length = 100;

    try Basics.testing.expect(!lock1.conflicts(&lock3));
}

test "release locks for process" {
    var table = FileLockTable.init();

    const lock1 = FileLock.init(.SHARED, .ADVISORY, 1);
    const lock2 = FileLock.init(.SHARED, .ADVISORY, 1);
    const lock3 = FileLock.init(.SHARED, .ADVISORY, 2);

    try table.acquireLock(lock1);
    try table.acquireLock(lock2);
    try table.acquireLock(lock3);

    try Basics.testing.expect(table.count == 3);

    // Release all locks for PID 1
    table.releaseAllForProcess(1);

    try Basics.testing.expect(table.count == 1);
}
