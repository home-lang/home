// Home OS Kernel - Advanced VFS Features
// Additional filesystem security and performance features

const Basics = @import("basics");
const sync = @import("sync.zig");
const atomic = @import("atomic.zig");
const audit = @import("audit.zig");
const capabilities = @import("capabilities.zig");
const vfs_sync = @import("vfs_sync.zig");

// ============================================================================
// Filesystem Quotas
// ============================================================================

pub const QuotaType = enum(u8) {
    /// User quota
    USER = 0,
    /// Group quota
    GROUP = 1,
    /// Project quota
    PROJECT = 2,
};

pub const QuotaLimits = struct {
    /// Soft limit for disk blocks
    blocks_soft: u64,
    /// Hard limit for disk blocks
    blocks_hard: u64,
    /// Soft limit for inodes
    inodes_soft: u64,
    /// Hard limit for inodes
    inodes_hard: u64,
    /// Current block usage
    blocks_used: atomic.AtomicU64,
    /// Current inode usage
    inodes_used: atomic.AtomicU64,
    /// Grace period (seconds)
    grace_period: u64,
    /// Soft limit exceeded time
    soft_exceeded_time: atomic.AtomicU64,

    pub fn init(blocks_hard: u64, inodes_hard: u64) QuotaLimits {
        return .{
            .blocks_soft = (blocks_hard * 90) / 100, // 90% of hard limit
            .blocks_hard = blocks_hard,
            .inodes_soft = (inodes_hard * 90) / 100,
            .inodes_hard = inodes_hard,
            .blocks_used = atomic.AtomicU64.init(0),
            .inodes_used = atomic.AtomicU64.init(0),
            .grace_period = 7 * 24 * 3600, // 7 days
            .soft_exceeded_time = atomic.AtomicU64.init(0),
        };
    }

    /// Check if allocation is allowed
    pub fn checkAllocation(self: *QuotaLimits, blocks: u64, inodes: u64, current_time: u64) !void {
        const current_blocks = self.blocks_used.load(.Acquire);
        const current_inodes = self.inodes_used.load(.Acquire);

        // Check hard limits
        if (current_blocks + blocks > self.blocks_hard) {
            return error.QuotaExceeded;
        }

        if (current_inodes + inodes > self.inodes_hard) {
            return error.QuotaExceeded;
        }

        // Check soft limits with grace period
        if (current_blocks + blocks > self.blocks_soft) {
            const exceeded_time = self.soft_exceeded_time.load(.Acquire);

            if (exceeded_time == 0) {
                // First time exceeding soft limit
                self.soft_exceeded_time.store(current_time, .Release);
            } else if (current_time - exceeded_time > self.grace_period) {
                // Grace period expired
                return error.QuotaGracePeriodExpired;
            }
        }
    }

    /// Charge quota
    pub fn charge(self: *QuotaLimits, blocks: u64, inodes: u64) void {
        _ = self.blocks_used.fetchAdd(blocks, .Release);
        _ = self.inodes_used.fetchAdd(inodes, .Release);
    }

    /// Release quota
    pub fn release(self: *QuotaLimits, blocks: u64, inodes: u64) void {
        _ = self.blocks_used.fetchSub(blocks, .Release);
        _ = self.inodes_used.fetchSub(inodes, .Release);
    }

    /// Get current usage
    pub fn getUsage(self: *const QuotaLimits) QuotaUsage {
        return .{
            .blocks_used = self.blocks_used.load(.Acquire),
            .blocks_limit = self.blocks_hard,
            .inodes_used = self.inodes_used.load(.Acquire),
            .inodes_limit = self.inodes_hard,
        };
    }
};

pub const QuotaUsage = struct {
    blocks_used: u64,
    blocks_limit: u64,
    inodes_used: u64,
    inodes_limit: u64,
};

// ============================================================================
// Extended Attributes (xattr)
// ============================================================================

pub const XattrNamespace = enum(u8) {
    /// Security attributes (SELinux, capabilities)
    SECURITY = 0,
    /// System attributes
    SYSTEM = 1,
    /// Trusted attributes (root only)
    TRUSTED = 2,
    /// User attributes
    USER = 3,
};

pub const Xattr = struct {
    /// Namespace
    namespace: XattrNamespace,
    /// Name (within namespace)
    name: [64]u8,
    /// Name length
    name_len: usize,
    /// Value
    value: [256]u8,
    /// Value length
    value_len: usize,

    pub fn init(namespace: XattrNamespace, name: []const u8, value: []const u8) !Xattr {
        if (name.len > 64 or value.len > 256) {
            return error.XattrTooLarge;
        }

        var xattr: Xattr = undefined;
        xattr.namespace = namespace;
        xattr.name_len = name.len;
        xattr.value_len = value.len;

        @memcpy(xattr.name[0..name.len], name);
        @memcpy(xattr.value[0..value.len], value);

        return xattr;
    }

    /// Check if caller can read this xattr
    pub fn canRead(self: *const Xattr, uid: u32) bool {
        return switch (self.namespace) {
            .SECURITY, .SYSTEM, .USER => true,
            .TRUSTED => uid == 0,
        };
    }

    /// Check if caller can write this xattr
    pub fn canWrite(self: *const Xattr, uid: u32) bool {
        return switch (self.namespace) {
            .USER => true,
            .SECURITY, .SYSTEM => capabilities.hasCapability(.CAP_SYS_ADMIN),
            .TRUSTED => uid == 0,
        };
    }
};

pub const XattrStore = struct {
    /// Stored attributes (up to 16 per file)
    attrs: [16]?Xattr,
    /// Attribute count
    count: usize,
    /// Lock
    lock: sync.RwLock,

    pub fn init() XattrStore {
        return .{
            .attrs = [_]?Xattr{null} ** 16,
            .count = 0,
            .lock = sync.RwLock.init(),
        };
    }

    /// Set attribute
    pub fn set(self: *XattrStore, uid: u32, xattr: Xattr) !void {
        if (!xattr.canWrite(uid)) {
            return error.PermissionDenied;
        }

        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        // Check if attribute already exists
        for (&self.attrs) |*maybe_attr| {
            if (maybe_attr.*) |*existing| {
                if (existing.namespace == xattr.namespace and
                    Basics.mem.eql(u8, existing.name[0..existing.name_len], xattr.name[0..xattr.name_len]))
                {
                    // Update existing
                    existing.* = xattr;
                    return;
                }
            }
        }

        // Add new attribute
        if (self.count < 16) {
            self.attrs[self.count] = xattr;
            self.count += 1;
        } else {
            return error.TooManyXattrs;
        }
    }

    /// Get attribute
    pub fn get(self: *XattrStore, uid: u32, namespace: XattrNamespace, name: []const u8) !Xattr {
        self.lock.acquireRead();
        defer self.lock.releaseRead();

        for (self.attrs) |maybe_attr| {
            if (maybe_attr) |attr| {
                if (attr.namespace == namespace and
                    Basics.mem.eql(u8, attr.name[0..attr.name_len], name))
                {
                    if (!attr.canRead(uid)) {
                        return error.PermissionDenied;
                    }
                    return attr;
                }
            }
        }

        return error.XattrNotFound;
    }

    /// Remove attribute
    pub fn remove(self: *XattrStore, uid: u32, namespace: XattrNamespace, name: []const u8) !void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (self.attrs[i]) |attr| {
                if (attr.namespace == namespace and
                    Basics.mem.eql(u8, attr.name[0..attr.name_len], name))
                {
                    if (!attr.canWrite(uid)) {
                        return error.PermissionDenied;
                    }

                    // Remove by shifting
                    var j = i;
                    while (j < self.count - 1) : (j += 1) {
                        self.attrs[j] = self.attrs[j + 1];
                    }

                    self.attrs[self.count - 1] = null;
                    self.count -= 1;
                    return;
                }
            }
        }

        return error.XattrNotFound;
    }
};

// ============================================================================
// Access Control Lists (ACLs)
// ============================================================================

pub const AclEntry = struct {
    /// Entry type
    entry_type: AclEntryType,
    /// ID (UID or GID)
    id: u32,
    /// Permissions
    perms: u8, // rwx bits

    pub fn init(entry_type: AclEntryType, id: u32, perms: u8) AclEntry {
        return .{
            .entry_type = entry_type,
            .id = id,
            .perms = perms & 0x7,
        };
    }

    /// Check if entry matches
    pub fn matches(self: *const AclEntry, uid: u32, gid: u32) bool {
        return switch (self.entry_type) {
            .USER => self.id == uid,
            .GROUP => self.id == gid,
            .OTHER => true,
            .MASK => false, // Mask doesn't match directly
        };
    }
};

pub const AclEntryType = enum(u8) {
    USER = 0,
    GROUP = 1,
    OTHER = 2,
    MASK = 3,
};

pub const Acl = struct {
    /// ACL entries (up to 32)
    entries: [32]?AclEntry,
    /// Entry count
    count: usize,
    /// Mask (limits maximum permissions)
    mask: u8,
    /// Lock
    lock: sync.RwLock,

    pub fn init() Acl {
        return .{
            .entries = [_]?AclEntry{null} ** 32,
            .count = 0,
            .mask = 0x7, // rwx by default
            .lock = sync.RwLock.init(),
        };
    }

    /// Add ACL entry
    pub fn addEntry(self: *Acl, entry: AclEntry) !void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        if (self.count >= 32) {
            return error.TooManyAclEntries;
        }

        self.entries[self.count] = entry;
        self.count += 1;
    }

    /// Check permissions
    pub fn checkPermission(self: *Acl, uid: u32, gid: u32, required_perms: u8) bool {
        self.lock.acquireRead();
        defer self.lock.releaseRead();

        // Find matching entry
        for (self.entries) |maybe_entry| {
            if (maybe_entry) |entry| {
                if (entry.matches(uid, gid)) {
                    // Apply mask for non-owner entries
                    const effective_perms = if (entry.entry_type != .OTHER) entry.perms & self.mask else entry.perms;

                    return (effective_perms & required_perms) == required_perms;
                }
            }
        }

        return false;
    }
};

// ============================================================================
// Inode Cache with LRU Eviction
// ============================================================================

pub const InodeCache = struct {
    /// Cache entries
    entries: [256]?CacheEntry,
    /// LRU list head
    lru_head: ?usize,
    /// LRU list tail
    lru_tail: ?usize,
    /// Hit count
    hit_count: atomic.AtomicU64,
    /// Miss count
    miss_count: atomic.AtomicU64,
    /// Lock
    lock: sync.RwLock,

    const CacheEntry = struct {
        inode_num: u64,
        refcount: vfs_sync.RefCount,
        access_time: u64,
        lru_prev: ?usize,
        lru_next: ?usize,
    };

    pub fn init() InodeCache {
        return .{
            .entries = [_]?CacheEntry{null} ** 256,
            .lru_head = null,
            .lru_tail = null,
            .hit_count = atomic.AtomicU64.init(0),
            .miss_count = atomic.AtomicU64.init(0),
            .lock = sync.RwLock.init(),
        };
    }

    /// Lookup inode in cache
    pub fn lookup(self: *InodeCache, inode_num: u64) ?usize {
        self.lock.acquireRead();
        defer self.lock.releaseRead();

        for (self.entries, 0..) |maybe_entry, i| {
            if (maybe_entry) |entry| {
                if (entry.inode_num == inode_num) {
                    _ = self.hit_count.fetchAdd(1, .Release);
                    return i;
                }
            }
        }

        _ = self.miss_count.fetchAdd(1, .Release);
        return null;
    }

    /// Insert inode into cache
    pub fn insert(self: *InodeCache, inode_num: u64) !usize {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        // Find empty slot or evict LRU
        for (self.entries, 0..) |maybe_entry, i| {
            if (maybe_entry == null) {
                self.entries[i] = .{
                    .inode_num = inode_num,
                    .refcount = vfs_sync.RefCount.init(1),
                    .access_time = @as(u64, @intCast(@as(u128, @bitCast(Basics.time.nanoTimestamp())))),
                    .lru_prev = null,
                    .lru_next = self.lru_head,
                };

                if (self.lru_head) |head| {
                    if (self.entries[head]) |*head_entry| {
                        head_entry.lru_prev = i;
                    }
                }

                self.lru_head = i;
                if (self.lru_tail == null) {
                    self.lru_tail = i;
                }

                return i;
            }
        }

        // Cache full - evict LRU
        if (self.lru_tail) |tail| {
            self.entries[tail] = .{
                .inode_num = inode_num,
                .refcount = vfs_sync.RefCount.init(1),
                .access_time = @as(u64, @intCast(@as(u128, @bitCast(Basics.time.nanoTimestamp())))),
                .lru_prev = null,
                .lru_next = self.lru_head,
            };

            // Move to head
            self.lru_tail = self.entries[tail].?.lru_prev;
            if (self.lru_tail) |new_tail| {
                if (self.entries[new_tail]) |*new_tail_entry| {
                    new_tail_entry.lru_next = null;
                }
            }

            if (self.lru_head) |head| {
                if (self.entries[head]) |*head_entry| {
                    head_entry.lru_prev = tail;
                }
            }

            self.lru_head = tail;

            return tail;
        }

        return error.CacheFull;
    }

    /// Get cache statistics
    pub fn getStats(self: *const InodeCache) CacheStats {
        const hits = self.hit_count.load(.Acquire);
        const misses = self.miss_count.load(.Acquire);
        const total = hits + misses;

        return .{
            .hits = hits,
            .misses = misses,
            .hit_rate = if (total > 0) (@as(f32, @floatFromInt(hits)) / @as(f32, @floatFromInt(total))) * 100.0 else 0.0,
        };
    }
};

pub const CacheStats = struct {
    hits: u64,
    misses: u64,
    hit_rate: f32,
};

// ============================================================================
// Tests
// ============================================================================

test "quota limits" {
    var quota = QuotaLimits.init(1000, 100);

    try quota.checkAllocation(500, 50, 1000);

    quota.charge(500, 50);

    try Basics.testing.expect(quota.blocks_used.load(.Acquire) == 500);
    try Basics.testing.expect(quota.inodes_used.load(.Acquire) == 50);

    // Should fail - exceeds hard limit
    const result = quota.checkAllocation(600, 10, 1000);
    try Basics.testing.expect(result == error.QuotaExceeded);
}

test "xattr storage" {
    var store = XattrStore.init();

    const xattr = try Xattr.init(.USER, "test.attr", "value123");
    try store.set(1000, xattr);

    const retrieved = try store.get(1000, .USER, "test.attr");
    try Basics.testing.expect(Basics.mem.eql(u8, retrieved.value[0..retrieved.value_len], "value123"));
}

test "xattr permissions" {
    var store = XattrStore.init();

    const secure_attr = try Xattr.init(.SECURITY, "security.test", "secret");
    try store.set(0, secure_attr); // Root can set

    // Non-root cannot get TRUSTED
    const trusted_attr = try Xattr.init(.TRUSTED, "trusted.test", "data");
    try store.set(0, trusted_attr);

    const result = store.get(1000, .TRUSTED, "trusted.test");
    try Basics.testing.expect(result == error.PermissionDenied or result == error.XattrNotFound);
}

test "acl basic" {
    var acl = Acl.init();

    try acl.addEntry(AclEntry.init(.USER, 1000, 0x7)); // rwx for UID 1000
    try acl.addEntry(AclEntry.init(.USER, 1001, 0x4)); // r-- for UID 1001

    try Basics.testing.expect(acl.checkPermission(1000, 100, 0x7)); // rwx allowed
    try Basics.testing.expect(acl.checkPermission(1001, 100, 0x4)); // r allowed
    try Basics.testing.expect(!acl.checkPermission(1001, 100, 0x2)); // w denied
}

test "inode cache lookup" {
    var cache = InodeCache.init();

    _ = try cache.insert(123);

    const result = cache.lookup(123);
    try Basics.testing.expect(result != null);

    const stats = cache.getStats();
    try Basics.testing.expect(stats.hits == 1);
}

test "inode cache miss" {
    var cache = InodeCache.init();

    const result = cache.lookup(999);
    try Basics.testing.expect(result == null);

    const stats = cache.getStats();
    try Basics.testing.expect(stats.misses == 1);
}
