// Home Programming Language - Process Management
// Process control and lifecycle management for OS

const Basics = @import("basics");
const memory = @import("memory.zig");
const paging = @import("paging.zig");
const cpu_context = @import("cpu_context.zig");
const atomic = @import("atomic.zig");
const sync = @import("sync.zig");
const random = @import("random.zig");

// Forward declaration
const Thread = @import("thread.zig").Thread;

// ============================================================================
// Process ID Management
// ============================================================================

/// Process ID type
pub const Pid = u32;

/// Special PIDs
pub const INVALID_PID: Pid = 0;
pub const INIT_PID: Pid = 1;
pub const KERNEL_PID: Pid = 0;

var next_pid = atomic.AtomicU32.init(2); // Start after init

/// Allocate a new PID
pub fn allocatePid() Pid {
    return next_pid.fetchAdd(1, .Monotonic);
}

// ============================================================================
// Process State
// ============================================================================

pub const ProcessState = enum(u8) {
    /// Process is being created
    Creating,
    /// Process is ready to run (has runnable threads)
    Running,
    /// Process is sleeping (all threads blocked)
    Sleeping,
    /// Process is stopped (debugging)
    Stopped,
    /// Process is terminating
    Zombie,
    /// Process is dead
    Dead,
};

// ============================================================================
// File Descriptor
// ============================================================================

pub const FileDescriptor = struct {
    fd: u32,
    // In a real implementation, this would point to a file object
    file_ptr: ?*anyopaque,
    flags: u32,

    pub fn init(fd: u32) FileDescriptor {
        return .{
            .fd = fd,
            .file_ptr = null,
            .flags = 0,
        };
    }
};

// ============================================================================
// Virtual Memory Area (VMA)
// ============================================================================

pub const VmaFlags = packed struct(u32) {
    read: bool = false,
    write: bool = false,
    execute: bool = false,
    shared: bool = false,
    stack: bool = false,
    heap: bool = false,
    _padding: u26 = 0,
};

pub const Vma = struct {
    start: memory.VirtualAddress,
    end: memory.VirtualAddress,
    flags: VmaFlags,
    next: ?*Vma,

    pub fn size(self: Vma) usize {
        return self.end - self.start;
    }

    pub fn contains(self: Vma, addr: memory.VirtualAddress) bool {
        return addr >= self.start and addr < self.end;
    }
};

// ============================================================================
// Address Space
// ============================================================================

pub const AddressSpace = struct {
    /// Page table for this address space
    page_mapper: paging.PageMapper,
    /// List of VMAs (memory regions)
    vma_list: ?*Vma,
    /// Lock for address space operations
    lock: sync.Spinlock,
    /// Reference count
    refcount: atomic.AtomicU32,

    // ASLR - Randomized base addresses
    /// Randomized stack base address
    stack_base: u64,
    /// Randomized heap base address
    heap_base: u64,
    /// Randomized mmap base address
    mmap_base: u64,

    pub fn init(allocator: Basics.Allocator) !*AddressSpace {
        const space = try allocator.create(AddressSpace);
        errdefer allocator.destroy(space);

        // ASLR: Generate randomized base addresses
        // User space on x86-64: 0x0000_0000_0000_0000 to 0x0000_7FFF_FFFF_FFFF

        // Stack: grows down from high address
        // Base: 0x0000_7000_0000_0000 + random(0-256MB)
        const STACK_BASE = 0x0000_7000_0000_0000;
        const STACK_RAND_SIZE = 0x10000000; // 256MB randomization
        const stack_base = random.getAslrBase(STACK_BASE, STACK_RAND_SIZE, 0x1000);

        // Heap: grows up from low address
        // Base: 0x0000_0000_1000_0000 + random(0-256MB)
        const HEAP_BASE = 0x0000_0000_1000_0000;
        const HEAP_RAND_SIZE = 0x10000000; // 256MB randomization
        const heap_base = random.getAslrBase(HEAP_BASE, HEAP_RAND_SIZE, 0x1000);

        // Mmap: middle of address space
        // Base: 0x0000_4000_0000_0000 + random(0-1GB)
        const MMAP_BASE = 0x0000_4000_0000_0000;
        const MMAP_RAND_SIZE = 0x40000000; // 1GB randomization
        const mmap_base = random.getAslrBase(MMAP_BASE, MMAP_RAND_SIZE, 0x1000);

        space.* = .{
            .page_mapper = try paging.PageMapper.init(allocator),
            .vma_list = null,
            .lock = sync.Spinlock.init(),
            .refcount = atomic.AtomicU32.init(1),
            .stack_base = stack_base,
            .heap_base = heap_base,
            .mmap_base = mmap_base,
        };

        return space;
    }

    pub fn deinit(self: *AddressSpace, allocator: Basics.Allocator) void {
        // Clean up VMAs
        var vma = self.vma_list;
        while (vma) |v| {
            const next = v.next;
            allocator.destroy(v);
            vma = next;
        }

        self.page_mapper.deinit();
        allocator.destroy(self);
    }

    /// Add a VMA to the address space
    pub fn addVma(self: *AddressSpace, allocator: Basics.Allocator, start: u64, end: u64, flags: VmaFlags) !*Vma {
        self.lock.acquire();
        defer self.lock.release();

        const vma = try allocator.create(Vma);
        vma.* = .{
            .start = start,
            .end = end,
            .flags = flags,
            .next = self.vma_list,
        };

        self.vma_list = vma;
        return vma;
    }

    /// Find VMA containing an address
    pub fn findVma(self: *AddressSpace, addr: memory.VirtualAddress) ?*Vma {
        self.lock.acquire();
        defer self.lock.release();

        var vma = self.vma_list;
        while (vma) |v| {
            if (v.contains(addr)) return v;
            vma = v.next;
        }
        return null;
    }

    /// Switch to this address space
    pub fn activate(self: *AddressSpace) void {
        self.page_mapper.activate();
    }

    /// Increment reference count
    pub fn acquire(self: *AddressSpace) void {
        _ = self.refcount.fetchAdd(1, .Monotonic);
    }

    /// Decrement reference count and free if zero
    pub fn release(self: *AddressSpace, allocator: Basics.Allocator) void {
        const old = self.refcount.fetchSub(1, .Release);
        if (old == 1) {
            // Last reference, clean up
            self.deinit(allocator);
        }
    }
};

// ============================================================================
// Process Control Block (PCB)
// ============================================================================

pub const Process = struct {
    /// Process ID
    pid: Pid,
    /// Parent process ID
    ppid: Pid,
    /// Process state
    state: ProcessState,
    /// Process name/command
    name: [256]u8,
    name_len: usize,
    /// Exit code (valid when state == Zombie)
    exit_code: i32,

    /// Virtual address space
    address_space: *AddressSpace,

    /// Thread list
    threads: Basics.ArrayList(*Thread),
    thread_lock: sync.Spinlock,

    /// Parent process
    parent: ?*Process,
    /// Child processes
    children: Basics.ArrayList(*Process),
    children_lock: sync.Spinlock,

    /// File descriptor table
    fd_table: [256]?FileDescriptor,
    fd_lock: sync.Spinlock,

    /// Working directory
    cwd: [4096]u8,
    cwd_len: usize,

    // Security credentials
    /// Real user ID
    uid: u32,
    /// Real group ID
    gid: u32,
    /// Effective user ID (used for permission checks)
    euid: u32,
    /// Effective group ID (used for permission checks)
    egid: u32,
    /// Saved set-user-ID (for setuid programs)
    saved_uid: u32,
    /// Saved set-group-ID (for setuid programs)
    saved_gid: u32,
    /// Filesystem user ID (for file operations)
    fsuid: u32,
    /// Filesystem group ID (for file operations)
    fsgid: u32,

    /// Supplementary groups
    groups: [32]u32,
    num_groups: usize,

    /// Capabilities (for fine-grained privileges)
    capabilities: u64,

    /// Process lock
    lock: sync.Spinlock,

    /// Allocator for this process
    allocator: Basics.Allocator,

    /// Create a new process
    pub fn create(allocator: Basics.Allocator, name: []const u8) !*Process {
        const process = try allocator.create(Process);
        errdefer allocator.destroy(process);

        // Create address space
        const addr_space = try AddressSpace.init(allocator);
        errdefer addr_space.deinit(allocator);

        var proc_name: [256]u8 = undefined;
        const name_len = Basics.math.min(name.len, 255);
        @memcpy(proc_name[0..name_len], name[0..name_len]);

        process.* = .{
            .pid = allocatePid(),
            .ppid = KERNEL_PID,
            .state = .Creating,
            .name = proc_name,
            .name_len = name_len,
            .exit_code = 0,
            .address_space = addr_space,
            .threads = Basics.ArrayList(*Thread).init(allocator),
            .thread_lock = sync.Spinlock.init(),
            .parent = null,
            .children = Basics.ArrayList(*Process).init(allocator),
            .children_lock = sync.Spinlock.init(),
            .fd_table = [_]?FileDescriptor{null} ** 256,
            .fd_lock = sync.Spinlock.init(),
            .cwd = undefined,
            .cwd_len = 1,
            // Initialize credentials (kernel processes start as root)
            .uid = 0,
            .gid = 0,
            .euid = 0,
            .egid = 0,
            .saved_uid = 0,
            .saved_gid = 0,
            .fsuid = 0,
            .fsgid = 0,
            .groups = [_]u32{0} ** 32,
            .num_groups = 0,
            .capabilities = 0xFFFFFFFFFFFFFFFF, // All capabilities for kernel processes
            .lock = sync.Spinlock.init(),
            .allocator = allocator,
        };

        // Set default cwd to /
        process.cwd[0] = '/';

        // Setup standard file descriptors
        process.fd_table[0] = FileDescriptor.init(0); // stdin
        process.fd_table[1] = FileDescriptor.init(1); // stdout
        process.fd_table[2] = FileDescriptor.init(2); // stderr

        return process;
    }

    /// Add a thread to this process
    pub fn addThread(self: *Process, thread: *Thread) !void {
        self.thread_lock.acquire();
        defer self.thread_lock.release();

        try self.threads.append(thread);
    }

    /// Remove a thread from this process
    pub fn removeThread(self: *Process, thread: *Thread) void {
        self.thread_lock.acquire();
        defer self.thread_lock.release();

        for (self.threads.items, 0..) |t, i| {
            if (t == thread) {
                _ = self.threads.swapRemove(i);
                break;
            }
        }
    }

    /// Add a child process
    pub fn addChild(self: *Process, child: *Process) !void {
        self.children_lock.acquire();
        defer self.children_lock.release();

        try self.children.append(child);
        child.parent = self;
        child.ppid = self.pid;
    }

    /// Remove a child process
    pub fn removeChild(self: *Process, child: *Process) void {
        self.children_lock.acquire();
        defer self.children_lock.release();

        for (self.children.items, 0..) |c, i| {
            if (c == child) {
                _ = self.children.swapRemove(i);
                break;
            }
        }
    }

    /// Allocate a file descriptor
    pub fn allocateFd(self: *Process) ?u32 {
        self.fd_lock.acquire();
        defer self.fd_lock.release();

        // Find first available FD (skip 0, 1, 2)
        for (3..256) |fd| {
            if (self.fd_table[fd] == null) {
                return @intCast(fd);
            }
        }
        return null;
    }

    /// Set a file descriptor
    pub fn setFd(self: *Process, fd: u32, file_desc: FileDescriptor) !void {
        if (fd >= 256) return error.InvalidFd;

        self.fd_lock.acquire();
        defer self.fd_lock.release();

        self.fd_table[fd] = file_desc;
    }

    /// Close a file descriptor
    pub fn closeFd(self: *Process, fd: u32) !void {
        if (fd >= 256) return error.InvalidFd;

        self.fd_lock.acquire();
        defer self.fd_lock.release();

        if (self.fd_table[fd] == null) return error.BadFd;
        self.fd_table[fd] = null;
    }

    /// Get name as string
    pub fn getName(self: *const Process) []const u8 {
        return self.name[0..self.name_len];
    }

    /// Get current working directory
    pub fn getCwd(self: *const Process) []const u8 {
        return self.cwd[0..self.cwd_len];
    }

    /// Set current working directory
    pub fn setCwd(self: *Process, path: []const u8) !void {
        if (path.len > 4095) return error.PathTooLong;

        self.lock.acquire();
        defer self.lock.release();

        @memcpy(self.cwd[0..path.len], path);
        self.cwd_len = path.len;
    }

    /// Mark process as running
    pub fn markRunning(self: *Process) void {
        self.lock.acquire();
        defer self.lock.release();
        self.state = .Running;
    }

    /// Mark process as sleeping
    pub fn markSleeping(self: *Process) void {
        self.lock.acquire();
        defer self.lock.release();
        self.state = .Sleeping;
    }

    /// Terminate process with exit code
    pub fn terminate(self: *Process, exit_code: i32) void {
        self.lock.acquire();
        defer self.lock.release();

        self.state = .Zombie;
        self.exit_code = exit_code;

        // Clean up resources
        self.cleanupResources();

        // Wake up parent if waiting
        // TODO: Implement wait queue
    }

    /// Clean up all process resources
    fn cleanupResources(self: *Process) void {
        // 1. Close all file descriptors
        self.fd_lock.acquire();
        for (self.file_descriptors.items, 0..) |fd, i| {
            if (fd) |_| {
                // Close FD (will be handled by VFS layer)
                self.file_descriptors.items[i] = null;
            }
        }
        self.fd_lock.release();

        // 2. Clean up memory mappings (VMAs)
        self.memory_lock.acquire();
        if (self.page_directory) |pd| {
            // TODO: Free all user-space page tables
            // This should iterate through VMAs and unmap them
            _ = pd;
        }
        self.memory_lock.release();

        // 3. Clean up IPC resources
        // Pipes - close any pipe FDs (handled above in FD cleanup)

        // Shared memory - detach all segments
        // TODO: Implement shm cleanup when shm.zig is available

        // Message queues - close all queues
        // TODO: Implement mqueue cleanup when mqueue.zig is available

        // 4. Clean up signal handlers
        // Reset to default handlers
        self.signal_lock.acquire();
        for (&self.signal_handlers) |*handler| {
            handler.* = null;
        }
        self.signal_lock.release();

        // 5. Terminate all threads
        self.thread_lock.acquire();
        for (self.threads.items) |thread_ptr| {
            // Mark thread as terminated
            thread_ptr.terminate();
        }
        self.thread_lock.release();

        // Note: Actual memory deallocation happens when parent reaps us
        // or when we transition from Zombie to Dead state
    }

    /// Fully destroy process and free all memory (called after reaping)
    pub fn destroy(self: *Process, allocator: Basics.Allocator) void {
        // Ensure we're already a zombie
        if (self.state != .Zombie) {
            self.terminate(0);
        }

        // Free all dynamically allocated memory
        self.fd_lock.acquire();
        self.file_descriptors.deinit();
        self.fd_lock.release();

        self.thread_lock.acquire();
        for (self.threads.items) |thread_ptr| {
            // Free thread resources
            allocator.destroy(thread_ptr);
        }
        self.threads.deinit();
        self.thread_lock.release();

        // Free page directory if allocated
        if (self.page_directory) |pd| {
            allocator.destroy(pd);
        }

        // Free children list
        self.children_lock.acquire();
        self.children.deinit();
        self.children_lock.release();

        // Mark as dead
        self.state = .Dead;
    }

    /// Check if process is alive
    pub fn isAlive(self: *const Process) bool {
        return self.state != .Zombie and self.state != .Dead;
    }

    /// Count running threads
    pub fn countRunningThreads(self: *const Process) usize {
        self.thread_lock.acquire();
        defer self.thread_lock.release();

        var count: usize = 0;
        for (self.threads.items) |thread| {
            if (thread.isRunnable()) {
                count += 1;
            }
        }
        return count;
    }

    /// Format for printing
    pub fn format(
        self: Process,
        comptime fmt: []const u8,
        options: Basics.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print(
            "Process[{d}] '{s}' state={s} threads={d}",
            .{
                self.pid,
                self.getName(),
                @tagName(self.state),
                self.threads.items.len,
            },
        );
    }
};

// ============================================================================
// Global Process List
// ============================================================================

var process_list_lock = sync.Spinlock.init();
pub const process_table_lock = &process_list_lock; // Public alias for syscall security
var process_list: ?Basics.ArrayList(*Process) = null;

/// Initialize process management subsystem
pub fn init(allocator: Basics.Allocator) !void {
    process_list_lock.acquire();
    defer process_list_lock.release();

    process_list = Basics.ArrayList(*Process).init(allocator);
}

/// Add process to global list
pub fn registerProcess(process: *Process) !void {
    process_list_lock.acquire();
    defer process_list_lock.release();

    if (process_list) |*list| {
        try list.append(process);
    }
}

/// Remove process from global list
pub fn unregisterProcess(process: *Process) void {
    process_list_lock.acquire();
    defer process_list_lock.release();

    if (process_list) |*list| {
        for (list.items, 0..) |p, i| {
            if (p == process) {
                _ = list.swapRemove(i);
                break;
            }
        }
    }
}

/// Find process by PID
pub fn findProcess(pid: Pid) ?*Process {
    process_list_lock.acquire();
    defer process_list_lock.release();

    if (process_list) |list| {
        for (list.items) |p| {
            if (p.pid == pid) {
                return p;
            }
        }
    }
    return null;
}

/// Find process by PID (returns error instead of null, assumes lock is held)
pub fn findProcessById(pid: Pid) !*Process {
    // NOTE: This function assumes the caller already holds process_list_lock
    if (process_list) |list| {
        for (list.items) |p| {
            if (p.pid == pid) {
                return p;
            }
        }
    }
    return error.NoSuchProcess;
}

/// Get all processes (returns a copy of the list)
pub fn getAllProcesses(allocator: Basics.Allocator) ![]const *Process {
    process_list_lock.acquire();
    defer process_list_lock.release();

    if (process_list) |list| {
        const procs = try allocator.alloc(*Process, list.items.len);
        @memcpy(procs, list.items);
        return procs;
    }
    return &[_]*Process{};
}

// ============================================================================
// Process Operations
// ============================================================================

/// Fork current process (create a copy)
pub fn fork(parent: *Process, allocator: Basics.Allocator) !*Process {
    const child = try Process.create(allocator, parent.getName());
    errdefer child.destroy();

    // Copy process state
    child.ppid = parent.pid;
    child.parent = parent;

    // Copy file descriptor table
    @memcpy(&child.fd_table, &parent.fd_table);

    // Copy working directory
    @memcpy(child.cwd[0..parent.cwd_len], parent.cwd[0..parent.cwd_len]);
    child.cwd_len = parent.cwd_len;

    // Inherit security credentials from parent
    child.uid = parent.uid;
    child.gid = parent.gid;
    child.euid = parent.euid;
    child.egid = parent.egid;
    child.saved_uid = parent.saved_uid;
    child.saved_gid = parent.saved_gid;
    child.fsuid = parent.fsuid;
    child.fsgid = parent.fsgid;

    // Copy supplementary groups
    @memcpy(&child.groups, &parent.groups);
    child.num_groups = parent.num_groups;

    // Inherit capabilities
    child.capabilities = parent.capabilities;

    // Add to parent's children
    try parent.addChild(child);

    // Register globally
    try registerProcess(child);

    return child;
}

/// Execute a new program in process
pub fn exec(process: *Process, path: []const u8, args: []const []const u8) !void {
    _ = args; // TODO: Pass to loader

    // Clear current address space and load new program
    process.lock.acquire();
    defer process.lock.release();

    // Update process name
    const name_len = Basics.math.min(path.len, 255);
    @memcpy(process.name[0..name_len], path[0..name_len]);
    process.name_len = name_len;

    // TODO: Load executable from path
    // TODO: Setup stack with arguments
    // TODO: Setup initial thread

    process.state = .Running;
}

/// Wait for child process to exit
pub fn wait(parent: *Process, target_pid: Pid) !i32 {
    _ = parent;
    _ = target_pid;
    // TODO: Implement wait queue and sleep/wake
    return error.NotImplemented;
}

// ============================================================================
// Tests
// ============================================================================

test "process creation" {
    const allocator = Basics.testing.allocator;

    try init(allocator);
    defer if (process_list) |*list| list.deinit();

    const proc = try Process.create(allocator, "test");
    defer proc.destroy();

    try Basics.testing.expect(proc.pid > 0);
    try Basics.testing.expectEqualStrings("test", proc.getName());
    try Basics.testing.expectEqual(ProcessState.Creating, proc.state);
}

test "process hierarchy" {
    const allocator = Basics.testing.allocator;

    try init(allocator);
    defer if (process_list) |*list| list.deinit();

    const parent = try Process.create(allocator, "parent");
    defer parent.destroy();

    const child = try Process.create(allocator, "child");
    defer child.destroy();

    try parent.addChild(child);

    try Basics.testing.expectEqual(parent.pid, child.ppid);
    try Basics.testing.expectEqual(@as(usize, 1), parent.children.items.len);
}

test "file descriptors" {
    const allocator = Basics.testing.allocator;

    const proc = try Process.create(allocator, "test");
    defer proc.destroy();

    // Standard FDs should exist
    try Basics.testing.expect(proc.fd_table[0] != null);
    try Basics.testing.expect(proc.fd_table[1] != null);
    try Basics.testing.expect(proc.fd_table[2] != null);

    // Allocate new FD
    const fd = proc.allocateFd().?;
    try Basics.testing.expect(fd >= 3);

    try proc.setFd(fd, FileDescriptor.init(fd));
    try Basics.testing.expect(proc.fd_table[fd] != null);

    try proc.closeFd(fd);
    try Basics.testing.expect(proc.fd_table[fd] == null);
}

test "address space" {
    const allocator = Basics.testing.allocator;

    var space = try AddressSpace.init(allocator);
    defer space.release(allocator);

    // Add VMA
    const vma = try space.addVma(allocator, 0x1000, 0x2000, .{ .read = true, .write = true });
    try Basics.testing.expectEqual(@as(u64, 0x1000), vma.start);
    try Basics.testing.expectEqual(@as(u64, 0x2000), vma.end);

    // Find VMA
    const found = space.findVma(0x1500);
    try Basics.testing.expect(found != null);
    try Basics.testing.expectEqual(vma, found.?);
}
