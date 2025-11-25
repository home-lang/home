// Home Programming Language - Shared Memory
// System V and POSIX shared memory implementation

const Basics = @import("basics");
const sync = @import("sync.zig");
const vmm = @import("vmm.zig");
const process = @import("process.zig");

// ============================================================================
// Shared Memory Segment
// ============================================================================

pub const ShmPermissions = struct {
    uid: u32, // Owner user ID
    gid: u32, // Owner group ID
    cuid: u32, // Creator user ID
    cgid: u32, // Creator group ID
    mode: u16, // Permissions (rwxrwxrwx)

    pub fn init(uid: u32, gid: u32, mode: u16) ShmPermissions {
        return .{
            .uid = uid,
            .gid = gid,
            .cuid = uid,
            .cgid = gid,
            .mode = mode,
        };
    }

    pub fn canRead(self: ShmPermissions, uid: u32, gid: u32) bool {
        if (uid == 0) return true; // Root can do anything
        if (uid == self.uid) return (self.mode & 0o400) != 0;
        if (gid == self.gid) return (self.mode & 0o040) != 0;
        return (self.mode & 0o004) != 0;
    }

    pub fn canWrite(self: ShmPermissions, uid: u32, gid: u32) bool {
        if (uid == 0) return true;
        if (uid == self.uid) return (self.mode & 0o200) != 0;
        if (gid == self.gid) return (self.mode & 0o020) != 0;
        return (self.mode & 0o002) != 0;
    }
};

pub const ShmSegment = struct {
    key: i32, // IPC key
    id: u32, // Segment ID
    size: usize, // Size in bytes
    physical_pages: []usize, // Physical page addresses
    perms: ShmPermissions,
    attach_count: u32, // Number of processes attached
    lock: sync.RwLock,
    allocator: Basics.Allocator,
    created_time: u64,
    attached_time: u64,
    detached_time: u64,
    creator_pid: u32,
    last_pid: u32,

    pub fn init(
        allocator: Basics.Allocator,
        key: i32,
        id: u32,
        size: usize,
        perms: ShmPermissions,
        creator_pid: u32,
    ) !*ShmSegment {
        const segment = try allocator.create(ShmSegment);
        errdefer allocator.destroy(segment);

        // Allocate physical pages
        const page_count = (size + 4095) / 4096;
        const pages = try allocator.alloc(usize, page_count);
        errdefer allocator.free(pages);

        for (pages) |*page| {
            page.* = try allocatePhysicalPage();
        }

        segment.* = .{
            .key = key,
            .id = id,
            .size = size,
            .physical_pages = pages,
            .perms = perms,
            .attach_count = 0,
            .lock = sync.RwLock.init(),
            .allocator = allocator,
            .created_time = getTimeSeconds(),
            .attached_time = 0,
            .detached_time = 0,
            .creator_pid = creator_pid,
            .last_pid = creator_pid,
        };

        return segment;
    }

    pub fn deinit(self: *ShmSegment) void {
        // Free physical pages
        for (self.physical_pages) |page| {
            freePhysicalPage(page);
        }
        self.allocator.free(self.physical_pages);
        self.allocator.destroy(self);
    }

    pub fn attach(self: *ShmSegment, proc: *process.Process, addr: ?usize, flags: u32) !usize {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        // Check permissions
        const SHM_RDONLY = 0o10000;
        const is_readonly = (flags & SHM_RDONLY) != 0;

        if (!self.perms.canRead(proc.uid, proc.gid)) {
            return error.PermissionDenied;
        }

        if (!is_readonly and !self.perms.canWrite(proc.uid, proc.gid)) {
            return error.PermissionDenied;
        }

        // Find virtual address
        const virt_addr = addr orelse try proc.vmm.?.findFreeRegion(self.size);

        // Map pages into process address space
        var offset: usize = 0;
        for (self.physical_pages) |phys_page| {
            const virt_page = virt_addr + offset;
            const prot = if (is_readonly)
                vmm.PROT_READ
            else
                vmm.PROT_READ | vmm.PROT_WRITE;

            try proc.vmm.?.mapPage(virt_page, phys_page, prot);
            offset += 4096;
        }

        self.attach_count += 1;
        self.attached_time = getTimeSeconds();
        self.last_pid = proc.pid;

        return virt_addr;
    }

    pub fn detach(self: *ShmSegment, proc: *process.Process, addr: usize) !void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        // Unmap pages from process address space
        var offset: usize = 0;
        for (self.physical_pages) |_| {
            const virt_page = addr + offset;
            try proc.vmm.?.unmapPage(virt_page);
            offset += 4096;
        }

        if (self.attach_count > 0) {
            self.attach_count -= 1;
        }
        self.detached_time = getTimeSeconds();
        self.last_pid = proc.pid;
    }
};

// ============================================================================
// Shared Memory Manager
// ============================================================================

pub const ShmManager = struct {
    segments: Basics.AutoHashMap(u32, *ShmSegment),
    key_to_id: Basics.AutoHashMap(i32, u32),
    next_id: u32,
    lock: sync.RwLock,
    allocator: Basics.Allocator,

    pub fn init(allocator: Basics.Allocator) ShmManager {
        return .{
            .segments = Basics.AutoHashMap(u32, *ShmSegment).init(allocator),
            .key_to_id = Basics.AutoHashMap(i32, u32).init(allocator),
            .next_id = 1,
            .lock = sync.RwLock.init(),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ShmManager) void {
        var it = self.segments.valueIterator();
        while (it.next()) |segment| {
            segment.*.deinit();
        }
        self.segments.deinit();
        self.key_to_id.deinit();
    }

    /// Create or get a shared memory segment
    pub fn get(self: *ShmManager, key: i32, size: usize, flags: u32, perms: ShmPermissions, creator_pid: u32) !u32 {
        const IPC_CREAT = 0o1000;
        const IPC_EXCL = 0o2000;
        const IPC_PRIVATE = 0;

        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        // IPC_PRIVATE always creates a new segment
        if (key == IPC_PRIVATE) {
            return try self.createSegment(key, size, perms, creator_pid);
        }

        // Check if segment with this key exists
        if (self.key_to_id.get(key)) |id| {
            if ((flags & IPC_EXCL) != 0) {
                return error.AlreadyExists;
            }
            return id;
        }

        // Create new segment if IPC_CREAT is set
        if ((flags & IPC_CREAT) != 0) {
            return try self.createSegment(key, size, perms, creator_pid);
        }

        return error.NoSuchSegment;
    }

    fn createSegment(self: *ShmManager, key: i32, size: usize, perms: ShmPermissions, creator_pid: u32) !u32 {
        const id = self.next_id;
        self.next_id += 1;

        const segment = try ShmSegment.init(self.allocator, key, id, size, perms, creator_pid);
        errdefer segment.deinit();

        try self.segments.put(id, segment);
        if (key != 0) {
            try self.key_to_id.put(key, id);
        }

        return id;
    }

    /// Get segment by ID
    pub fn getById(self: *ShmManager, id: u32) ?*ShmSegment {
        self.lock.acquireRead();
        defer self.lock.releaseRead();

        return self.segments.get(id);
    }

    /// Remove a segment
    pub fn remove(self: *ShmManager, id: u32) !void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        const segment = self.segments.get(id) orelse return error.NoSuchSegment;

        // Check if anyone is still attached
        if (segment.attach_count > 0) {
            return error.StillAttached;
        }

        // Remove from maps
        _ = self.segments.remove(id);
        if (segment.key != 0) {
            _ = self.key_to_id.remove(segment.key);
        }

        segment.deinit();
    }

    /// Mark segment for deletion when all processes detach
    pub fn markForDeletion(self: *ShmManager, id: u32) !void {
        _ = self;
        _ = id;
        // TODO: Implement deferred deletion
    }
};

// ============================================================================
// Global Manager
// ============================================================================

var global_manager: ?ShmManager = null;
var manager_lock = sync.Spinlock.init();

pub fn getManager() *ShmManager {
    manager_lock.acquire();
    defer manager_lock.release();

    if (global_manager == null) {
        global_manager = ShmManager.init(Basics.heap.page_allocator);
    }

    return &global_manager.?;
}

// ============================================================================
// System Call Interface
// ============================================================================

/// sys_shmget - Get shared memory segment
pub fn sysShmget(key: i32, size: usize, flags: i32) !i32 {
    const proc = process.current() orelse return error.NoProcess;
    const perms = ShmPermissions.init(proc.uid, proc.gid, @intCast(flags & 0o777));

    const manager = getManager();
    const id = try manager.get(key, size, @intCast(flags), perms, proc.pid);

    return @intCast(id);
}

/// sys_shmat - Attach shared memory segment
pub fn sysShmat(shmid: i32, addr: ?usize, flags: i32) !usize {
    const proc = process.current() orelse return error.NoProcess;
    const manager = getManager();

    const segment = manager.getById(@intCast(shmid)) orelse return error.InvalidSegment;

    return try segment.attach(proc, addr, @intCast(flags));
}

/// sys_shmdt - Detach shared memory segment
pub fn sysShmdt(addr: usize) !void {
    const proc = process.current() orelse return error.NoProcess;

    // Find segment that contains this address
    const manager = getManager();
    var it = manager.segments.valueIterator();

    while (it.next()) |segment| {
        // Check if this address belongs to this segment
        // TODO: Track attachments per process
        try segment.*.detach(proc, addr);
        return;
    }

    return error.InvalidAddress;
}

/// sys_shmctl - Control shared memory segment
pub fn sysShmctl(shmid: i32, cmd: i32, buf: ?*anyopaque) !i32 {
    const manager = getManager();
    const segment = manager.getById(@intCast(shmid)) orelse return error.InvalidSegment;

    const IPC_STAT = 2;
    const IPC_SET = 1;
    const IPC_RMID = 0;

    switch (cmd) {
        IPC_STAT => {
            // Get segment info
            _ = buf;
            // TODO: Copy segment info to user buffer
            return 0;
        },
        IPC_SET => {
            // Set segment info
            _ = buf;
            // TODO: Update segment info from user buffer
            return 0;
        },
        IPC_RMID => {
            // Remove segment
            try manager.remove(@intCast(shmid));
            return 0;
        },
        else => return error.InvalidCommand,
    }
}

// ============================================================================
// POSIX Shared Memory (shm_open/shm_unlink)
// ============================================================================

pub const PosixShm = struct {
    name: []const u8,
    segment: *ShmSegment,

    pub fn open(allocator: Basics.Allocator, name: []const u8, flags: u32, mode: u16, size: usize) !*PosixShm {
        const proc = process.current() orelse return error.NoProcess;
        const perms = ShmPermissions.init(proc.uid, proc.gid, mode);

        const manager = getManager();
        const key = hashName(name);
        const id = try manager.get(key, size, flags, perms, proc.pid);
        const segment = manager.getById(id) orelse return error.NoSuchSegment;

        const shm = try allocator.create(PosixShm);
        shm.* = .{
            .name = try allocator.dupe(u8, name),
            .segment = segment,
        };

        return shm;
    }

    pub fn close(self: *PosixShm, allocator: Basics.Allocator) void {
        allocator.free(self.name);
        allocator.destroy(self);
    }
};

fn hashName(name: []const u8) i32 {
    var hash: u32 = 5381;
    for (name) |c| {
        hash = ((hash << 5) +% hash) +% c;
    }
    return @bitCast(hash);
}

// ============================================================================
// Helper Functions
// ============================================================================

fn allocatePhysicalPage() !usize {
    // TODO: Integrate with physical memory allocator
    return @import("pmm.zig").allocPage();
}

fn freePhysicalPage(page: usize) void {
    // TODO: Integrate with physical memory allocator
    @import("pmm.zig").freePage(page);
}

fn getTimeSeconds() u64 {
    // Get current time in seconds (timer ticks / 1000)
    const timer = @import("timer.zig");
    return timer.getTicks() / 1000;
}

/// Detach all shared memory segments for a process (called on process exit)
pub fn detachAllSegments(proc: *process.Process) void {
    const manager = getManager();

    // Iterate through all segments and detach any belonging to this process
    var it = manager.segments.valueIterator();
    while (it.next()) |segment| {
        // Decrement attach count if this process had it attached
        // Note: In a full implementation, we'd track per-process attachments
        // For now, just check if creator matches
        if (segment.*.perms.creator_pid == proc.pid) {
            _ = segment.*.attach_count.fetchSub(1, .Monotonic);
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "shared memory permissions" {
    const perms = ShmPermissions.init(1000, 1000, 0o644);

    try Basics.testing.expect(perms.canRead(1000, 1000)); // Owner can read
    try Basics.testing.expect(perms.canWrite(1000, 1000)); // Owner can write
    try Basics.testing.expect(perms.canRead(1001, 1000)); // Group can read
    try Basics.testing.expect(!perms.canWrite(1001, 1000)); // Group cannot write
    try Basics.testing.expect(perms.canRead(1001, 1001)); // Others can read
    try Basics.testing.expect(!perms.canWrite(1001, 1001)); // Others cannot write
}

test "shared memory manager" {
    const allocator = Basics.testing.allocator;
    var manager = ShmManager.init(allocator);
    defer manager.deinit();

    const perms = ShmPermissions.init(1000, 1000, 0o644);
    const id = try manager.get(1234, 4096, 0o1000, perms, 1);

    const segment = manager.getById(id);
    try Basics.testing.expect(segment != null);
    try Basics.testing.expectEqual(@as(i32, 1234), segment.?.key);
    try Basics.testing.expectEqual(@as(usize, 4096), segment.?.size);
}

test "shared memory key lookup" {
    const allocator = Basics.testing.allocator;
    var manager = ShmManager.init(allocator);
    defer manager.deinit();

    const perms = ShmPermissions.init(1000, 1000, 0o644);
    const id1 = try manager.get(5678, 4096, 0o1000, perms, 1);
    const id2 = try manager.get(5678, 4096, 0o0000, perms, 1);

    try Basics.testing.expectEqual(id1, id2);
}
