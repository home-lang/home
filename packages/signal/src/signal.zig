// Home Programming Language - Signal Handling
// Cross-platform signal handling with handlers and masking

const std = @import("std");
const builtin = @import("builtin");

/// Signal types (POSIX signals)
pub const Signal = enum(i32) {
    SIGHUP = 1, // Hangup
    SIGINT = 2, // Interrupt (Ctrl+C)
    SIGQUIT = 3, // Quit
    SIGILL = 4, // Illegal instruction
    SIGTRAP = 5, // Trace trap
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
    SIGCHLD = 17, // Child status changed
    SIGCONT = 18, // Continue
    SIGSTOP = 19, // Stop (cannot be caught)
    SIGTSTP = 20, // Stop typed at terminal
    SIGTTIN = 21, // Background read from tty
    SIGTTOU = 22, // Background write to tty
    SIGURG = 23, // Urgent condition on socket
    SIGXCPU = 24, // CPU time limit exceeded
    SIGXFSZ = 25, // File size limit exceeded
    SIGVTALRM = 26, // Virtual alarm clock
    SIGPROF = 27, // Profiling alarm clock
    SIGWINCH = 28, // Window size change
    SIGIO = 29, // I/O now possible
    SIGPWR = 30, // Power failure

    pub fn toInt(self: Signal) i32 {
        return @intFromEnum(self);
    }

    pub fn fromInt(value: i32) ?Signal {
        inline for (@typeInfo(Signal).@"enum".fields) |field| {
            if (value == field.value) return @enumFromInt(value);
        }
        return null;
    }

    /// Get human-readable signal name
    pub fn name(self: Signal) []const u8 {
        return switch (self) {
            .SIGHUP => "SIGHUP",
            .SIGINT => "SIGINT",
            .SIGQUIT => "SIGQUIT",
            .SIGILL => "SIGILL",
            .SIGTRAP => "SIGTRAP",
            .SIGABRT => "SIGABRT",
            .SIGBUS => "SIGBUS",
            .SIGFPE => "SIGFPE",
            .SIGKILL => "SIGKILL",
            .SIGUSR1 => "SIGUSR1",
            .SIGSEGV => "SIGSEGV",
            .SIGUSR2 => "SIGUSR2",
            .SIGPIPE => "SIGPIPE",
            .SIGALRM => "SIGALRM",
            .SIGTERM => "SIGTERM",
            .SIGCHLD => "SIGCHLD",
            .SIGCONT => "SIGCONT",
            .SIGSTOP => "SIGSTOP",
            .SIGTSTP => "SIGTSTP",
            .SIGTTIN => "SIGTTIN",
            .SIGTTOU => "SIGTTOU",
            .SIGURG => "SIGURG",
            .SIGXCPU => "SIGXCPU",
            .SIGXFSZ => "SIGXFSZ",
            .SIGVTALRM => "SIGVTALRM",
            .SIGPROF => "SIGPROF",
            .SIGWINCH => "SIGWINCH",
            .SIGIO => "SIGIO",
            .SIGPWR => "SIGPWR",
        };
    }
};

/// Signal handler function type
pub const Handler = *const fn (signal: Signal) void;

/// Default signal actions
pub const Action = enum {
    default, // Default action (usually terminate)
    ignore, // Ignore the signal
    handler, // Call custom handler
};

// Signal handler storage
var handlers: [32]?Handler = [_]?Handler{null} ** 32;
var original_handlers: [32]?*const anyopaque = [_]?*const anyopaque{null} ** 32;

/// Send a signal to a process
pub fn kill(pid: std.posix.pid_t, sig: Signal) !void {
    if (builtin.os.tag == .windows) {
        return error.OperationNotSupported;
    }

    try std.posix.kill(pid, sig.toInt());
}

/// Send a signal to the current process
pub fn raise(sig: Signal) !void {
    if (builtin.os.tag == .windows) {
        return error.OperationNotSupported;
    }

    const c = struct {
        extern "c" fn raise(c_int) c_int;
    };

    const result = c.raise(@intCast(sig.toInt()));
    if (result != 0) {
        return error.RaiseFailed;
    }
}

/// Set a signal handler (Unix-only)
pub fn setHandler(sig: Signal, handler: Handler) !void {
    if (builtin.os.tag == .windows) {
        return error.OperationNotSupported;
    }

    const sig_num = sig.toInt();
    if (sig_num < 0 or sig_num >= 32) {
        return error.InvalidSignal;
    }

    // Store the handler
    handlers[@intCast(sig_num)] = handler;

    // Create signal action
    const c = struct {
        extern "c" fn signal(c_int, ?*const anyopaque) ?*const anyopaque;
    };

    const wrapper = struct {
        fn handleSignal(s: c_int) callconv(.C) void {
            const signal = Signal.fromInt(s) orelse return;
            if (handlers[@intCast(s)]) |h| {
                h(signal);
            }
        }
    }.handleSignal;

    const old_handler = c.signal(@intCast(sig_num), @ptrCast(&wrapper));
    original_handlers[@intCast(sig_num)] = old_handler;
}

/// Reset signal to default handler
pub fn resetHandler(sig: Signal) !void {
    if (builtin.os.tag == .windows) {
        return error.OperationNotSupported;
    }

    const sig_num = sig.toInt();
    if (sig_num < 0 or sig_num >= 32) {
        return error.InvalidSignal;
    }

    handlers[@intCast(sig_num)] = null;

    const c = struct {
        extern "c" fn signal(c_int, ?*const anyopaque) ?*const anyopaque;
        const SIG_DFL: ?*const anyopaque = null;
    };

    _ = c.signal(@intCast(sig_num), c.SIG_DFL);
}

/// Ignore a signal
pub fn ignore(sig: Signal) !void {
    if (builtin.os.tag == .windows) {
        return error.OperationNotSupported;
    }

    const sig_num = sig.toInt();
    if (sig_num < 0 or sig_num >= 32) {
        return error.InvalidSignal;
    }

    const c = struct {
        extern "c" fn signal(c_int, ?*const anyopaque) ?*const anyopaque;
        const SIG_IGN: *const anyopaque = @ptrFromInt(1);
    };

    _ = c.signal(@intCast(sig_num), c.SIG_IGN);
}

/// Block a signal (add to signal mask)
pub fn block(sig: Signal) !void {
    if (builtin.os.tag == .windows) {
        return error.OperationNotSupported;
    }

    const c = struct {
        extern "c" fn sigprocmask(c_int, ?*const anyopaque, ?*anyopaque) c_int;
        extern "c" fn sigemptyset(*anyopaque) c_int;
        extern "c" fn sigaddset(*anyopaque, c_int) c_int;
        const SIG_BLOCK: c_int = 0;
    };

    var set: [128]u8 = undefined;
    _ = c.sigemptyset(&set);
    _ = c.sigaddset(&set, @intCast(sig.toInt()));

    const result = c.sigprocmask(c.SIG_BLOCK, &set, null);
    if (result != 0) {
        return error.BlockFailed;
    }
}

/// Unblock a signal (remove from signal mask)
pub fn unblock(sig: Signal) !void {
    if (builtin.os.tag == .windows) {
        return error.OperationNotSupported;
    }

    const c = struct {
        extern "c" fn sigprocmask(c_int, ?*const anyopaque, ?*anyopaque) c_int;
        extern "c" fn sigemptyset(*anyopaque) c_int;
        extern "c" fn sigaddset(*anyopaque, c_int) c_int;
        const SIG_UNBLOCK: c_int = 1;
    };

    var set: [128]u8 = undefined;
    _ = c.sigemptyset(&set);
    _ = c.sigaddset(&set, @intCast(sig.toInt()));

    const result = c.sigprocmask(c.SIG_UNBLOCK, &set, null);
    if (result != 0) {
        return error.UnblockFailed;
    }
}

/// Set an alarm to deliver SIGALRM after specified seconds
pub fn alarm(seconds: u32) u32 {
    if (builtin.os.tag == .windows) {
        return 0;
    }

    const c = struct {
        extern "c" fn alarm(c_uint) c_uint;
    };

    return c.alarm(seconds);
}

/// Cancel pending alarm
pub fn cancelAlarm() void {
    _ = alarm(0);
}

/// Signal set for managing multiple signals
pub const SignalSet = struct {
    signals: std.AutoHashMap(i32, void),

    pub fn init(allocator: std.mem.Allocator) SignalSet {
        return .{
            .signals = std.AutoHashMap(i32, void).init(allocator),
        };
    }

    pub fn deinit(self: *SignalSet) void {
        self.signals.deinit();
    }

    pub fn add(self: *SignalSet, sig: Signal) !void {
        try self.signals.put(sig.toInt(), {});
    }

    pub fn remove(self: *SignalSet, sig: Signal) void {
        _ = self.signals.remove(sig.toInt());
    }

    pub fn contains(self: *SignalSet, sig: Signal) bool {
        return self.signals.contains(sig.toInt());
    }

    pub fn clear(self: *SignalSet) void {
        self.signals.clearRetainingCapacity();
    }

    /// Block all signals in this set
    pub fn blockAll(self: *SignalSet) !void {
        var iter = self.signals.keyIterator();
        while (iter.next()) |sig_num| {
            if (Signal.fromInt(sig_num.*)) |sig| {
                try block(sig);
            }
        }
    }

    /// Unblock all signals in this set
    pub fn unblockAll(self: *SignalSet) !void {
        var iter = self.signals.keyIterator();
        while (iter.next()) |sig_num| {
            if (Signal.fromInt(sig_num.*)) |sig| {
                try unblock(sig);
            }
        }
    }
};

test "signal enum" {
    const testing = std.testing;

    try testing.expectEqual(@as(i32, 2), Signal.SIGINT.toInt());
    try testing.expectEqual(@as(i32, 15), Signal.SIGTERM.toInt());

    try testing.expectEqualStrings("SIGINT", Signal.SIGINT.name());
    try testing.expectEqualStrings("SIGTERM", Signal.SIGTERM.name());

    const sig = Signal.fromInt(2);
    try testing.expect(sig != null);
    try testing.expectEqual(Signal.SIGINT, sig.?);
}

test "signal set" {
    const testing = std.testing;

    var set = SignalSet.init(testing.allocator);
    defer set.deinit();

    try set.add(.SIGINT);
    try set.add(.SIGTERM);

    try testing.expect(set.contains(.SIGINT));
    try testing.expect(set.contains(.SIGTERM));
    try testing.expect(!set.contains(.SIGHUP));

    set.remove(.SIGINT);
    try testing.expect(!set.contains(.SIGINT));
    try testing.expect(set.contains(.SIGTERM));
}

test "raise signal to self" {
    // This test is commented out because raising SIGTERM would kill the test process
    // Uncomment only for manual testing
    // try raise(.SIGTERM);
}
