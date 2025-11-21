const std = @import("std");
const builtin = @import("builtin");
const async_runtime = @import("async_runtime.zig");
const executor = @import("executor.zig");

/// Async I/O reactor using epoll (Linux), kqueue (BSD/macOS), or IOCP (Windows)
pub const IoReactor = struct {
    allocator: std.mem.Allocator,
    poll_fd: if (builtin.os.tag == .windows) std.os.windows.HANDLE else std.posix.fd_t,
    events: std.ArrayList(Event),
    registrations: if (builtin.os.tag == .windows)
        std.AutoHashMap(std.os.windows.SOCKET, Registration)
    else
        std.AutoHashMap(std.posix.fd_t, Registration),
    running: bool,

    const MAX_EVENTS = 1024;

    pub fn init(allocator: std.mem.Allocator) !IoReactor {
        const poll_fd = if (builtin.os.tag == .linux)
            try std.posix.epoll_create1(0)
        else if (builtin.os.tag == .macos)
            try std.posix.kqueue()
        else if (builtin.os.tag == .windows)
            try std.os.windows.CreateIoCompletionPort(
                std.os.windows.INVALID_HANDLE_VALUE,
                null,
                0,
                0,
            )
        else
            return error.UnsupportedPlatform;

        return .{
            .allocator = allocator,
            .poll_fd = poll_fd,
            .events = std.ArrayList(Event).init(allocator),
            .registrations = if (builtin.os.tag == .windows)
                std.AutoHashMap(std.os.windows.SOCKET, Registration).init(allocator)
            else
                std.AutoHashMap(std.posix.fd_t, Registration).init(allocator),
            .running = false,
        };
    }

    pub fn deinit(self: *IoReactor) void {
        if (builtin.os.tag == .windows) {
            std.os.windows.CloseHandle(self.poll_fd);
        } else {
            std.posix.close(self.poll_fd);
        }
        self.events.deinit();
        self.registrations.deinit();
    }

    /// Register a file descriptor for I/O events
    pub fn register(self: *IoReactor, fd: if (builtin.os.tag == .windows) std.os.windows.SOCKET else std.posix.fd_t, interests: Interests, waker: async_runtime.Waker) !void {
        if (builtin.os.tag == .linux) {
            var event = std.os.linux.epoll_event{
                .events = 0,
                .data = .{ .fd = @intCast(fd) },
            };

            if (interests.read) event.events |= std.os.linux.EPOLL.IN;
            if (interests.write) event.events |= std.os.linux.EPOLL.OUT;
            event.events |= std.os.linux.EPOLL.ET; // Edge-triggered

            try std.posix.epoll_ctl(
                self.poll_fd,
                std.os.linux.EPOLL.CTL_ADD,
                fd,
                &event,
            );
        } else if (builtin.os.tag == .macos) {
            var changes: [2]std.posix.Kevent = undefined;
            var n_changes: usize = 0;

            if (interests.read) {
                changes[n_changes] = .{
                    .ident = @intCast(fd),
                    .filter = std.posix.system.EVFILT_READ,
                    .flags = std.posix.system.EV_ADD | std.posix.system.EV_ENABLE,
                    .fflags = 0,
                    .data = 0,
                    .udata = 0,
                };
                n_changes += 1;
            }

            if (interests.write) {
                changes[n_changes] = .{
                    .ident = @intCast(fd),
                    .filter = std.posix.system.EVFILT_WRITE,
                    .flags = std.posix.system.EV_ADD | std.posix.system.EV_ENABLE,
                    .fflags = 0,
                    .data = 0,
                    .udata = 0,
                };
                n_changes += 1;
            }

            _ = try std.posix.kevent(self.poll_fd, changes[0..n_changes], &[_]std.posix.Kevent{}, null);
        } else if (builtin.os.tag == .windows) {
            // On Windows, associate the socket with the IOCP
            _ = try std.os.windows.CreateIoCompletionPort(
                @ptrFromInt(@as(usize, @intCast(fd))),
                self.poll_fd,
                fd,
                0,
            );
        }

        try self.registrations.put(fd, .{
            .interests = interests,
            .waker = waker,
        });
    }

    /// Deregister a file descriptor
    pub fn deregister(self: *IoReactor, fd: if (builtin.os.tag == .windows) std.os.windows.SOCKET else std.posix.fd_t) !void {
        if (builtin.os.tag == .linux) {
            try std.posix.epoll_ctl(
                self.poll_fd,
                std.os.linux.EPOLL.CTL_DEL,
                fd,
                null,
            );
        } else if (builtin.os.tag == .macos) {
            var changes = [_]std.posix.Kevent{
                .{
                    .ident = @intCast(fd),
                    .filter = std.posix.system.EVFILT_READ,
                    .flags = std.posix.system.EV_DELETE,
                    .fflags = 0,
                    .data = 0,
                    .udata = 0,
                },
                .{
                    .ident = @intCast(fd),
                    .filter = std.posix.system.EVFILT_WRITE,
                    .flags = std.posix.system.EV_DELETE,
                    .fflags = 0,
                    .data = 0,
                    .udata = 0,
                },
            };

            _ = try std.posix.kevent(self.poll_fd, &changes, &[_]std.posix.Kevent{}, null);
        } else if (builtin.os.tag == .windows) {
            // On Windows, IOCP doesn't need explicit deregistration
            // The socket will be removed when closed
        }

        _ = self.registrations.remove(fd);
    }

    /// Poll for I/O events
    pub fn poll(self: *IoReactor, timeout_ms: ?i32) !usize {
        var ready_count: usize = 0;

        if (builtin.os.tag == .linux) {
            var events: [MAX_EVENTS]std.os.linux.epoll_event = undefined;

            const n = std.posix.epoll_wait(
                self.poll_fd,
                &events,
                timeout_ms orelse -1,
            );

            for (events[0..n]) |event| {
                const fd: std.posix.fd_t = @intCast(event.data.fd);

                if (self.registrations.get(fd)) |registration| {
                    if ((event.events & std.os.linux.EPOLL.IN) != 0 or
                        (event.events & std.os.linux.EPOLL.OUT) != 0)
                    {
                        registration.waker.wake();
                        ready_count += 1;
                    }
                }
            }
        } else if (builtin.os.tag == .macos) {
            var events: [MAX_EVENTS]std.posix.Kevent = undefined;

            const timespec = if (timeout_ms) |ms| std.posix.timespec{
                .tv_sec = @divTrunc(ms, 1000),
                .tv_nsec = @rem(ms, 1000) * 1_000_000,
            } else null;

            const n = try std.posix.kevent(
                self.poll_fd,
                &[_]std.posix.Kevent{},
                &events,
                if (timespec) |*ts| ts else null,
            );

            for (events[0..n]) |event| {
                const fd: std.posix.fd_t = @intCast(event.ident);

                if (self.registrations.get(fd)) |registration| {
                    registration.waker.wake();
                    ready_count += 1;
                }
            }
        } else if (builtin.os.tag == .windows) {
            // Windows IOCP implementation
            var overlapped_entries: [MAX_EVENTS]std.os.windows.OVERLAPPED_ENTRY = undefined;
            var num_entries: u32 = 0;

            const timeout: u32 = if (timeout_ms) |ms| @intCast(ms) else std.os.windows.INFINITE;

            const result = std.os.windows.kernel32.GetQueuedCompletionStatusEx(
                self.poll_fd,
                &overlapped_entries,
                MAX_EVENTS,
                &num_entries,
                timeout,
                std.os.windows.FALSE,
            );

            if (result == std.os.windows.FALSE) {
                const err = std.os.windows.kernel32.GetLastError();
                if (err == .WAIT_TIMEOUT) {
                    return 0;
                }
                return error.WindowsIOCPError;
            }

            for (overlapped_entries[0..num_entries]) |entry| {
                const socket: std.os.windows.SOCKET = @intCast(entry.lpCompletionKey);

                if (self.registrations.get(socket)) |registration| {
                    registration.waker.wake();
                    ready_count += 1;
                }
            }
        }

        return ready_count;
    }

    /// Run the reactor event loop
    pub fn run(self: *IoReactor) !void {
        self.running = true;

        while (self.running) {
            _ = try self.poll(100); // 100ms timeout
        }
    }

    pub fn stop(self: *IoReactor) void {
        self.running = false;
    }
};

pub const Event = struct {
    fd: if (builtin.os.tag == .windows) std.os.windows.SOCKET else std.posix.fd_t,
    readable: bool,
    writable: bool,
};

pub const Interests = struct {
    read: bool = false,
    write: bool = false,
};

pub const Registration = struct {
    interests: Interests,
    waker: async_runtime.Waker,
};

/// Async TCP listener
pub const TcpListener = struct {
    fd: if (builtin.os.tag == .windows) std.os.windows.SOCKET else std.posix.fd_t,
    reactor: *IoReactor,

    pub fn bind(allocator: std.mem.Allocator, address: std.net.Address, reactor: *IoReactor) !TcpListener {
        _ = allocator;

        const fd = try std.posix.socket(
            address.any.family,
            std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
            std.posix.IPPROTO.TCP,
        );
        errdefer std.posix.close(fd);

        // Set SO_REUSEADDR
        try std.posix.setsockopt(
            fd,
            std.posix.SOL.SOCKET,
            std.posix.SO.REUSEADDR,
            &std.mem.toBytes(@as(c_int, 1)),
        );

        // Bind
        try std.posix.bind(fd, &address.any, address.getOsSockLen());

        // Listen
        try std.posix.listen(fd, 128);

        // Set non-blocking
        const flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
        _ = try std.posix.fcntl(fd, std.posix.F.SETFL, flags | std.posix.O.NONBLOCK);

        return .{
            .fd = fd,
            .reactor = reactor,
        };
    }

    pub fn accept(self: *TcpListener) !TcpStream {
        while (true) {
            const result = std.posix.accept(
                self.fd,
                null,
                null,
                std.posix.SOCK.CLOEXEC,
            ) catch |err| {
                if (err == error.WouldBlock) {
                    // Register for read events and yield
                    const waker = async_runtime.Waker{
                        .wake_fn = wakeCallback,
                        .data = null,
                    };

                    try self.reactor.register(self.fd, .{ .read = true }, waker);

                    // In full implementation, this would yield to runtime
                    std.posix.nanosleep(0, 10_000_000); // 10ms
                    continue;
                }
                return err;
            };

            // Set accepted socket to non-blocking
            const flags = try std.posix.fcntl(result, std.posix.F.GETFL, 0);
            _ = try std.posix.fcntl(result, std.posix.F.SETFL, flags | std.posix.O.NONBLOCK);

            return TcpStream{
                .fd = result,
                .reactor = self.reactor,
            };
        }
    }

    pub fn close(self: *TcpListener) void {
        self.reactor.deregister(self.fd) catch {};
        std.posix.close(self.fd);
    }
};

/// Async TCP stream
pub const TcpStream = struct {
    fd: if (builtin.os.tag == .windows) std.os.windows.SOCKET else std.posix.fd_t,
    reactor: *IoReactor,

    pub fn connect(allocator: std.mem.Allocator, address: std.net.Address, reactor: *IoReactor) !TcpStream {
        _ = allocator;

        const fd = try std.posix.socket(
            address.any.family,
            std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
            std.posix.IPPROTO.TCP,
        );
        errdefer std.posix.close(fd);

        // Set non-blocking
        const flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
        _ = try std.posix.fcntl(fd, std.posix.F.SETFL, flags | std.posix.O.NONBLOCK);

        // Connect
        std.posix.connect(fd, &address.any, address.getOsSockLen()) catch |err| {
            if (err != error.WouldBlock) {
                return err;
            }
        };

        // Register for write events to detect connection completion
        const waker = async_runtime.Waker{
            .wake_fn = wakeCallback,
            .data = null,
        };

        try reactor.register(fd, .{ .write = true }, waker);

        return .{
            .fd = fd,
            .reactor = reactor,
        };
    }

    pub fn read(self: *TcpStream, buffer: []u8) !usize {
        while (true) {
            const n = std.posix.read(self.fd, buffer) catch |err| {
                if (err == error.WouldBlock) {
                    // Register for read events and yield
                    const waker = async_runtime.Waker{
                        .wake_fn = wakeCallback,
                        .data = null,
                    };

                    try self.reactor.register(self.fd, .{ .read = true }, waker);

                    // In full implementation, this would yield to runtime
                    std.posix.nanosleep(0, 10_000_000); // 10ms
                    continue;
                }
                return err;
            };

            return n;
        }
    }

    pub fn write(self: *TcpStream, buffer: []const u8) !usize {
        while (true) {
            const n = std.posix.write(self.fd, buffer) catch |err| {
                if (err == error.WouldBlock) {
                    // Register for write events and yield
                    const waker = async_runtime.Waker{
                        .wake_fn = wakeCallback,
                        .data = null,
                    };

                    try self.reactor.register(self.fd, .{ .write = true }, waker);

                    // In full implementation, this would yield to runtime
                    std.posix.nanosleep(0, 10_000_000); // 10ms
                    continue;
                }
                return err;
            };

            return n;
        }
    }

    pub fn close(self: *TcpStream) void {
        self.reactor.deregister(self.fd) catch {};
        std.posix.close(self.fd);
    }
};

fn wakeCallback(waker: *async_runtime.Waker) void {
    _ = waker;
    // In full implementation, this would wake the task
}

/// Async file operations
pub const File = struct {
    fd: if (builtin.os.tag == .windows) std.os.windows.HANDLE else std.posix.fd_t,
    reactor: *IoReactor,

    pub fn open(path: []const u8, flags: std.fs.File.OpenFlags, reactor: *IoReactor) !File {
        const fd = try std.fs.cwd().openFile(path, flags);

        // Set non-blocking
        const fl = try std.posix.fcntl(fd.handle, std.posix.F.GETFL, 0);
        _ = try std.posix.fcntl(fd.handle, std.posix.F.SETFL, fl | std.posix.O.NONBLOCK);

        return .{
            .fd = fd.handle,
            .reactor = reactor,
        };
    }

    pub fn read(self: *File, buffer: []u8) !usize {
        while (true) {
            const n = std.posix.read(self.fd, buffer) catch |err| {
                if (err == error.WouldBlock) {
                    const waker = async_runtime.Waker{
                        .wake_fn = wakeCallback,
                        .data = null,
                    };

                    try self.reactor.register(self.fd, .{ .read = true }, waker);
                    std.posix.nanosleep(0, 10_000_000);
                    continue;
                }
                return err;
            };

            return n;
        }
    }

    pub fn write(self: *File, buffer: []const u8) !usize {
        while (true) {
            const n = std.posix.write(self.fd, buffer) catch |err| {
                if (err == error.WouldBlock) {
                    const waker = async_runtime.Waker{
                        .wake_fn = wakeCallback,
                        .data = null,
                    };

                    try self.reactor.register(self.fd, .{ .write = true }, waker);
                    std.posix.nanosleep(0, 10_000_000);
                    continue;
                }
                return err;
            };

            return n;
        }
    }

    pub fn close(self: *File) void {
        self.reactor.deregister(self.fd) catch {};
        std.posix.close(self.fd);
    }
};

/// Async timer
pub const Timer = struct {
    deadline: i64,
    waker: ?async_runtime.Waker,

    pub fn init(duration_ms: u64) Timer {
        const now = std.time.milliTimestamp();
        return .{
            .deadline = now + @as(i64, @intCast(duration_ms)),
            .waker = null,
        };
    }

    pub fn poll(self: *Timer) bool {
        const now = std.time.milliTimestamp();
        return now >= self.deadline;
    }

    pub fn setWaker(self: *Timer, waker: async_runtime.Waker) void {
        self.waker = waker;
    }
};
