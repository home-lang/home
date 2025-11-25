// Home Programming Language - Process Execution
// Load and execute programs in processes

const Basics = @import("basics");
const process = @import("process.zig");
const memory = @import("memory.zig");
const paging = @import("paging.zig");
const signal = @import("signal.zig");
const sched = @import("sched.zig");
const thread = @import("thread.zig");
const vfs = @import("vfs.zig");

// ============================================================================
// Executable Format Types
// ============================================================================

pub const ExecutableFormat = enum {
    ELF64,
    ELF32,
    MachO,
    PE,
    Unknown,
};

/// ELF header identification
pub const ELF_MAGIC = [4]u8{ 0x7F, 'E', 'L', 'F' };

/// Mach-O magic numbers
pub const MACHO_MAGIC_64 = 0xFEEDFACF;
pub const MACHO_MAGIC_32 = 0xFEEDFACE;

/// PE magic numbers
pub const PE_MAGIC = [2]u8{ 'M', 'Z' };

/// Detect executable format from file header
pub fn detectFormat(header: []const u8) ExecutableFormat {
    if (header.len < 4) return .Unknown;

    // Check for ELF
    if (Basics.mem.eql(u8, header[0..4], &ELF_MAGIC)) {
        if (header.len >= 5) {
            return if (header[4] == 2) .ELF64 else .ELF32;
        }
        return .Unknown;
    }

    // Check for Mach-O
    if (header.len >= 4) {
        const magic = Basics.mem.readInt(u32, header[0..4].*, .little);
        if (magic == MACHO_MAGIC_64) return .MachO;
        if (magic == MACHO_MAGIC_32) return .MachO;
    }

    // Check for PE
    if (Basics.mem.eql(u8, header[0..2], &PE_MAGIC)) {
        return .PE;
    }

    return .Unknown;
}

// ============================================================================
// ELF64 Structures
// ============================================================================

pub const Elf64_Ehdr = extern struct {
    e_ident: [16]u8,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u64,
    e_phoff: u64,
    e_shoff: u64,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,
};

pub const Elf64_Phdr = extern struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,
};

pub const PT_LOAD = 1;
pub const PT_DYNAMIC = 2;
pub const PT_INTERP = 3;

pub const PF_X = 1;
pub const PF_W = 2;
pub const PF_R = 4;

// ============================================================================
// Program Arguments and Environment
// ============================================================================

pub const MAX_ARG_STRLEN = 4096;
pub const MAX_ARG_STRINGS = 256;
pub const MAX_ENV_STRINGS = 256;

/// Calculate size needed for argv/envp on stack
fn calculateArgSize(args: []const []const u8, envp: []const []const u8) usize {
    var size: usize = 0;

    // Space for argv pointers (including NULL terminator)
    size += (args.len + 1) * @sizeOf(usize);

    // Space for envp pointers (including NULL terminator)
    size += (envp.len + 1) * @sizeOf(usize);

    // Space for arg strings
    for (args) |arg| {
        size += arg.len + 1; // +1 for NULL terminator
    }

    // Space for env strings
    for (envp) |env| {
        size += env.len + 1; // +1 for NULL terminator
    }

    // Align to 16 bytes
    return Basics.mem.alignForward(usize, size, 16);
}

/// Setup program arguments and environment on stack
fn setupProgramStack(
    addr_space: *process.AddressSpace,
    allocator: Basics.Allocator,
    args: []const []const u8,
    envp: []const []const u8,
) !u64 {
    // Calculate required stack size
    const arg_size = calculateArgSize(args, envp);
    const stack_size = 2 * 1024 * 1024; // 2MB default stack
    const total_size = stack_size + arg_size;

    // Allocate stack memory (grows down)
    const stack_top = addr_space.stack_base;
    const stack_bottom = stack_top - total_size;

    // Create VMA for stack
    _ = try addr_space.addVma(
        allocator,
        stack_bottom,
        stack_top,
        .{ .read = true, .write = true, .stack = true },
    );

    // Write args/env to stack memory
    // Stack layout (growing down from stack_top):
    // - Environment strings (NULL-terminated)
    // - Argument strings (NULL-terminated)
    // - envp[] pointers (NULL-terminated array)
    // - argv[] pointers (NULL-terminated array)
    // - argc (number of arguments)
    //
    // In a real implementation, this would write to actual mapped pages.
    // For now, we'll set up the pointers correctly but note that actual
    // page mapping needs to happen first.

    var sp = stack_top - arg_size;

    // Calculate positions for argv and envp arrays
    const argc = args.len;
    const argv_pos = sp;
    const envp_pos = argv_pos + ((argc + 1) * @sizeOf(usize));

    // Calculate position for strings
    var string_pos = envp_pos + ((envp.len + 1) * @sizeOf(usize));

    // Note: In a real implementation with actual page mapping, we would:
    // 1. Map the stack pages
    // 2. Write argc at sp
    // 3. Write argv pointers at argv_pos
    // 4. Write envp pointers at envp_pos
    // 5. Copy argument strings to string_pos
    // 6. Copy environment strings after argument strings
    //
    // Stack pointer layout:
    // [sp] = argc
    // [sp+8] = argv[0]
    // [sp+16] = argv[1]
    // ...
    // [sp+(argc+1)*8] = NULL (argv terminator)
    // [sp+(argc+2)*8] = envp[0]
    // ...
    // Then strings follow

    _ = argc;
    _ = argv_pos;
    _ = envp_pos;
    _ = string_pos;

    // Return stack pointer (would point to argc in real implementation)
    return sp;
}

// ============================================================================
// ELF Loader (using complete implementation)
// ============================================================================

const elf_loader = @import("elf_loader.zig");

pub const ElfLoader = struct {
    /// Load ELF64 executable into address space with full memory mapping
    pub fn loadElf64(
        addr_space: *process.AddressSpace,
        allocator: Basics.Allocator,
        elf_data: []const u8,
    ) !u64 {
        return try elf_loader.SegmentLoader.loadAllSegments(
            &addr_space.page_mapper,
            allocator,
            elf_data,
        );
    }
};

// ============================================================================
// Process Spawning
// ============================================================================

/// Spawn a new process with the given program
pub fn spawn(
    allocator: Basics.Allocator,
    path: []const u8,
    args: []const []const u8,
    envp: []const []const u8,
) !*process.Process {
    // Create new process
    const proc = try process.Process.create(allocator, path);
    errdefer proc.destroy(allocator);

    // Load executable file from path via VFS
    const elf_data = try loadExecutableFromPath(allocator, path);
    defer allocator.free(elf_data);

    // Detect format
    const format = detectFormat(elf_data);
    if (format != .ELF64 and format != .ELF32) {
        return error.UnsupportedExecutableFormat;
    }

    // Load executable into process address space
    const entry_point = try ElfLoader.loadElf64(proc.address_space, allocator, elf_data);

    // Setup program stack with args and environment
    const stack_ptr = try setupProgramStack(proc.address_space, allocator, args, envp);

    // Create initial thread with entry point and stack pointer
    const main_thread = try thread.Thread.create(allocator, proc);
    errdefer main_thread.destroy(allocator);

    // Set up thread CPU context
    main_thread.context.rip = entry_point; // Instruction pointer
    main_thread.context.rsp = stack_ptr; // Stack pointer
    main_thread.context.rflags = 0x202; // Interrupts enabled
    main_thread.context.cs = 0x23; // User code segment
    main_thread.context.ss = 0x1b; // User data segment

    // Add thread to process
    proc.main_thread = main_thread;
    try proc.addThread(main_thread);

    // Initialize signal queue
    proc.signals = try signal.SignalQueue.init(allocator);

    // Add thread to scheduler
    try sched.addThread(main_thread);

    // Mark process as runnable
    proc.markRunning();

    // Register process
    try process.registerProcess(proc);

    return proc;
}

/// Load executable file data from VFS
fn loadExecutableFromPath(allocator: Basics.Allocator, path: []const u8) ![]u8 {
    // Get current process for VFS context
    const current_proc = process.current();
    const root_dentry = if (current_proc) |p| p.fs_root else null;
    const cwd_dentry = if (current_proc) |p| p.fs_cwd else null;

    // Open the file
    const file = try vfs.open(
        path,
        vfs.OpenFlags.O_RDONLY,
        0,
        current_proc,
    );
    defer file.put(allocator);

    // Get file size
    const inode = file.dentry.inode;
    const size = inode.size;

    if (size == 0 or size > 100 * 1024 * 1024) { // Max 100MB executable
        return error.InvalidExecutable;
    }

    // Allocate buffer
    const buffer = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(buffer);

    // Read file contents
    const bytes_read = try file.read(buffer);
    if (bytes_read != size) {
        return error.ReadError;
    }

    _ = root_dentry;
    _ = cwd_dentry;

    return buffer;
}

/// Execute a new program in the current process (replaces current program)
pub fn exec(
    proc: *process.Process,
    allocator: Basics.Allocator,
    path: []const u8,
    args: []const []const u8,
    envp: []const []const u8,
) !void {
    // Save old address space in case we need to rollback
    const old_addr_space = proc.address_space;

    // Create new address space
    const new_addr_space = try process.AddressSpace.init(allocator);
    errdefer new_addr_space.deinit(allocator);

    // TODO: Load executable file
    const elf_data = &[_]u8{};
    const format = detectFormat(elf_data);
    _ = format;

    // Load program
    // const entry_point = try ElfLoader.loadElf64(new_addr_space, allocator, elf_data);

    // Setup stack
    const stack_ptr = try setupProgramStack(new_addr_space, allocator, args, envp);
    _ = stack_ptr;

    // Update process name
    const name_len = Basics.math.min(path.len, 255);
    @memcpy(proc.name[0..name_len], path[0..name_len]);
    proc.name_len = name_len;

    // Close file descriptors marked as close-on-exec (FD_CLOEXEC)
    proc.fd_lock.acquire();
    for (&proc.fd_table, 0..) |*fd_opt, i| {
        if (fd_opt.*) |fd| {
            // Check FD_CLOEXEC flag (bit 0)
            const FD_CLOEXEC: u32 = 1;
            if (fd.flags & FD_CLOEXEC != 0) {
                // Close this file descriptor
                if (fd.file) |file| {
                    file.put(proc.allocator);
                }
                proc.fd_table[i] = null;
            }
        }
    }
    proc.fd_lock.release();

    // Reset signal handlers to defaults and clear signal masks
    proc.signals.resetForExec();

    // Terminate all threads except calling thread
    // Get current thread (calling thread)
    const current_thread = thread.current();

    proc.thread_lock.acquire();
    var it = proc.threads.first;
    while (it) |node| {
        const next = node.next;
        const thr = node.data;

        // Don't terminate the calling thread
        if (current_thread != null and thr == current_thread.?) {
            it = next;
            continue;
        }

        // Mark thread as dead and remove from scheduler
        thr.state = .Dead;
        sched.removeThread(thr);

        it = next;
    }
    proc.thread_lock.release();

    // Switch to new address space
    proc.address_space = new_addr_space;

    // Release old address space
    old_addr_space.release(allocator);

    proc.state = .Running;
}

/// Fork and exec pattern (common POSIX idiom)
pub fn forkExec(
    parent: *process.Process,
    allocator: Basics.Allocator,
    path: []const u8,
    args: []const []const u8,
    envp: []const []const u8,
) !*process.Process {
    // Fork parent process
    const child = try process.fork(parent, allocator);
    errdefer child.destroy(allocator);

    // Execute new program in child
    try exec(child, allocator, path, args, envp);

    return child;
}

// ============================================================================
// Process Exit
// ============================================================================

/// Exit current process with given exit code
pub fn exit(proc: *process.Process, exit_code: i32) void {
    proc.terminate(exit_code);

    // Reparent children to init process
    proc.children_lock.acquire();

    if (process.findProcess(process.INIT_PID)) |init_proc| {
        for (proc.children.items) |child| {
            child.parent = init_proc;
            child.ppid = process.INIT_PID;
            init_proc.addChild(child) catch {};
        }
        proc.children.clearRetainingCapacity();
    }

    proc.children_lock.release();

    // Send SIGCHLD to parent process
    signal.notifyParentChildStatusChanged(proc, .Exited);

    // Wake up parent if it's waiting
    if (process.findProcess(proc.ppid)) |parent| {
        // Check if parent is sleeping in wait()
        if (parent.state == .Sleeping) {
            // Check if parent was waiting for this child
            if (parent.wait_pid == 0 or parent.wait_pid == proc.pid) {
                parent.state = .Ready;
                // Add parent to scheduler run queue
                if (parent.main_thread) |main_thr| {
                    sched.addThread(main_thr) catch {};
                }
            }
        }
    }

    // Unregister from global process list (but don't destroy - parent needs to wait)
    // Process stays as zombie until parent calls wait()
    // process.unregisterProcess(proc);

    // Switch to next runnable thread/process
    sched.schedule();
}

/// Wait for child process to terminate
pub fn wait(parent: *process.Process, pid: process.Pid) !i32 {
    while (true) {
        // Find child process
        parent.children_lock.acquire();

        var child: ?*process.Process = null;
        for (parent.children.items) |c| {
            if (pid == 0 or c.pid == pid) {
                child = c;
                break;
            }
        }

        if (child == null) {
            parent.children_lock.release();
            return error.NoSuchProcess;
        }

        parent.children_lock.release();

        const target = child.?;

        // Check if already a zombie
        if (target.state == .Zombie) {
            const exit_code = target.exit_code;

            // Remove from children list
            parent.removeChild(target);

            // Unregister and destroy child process
            process.unregisterProcess(target);
            target.destroy(parent.allocator);

            return exit_code;
        }

        // Not a zombie yet - sleep until child status changes
        // Set the PID we're waiting for so exit() can wake us up
        parent.wait_pid = pid;
        parent.state = .Sleeping;

        // Remove from run queue and yield to scheduler
        if (parent.main_thread) |main_thr| {
            sched.removeThread(main_thr);
        }
        sched.schedule();

        // When we wake up, loop again to check if child is now a zombie
        parent.wait_pid = 0;
    }
}

/// Wait for any child process
pub fn waitAny(parent: *process.Process) !struct { pid: process.Pid, exit_code: i32 } {
    parent.children_lock.acquire();
    defer parent.children_lock.release();

    // Look for zombie children
    for (parent.children.items) |child| {
        if (child.state == .Zombie) {
            const pid = child.pid;
            const exit_code = child.exit_code;

            // Remove and destroy
            parent.removeChild(child);
            child.destroy(parent.allocator);

            return .{ .pid = pid, .exit_code = exit_code };
        }
    }

    // No zombie children
    return error.WouldBlock;
}

// ============================================================================
// Tests
// ============================================================================

test "detect executable format" {
    const elf_header = ELF_MAGIC ++ [_]u8{ 2, 1, 1 } ++ [_]u8{0} ** 9;
    const format = detectFormat(&elf_header);
    try Basics.testing.expectEqual(ExecutableFormat.ELF64, format);
}

test "calculate arg size" {
    const args = [_][]const u8{ "program", "arg1", "arg2" };
    const envp = [_][]const u8{ "PATH=/bin", "HOME=/root" };

    const size = calculateArgSize(&args, &envp);
    try Basics.testing.expect(size > 0);

    // Should be aligned to 16 bytes
    try Basics.testing.expect(size % 16 == 0);
}

test "VMA W^X enforcement" {
    // This should fail - write and execute not allowed together
    const bad_flags = process.VmaFlags{
        .read = true,
        .write = true,
        .execute = true,
    };

    const result = bad_flags.validateWX();
    try Basics.testing.expectError(error.WriteAndExecuteNotAllowed, result);

    // These should pass
    const read_only = process.VmaFlags{ .read = true };
    try read_only.validateWX();

    const read_write = process.VmaFlags{ .read = true, .write = true };
    try read_write.validateWX();

    const read_exec = process.VmaFlags{ .read = true, .execute = true };
    try read_exec.validateWX();
}
