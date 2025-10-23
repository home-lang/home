const std = @import("std");
const async_runtime = @import("async_runtime.zig");
const executor = @import("executor.zig");

/// Async I/O reactor using epoll (Linux) or kqueue (BSD/macOS)
pub const IoReactor = struct {
    allocator: std.mem.Allocator,
    poll_fd: std.posix.fd_t,
    events: std.ArrayList(Event),
    registrations: std.AutoHashMap(std.posix.fd_t, Registration),
    running: bool,

    const MAX_EVENTS = 1024;

    pub fn init(allocator: std.mem.Allocator) !IoReactor {
        const poll_fd = if (std.Target.current.os.tag == .linux)
            try std.posix.epoll_create1(0)
        else if (std.Target.current.os.tag == .macos)
            try std.posix.kqueue()
        else
            return error.UnsupportedPlatform;

        return .{
            .allocator = allocator,
            .poll_fd = poll_fd,
            .events = std.ArrayList(Event).init(allocator),
            .registrations = std.AutoHashMap(std.posix.fd_t, Registration).init(allocator),
            .running = false,
        };
    }

    pub fn deinit(self: *IoReactor) void {
        std.posix.close(self.poll_fd);
        self.events.deinit();
        self.registrations.deinit();
    }

    /// Register a file descriptor for I/O events
    pub fn register(self: *IoReactor, fd: std.posix.fd_t, interests: Interests, waker: async_runtime.Waker) !void {
        if (std.Target.current.os.tag == .linux) {
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
        } else if (std.Target.current.os.tag == .macos) {
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
        }

        try self.registrations.put(fd, .{
            .interests = interests,
            .waker = waker,
        });
    }

    /// Deregister a file descriptor
    pub fn deregister(self: *IoReactor, fd: std.posix.fd_t) !void {
        if (std.Target.current.os.tag == .linux) {
            try std.posix.epoll_ctl(
                self.poll_fd,
                std.os.linux.EPOLL.CTL_DEL,
                fd,
                null,
            );
        } else if (std.Target.current.os.tag == .macos) {
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
        }

        _ = self.registrations.remove(fd);
    }

    /// Poll for I/O events
    pub fn poll(self: *IoReactor, timeout_ms: ?i32) !usize {
        var ready_count: usize = 0;

        if (std.Target.current.os.tag == .linux) {
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
        } else if (std.Target.current.os.tag == .macos) {
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
    fd: std.posix.fd_t,
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
    fd: std.posix.fd_t,
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
                    std.time.sleep(10_000_000); // 10ms
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
    fd: std.posix.fd_t,
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
                    std.time.sleep(10_000_000); // 10ms
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
                    std.time.sleep(10_000_000); // 10ms
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
    fd: std.posix.fd_t,
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
                    std.time.sleep(10_000_000);
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
                    std.time.sleep(10_000_000);
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
