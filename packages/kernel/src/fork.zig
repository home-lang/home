// Home Programming Language - Process Forking
// Efficient process forking with copy-on-write

const Basics = @import("basics");
const process = @import("process.zig");
const memory = @import("memory.zig");
const paging = @import("paging.zig");
const thread = @import("thread.zig");

// ============================================================================
// Copy-on-Write Support
// ============================================================================

const cow = @import("cow.zig");

/// Mark page table entries as copy-on-write
fn markCopyOnWrite(parent: *process.Process) !void {
    try cow.markAddressSpaceCow(
        &parent.address_space.page_mapper,
        parent.address_space.vma_list,
    );
}

/// Handle copy-on-write page fault
pub fn handleCowPageFault(addr: u64, proc: *process.Process, is_write: bool) !bool {
    _ = proc;

    return try cow.CowFaultHandler.handleFault(
        &proc.address_space.page_mapper,
        addr,
        is_write,
    );
}

// ============================================================================
// Fork Implementation
// ============================================================================

pub const ForkFlags = packed struct(u32) {
    /// Clone parent's memory (copy-on-write)
    clone_vm: bool = true,
    /// Clone parent's file descriptors
    clone_files: bool = true,
    /// Clone parent's filesystem info (cwd, root, umask)
    clone_fs: bool = true,
    /// Clone parent's signal handlers
    clone_sighand: bool = true,
    /// Parent and child share same PID (for thread creation)
    clone_thread: bool = false,
    /// Create new PID namespace
    clone_newpid: bool = false,
    /// Create new mount namespace
    clone_newns: bool = false,
    /// Create new network namespace
    clone_newnet: bool = false,
    /// Create new IPC namespace
    clone_newipc: bool = false,
    /// Create new UTS namespace
    clone_newuts: bool = false,
    /// Create new user namespace
    clone_newuser: bool = false,
    /// Set parent death signal
    set_parent_death_signal: bool = false,
    /// Create new cgroup namespace
    clone_newcgroup: bool = false,

    _padding: u19 = 0,
};

/// Fork with detailed options (like Linux clone())
pub fn forkWithOptions(
    parent: *process.Process,
    allocator: Basics.Allocator,
    flags: ForkFlags,
    stack_ptr: ?u64,
) !*process.Process {
    // Create new process
    const child = try process.Process.create(allocator, parent.getName());
    errdefer child.destroy(allocator);

    child.ppid = parent.pid;
    child.parent = parent;

    // Copy or share file descriptors
    if (flags.clone_files) {
        // Share file descriptor table (increment refcounts)
        @memcpy(&child.fd_table, &parent.fd_table);
    } else {
        // Deep copy file descriptor table
        child.fd_lock.acquire();
        parent.fd_lock.acquire();
        for (parent.fd_table, 0..) |fd_opt, i| {
            if (fd_opt) |fd| {
                // TODO: Increment file refcount
                child.fd_table[i] = fd;
            }
        }
        parent.fd_lock.release();
        child.fd_lock.release();
    }

    // Copy filesystem info
    if (flags.clone_fs) {
        @memcpy(child.cwd[0..parent.cwd_len], parent.cwd[0..parent.cwd_len]);
        child.cwd_len = parent.cwd_len;
    }

    // Copy credentials
    child.uid = parent.uid;
    child.gid = parent.gid;
    child.euid = parent.euid;
    child.egid = parent.egid;
    child.saved_uid = parent.saved_uid;
    child.saved_gid = parent.saved_gid;
    child.fsuid = parent.fsuid;
    child.fsgid = parent.fsgid;
    @memcpy(&child.groups, &parent.groups);
    child.num_groups = parent.num_groups;
    child.capabilities = parent.capabilities;

    // Handle memory space
    if (flags.clone_vm) {
        // Copy-on-write: Set up COW sharing
        try cow.CowFork.setupCowFork(parent, child);
    } else {
        // Deep copy address space (expensive but sometimes needed)
        try copyAddressSpace(parent.address_space, child.address_space, allocator);
    }

    // Handle namespaces
    if (parent.namespaces) |parent_ns| {
        const ns_flags = @as(u32, 0) |
            (if (flags.clone_newpid) @as(u32, 0x20000000) else 0) |
            (if (flags.clone_newns) @as(u32, 0x00020000) else 0) |
            (if (flags.clone_newnet) @as(u32, 0x40000000) else 0) |
            (if (flags.clone_newipc) @as(u32, 0x08000000) else 0) |
            (if (flags.clone_newuts) @as(u32, 0x04000000) else 0);

        if (ns_flags != 0) {
            // Create new namespaces based on flags
            child.namespaces = try parent_ns.clone(allocator, ns_flags);
        } else {
            // Share all namespaces
            parent_ns.pid_ns.acquire();
            parent_ns.mnt_ns.acquire();
            parent_ns.net_ns.acquire();
            parent_ns.ipc_ns.acquire();
            parent_ns.uts_ns.acquire();
            child.namespaces = parent_ns;
        }
    }

    // Handle thread vs process creation
    if (flags.clone_thread) {
        // Creating a new thread in same process
        // Use provided stack or allocate new one
        _ = stack_ptr;
        // TODO: Create thread with given stack
        return error.NotImplemented;
    }

    // Add to parent's children
    try parent.addChild(child);

    // Register globally
    try process.registerProcess(child);

    return child;
}

/// Standard POSIX fork - create exact copy of process
pub fn fork(parent: *process.Process, allocator: Basics.Allocator) !*process.Process {
    return forkWithOptions(parent, allocator, .{
        .clone_vm = true,
        .clone_files = true,
        .clone_fs = true,
        .clone_sighand = true,
    }, null);
}

/// vfork - like fork but shares memory until exec (for exec-immediately pattern)
pub fn vfork(parent: *process.Process, allocator: Basics.Allocator) !*process.Process {
    // vfork is dangerous but efficient
    // Parent is suspended until child calls exec or exit
    const child = try forkWithOptions(parent, allocator, .{
        .clone_vm = true, // Share VM completely (not even COW)
        .clone_files = true,
        .clone_fs = true,
        .clone_sighand = true,
    }, null);

    // TODO: Suspend parent process
    // TODO: Child must call exec or exit before parent can resume

    return child;
}

/// Copy address space (deep copy for non-COW scenarios)
fn copyAddressSpace(
    src: *process.AddressSpace,
    dst: *process.AddressSpace,
    allocator: Basics.Allocator,
) !void {
    src.lock.acquire();
    defer src.lock.release();

    dst.lock.acquire();
    defer dst.lock.release();

    // Copy all VMAs
    var vma = src.vma_list;
    while (vma) |v| {
        // Create corresponding VMA in destination
        const new_vma = try dst.addVma(allocator, v.start, v.end, v.flags);

        // TODO: Copy actual page data
        // This would involve:
        // 1. Walking source page tables
        // 2. Allocating new physical pages
        // 3. Copying data page by page
        // 4. Setting up new page table entries

        _ = new_vma;
        vma = v.next;
    }

    // Copy ASLR bases
    dst.stack_base = src.stack_base;
    dst.heap_base = src.heap_base;
    dst.mmap_base = src.mmap_base;
}

// ============================================================================
// Process Creation Helpers
// ============================================================================

/// Create a new kernel thread
pub fn createKernelThread(
    allocator: Basics.Allocator,
    name: []const u8,
    entry_point: *const fn (*anyopaque) void,
    arg: ?*anyopaque,
) !*process.Process {
    const proc = try process.Process.create(allocator, name);
    errdefer proc.destroy(allocator);

    // Kernel threads run in kernel space only
    // They don't need user-space address space

    // TODO: Create thread with entry point
    _ = entry_point;
    _ = arg;

    // Register process
    try process.registerProcess(proc);

    return proc;
}

/// Create init process (PID 1)
pub fn createInitProcess(allocator: Basics.Allocator) !*process.Process {
    const proc = try process.Process.create(allocator, "init");
    errdefer proc.destroy(allocator);

    // Force PID to 1
    // This is a hack - in real implementation, we'd reserve PID 1
    // proc.pid = process.INIT_PID;

    // Init starts as root
    proc.uid = 0;
    proc.gid = 0;
    proc.euid = 0;
    proc.egid = 0;
    proc.capabilities = 0xFFFFFFFFFFFFFFFF;

    // Register process
    try process.registerProcess(proc);

    return proc;
}

// ============================================================================
// Process Cloning Statistics
// ============================================================================

pub const ForkStats = struct {
    total_forks: u64 = 0,
    total_vforks: u64 = 0,
    cow_faults: u64 = 0,
    pages_copied: u64 = 0,
    pages_shared: u64 = 0,

    pub fn recordFork(self: *ForkStats) void {
        _ = @atomicRmw(u64, &self.total_forks, .Add, 1, .monotonic);
    }

    pub fn recordVfork(self: *ForkStats) void {
        _ = @atomicRmw(u64, &self.total_vforks, .Add, 1, .monotonic);
    }

    pub fn recordCowFault(self: *ForkStats) void {
        _ = @atomicRmw(u64, &self.cow_faults, .Add, 1, .monotonic);
    }

    pub fn recordPageCopied(self: *ForkStats) void {
        _ = @atomicRmw(u64, &self.pages_copied, .Add, 1, .monotonic);
    }

    pub fn recordPageShared(self: *ForkStats) void {
        _ = @atomicRmw(u64, &self.pages_shared, .Add, 1, .monotonic);
    }
};

var global_fork_stats = ForkStats{};

pub fn getForkStats() ForkStats {
    return global_fork_stats;
}

// ============================================================================
// Tests
// ============================================================================

test "fork flags" {
    const flags = ForkFlags{
        .clone_vm = true,
        .clone_files = true,
        .clone_fs = true,
        .clone_sighand = true,
    };

    try Basics.testing.expect(flags.clone_vm);
    try Basics.testing.expect(flags.clone_files);
    try Basics.testing.expect(!flags.clone_thread);
    try Basics.testing.expect(!flags.clone_newpid);
}

test "fork stats" {
    var stats = ForkStats{};

    stats.recordFork();
    stats.recordFork();
    stats.recordCowFault();

    try Basics.testing.expectEqual(@as(u64, 2), stats.total_forks);
    try Basics.testing.expectEqual(@as(u64, 1), stats.cow_faults);
}
