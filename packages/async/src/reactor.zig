const std = @import("std");
const builtin = @import("builtin");
const Waker = @import("future.zig").Waker;

/// Interest flags for I/O events
pub const Interest = packed struct {
    readable: bool = false,
    writable: bool = false,
    error_events: bool = false,
    hangup: bool = false,
};

/// I/O event from the reactor
pub const Event = struct {
    fd: std.os.fd_t,
    interest: Interest,
};

/// Platform-specific reactor for I/O multiplexing
///
/// Provides a uniform interface across:
/// - Linux: epoll
/// - macOS/BSD: kqueue
/// - Windows: IOCP
pub const Reactor = switch (builtin.os.tag) {
    .linux => EpollReactor,
    .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .openbsd, .dragonfly => KqueueReactor,
    .windows => IOCPReactor,
    else => @compileError("Unsupported platform for async I/O"),
};

// =================================================================================
//                            Linux - epoll
// =================================================================================

const EpollReactor = struct {
    epoll_fd: i32,
    events: []std.os.linux.epoll_event,
    registry: std.AutoHashMap(i32, *Waker),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !EpollReactor {
        const epoll_fd = try std.os.epoll_create1(std.os.linux.EPOLL.CLOEXEC);

        return EpollReactor{
            .epoll_fd = epoll_fd,
            .events = try allocator.alloc(std.os.linux.epoll_event, 1024),
            .registry = std.AutoHashMap(i32, *Waker).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *EpollReactor) void {
        std.os.close(self.epoll_fd);
        self.allocator.free(self.events);

        // Free all wakers
        var iter = self.registry.valueIterator();
        while (iter.next()) |waker| {
            waker.*.drop();
        }

        self.registry.deinit();
    }

    /// Register a file descriptor with the reactor
    pub fn register(self: *EpollReactor, fd: i32, interest: Interest, waker: *Waker) !void {
        var event = std.os.linux.epoll_event{
            .events = interestToEpollEvents(interest),
            .data = .{ .fd = fd },
        };

        try std.os.epoll_ctl(
            self.epoll_fd,
            std.os.linux.EPOLL.CTL_ADD,
            fd,
            &event,
        );

        try self.registry.put(fd, waker);
    }

    /// Modify interest for a registered file descriptor
    pub fn reregister(self: *EpollReactor, fd: i32, interest: Interest) !void {
        var event = std.os.linux.epoll_event{
            .events = interestToEpollEvents(interest),
            .data = .{ .fd = fd },
        };

        try std.os.epoll_ctl(
            self.epoll_fd,
            std.os.linux.EPOLL.CTL_MOD,
            fd,
            &event,
        );
    }

    /// Unregister a file descriptor
    pub fn unregister(self: *EpollReactor, fd: i32) !void {
        try std.os.epoll_ctl(
            self.epoll_fd,
            std.os.linux.EPOLL.CTL_DEL,
            fd,
            null,
        );

        if (self.registry.fetchRemove(fd)) |entry| {
            entry.value.drop();
        }
    }

    /// Poll for I/O events
    ///
    /// timeout_ms: timeout in milliseconds, null for no timeout
    /// Returns the number of events processed
    pub fn poll(self: *EpollReactor, timeout_ms: ?i32) !usize {
        const n = std.os.epoll_wait(
            self.epoll_fd,
            self.events.ptr,
            @intCast(self.events.len),
            timeout_ms orelse -1,
        );

        for (self.events[0..n]) |event| {
            const fd = event.data.fd;

            if (self.registry.get(fd)) |waker| {
                waker.wakeByRef();
            }
        }

        return n;
    }

    fn interestToEpollEvents(interest: Interest) u32 {
        var events: u32 = std.os.linux.EPOLL.ET; // Edge-triggered

        if (interest.readable) {
            events |= std.os.linux.EPOLL.IN;
        }

        if (interest.writable) {
            events |= std.os.linux.EPOLL.OUT;
        }

        if (interest.error_events) {
            events |= std.os.linux.EPOLL.ERR;
        }

        if (interest.hangup) {
            events |= std.os.linux.EPOLL.HUP;
        }

        return events;
    }
};

// =================================================================================
//                            macOS/BSD - kqueue
// =================================================================================

const KqueueReactor = struct {
    kq: i32,
    events: []std.os.Kevent,
    registry: std.AutoHashMap(i32, *Waker),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !KqueueReactor {
        const kq = try std.os.kqueue();

        return KqueueReactor{
            .kq = kq,
            .events = try allocator.alloc(std.os.Kevent, 1024),
            .registry = std.AutoHashMap(i32, *Waker).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *KqueueReactor) void {
        std.os.close(self.kq);
        self.allocator.free(self.events);

        var iter = self.registry.valueIterator();
        while (iter.next()) |waker| {
            waker.*.drop();
        }

        self.registry.deinit();
    }

    pub fn register(self: *KqueueReactor, fd: i32, interest: Interest, waker: *Waker) !void {
        var changes: [2]std.os.Kevent = undefined;
        var change_count: usize = 0;

        if (interest.readable) {
            changes[change_count] = std.os.Kevent{
                .ident = @intCast(fd),
                .filter = std.os.system.EVFILT_READ,
                .flags = std.os.system.EV_ADD | std.os.system.EV_CLEAR,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            };
            change_count += 1;
        }

        if (interest.writable) {
            changes[change_count] = std.os.Kevent{
                .ident = @intCast(fd),
                .filter = std.os.system.EVFILT_WRITE,
                .flags = std.os.system.EV_ADD | std.os.system.EV_CLEAR,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            };
            change_count += 1;
        }

        _ = try std.os.kevent(self.kq, changes[0..change_count], &[_]std.os.Kevent{}, null);

        try self.registry.put(fd, waker);
    }

    pub fn reregister(self: *KqueueReactor, fd: i32, interest: Interest) !void {
        // For kqueue, we just modify the events
        var changes: [2]std.os.Kevent = undefined;
        var change_count: usize = 0;

        if (interest.readable) {
            changes[change_count] = std.os.Kevent{
                .ident = @intCast(fd),
                .filter = std.os.system.EVFILT_READ,
                .flags = std.os.system.EV_ADD | std.os.system.EV_CLEAR,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            };
            change_count += 1;
        }

        if (interest.writable) {
            changes[change_count] = std.os.Kevent{
                .ident = @intCast(fd),
                .filter = std.os.system.EVFILT_WRITE,
                .flags = std.os.system.EV_ADD | std.os.system.EV_CLEAR,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            };
            change_count += 1;
        }

        _ = try std.os.kevent(self.kq, changes[0..change_count], &[_]std.os.Kevent{}, null);
    }

    pub fn unregister(self: *KqueueReactor, fd: i32) !void {
        var changes = [_]std.os.Kevent{
            std.os.Kevent{
                .ident = @intCast(fd),
                .filter = std.os.system.EVFILT_READ,
                .flags = std.os.system.EV_DELETE,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            },
            std.os.Kevent{
                .ident = @intCast(fd),
                .filter = std.os.system.EVFILT_WRITE,
                .flags = std.os.system.EV_DELETE,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            },
        };

        _ = std.os.kevent(self.kq, &changes, &[_]std.os.Kevent{}, null) catch {};

        if (self.registry.fetchRemove(fd)) |entry| {
            entry.value.drop();
        }
    }

    pub fn poll(self: *KqueueReactor, timeout_ms: ?i32) !usize {
        const timespec = if (timeout_ms) |ms| std.os.timespec{
            .tv_sec = @divFloor(ms, 1000),
            .tv_nsec = @mod(ms, 1000) * 1_000_000,
        } else null;

        const n = try std.os.kevent(
            self.kq,
            &[_]std.os.Kevent{},
            self.events,
            if (timespec) |*ts| ts else null,
        );

        for (self.events[0..n]) |event| {
            const fd: i32 = @intCast(event.ident);

            if (self.registry.get(fd)) |waker| {
                waker.wakeByRef();
            }
        }

        return n;
    }
};

// =================================================================================
//                            Windows - IOCP
// =================================================================================

const IOCPReactor = struct {
    iocp_handle: std.os.windows.HANDLE,
    entries: []std.os.windows.OVERLAPPED_ENTRY,
    registry: std.AutoHashMap(usize, *Waker),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !IOCPReactor {
        const iocp = try std.os.windows.CreateIoCompletionPort(
            std.os.windows.INVALID_HANDLE_VALUE,
            null,
            0,
            0,
        );

        return IOCPReactor{
            .iocp_handle = iocp,
            .entries = try allocator.alloc(std.os.windows.OVERLAPPED_ENTRY, 1024),
            .registry = std.AutoHashMap(usize, *Waker).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *IOCPReactor) void {
        std.os.windows.CloseHandle(self.iocp_handle);
        self.allocator.free(self.entries);

        var iter = self.registry.valueIterator();
        while (iter.next()) |waker| {
            waker.*.drop();
        }

        self.registry.deinit();
    }

    pub fn register(
        self: *IOCPReactor,
        handle: std.os.windows.HANDLE,
        key: usize,
        waker: *Waker,
    ) !void {
        _ = try std.os.windows.CreateIoCompletionPort(
            handle,
            self.iocp_handle,
            key,
            0,
        );

        try self.registry.put(key, waker);
    }

    pub fn unregister(self: *IOCPReactor, key: usize) void {
        if (self.registry.fetchRemove(key)) |entry| {
            entry.value.drop();
        }
    }

    pub fn poll(self: *IOCPReactor, timeout_ms: ?u32) !usize {
        var num_entries: u32 = 0;

        const result = std.os.windows.kernel32.GetQueuedCompletionStatusEx(
            self.iocp_handle,
            self.entries.ptr,
            @intCast(self.entries.len),
            &num_entries,
            timeout_ms orelse std.os.windows.INFINITE,
            std.os.windows.FALSE,
        );

        if (result == 0) {
            return error.IOCPError;
        }

        for (self.entries[0..num_entries]) |entry| {
            const key: usize = @intCast(entry.lpCompletionKey);

            if (self.registry.get(key)) |waker| {
                waker.wakeByRef();
            }
        }

        return num_entries;
    }
};

// =================================================================================
//                                    TESTS
// =================================================================================

test "Reactor - init and deinit" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var reactor = try Reactor.init(allocator);
    defer reactor.deinit();

    // Should initialize without error
    try testing.expect(true);
}

test "Reactor - poll with no events" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var reactor = try Reactor.init(allocator);
    defer reactor.deinit();

    // Poll with immediate timeout
    const n = try reactor.poll(0);

    // Should return 0 (no events)
    try testing.expectEqual(@as(usize, 0), n);
}

// Platform-specific tests would go here, testing actual I/O operations
