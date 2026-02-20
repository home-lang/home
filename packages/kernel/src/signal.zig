// Home Programming Language - Signal System
// POSIX signals for inter-process communication

const Basics = @import("basics");
const process = @import("process.zig");
const thread = @import("thread.zig");
const sync = @import("sync.zig");
const arch = @import("arch.zig");

// ============================================================================
// Signal Numbers (POSIX)
// ============================================================================

pub const Signal = enum(u8) {
    SIGHUP = 1, // Hangup
    SIGINT = 2, // Interrupt (Ctrl+C)
    SIGQUIT = 3, // Quit (Ctrl+\)
    SIGILL = 4, // Illegal instruction
    SIGTRAP = 5, // Trace/breakpoint trap
    SIGABRT = 6, // Abort
    SIGBUS = 7, // Bus error
    SIGFPE = 8, // Floating point exception
    SIGKILL = 9, // Kill (cannot be caught)
    SIGUSR1 = 10, // User-defined signal 1
    SIGSEGV = 11, // Segmentation fault
    SIGUSR2 = 12, // User-defined signal 2
    SIGPIPE = 13, // Broken pipe
    SIGALRM = 14, // Alarm clock
    SIGTERM = 15, // Termination
    SIGSTKFLT = 16, // Stack fault
    SIGCHLD = 17, // Child process status changed
    SIGCONT = 18, // Continue if stopped
    SIGSTOP = 19, // Stop (cannot be caught)
    SIGTSTP = 20, // Stop (Ctrl+Z)
    SIGTTIN = 21, // Background read from tty
    SIGTTOU = 22, // Background write to tty
    SIGURG = 23, // Urgent data on socket
    SIGXCPU = 24, // CPU time limit exceeded
    SIGXFSZ = 25, // File size limit exceeded
    SIGVTALRM = 26, // Virtual timer expired
    SIGPROF = 27, // Profiling timer expired
    SIGWINCH = 28, // Window size changed
    SIGIO = 29, // I/O possible
    SIGPWR = 30, // Power failure
    SIGSYS = 31, // Bad system call
};

pub const MAX_SIGNALS = 32;

// ============================================================================
// Signal Actions
// ============================================================================

pub const SignalAction = enum(u8) {
    Default,
    Ignore,
    Handle,
    Stop,
    Continue,
    Core, // Core dump
};

pub const SigAction = struct {
    handler: ?*const fn (Signal) void,
    mask: SignalSet,
    flags: u32,

    pub fn init() SigAction {
        return .{
            .handler = null,
            .mask = SignalSet.init(),
            .flags = 0,
        };
    }
};

// Flags for SigAction
pub const SA_NOCLDSTOP = 0x00000001;
pub const SA_NOCLDWAIT = 0x00000002;
pub const SA_SIGINFO = 0x00000004;
pub const SA_ONSTACK = 0x08000000;
pub const SA_RESTART = 0x10000000;
pub const SA_NODEFER = 0x40000000;
pub const SA_RESETHAND = 0x80000000;

// ============================================================================
// Signal Set (Bitset for 32 signals)
// ============================================================================

pub const SignalSet = struct {
    bits: u32,

    pub fn init() SignalSet {
        return .{ .bits = 0 };
    }

    pub fn add(self: *SignalSet, sig: Signal) void {
        const bit = @as(u5, @intCast(@intFromEnum(sig) - 1));
        self.bits |= @as(u32, 1) << bit;
    }

    pub fn remove(self: *SignalSet, sig: Signal) void {
        const bit = @as(u5, @intCast(@intFromEnum(sig) - 1));
        self.bits &= ~(@as(u32, 1) << bit);
    }

    pub fn contains(self: SignalSet, sig: Signal) bool {
        const bit = @as(u5, @intCast(@intFromEnum(sig) - 1));
        return (self.bits & (@as(u32, 1) << bit)) != 0;
    }

    pub fn isEmpty(self: SignalSet) bool {
        return self.bits == 0;
    }

    pub fn clear(self: *SignalSet) void {
        self.bits = 0;
    }

    pub fn fill(self: *SignalSet) void {
        self.bits = 0xFFFFFFFF;
    }

    pub fn merge(self: *SignalSet, other: SignalSet) void {
        self.bits |= other.bits;
    }

    pub fn intersect(self: *SignalSet, other: SignalSet) SignalSet {
        return .{ .bits = self.bits & other.bits };
    }

    pub fn firstSignal(self: SignalSet) ?Signal {
        if (self.bits == 0) return null;
        const first_bit = @ctz(self.bits);
        return @enumFromInt(first_bit + 1);
    }
};

// ============================================================================
// Signal Information
// ============================================================================

pub const SigInfo = struct {
    signal: Signal,
    code: i32,
    errno: i32,
    pid: u32,
    uid: u32,
    addr: ?*anyopaque,
    value: usize,

    pub fn init(sig: Signal) SigInfo {
        return .{
            .signal = sig,
            .code = 0,
            .errno = 0,
            .pid = 0,
            .uid = 0,
            .addr = null,
            .value = 0,
        };
    }
};

// ============================================================================
// Process Signal State
// ============================================================================

pub const SignalQueue = struct {
    pending: SignalSet,
    blocked: SignalSet,
    actions: [MAX_SIGNALS]SigAction,
    lock: sync.Spinlock,
    info_queue: Basics.ArrayList(SigInfo),

    pub fn init(allocator: Basics.Allocator) !SignalQueue {
        var result = SignalQueue{
            .pending = SignalSet.init(),
            .blocked = SignalSet.init(),
            .actions = undefined,
            .lock = sync.Spinlock.init(),
            .info_queue = Basics.ArrayList(SigInfo).init(allocator),
        };

        // Initialize all actions to default
        for (&result.actions) |*action| {
            action.* = SigAction.init();
        }

        return result;
    }

    pub fn deinit(self: *SignalQueue) void {
        self.info_queue.deinit();
    }

    /// Queue a signal for delivery
    pub fn queue(self: *SignalQueue, sig: Signal, info: SigInfo) !void {
        self.lock.acquire();
        defer self.lock.release();

        // Cannot block SIGKILL or SIGSTOP
        if (sig == .SIGKILL or sig == .SIGSTOP) {
            self.pending.add(sig);
            try self.info_queue.append(info);
            return;
        }

        // Check if signal is blocked
        if (!self.blocked.contains(sig)) {
            self.pending.add(sig);
            try self.info_queue.append(info);
        }
    }

    /// Get the next pending signal
    pub fn dequeue(self: *SignalQueue) ?SigInfo {
        self.lock.acquire();
        defer self.lock.release();

        // Get unblocked pending signals
        const deliverable = self.pending.intersect(SignalSet{ .bits = ~self.blocked.bits });
        if (deliverable.isEmpty()) return null;

        const sig = deliverable.firstSignal() orelse return null;
        self.pending.remove(sig);

        // Find and remove the corresponding SigInfo
        for (self.info_queue.items, 0..) |info, i| {
            if (info.signal == sig) {
                _ = self.info_queue.orderedRemove(i);
                return info;
            }
        }

        return SigInfo.init(sig);
    }

    /// Set signal action
    pub fn setAction(self: *SignalQueue, sig: Signal, action: SigAction) void {
        self.lock.acquire();
        defer self.lock.release();

        const idx = @intFromEnum(sig) - 1;
        self.actions[idx] = action;
    }

    /// Get signal action
    pub fn getAction(self: *SignalQueue, sig: Signal) SigAction {
        self.lock.acquire();
        defer self.lock.release();

        const idx = @intFromEnum(sig) - 1;
        return self.actions[idx];
    }

    /// Block signals
    pub fn block(self: *SignalQueue, mask: SignalSet) void {
        self.lock.acquire();
        defer self.lock.release();

        self.blocked.merge(mask);
    }

    /// Unblock signals
    pub fn unblock(self: *SignalQueue, mask: SignalSet) void {
        self.lock.acquire();
        defer self.lock.release();

        self.blocked.bits &= ~mask.bits;
    }

    /// Check if signals are pending
    pub fn hasPending(self: *SignalQueue) bool {
        self.lock.acquire();
        defer self.lock.release();

        const deliverable = self.pending.intersect(SignalSet{ .bits = ~self.blocked.bits });
        return !deliverable.isEmpty();
    }

    /// Reset all signal handlers to default (used by exec)
    pub fn resetHandlersToDefault(self: *SignalQueue) void {
        self.lock.acquire();
        defer self.lock.release();

        for (&self.actions) |*action| {
            action.* = SigAction.init();
        }
    }

    /// Clear all signal masks (used by exec)
    pub fn clearMasks(self: *SignalQueue) void {
        self.lock.acquire();
        defer self.lock.release();

        self.blocked.clear();
    }

    /// Clear pending signals (used by exec)
    pub fn clearPending(self: *SignalQueue) void {
        self.lock.acquire();
        defer self.lock.release();

        self.pending.clear();
        self.info_queue.clearRetainingCapacity();
    }

    /// Full reset for exec (reset handlers, clear masks, but keep pending)
    pub fn resetForExec(self: *SignalQueue) void {
        self.lock.acquire();
        defer self.lock.release();

        // Reset all handlers to default
        for (&self.actions) |*action| {
            action.* = SigAction.init();
        }

        // Clear signal masks
        self.blocked.clear();
    }
};

// ============================================================================
// Signal Delivery
// ============================================================================

/// Send signal to a process
pub fn sendSignal(proc: *process.Process, sig: Signal, info: SigInfo) !void {
    try proc.signals.queue(sig, info);

    // Wake up the process if it's sleeping
    if (proc.state == .Sleeping) {
        proc.state = .Ready;
        // Add main thread to scheduler run queue
        const sched = @import("sched.zig");
        if (proc.main_thread) |main_thr| {
            sched.addThread(main_thr);
        }
    }
}

/// Send signal to a thread
pub fn sendSignalToThread(thr: *thread.Thread, sig: Signal, info: SigInfo) !void {
    const proc = thr.process orelse return error.NoProcess;
    try proc.signals.queue(sig, info);

    // Wake up the thread if it's sleeping
    if (thr.state == .Sleeping) {
        thr.state = .Ready;
        // Add thread to scheduler run queue
        const sched = @import("sched.zig");
        sched.addThread(thr);
    }
}

/// Handle pending signals for current thread
pub fn handlePendingSignals() void {
    const current = thread.current() orelse return;
    const proc = current.process orelse return;

    while (proc.signals.dequeue()) |info| {
        deliverSignal(current, info);
    }
}

/// Deliver a signal to a thread
fn deliverSignal(thr: *thread.Thread, info: SigInfo) void {
    const proc = thr.process orelse return;
    const action = proc.signals.getAction(info.signal);

    if (action.handler) |handler| {
        // Call user-space signal handler
        setupSignalFrame(thr, handler, info);
    } else {
        // Default action
        switch (getDefaultAction(info.signal)) {
            .Default => handleDefaultAction(proc, info.signal),
            .Ignore => {},
            .Stop => stopProcess(proc),
            .Continue => continueProcess(proc),
            .Core => coreDump(proc, info.signal),
            .Handle => {},
        }
    }
}

/// Get default action for a signal
fn getDefaultAction(sig: Signal) SignalAction {
    return switch (sig) {
        .SIGCHLD, .SIGURG, .SIGWINCH => .Ignore,
        .SIGSTOP, .SIGTSTP, .SIGTTIN, .SIGTTOU => .Stop,
        .SIGCONT => .Continue,
        .SIGQUIT, .SIGILL, .SIGTRAP, .SIGABRT, .SIGBUS, .SIGFPE, .SIGSEGV, .SIGSYS => .Core,
        else => .Default,
    };
}

/// Handle default termination action
fn handleDefaultAction(proc: *process.Process, sig: Signal) void {
    // Terminate the process
    proc.state = .Zombie;
    proc.exit_code = 128 + @as(i32, @intFromEnum(sig));
}

/// Stop a process
fn stopProcess(proc: *process.Process) void {
    proc.state = .Stopped;
    // Notify parent with SIGCHLD
    notifyParentChildStatusChanged(proc, .Stopped);
}

/// Send SIGCHLD to parent process when child status changes
pub fn notifyParentChildStatusChanged(child: *process.Process, reason: enum { Exited, Stopped, Continued }) void {
    // Find parent process
    const parent = process.findProcess(child.ppid) orelse return;

    // Create SigInfo for SIGCHLD
    var info = SigInfo.init(.SIGCHLD);
    info.pid = child.pid;
    info.uid = child.uid;

    // Set code based on reason
    info.code = switch (reason) {
        .Exited => 1, // CLD_EXITED
        .Stopped => 5, // CLD_STOPPED
        .Continued => 6, // CLD_CONTINUED
    };

    // Set exit status as value for exited processes
    if (reason == .Exited) {
        info.value = @as(usize, @intCast(child.exit_code));
    }

    // Queue the signal
    sendSignal(parent, .SIGCHLD, info) catch {};
}

/// Continue a stopped process
fn continueProcess(proc: *process.Process) void {
    if (proc.state == .Stopped) {
        proc.state = .Ready;
        // Add main thread to scheduler run queue
        const sched = @import("sched.zig");
        if (proc.main_thread) |main_thr| {
            sched.addThread(main_thr);
        }
    }
}

/// Generate core dump
fn coreDump(proc: *process.Process, sig: Signal) void {
    // Core dump implementation:
    // In a full implementation, this would write the process memory to a file
    // named "core" or "core.<pid>" in the current working directory.
    // For now, we just set the exit status to indicate the signal.
    //
    // Core file format (ELF core dump):
    // - ELF header with ET_CORE type
    // - PT_NOTE segment with process info, registers
    // - PT_LOAD segments for each memory region
    //
    // For embedded/minimal systems, core dumps may not be needed.

    proc.state = .Zombie;
    proc.exit_code = 128 + @as(i32, @intFromEnum(sig));
}

/// Setup signal handler frame on user stack
fn setupSignalFrame(thr: *thread.Thread, handler: *const fn (Signal) void, info: SigInfo) void {
    // Architecture-specific signal frame setup for x86_64:
    // 1. Save current thread context (RIP, RSP, registers) to ucontext_t
    // 2. Push signal info (siginfo_t) onto user stack
    // 3. Push saved context (ucontext_t) onto user stack
    // 4. Setup return address to point to sigreturn trampoline
    // 5. Set RIP to handler address
    // 6. Set RSP to new stack pointer
    //
    // The sigreturn trampoline typically looks like:
    //   mov rax, SYS_rt_sigreturn
    //   syscall
    //
    // This allows the handler to return and restore original context.

    // For now, skip frame setup as this requires user-space memory mapping
    // When implemented, use thr.context to save/restore registers
    _ = thr;
    _ = handler;
    _ = info;
}

// ============================================================================
// System Call Interface
// ============================================================================

/// sys_kill - Send signal to a process
pub fn sysKill(pid: i32, sig: i32) !void {
    if (sig < 0 or sig >= MAX_SIGNALS) return error.InvalidSignal;

    const signal: Signal = @enumFromInt(@as(u8, @intCast(sig)));
    const target_pid: u32 = @intCast(pid);

    const proc = process.findById(target_pid) orelse return error.NoSuchProcess;
    var info = SigInfo.init(signal);
    info.pid = process.current().?.pid;

    try sendSignal(proc, signal, info);
}

/// sys_sigaction - Set signal action
pub fn sysSigaction(sig: i32, act: ?*const SigAction, oldact: ?*SigAction) !void {
    if (sig < 1 or sig >= MAX_SIGNALS) return error.InvalidSignal;
    if (sig == @intFromEnum(Signal.SIGKILL) or sig == @intFromEnum(Signal.SIGSTOP)) {
        return error.CannotCatch;
    }

    const signal: Signal = @enumFromInt(@as(u8, @intCast(sig)));
    const proc = process.current() orelse return error.NoProcess;

    // Save old action if requested
    if (oldact) |old| {
        old.* = proc.signals.getAction(signal);
    }

    // Set new action if provided
    if (act) |new| {
        proc.signals.setAction(signal, new.*);
    }
}

/// sys_sigprocmask - Change signal mask
pub fn sysSigprocmask(how: i32, set: ?*const SignalSet, oldset: ?*SignalSet) !void {
    const proc = process.current() orelse return error.NoProcess;

    // Save old mask if requested
    if (oldset) |old| {
        old.* = proc.signals.blocked;
    }

    // Update mask if set is provided
    if (set) |new| {
        switch (how) {
            0 => proc.signals.blocked = new.*, // SIG_SETMASK
            1 => proc.signals.block(new.*), // SIG_BLOCK
            2 => proc.signals.unblock(new.*), // SIG_UNBLOCK
            else => return error.InvalidArgument,
        }
    }
}

/// sys_sigpending - Get pending signals
pub fn sysSigpending(set: *SignalSet) !void {
    const proc = process.current() orelse return error.NoProcess;
    set.* = proc.signals.pending;
}

// ============================================================================
// Tests
// ============================================================================

test "signal set operations" {
    var set = SignalSet.init();
    try Basics.testing.expect(set.isEmpty());

    set.add(.SIGINT);
    try Basics.testing.expect(set.contains(.SIGINT));
    try Basics.testing.expect(!set.contains(.SIGTERM));

    set.add(.SIGTERM);
    try Basics.testing.expect(set.contains(.SIGTERM));

    set.remove(.SIGINT);
    try Basics.testing.expect(!set.contains(.SIGINT));
    try Basics.testing.expect(set.contains(.SIGTERM));
}

test "signal queue" {
    var queue = try SignalQueue.init(Basics.testing.allocator);
    defer queue.deinit();

    const info = SigInfo.init(.SIGINT);
    try queue.queue(.SIGINT, info);

    try Basics.testing.expect(queue.hasPending());

    const dequeued = queue.dequeue();
    try Basics.testing.expect(dequeued != null);
    try Basics.testing.expectEqual(Signal.SIGINT, dequeued.?.signal);
}

test "signal blocking" {
    var queue = try SignalQueue.init(Basics.testing.allocator);
    defer queue.deinit();

    var mask = SignalSet.init();
    mask.add(.SIGTERM);
    queue.block(mask);

    const info = SigInfo.init(.SIGTERM);
    try queue.queue(.SIGTERM, info);

    // Signal is pending but blocked
    try Basics.testing.expect(!queue.hasPending());

    // Unblock it
    queue.unblock(mask);
    try Basics.testing.expect(queue.hasPending());
}
