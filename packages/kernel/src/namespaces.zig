// Home OS Kernel - Namespace Isolation
// Provides container-style isolation for processes

const Basics = @import("basics");
const sync = @import("sync.zig");
const atomic = @import("atomic.zig");
const process = @import("process.zig");

// ============================================================================
// Namespace Types
// ============================================================================

pub const NamespaceType = enum(u32) {
    /// PID namespace (process isolation)
    CLONE_NEWPID = 0x20000000,
    /// Mount namespace (filesystem isolation)
    CLONE_NEWNS = 0x00020000,
    /// Network namespace (network stack isolation)
    CLONE_NEWNET = 0x40000000,
    /// IPC namespace (IPC isolation)
    CLONE_NEWIPC = 0x08000000,
    /// UTS namespace (hostname/domainname isolation)
    CLONE_NEWUTS = 0x04000000,
    /// User namespace (UID/GID isolation)
    CLONE_NEWUSER = 0x10000000,
    /// Cgroup namespace
    CLONE_NEWCGROUP = 0x02000000,
};

// ============================================================================
// PID Namespace
// ============================================================================

pub const PidNamespace = struct {
    /// Namespace ID
    id: u32,
    /// Parent namespace (null for root namespace)
    parent: ?*PidNamespace,
    /// Process counter (for allocating PIDs within namespace)
    next_pid: atomic.AtomicU32,
    /// Reference count
    refcount: atomic.AtomicU32,
    /// Lock for namespace operations
    lock: sync.Spinlock,

    pub fn init(parent: ?*PidNamespace) PidNamespace {
        return .{
            .id = allocateNamespaceId(),
            .parent = parent,
            .next_pid = atomic.AtomicU32.init(1), // PIDs start at 1
            .refcount = atomic.AtomicU32.init(1),
            .lock = sync.Spinlock.init(),
        };
    }

    /// Allocate a PID within this namespace
    pub fn allocatePid(self: *PidNamespace) u32 {
        return self.next_pid.fetchAdd(1, .Monotonic);
    }

    /// Acquire reference
    pub fn acquire(self: *PidNamespace) void {
        _ = self.refcount.fetchAdd(1, .Monotonic);
    }

    /// Release reference
    pub fn release(self: *PidNamespace) void {
        const old_count = self.refcount.fetchSub(1, .Monotonic);
        if (old_count == 1) {
            // Last reference, cleanup resources
            self.lock.acquire();
            // No dynamic allocations in PidNamespace itself, just reset state
            self.next_pid.store(0, .Monotonic);
            self.lock.release();
            // Note: Actual deallocation handled by whoever allocated this
        }
    }

    /// Translate PID to global PID
    pub fn translatePidToGlobal(self: *PidNamespace, local_pid: u32) u32 {
        _ = self;
        // For now, PIDs are global
        // In a full implementation, we'd maintain a mapping table
        return local_pid;
    }

    /// Translate global PID to local PID (or return null if not visible)
    pub fn translatePidToLocal(self: *PidNamespace, global_pid: u32) ?u32 {
        _ = self;
        // For now, all PIDs are visible
        // In a full implementation, we'd check namespace hierarchy
        return global_pid;
    }
};

// ============================================================================
// Mount Namespace
// ============================================================================

pub const MountNamespace = struct {
    /// Namespace ID
    id: u32,
    /// Root filesystem (vfs mount)
    root: ?*anyopaque, // TODO: Use actual VFS mount type
    /// List of mounts
    mounts: ?*anyopaque, // TODO: Use actual mount list
    /// Reference count
    refcount: atomic.AtomicU32,
    /// Lock for namespace operations
    lock: sync.RwLock,

    pub fn init() MountNamespace {
        return .{
            .id = allocateNamespaceId(),
            .root = null,
            .mounts = null,
            .refcount = atomic.AtomicU32.init(1),
            .lock = sync.RwLock.init(),
        };
    }

    pub fn acquire(self: *MountNamespace) void {
        _ = self.refcount.fetchAdd(1, .Monotonic);
    }

    pub fn release(self: *MountNamespace) void {
        const old_count = self.refcount.fetchSub(1, .Monotonic);
        if (old_count == 1) {
            // Last reference, cleanup
        }
    }
};

// ============================================================================
// Network Namespace
// ============================================================================

pub const NetworkNamespace = struct {
    /// Namespace ID
    id: u32,
    /// Network interfaces in this namespace
    interfaces: ?*anyopaque, // TODO: Network interface list
    /// Routing table
    routing_table: ?*anyopaque,
    /// Reference count
    refcount: atomic.AtomicU32,
    /// Lock for namespace operations
    lock: sync.RwLock,

    pub fn init() NetworkNamespace {
        return .{
            .id = allocateNamespaceId(),
            .interfaces = null,
            .routing_table = null,
            .refcount = atomic.AtomicU32.init(1),
            .lock = sync.RwLock.init(),
        };
    }

    pub fn acquire(self: *NetworkNamespace) void {
        _ = self.refcount.fetchAdd(1, .Monotonic);
    }

    pub fn release(self: *NetworkNamespace) void {
        const old_count = self.refcount.fetchSub(1, .Monotonic);
        if (old_count == 1) {
            // Last reference, cleanup
        }
    }
};

// ============================================================================
// IPC Namespace
// ============================================================================

pub const IpcNamespace = struct {
    /// Namespace ID
    id: u32,
    /// Message queues
    mqueues: ?*anyopaque,
    /// Semaphores
    semaphores: ?*anyopaque,
    /// Shared memory segments
    shm_segments: ?*anyopaque,
    /// Reference count
    refcount: atomic.AtomicU32,
    /// Lock for namespace operations
    lock: sync.RwLock,

    pub fn init() IpcNamespace {
        return .{
            .id = allocateNamespaceId(),
            .mqueues = null,
            .semaphores = null,
            .shm_segments = null,
            .refcount = atomic.AtomicU32.init(1),
            .lock = sync.RwLock.init(),
        };
    }

    pub fn acquire(self: *IpcNamespace) void {
        _ = self.refcount.fetchAdd(1, .Monotonic);
    }

    pub fn release(self: *IpcNamespace) void {
        const old_count = self.refcount.fetchSub(1, .Monotonic);
        if (old_count == 1) {
            // Last reference, cleanup
        }
    }
};

// ============================================================================
// UTS Namespace (hostname/domainname)
// ============================================================================

pub const UtsNamespace = struct {
    /// Namespace ID
    id: u32,
    /// Hostname
    hostname: [256]u8,
    hostname_len: usize,
    /// Domain name
    domainname: [256]u8,
    domainname_len: usize,
    /// Reference count
    refcount: atomic.AtomicU32,
    /// Lock for namespace operations
    lock: sync.RwLock,

    pub fn init() UtsNamespace {
        var ns = UtsNamespace{
            .id = allocateNamespaceId(),
            .hostname = undefined,
            .hostname_len = 0,
            .domainname = undefined,
            .domainname_len = 0,
            .refcount = atomic.AtomicU32.init(1),
            .lock = sync.RwLock.init(),
        };

        // Default hostname
        const default_hostname = "localhost";
        @memcpy(ns.hostname[0..default_hostname.len], default_hostname);
        ns.hostname_len = default_hostname.len;
        ns.domainname_len = 0;

        return ns;
    }

    pub fn acquire(self: *UtsNamespace) void {
        _ = self.refcount.fetchAdd(1, .Monotonic);
    }

    pub fn release(self: *UtsNamespace) void {
        const old_count = self.refcount.fetchSub(1, .Monotonic);
        if (old_count == 1) {
            // Last reference, cleanup
        }
    }

    pub fn setHostname(self: *UtsNamespace, hostname: []const u8) !void {
        if (hostname.len > 255) return error.NameTooLong;

        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        @memcpy(self.hostname[0..hostname.len], hostname);
        self.hostname_len = hostname.len;
    }

    pub fn getHostname(self: *UtsNamespace) []const u8 {
        self.lock.acquireRead();
        defer self.lock.releaseRead();

        return self.hostname[0..self.hostname_len];
    }
};

// ============================================================================
// Namespace Set (per-process)
// ============================================================================

pub const NamespaceSet = struct {
    pid_ns: *PidNamespace,
    mnt_ns: *MountNamespace,
    net_ns: *NetworkNamespace,
    ipc_ns: *IpcNamespace,
    uts_ns: *UtsNamespace,

    pub fn initDefault(allocator: Basics.Allocator) !*NamespaceSet {
        const ns_set = try allocator.create(NamespaceSet);

        // Allocate default namespaces
        const pid_ns = try allocator.create(PidNamespace);
        pid_ns.* = PidNamespace.init(null);

        const mnt_ns = try allocator.create(MountNamespace);
        mnt_ns.* = MountNamespace.init();

        const net_ns = try allocator.create(NetworkNamespace);
        net_ns.* = NetworkNamespace.init();

        const ipc_ns = try allocator.create(IpcNamespace);
        ipc_ns.* = IpcNamespace.init();

        const uts_ns = try allocator.create(UtsNamespace);
        uts_ns.* = UtsNamespace.init();

        ns_set.* = .{
            .pid_ns = pid_ns,
            .mnt_ns = mnt_ns,
            .net_ns = net_ns,
            .ipc_ns = ipc_ns,
            .uts_ns = uts_ns,
        };

        return ns_set;
    }

    /// Clone namespace set, creating new namespaces based on flags
    pub fn clone(self: *NamespaceSet, allocator: Basics.Allocator, flags: u32) !*NamespaceSet {
        const new_set = try allocator.create(NamespaceSet);

        // Clone PID namespace if requested
        const new_pid_ns = if (flags & @intFromEnum(NamespaceType.CLONE_NEWPID) != 0) blk: {
            const ns = try allocator.create(PidNamespace);
            ns.* = PidNamespace.init(self.pid_ns); // Set parent
            break :blk ns;
        } else blk: {
            self.pid_ns.acquire();
            break :blk self.pid_ns;
        };

        // Clone mount namespace if requested
        const new_mnt_ns = if (flags & @intFromEnum(NamespaceType.CLONE_NEWNS) != 0) blk: {
            const ns = try allocator.create(MountNamespace);
            ns.* = MountNamespace.init();
            // Copy mounts from parent namespace (copy-on-write semantics)
            ns.root = self.mnt_ns.root;
            ns.mounts = self.mnt_ns.mounts;
            // Note: In a full implementation, we would create a deep copy of the
            // mount tree with proper reference counting on each mount point.
            // For now, we share the same mount list (which works for read-only ops).
            break :blk ns;
        } else blk: {
            self.mnt_ns.acquire();
            break :blk self.mnt_ns;
        };

        // Clone network namespace if requested
        const new_net_ns = if (flags & @intFromEnum(NamespaceType.CLONE_NEWNET) != 0) blk: {
            const ns = try allocator.create(NetworkNamespace);
            ns.* = NetworkNamespace.init();
            break :blk ns;
        } else blk: {
            self.net_ns.acquire();
            break :blk self.net_ns;
        };

        // Clone IPC namespace if requested
        const new_ipc_ns = if (flags & @intFromEnum(NamespaceType.CLONE_NEWIPC) != 0) blk: {
            const ns = try allocator.create(IpcNamespace);
            ns.* = IpcNamespace.init();
            break :blk ns;
        } else blk: {
            self.ipc_ns.acquire();
            break :blk self.ipc_ns;
        };

        // Clone UTS namespace if requested
        const new_uts_ns = if (flags & @intFromEnum(NamespaceType.CLONE_NEWUTS) != 0) blk: {
            const ns = try allocator.create(UtsNamespace);
            ns.* = UtsNamespace.init();
            // Copy hostname from parent
            ns.hostname_len = self.uts_ns.hostname_len;
            @memcpy(ns.hostname[0..ns.hostname_len], self.uts_ns.hostname[0..self.uts_ns.hostname_len]);
            break :blk ns;
        } else blk: {
            self.uts_ns.acquire();
            break :blk self.uts_ns;
        };

        new_set.* = .{
            .pid_ns = new_pid_ns,
            .mnt_ns = new_mnt_ns,
            .net_ns = new_net_ns,
            .ipc_ns = new_ipc_ns,
            .uts_ns = new_uts_ns,
        };

        return new_set;
    }

    pub fn release(self: *NamespaceSet) void {
        self.pid_ns.release();
        self.mnt_ns.release();
        self.net_ns.release();
        self.ipc_ns.release();
        self.uts_ns.release();
    }
};

// ============================================================================
// Global Namespace ID Allocation
// ============================================================================

var next_namespace_id = atomic.AtomicU32.init(1);

fn allocateNamespaceId() u32 {
    return next_namespace_id.fetchAdd(1, .Monotonic);
}

// ============================================================================
// Namespace Operations
// ============================================================================

/// Check if process can create new namespaces (requires CAP_SYS_ADMIN)
pub fn canCreateNamespace() bool {
    const capabilities = @import("capabilities.zig");
    return capabilities.hasCapability(.CAP_SYS_ADMIN);
}

/// Check if process can enter namespace (setns syscall)
pub fn canEnterNamespace(target_ns_id: u32) bool {
    _ = target_ns_id;
    const capabilities = @import("capabilities.zig");
    return capabilities.hasCapability(.CAP_SYS_ADMIN);
}

// ============================================================================
// Tests
// ============================================================================

test "namespace ID allocation" {
    const id1 = allocateNamespaceId();
    const id2 = allocateNamespaceId();

    try Basics.testing.expect(id2 > id1);
}

test "PID namespace creation" {
    var ns = PidNamespace.init(null);

    try Basics.testing.expect(ns.refcount.load(.Monotonic) == 1);
    try Basics.testing.expect(ns.parent == null);

    const pid1 = ns.allocatePid();
    const pid2 = ns.allocatePid();

    try Basics.testing.expect(pid1 == 1);
    try Basics.testing.expect(pid2 == 2);
}

test "mount namespace creation" {
    var ns = MountNamespace.init();

    try Basics.testing.expect(ns.refcount.load(.Monotonic) == 1);

    ns.acquire();
    try Basics.testing.expect(ns.refcount.load(.Monotonic) == 2);

    ns.release();
    try Basics.testing.expect(ns.refcount.load(.Monotonic) == 1);
}

test "UTS namespace hostname" {
    var ns = UtsNamespace.init();

    const default_hostname = ns.getHostname();
    try Basics.testing.expectEqualStrings("localhost", default_hostname);

    try ns.setHostname("test-host");
    const new_hostname = ns.getHostname();
    try Basics.testing.expectEqualStrings("test-host", new_hostname);
}

test "namespace reference counting" {
    var ns = NetworkNamespace.init();

    try Basics.testing.expect(ns.refcount.load(.Monotonic) == 1);

    ns.acquire();
    ns.acquire();
    try Basics.testing.expect(ns.refcount.load(.Monotonic) == 3);

    ns.release();
    ns.release();
    try Basics.testing.expect(ns.refcount.load(.Monotonic) == 1);
}
