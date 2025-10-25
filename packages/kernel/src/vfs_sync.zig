// Home OS Kernel - VFS Synchronization and Race Condition Fixes
// Prevents TOCTOU bugs in VFS operations

const Basics = @import("basics");
const sync = @import("sync.zig");
const atomic = @import("atomic.zig");

// ============================================================================
// Reference Counting for Inodes and Dentries
// ============================================================================

/// Thread-safe reference counter
pub const RefCount = struct {
    count: atomic.AtomicU32,

    pub fn init(initial: u32) RefCount {
        return .{ .count = atomic.AtomicU32.init(initial) };
    }

    /// Acquire a reference (increment)
    pub fn acquire(self: *RefCount) u32 {
        return self.count.fetchAdd(1, .Acquire);
    }

    /// Release a reference (decrement), returns true if last reference
    pub fn release(self: *RefCount) bool {
        const old = self.count.fetchSub(1, .Release);
        return old == 1;
    }

    /// Get current count (for debugging)
    pub fn get(self: *const RefCount) u32 {
        return self.count.load(.Acquire);
    }

    /// Try to acquire if count > 0 (prevents use-after-free)
    pub fn tryAcquire(self: *RefCount) bool {
        var current = self.count.load(.Acquire);
        while (current > 0) {
            const result = self.count.compareAndSwap(
                current,
                current + 1,
                .Acquire,
                .Acquire,
            );

            if (result == null) return true; // Success
            current = result.?; // CAS failed, retry
        }
        return false; // Count is 0, cannot acquire
    }
};

// ============================================================================
// Sequence Lock for Consistent Reads
// ============================================================================

/// Seqlock allows multiple readers without blocking, writers are serialized
pub const SeqLock = struct {
    sequence: atomic.AtomicU32,
    writer_lock: sync.Spinlock,

    pub fn init() SeqLock {
        return .{
            .sequence = atomic.AtomicU32.init(0),
            .writer_lock = sync.Spinlock.init(),
        };
    }

    /// Begin write (acquire exclusive access)
    pub fn writeBegin(self: *SeqLock) void {
        self.writer_lock.acquire();
        // Increment sequence (make it odd = write in progress)
        _ = self.sequence.fetchAdd(1, .Release);
    }

    /// End write
    pub fn writeEnd(self: *SeqLock) void {
        // Increment sequence (make it even = write complete)
        _ = self.sequence.fetchAdd(1, .Release);
        self.writer_lock.release();
    }

    /// Begin read (get sequence number)
    pub fn readBegin(self: *const SeqLock) u32 {
        while (true) {
            const seq = self.sequence.load(.Acquire);
            // If even, no write in progress
            if (seq & 1 == 0) return seq;
            // Spin until write completes
        }
    }

    /// Validate read (check if sequence changed)
    pub fn readValidate(self: *const SeqLock, seq: u32) bool {
        // Ensure all reads complete before checking sequence
        atomic.fence(.Acquire);
        return self.sequence.load(.Acquire) == seq;
    }
};

// ============================================================================
// RCU-like Read-Copy-Update for Lockless Reads
// ============================================================================

pub const RcuState = enum(u8) {
    ACTIVE = 0,
    GRACE = 1,
    FREED = 2,
};

pub const RcuNode = struct {
    state: atomic.AtomicU8,
    next: ?*RcuNode,

    pub fn init() RcuNode {
        return .{
            .state = atomic.AtomicU8.init(@intFromEnum(RcuState.ACTIVE)),
            .next = null,
        };
    }

    pub fn markForFree(self: *RcuNode) void {
        _ = self.state.store(@intFromEnum(RcuState.GRACE), .Release);
    }

    pub fn isActive(self: *const RcuNode) bool {
        const state: RcuState = @enumFromInt(self.state.load(.Acquire));
        return state == .ACTIVE;
    }
};

// ============================================================================
// Path Resolution Race Prevention
// ============================================================================

pub const PathContext = struct {
    /// Lock held during path traversal
    lock: sync.RwLock,
    /// Sequence number for validation
    seq: SeqLock,
    /// Current working directory reference
    cwd_refcount: RefCount,

    pub fn init() PathContext {
        return .{
            .lock = sync.RwLock.init(),
            .seq = SeqLock.init(),
            .cwd_refcount = RefCount.init(1),
        };
    }

    /// Begin atomic path resolution
    pub fn beginResolution(self: *PathContext) u32 {
        self.lock.acquireRead();
        return self.seq.readBegin();
    }

    /// Validate path resolution (detect races)
    pub fn validateResolution(self: *PathContext, seq: u32) bool {
        const valid = self.seq.readValidate(seq);
        self.lock.releaseRead();
        return valid;
    }

    /// Modify path (e.g., chdir)
    pub fn modifyPath(self: *PathContext) void {
        self.lock.acquireWrite();
        self.seq.writeBegin();
        // Critical section for path modification
    }

    pub fn endModifyPath(self: *PathContext) void {
        self.seq.writeEnd();
        self.lock.releaseWrite();
    }
};

// ============================================================================
// Inode Invalidation (Prevents Stale Reads)
// ============================================================================

pub const InodeGeneration = struct {
    generation: atomic.AtomicU64,

    pub fn init() InodeGeneration {
        return .{ .generation = atomic.AtomicU64.init(0) };
    }

    /// Get current generation
    pub fn get(self: *const InodeGeneration) u64 {
        return self.generation.load(.Acquire);
    }

    /// Invalidate (increment generation)
    pub fn invalidate(self: *InodeGeneration) void {
        _ = self.generation.fetchAdd(1, .Release);
    }

    /// Check if generation is current
    pub fn isCurrent(self: *const InodeGeneration, gen: u64) bool {
        return self.generation.load(.Acquire) == gen;
    }
};

// ============================================================================
// Dentry Cache Synchronization
// ============================================================================

pub const DentryState = enum(u8) {
    VALID = 0,
    NEGATIVE = 1, // Name doesn't exist
    INVALID = 2,  // Needs revalidation
};

pub const DentrySyncInfo = struct {
    state: atomic.AtomicU8,
    generation: atomic.AtomicU64,
    refcount: RefCount,

    pub fn init() DentrySyncInfo {
        return .{
            .state = atomic.AtomicU8.init(@intFromEnum(DentryState.VALID)),
            .generation = atomic.AtomicU64.init(0),
            .refcount = RefCount.init(1),
        };
    }

    pub fn isValid(self: *const DentrySyncInfo) bool {
        const state: DentryState = @enumFromInt(self.state.load(.Acquire));
        return state == .VALID;
    }

    pub fn invalidate(self: *DentrySyncInfo) void {
        _ = self.state.store(@intFromEnum(DentryState.INVALID), .Release);
        _ = self.generation.fetchAdd(1, .Release);
    }

    pub fn markNegative(self: *DentrySyncInfo) void {
        _ = self.state.store(@intFromEnum(DentryState.NEGATIVE), .Release);
    }

    pub fn revalidate(self: *DentrySyncInfo) void {
        _ = self.state.store(@intFromEnum(DentryState.VALID), .Release);
        _ = self.generation.fetchAdd(1, .Release);
    }
};

// ============================================================================
// Permission Check Synchronization
// ============================================================================

pub const PermissionCache = struct {
    /// Last checked permissions
    cached_perm: atomic.AtomicU32,
    /// UID of last check
    cached_uid: atomic.AtomicU32,
    /// Generation number
    generation: atomic.AtomicU64,
    /// Lock for updates
    lock: sync.Spinlock,

    pub fn init() PermissionCache {
        return .{
            .cached_perm = atomic.AtomicU32.init(0),
            .cached_uid = atomic.AtomicU32.init(0),
            .generation = atomic.AtomicU64.init(0),
            .lock = sync.Spinlock.init(),
        };
    }

    /// Check cached permission
    pub fn checkCached(self: *const PermissionCache, uid: u32, required_perm: u32, gen: u64) ?bool {
        // Verify generation
        if (self.generation.load(.Acquire) != gen) {
            return null; // Cache invalid
        }

        // Check if UID matches
        if (self.cached_uid.load(.Acquire) != uid) {
            return null;
        }

        // Check permission
        const perm = self.cached_perm.load(.Acquire);
        return (perm & required_perm) == required_perm;
    }

    /// Update cache
    pub fn update(self: *PermissionCache, uid: u32, perm: u32) u64 {
        self.lock.acquire();
        defer self.lock.release();

        self.cached_uid.store(uid, .Release);
        self.cached_perm.store(perm, .Release);
        const gen = self.generation.fetchAdd(1, .Release) + 1;
        return gen;
    }

    /// Invalidate cache
    pub fn invalidate(self: *PermissionCache) void {
        _ = self.generation.fetchAdd(1, .Release);
    }
};

// ============================================================================
// Atomic Rename Operation
// ============================================================================

pub const RenameContext = struct {
    /// Locks for source and destination parents
    src_lock: *sync.RwLock,
    dst_lock: *sync.RwLock,
    /// Sequence locks
    src_seq: *SeqLock,
    dst_seq: *SeqLock,

    pub fn init(src_lock: *sync.RwLock, dst_lock: *sync.RwLock, src_seq: *SeqLock, dst_seq: *SeqLock) RenameContext {
        return .{
            .src_lock = src_lock,
            .dst_lock = dst_lock,
            .src_seq = src_seq,
            .dst_seq = dst_seq,
        };
    }

    /// Lock in correct order to prevent deadlock
    pub fn lockForRename(self: *RenameContext) void {
        // Lock in pointer order to prevent deadlock
        const src_ptr = @intFromPtr(self.src_lock);
        const dst_ptr = @intFromPtr(self.dst_lock);

        if (src_ptr < dst_ptr) {
            self.src_lock.acquireWrite();
            self.dst_lock.acquireWrite();
        } else if (src_ptr > dst_ptr) {
            self.dst_lock.acquireWrite();
            self.src_lock.acquireWrite();
        } else {
            // Same directory
            self.src_lock.acquireWrite();
        }

        self.src_seq.writeBegin();
        if (src_ptr != dst_ptr) {
            self.dst_seq.writeBegin();
        }
    }

    pub fn unlockAfterRename(self: *RenameContext) void {
        const src_ptr = @intFromPtr(self.src_lock);
        const dst_ptr = @intFromPtr(self.dst_lock);

        if (src_ptr != dst_ptr) {
            self.dst_seq.writeEnd();
        }
        self.src_seq.writeEnd();

        if (src_ptr < dst_ptr) {
            self.dst_lock.releaseWrite();
            self.src_lock.releaseWrite();
        } else if (src_ptr > dst_ptr) {
            self.src_lock.releaseWrite();
            self.dst_lock.releaseWrite();
        } else {
            self.src_lock.releaseWrite();
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "refcount basic operations" {
    var rc = RefCount.init(1);

    try Basics.testing.expect(rc.get() == 1);

    _ = rc.acquire();
    try Basics.testing.expect(rc.get() == 2);

    const is_last = rc.release();
    try Basics.testing.expect(!is_last);
    try Basics.testing.expect(rc.get() == 1);

    const is_last2 = rc.release();
    try Basics.testing.expect(is_last2);
    try Basics.testing.expect(rc.get() == 0);
}

test "refcount try acquire" {
    var rc = RefCount.init(1);

    try Basics.testing.expect(rc.tryAcquire());
    try Basics.testing.expect(rc.get() == 2);

    _ = rc.release();
    _ = rc.release();
    try Basics.testing.expect(rc.get() == 0);

    // Cannot acquire when count is 0
    try Basics.testing.expect(!rc.tryAcquire());
}

test "seqlock basic usage" {
    var seq = SeqLock.init();

    // Reader can read while no write in progress
    const seq1 = seq.readBegin();
    try Basics.testing.expect(seq.readValidate(seq1));
}

test "inode generation" {
    var gen = InodeGeneration.init();

    const g1 = gen.get();
    try Basics.testing.expect(gen.isCurrent(g1));

    gen.invalidate();

    try Basics.testing.expect(!gen.isCurrent(g1));
    const g2 = gen.get();
    try Basics.testing.expect(gen.isCurrent(g2));
    try Basics.testing.expect(g2 == g1 + 1);
}

test "dentry sync state" {
    var dentry_sync = DentrySyncInfo.init();

    try Basics.testing.expect(dentry_sync.isValid());

    dentry_sync.invalidate();
    try Basics.testing.expect(!dentry_sync.isValid());

    dentry_sync.revalidate();
    try Basics.testing.expect(dentry_sync.isValid());
}

test "permission cache" {
    var perm_cache = PermissionCache.init();

    const gen = perm_cache.update(1000, 0x7); // rwx

    // Cache hit
    const result = perm_cache.checkCached(1000, 0x4, gen); // read
    try Basics.testing.expect(result != null);
    try Basics.testing.expect(result.?);

    // Wrong UID
    const result2 = perm_cache.checkCached(1001, 0x4, gen);
    try Basics.testing.expect(result2 == null);

    // Invalidate
    perm_cache.invalidate();
    const result3 = perm_cache.checkCached(1000, 0x4, gen);
    try Basics.testing.expect(result3 == null);
}
