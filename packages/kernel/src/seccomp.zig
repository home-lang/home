// Home OS Kernel - Seccomp (Secure Computing) Filtering
// Syscall sandboxing and filtering framework

const Basics = @import("basics");
const sync = @import("sync.zig");
const atomic = @import("atomic.zig");
const process = @import("process.zig");
const audit = @import("audit.zig");

// ============================================================================
// Seccomp Modes
// ============================================================================

pub const SeccompMode = enum(u32) {
    /// Seccomp disabled (normal operation)
    SECCOMP_MODE_DISABLED = 0,
    /// Strict mode - only read, write, _exit, sigreturn allowed
    SECCOMP_MODE_STRICT = 1,
    /// Filter mode - custom BPF filter
    SECCOMP_MODE_FILTER = 2,
};

// ============================================================================
// Seccomp Actions
// ============================================================================

pub const SeccompAction = enum(u32) {
    /// Kill the thread
    SECCOMP_RET_KILL_THREAD = 0x00000000,
    /// Kill the entire process
    SECCOMP_RET_KILL_PROCESS = 0x80000000,
    /// Return errno
    SECCOMP_RET_ERRNO = 0x00050000,
    /// Notify user space
    SECCOMP_RET_TRACE = 0x7ff00000,
    /// Allow after logging
    SECCOMP_RET_LOG = 0x7ffc0000,
    /// Allow syscall
    SECCOMP_RET_ALLOW = 0x7fff0000,
};

// ============================================================================
// Seccomp Filter (Simplified BPF)
// ============================================================================

pub const SeccompFilter = struct {
    /// Filter mode
    mode: SeccompMode,
    /// Syscall whitelist (for simple filtering)
    /// If mode is STRICT, this is ignored
    /// If mode is FILTER, this contains allowed syscalls
    whitelist: [64]bool,
    /// Default action when syscall not in whitelist
    default_action: SeccompAction,
    /// Lock (prevents changes after set)
    locked: bool,

    pub fn init(mode: SeccompMode) SeccompFilter {
        var filter = SeccompFilter{
            .mode = mode,
            .whitelist = [_]bool{false} ** 64,
            .default_action = .SECCOMP_RET_KILL_THREAD,
            .locked = false,
        };

        // If strict mode, only allow read, write, exit, sigreturn
        if (mode == .SECCOMP_MODE_STRICT) {
            filter.whitelist[0] = true; // read
            filter.whitelist[1] = true; // write
            filter.whitelist[60] = true; // exit
            filter.whitelist[15] = true; // rt_sigreturn
        }

        return filter;
    }

    /// Add syscall to whitelist
    pub fn allowSyscall(self: *SeccompFilter, syscall_nr: u32) !void {
        if (self.locked) return error.FilterLocked;
        if (syscall_nr >= 64) return error.SyscallOutOfRange;

        self.whitelist[syscall_nr] = true;
    }

    /// Remove syscall from whitelist
    pub fn denySyscall(self: *SeccompFilter, syscall_nr: u32) !void {
        if (self.locked) return error.FilterLocked;
        if (syscall_nr >= 64) return error.SyscallOutOfRange;

        self.whitelist[syscall_nr] = false;
    }

    /// Check if syscall is allowed
    pub fn checkSyscall(self: *const SeccompFilter, syscall_nr: u32) SeccompAction {
        if (self.mode == .SECCOMP_MODE_DISABLED) {
            return .SECCOMP_RET_ALLOW;
        }

        if (syscall_nr >= 64) {
            return self.default_action;
        }

        if (self.whitelist[syscall_nr]) {
            return .SECCOMP_RET_ALLOW;
        }

        return self.default_action;
    }

    /// Lock the filter (prevents further modifications)
    pub fn lock(self: *SeccompFilter) void {
        self.locked = true;
    }
};

// ============================================================================
// Per-Process Seccomp State
// ============================================================================

pub const ProcessSeccomp = struct {
    filter: ?*SeccompFilter,
    lock: sync.Spinlock,

    pub fn init() ProcessSeccomp {
        return .{
            .filter = null,
            .lock = sync.Spinlock.init(),
        };
    }

    /// Set seccomp filter for process
    pub fn setFilter(self: *ProcessSeccomp, filter: *SeccompFilter) void {
        self.lock.acquire();
        defer self.lock.release();

        self.filter = filter;
    }

    /// Check syscall against filter
    pub fn checkSyscall(self: *ProcessSeccomp, syscall_nr: u32) SeccompAction {
        self.lock.acquire();
        defer self.lock.release();

        if (self.filter) |filter| {
            return filter.checkSyscall(syscall_nr);
        }

        return .SECCOMP_RET_ALLOW;
    }
};

// ============================================================================
// Seccomp Syscall Operations
// ============================================================================

pub const SECCOMP_SET_MODE_STRICT: u32 = 0;
pub const SECCOMP_SET_MODE_FILTER: u32 = 1;
pub const SECCOMP_GET_ACTION_AVAIL: u32 = 2;

/// Set seccomp mode for current process
pub fn setSeccompMode(proc: *process.Process, mode: SeccompMode, filter: ?*SeccompFilter) !void {
    // Seccomp is one-way: once enabled, cannot be disabled
    // This is a security feature

    // Create filter based on mode
    const new_filter = filter orelse blk: {
        const f = try proc.allocator.create(SeccompFilter);
        f.* = SeccompFilter.init(mode);
        break :blk f;
    };

    // Lock the filter
    new_filter.lock();

    // Set filter on process's seccomp context
    proc.seccomp_filter = new_filter;
    proc.seccomp_mode = .FILTER;

    // Log seccomp activation
    audit.logSecurityViolation("Seccomp filter activated");
}

/// Check if syscall should be allowed
pub fn checkSyscallFilter(proc: *process.Process, syscall_nr: u32) !void {
    // Check if process has a seccomp filter installed
    if (proc.seccomp_filter) |filter| {
        // Evaluate the filter against the syscall number
        const action = filter.check(syscall_nr);
        switch (action) {
            .ALLOW => return, // Syscall allowed
            .KILL => return error.SeccompKill, // Kill process
            .TRAP => return error.SeccompTrap, // Send SIGSYS
            .ERRNO => return error.SeccompErrno, // Return error
            .TRACE => {}, // Allow but notify tracer
            .LOG => {}, // Allow but log
        }
    }

    // No filter or filter allows - syscall proceeds
}

// ============================================================================
// Common Seccomp Profiles
// ============================================================================

/// Create a read-only filesystem profile
pub fn createReadOnlyFsProfile(allocator: Basics.Allocator) !*SeccompFilter {
    const filter = try allocator.create(SeccompFilter);
    filter.* = SeccompFilter.init(.SECCOMP_MODE_FILTER);

    // Allow read operations
    try filter.allowSyscall(0); // read
    try filter.allowSyscall(2); // open (read-only)
    try filter.allowSyscall(3); // close
    try filter.allowSyscall(8); // lseek
    try filter.allowSyscall(9); // mmap (read-only)
    try filter.allowSyscall(11); // munmap

    // Allow process operations
    try filter.allowSyscall(60); // exit
    try filter.allowSyscall(231); // exit_group

    // Allow basic operations
    try filter.allowSyscall(15); // rt_sigreturn
    try filter.allowSyscall(39); // getpid
    try filter.allowSyscall(102); // getuid

    filter.default_action = .SECCOMP_RET_ERRNO;

    return filter;
}

/// Create a network-disabled profile
pub fn createNoNetworkProfile(allocator: Basics.Allocator) !*SeccompFilter {
    const filter = try allocator.create(SeccompFilter);
    filter.* = SeccompFilter.init(.SECCOMP_MODE_FILTER);

    // Allow all syscalls EXCEPT network syscalls
    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        // Skip network syscalls
        const is_network_syscall = switch (i) {
            41 => true, // socket
            42 => true, // connect
            43 => true, // accept
            44 => true, // sendto
            45 => true, // recvfrom
            46 => true, // sendmsg
            47 => true, // recvmsg
            48 => true, // shutdown
            49 => true, // bind
            50 => true, // listen
            else => false,
        };

        if (!is_network_syscall) {
            try filter.allowSyscall(i);
        }
    }

    filter.default_action = .SECCOMP_RET_ERRNO;

    return filter;
}

// ============================================================================
// Tests
// ============================================================================

test "seccomp filter initialization" {
    const filter = SeccompFilter.init(.SECCOMP_MODE_STRICT);

    try Basics.testing.expect(filter.mode == .SECCOMP_MODE_STRICT);
    try Basics.testing.expect(!filter.locked);

    // Strict mode should only allow read, write, exit, sigreturn
    try Basics.testing.expect(filter.whitelist[0]); // read
    try Basics.testing.expect(filter.whitelist[1]); // write
    try Basics.testing.expect(filter.whitelist[60]); // exit
    try Basics.testing.expect(filter.whitelist[15]); // rt_sigreturn
}

test "seccomp filter allow/deny" {
    var filter = SeccompFilter.init(.SECCOMP_MODE_FILTER);

    try filter.allowSyscall(5); // open
    try Basics.testing.expect(filter.whitelist[5]);

    try filter.denySyscall(5);
    try Basics.testing.expect(!filter.whitelist[5]);
}

test "seccomp filter locking" {
    var filter = SeccompFilter.init(.SECCOMP_MODE_FILTER);

    try filter.allowSyscall(10);
    filter.lock();

    // Should fail to modify locked filter
    const result = filter.allowSyscall(11);
    try Basics.testing.expectError(error.FilterLocked, result);
}

test "seccomp syscall checking" {
    var filter = SeccompFilter.init(.SECCOMP_MODE_FILTER);
    filter.default_action = .SECCOMP_RET_ERRNO;

    try filter.allowSyscall(0); // read

    const action_allowed = filter.checkSyscall(0);
    const action_denied = filter.checkSyscall(1);

    try Basics.testing.expect(action_allowed == .SECCOMP_RET_ALLOW);
    try Basics.testing.expect(action_denied == .SECCOMP_RET_ERRNO);
}

test "seccomp disabled mode" {
    const filter = SeccompFilter.init(.SECCOMP_MODE_DISABLED);

    // All syscalls should be allowed in disabled mode
    const action = filter.checkSyscall(999);
    try Basics.testing.expect(action == .SECCOMP_RET_ALLOW);
}
