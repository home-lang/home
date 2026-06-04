// Copied verbatim from bun/src/io/stub_event_loop.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.

pub const Loop = struct {
    var global: Loop = .{};

    pub fn get() *Loop {
        return &global;
    }

    pub fn schedule(_: *Loop, request: anytype) void {
        if (request.scheduled) return;
        request.scheduled = true;
        _ = request.callback(request);
    }
};
pub const KeepAlive = struct {
    ref_count: usize = 0,

    pub fn init() KeepAlive {
        return .{};
    }
    // Real callers pass the VM/event-loop; the stub ignores it.
    pub fn ref(this: *KeepAlive, _: anytype) void {
        this.ref_count += 1;
    }
    pub fn unref(this: *KeepAlive, _: anytype) void {
        if (this.ref_count > 0) this.ref_count -= 1;
    }
    pub fn unrefOnNextTick(this: *KeepAlive, ctx: anytype) void {
        this.unref(ctx);
    }
    pub fn refConcurrently(this: *KeepAlive, _: anytype) void {
        this.ref_count += 1;
    }
    pub fn unrefConcurrently(this: *KeepAlive, _: anytype) void {
        if (this.ref_count > 0) this.ref_count -= 1;
    }
    pub fn refConcurrentlyFromEventLoop(this: *KeepAlive, event_loop: anytype) void {
        this.refConcurrently(event_loop);
    }
    pub fn unrefConcurrentlyFromEventLoop(this: *KeepAlive, event_loop: anytype) void {
        this.unrefConcurrently(event_loop);
    }
    pub fn disable(this: *KeepAlive) void {
        this.ref_count = 0;
    }
    pub fn isActive(this: *const KeepAlive) bool {
        return this.ref_count > 0;
    }
};
pub const FilePoll = struct {
    fd: @import("bun").FD = @import("bun").invalid_fd,
    owner: Owner = .{},
    next_to_free: ?*FilePoll = null,
    flags: Flags = .{},

    pub fn enableKeepingProcessAlive(this: *FilePoll, event_loop_ctx_: anytype) void {
        this.flags.keeps_event_loop_alive = true;
        _ = event_loop_ctx_;
    }
    pub fn disableKeepingProcessAlive(this: *FilePoll, event_loop_ctx_: anytype) void {
        this.flags.keeps_event_loop_alive = false;
        _ = event_loop_ctx_;
    }

    pub const Flags = packed struct {
        poll_readable: bool = false,
        poll_writable: bool = false,
        poll_process: bool = false,
        poll_machport: bool = false,
        nonblocking: bool = false,
        socket: bool = false,
        fifo: bool = false,
        keeps_event_loop_alive: bool = false,
        closed: bool = false,

        pub fn contains(this: Flags, comptime flag: anytype) bool {
            return switch (flag) {
                .poll_readable => this.poll_readable,
                .poll_writable => this.poll_writable,
                .poll_process => this.poll_process,
                .poll_machport => this.poll_machport,
                .nonblocking => this.nonblocking,
                .socket => this.socket,
                .fifo => this.fifo,
                .keeps_event_loop_alive => this.keeps_event_loop_alive,
                .closed => this.closed,
                else => false,
            };
        }

        pub fn insert(this: *Flags, comptime flag: anytype) void {
            switch (flag) {
                .poll_readable => this.poll_readable = true,
                .poll_writable => this.poll_writable = true,
                .poll_process => this.poll_process = true,
                .poll_machport => this.poll_machport = true,
                .readable => this.poll_readable = true,
                .writable => this.poll_writable = true,
                .process => this.poll_process = true,
                .machport => this.poll_machport = true,
                .nonblocking => this.nonblocking = true,
                .socket => this.socket = true,
                .fifo => this.fifo = true,
                .keeps_event_loop_alive => this.keeps_event_loop_alive = true,
                .closed => this.closed = true,
                else => {},
            }
        }

        pub fn remove(this: *Flags, comptime flag: anytype) void {
            switch (flag) {
                .poll_readable => this.poll_readable = false,
                .poll_writable => this.poll_writable = false,
                .poll_process => this.poll_process = false,
                .poll_machport => this.poll_machport = false,
                .readable => this.poll_readable = false,
                .writable => this.poll_writable = false,
                .process => this.poll_process = false,
                .machport => this.poll_machport = false,
                .nonblocking => this.nonblocking = false,
                .socket => this.socket = false,
                .fifo => this.fifo = false,
                .keeps_event_loop_alive => this.keeps_event_loop_alive = false,
                .closed => this.closed = false,
                else => {},
            }
        }
    };

    pub const Owner = struct {
        ptr: ?*anyopaque = null,

        pub fn set(this: *Owner, owner: anytype) void {
            this.ptr = @ptrCast(owner);
        }
    };

    pub fn init(_: anytype, fd: @import("bun").FD, flags: Flags, comptime OwnerType: type, owner: *OwnerType) *FilePoll {
        const bun = @import("bun");
        const poll = bun.default_allocator.create(FilePoll) catch @panic("FilePoll.init: out of memory");
        poll.* = .{
            .fd = fd,
            .flags = flags,
        };
        poll.owner.set(owner);
        return poll;
    }

    pub fn deinitForceUnregister(this: *FilePoll) void {
        this.fd = @import("bun").invalid_fd;
        this.flags.insert(.closed);
    }

    pub fn deinit(this: *FilePoll) void {
        this.deinitForceUnregister();
    }

    pub fn deinitWithVM(this: *FilePoll, _: anytype) void {
        this.deinitForceUnregister();
    }

    pub fn isWatching(this: *const FilePoll) bool {
        return this.flags.poll_readable or this.flags.poll_writable or this.flags.poll_process or this.flags.poll_machport;
    }

    pub fn isRegistered(this: *const FilePoll) bool {
        return this.isWatching();
    }

    pub fn fileType(this: *const FilePoll) @import("bun").io.FileType {
        if (this.flags.socket) return .socket;
        if (this.flags.nonblocking) return .nonblocking_pipe;
        if (this.flags.fifo or this.flags.poll_readable or this.flags.poll_writable) return .pipe;
        return .file;
    }

    pub fn setKeepingProcessAlive(this: *FilePoll, _: anytype, value: bool) void {
        this.flags.keeps_event_loop_alive = value;
    }

    pub fn register(this: *FilePoll, _: anytype, comptime flag: anytype, _: bool) @import("bun").sys.Maybe(void) {
        this.flags.insert(flag);
        return .{ .result = {} };
    }

    pub fn registerWithFd(this: *FilePoll, loop: anytype, comptime flag: anytype, one_shot: anytype, fd: @import("bun").FD) @import("bun").sys.Maybe(void) {
        _ = loop;
        _ = one_shot;
        this.fd = fd;
        this.flags.insert(flag);
        return .{ .result = {} };
    }

    pub fn unregisterWithFd(this: *FilePoll, loop: anytype, fd: @import("bun").FD, force_unregister: bool) @import("bun").sys.Maybe(void) {
        _ = loop;
        _ = fd;
        _ = force_unregister;
        return this.unregister({}, false);
    }

    pub fn unregister(this: *FilePoll, _: anytype, _: bool) @import("bun").sys.Maybe(void) {
        this.flags.remove(.poll_readable);
        this.flags.remove(.poll_writable);
        this.flags.remove(.poll_process);
        this.flags.remove(.poll_machport);
        return .{ .result = {} };
    }

    pub const Store = struct {
        pub fn init() Store {
            return .{};
        }

        pub fn get(_: *Store) *FilePoll {
            const bun = @import("bun");
            return bun.default_allocator.create(FilePoll) catch @panic("FilePoll.Store.get: out of memory");
        }

        pub fn put(_: *Store, poll: *FilePoll, _: anytype, _: bool) void {
            const bun = @import("bun");
            bun.default_allocator.destroy(poll);
        }

        pub fn processDeferredFrees(_: *Store) void {}
    };
};
