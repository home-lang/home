const WindowsNamedPipeContext = @This();

ref_count: RefCount,
named_pipe: uws.WindowsNamedPipe,
socket: SocketType,

// task used to deinit the context in the next tick, vm is used to enqueue the task
vm: *jsc.VirtualMachine,
globalThis: *jsc.JSGlobalObject,
task: jsc.AnyTask,
task_event: EventState = .none,
is_open: bool = false,

const RefCount = bun.ptr.RefCount(@This(), "ref_count", scheduleDeinit, .{});
pub const ref = RefCount.ref;
pub const deref = RefCount.deref;

fn scheduleDeinit(this: *WindowsNamedPipeContext) void {
    this.deinitInNextTick();
}

pub const EventState = enum(u8) {
    deinit,
    none,
};

pub const SocketType = union(enum) {
    tls: *TLSSocket,
    tcp: *TCPSocket,
    none: void,
};

pub const new = bun.TrivialNew(WindowsNamedPipeContext);
const log = Output.scoped(.WindowsNamedPipeContext, .visible);

fn onOpen(this: *WindowsNamedPipeContext) void {
    this.is_open = true;
    switch (this.socket) {
        .tls => |tls| {
            const socket = TLSSocket.Socket.fromNamedPipe(&this.named_pipe);
            tls.onOpen(socket);
        },
        .tcp => |tcp| {
            const socket = TCPSocket.Socket.fromNamedPipe(&this.named_pipe);
            tcp.onOpen(socket);
        },
        .none => {},
    }
}

fn onData(this: *WindowsNamedPipeContext, decoded_data: []const u8) void {
    switch (this.socket) {
        .tls => |tls| {
            const socket = TLSSocket.Socket.fromNamedPipe(&this.named_pipe);
            tls.onData(socket, decoded_data);
        },
        .tcp => |tcp| {
            const socket = TCPSocket.Socket.fromNamedPipe(&this.named_pipe);
            tcp.onData(socket, decoded_data);
        },
        .none => {},
    }
}

fn onHandshake(this: *WindowsNamedPipeContext, success: bool, ssl_error: uws.us_bun_verify_error_t) void {
    switch (this.socket) {
        .tls => |tls| {
            const socket = TLSSocket.Socket.fromNamedPipe(&this.named_pipe);
            tls.onHandshake(socket, @intFromBool(success), ssl_error) catch {};
        },
        .tcp => |tcp| {
            const socket = TCPSocket.Socket.fromNamedPipe(&this.named_pipe);
            tcp.onHandshake(socket, @intFromBool(success), ssl_error) catch {};
        },
        .none => {},
    }
}

fn onEnd(this: *WindowsNamedPipeContext) void {
    switch (this.socket) {
        .tls => |tls| {
            const socket = TLSSocket.Socket.fromNamedPipe(&this.named_pipe);
            tls.onEnd(socket);
        },
        .tcp => |tcp| {
            const socket = TCPSocket.Socket.fromNamedPipe(&this.named_pipe);
            tcp.onEnd(socket);
        },
        .none => {},
    }
}

fn onWritable(this: *WindowsNamedPipeContext) void {
    switch (this.socket) {
        .tls => |tls| {
            const socket = TLSSocket.Socket.fromNamedPipe(&this.named_pipe);
            tls.onWritable(socket);
        },
        .tcp => |tcp| {
            const socket = TCPSocket.Socket.fromNamedPipe(&this.named_pipe);
            tcp.onWritable(socket);
        },
        .none => {},
    }
}

const ConnectFailureTiming = enum {
    synchronous,
    asynchronous,
};

const ConnectFailurePlan = struct {
    take_socket_from_context: bool,
    close_callback_reenters_socket: bool,
    explicit_socket_derefs: u8,
    context_deinit_socket_derefs: u8,
};

fn connectFailurePlan(timing: ConnectFailureTiming) ConnectFailurePlan {
    return switch (timing) {
        // The socket is already attached. handleConnectError consumes its
        // active/connect ref; we take and release the Context-owned ref now so
        // the later raw-pipe close callback cannot re-enter dead handlers.
        .asynchronous => .{
            .take_socket_from_context = true,
            .close_callback_reenters_socket = false,
            .explicit_socket_derefs = 1,
            .context_deinit_socket_derefs = 0,
        },
        // The Listener has not attached the socket yet, so handleConnectError
        // cannot consume the Listener's unconditional connect ref. Release it
        // explicitly and leave the Context-owned ref for Context.deinit.
        .synchronous => .{
            .take_socket_from_context = false,
            .close_callback_reenters_socket = false,
            .explicit_socket_derefs = 1,
            .context_deinit_socket_derefs = 1,
        },
    };
}

fn reportConnectErrorAndReleaseSocketRef(socket: SocketType, errno: c_int) void {
    switch (socket) {
        .tls => |tls| {
            tls.handleConnectError(errno) catch {};
            tls.deref();
        },
        .tcp => |tcp| {
            tcp.handleConnectError(errno) catch {};
            tcp.deref();
        },
        .none => {},
    }
}

fn onError(this: *WindowsNamedPipeContext, err: bun.sys.Error) void {
    if (this.is_open) {
        switch (this.socket) {
            .tls => |tls| {
                tls.handleError(err.toJS(this.globalThis) catch return);
            },
            .tcp => |tcp| {
                tcp.handleError(err.toJS(this.globalThis) catch return);
            },
            else => {},
        }
    } else {
        const plan = connectFailurePlan(.asynchronous);
        bun.assert(plan.take_socket_from_context);
        const socket = this.socket;
        this.socket = .none;
        reportConnectErrorAndReleaseSocketRef(socket, err.errno);
    }
}

fn onTimeout(this: *WindowsNamedPipeContext) void {
    switch (this.socket) {
        .tls => |tls| {
            const socket = TLSSocket.Socket.fromNamedPipe(&this.named_pipe);
            tls.onTimeout(socket);
        },
        .tcp => |tcp| {
            const socket = TCPSocket.Socket.fromNamedPipe(&this.named_pipe);
            tcp.onTimeout(socket);
        },
        .none => {},
    }
}

fn onClose(this: *WindowsNamedPipeContext) void {
    const socket = this.socket;
    this.socket = .none;
    switch (socket) {
        .tls => |tls| {
            tls.onClose(TLSSocket.Socket.fromNamedPipe(&this.named_pipe), 0, null) catch {};
            tls.deref();
        },
        .tcp => |tcp| {
            tcp.onClose(TCPSocket.Socket.fromNamedPipe(&this.named_pipe), 0, null) catch {};
            tcp.deref();
        },
        .none => {},
    }

    this.deref();
}

fn runEvent(this: *WindowsNamedPipeContext) void {
    switch (this.task_event) {
        .deinit => {
            this.deinit();
        },
        .none => @panic("Invalid event state"),
    }
}

fn deinitInNextTick(this: *WindowsNamedPipeContext) void {
    bun.assert(this.task_event != .deinit);
    this.task_event = .deinit;
    this.vm.enqueueTask(jsc.Task.init(&this.task));
}

pub fn create(globalThis: *jsc.JSGlobalObject, socket: SocketType) *WindowsNamedPipeContext {
    const vm = globalThis.bunVM();
    const this = WindowsNamedPipeContext.new(.{
        .ref_count = .init(),
        .vm = vm,
        .globalThis = globalThis,
        .task = undefined,
        .socket = socket,
        .named_pipe = undefined,
    });

    // named_pipe owns the pipe (PipeWriter owns the pipe and will close and deinit it)
    this.named_pipe = uws.WindowsNamedPipe.from(bun.new(uv.Pipe, std.mem.zeroes(uv.Pipe)), .{
        .ctx = this,
        .ref_ctx = @ptrCast(&WindowsNamedPipeContext.ref),
        .deref_ctx = @ptrCast(&WindowsNamedPipeContext.deref),
        .onOpen = @ptrCast(&WindowsNamedPipeContext.onOpen),
        .onData = @ptrCast(&WindowsNamedPipeContext.onData),
        .onHandshake = @ptrCast(&WindowsNamedPipeContext.onHandshake),
        .onEnd = @ptrCast(&WindowsNamedPipeContext.onEnd),
        .onWritable = @ptrCast(&WindowsNamedPipeContext.onWritable),
        .onError = @ptrCast(&WindowsNamedPipeContext.onError),
        .onTimeout = @ptrCast(&WindowsNamedPipeContext.onTimeout),
        .onClose = @ptrCast(&WindowsNamedPipeContext.onClose),
    }, vm);
    this.task = jsc.AnyTask.New(WindowsNamedPipeContext, WindowsNamedPipeContext.runEvent).init(this);

    switch (socket) {
        .tls => |tls| {
            tls.ref();
        },
        .tcp => |tcp| {
            tcp.ref();
        },
        .none => {},
    }

    return this;
}

/// `owned_ctx` is one `SSL_CTX_up_ref` ADOPTED by `named_pipe.open` (kept on
/// success, freed by it on failure). Prefer it over `ssl_config` so a memoised
/// `tls.createSecureContext` reaches this path with its trust store intact —
/// on this branch `[buntls]` returns `{secureContext}` only, so `ssl_config`
/// alone would be empty.
pub fn open(globalThis: *jsc.JSGlobalObject, fd: bun.FD, ssl_config: ?jsc.API.ServerConfig.SSLConfig, owned_ctx: ?*BoringSSL.SSL_CTX, socket: SocketType) !*uws.WindowsNamedPipe {
    // TODO: reuse the same context for multiple connections when possibles

    const this = WindowsNamedPipeContext.create(globalThis, socket);
    var failure_errno: c_int = @backingInt(bun.sys.SystemErrno.ENOENT);

    errdefer {
        const plan = connectFailurePlan(.synchronous);
        bun.assert(!plan.take_socket_from_context);
        reportConnectErrorAndReleaseSocketRef(socket, failure_errno);
        this.deref();
    }
    const result = this.named_pipe.open(fd, ssl_config, owned_ctx);
    if (result.asErr()) |err| {
        failure_errno = @intCast(err.errno);
        return error.NamedPipeOpenFailed;
    }
    return &this.named_pipe;
}

/// See `open` for `owned_ctx` ownership.
pub fn connect(globalThis: *jsc.JSGlobalObject, path: []const u8, ssl_config: ?jsc.API.ServerConfig.SSLConfig, owned_ctx: ?*BoringSSL.SSL_CTX, socket: SocketType) !*uws.WindowsNamedPipe {
    // TODO: reuse the same context for multiple connections when possibles

    const this = WindowsNamedPipeContext.create(globalThis, socket);
    var failure_errno: c_int = @backingInt(bun.sys.SystemErrno.ENOENT);
    errdefer {
        const plan = connectFailurePlan(.synchronous);
        bun.assert(!plan.take_socket_from_context);
        reportConnectErrorAndReleaseSocketRef(socket, failure_errno);
        this.deref();
    }

    if (path[path.len - 1] == 0) {
        // is already null terminated
        const slice_z = path[0 .. path.len - 1 :0];
        const result = this.named_pipe.connect(slice_z, ssl_config, owned_ctx);
        if (result.asErr()) |err| {
            failure_errno = @intCast(err.errno);
            return error.NamedPipeConnectFailed;
        }
    } else {
        var path_buf: bun.PathBuffer = undefined;
        // we need to null terminate the path
        const len = @min(path.len, path_buf.len - 1);

        @memcpy(path_buf[0..len], path[0..len]);
        path_buf[len] = 0;
        const slice_z = path_buf[0..len :0];
        const result = this.named_pipe.connect(slice_z, ssl_config, owned_ctx);
        if (result.asErr()) |err| {
            failure_errno = @intCast(err.errno);
            return error.NamedPipeConnectFailed;
        }
    }
    return &this.named_pipe;
}

pub fn deinit(this: *WindowsNamedPipeContext) void {
    log("deinit", .{});
    const socket = this.socket;
    this.socket = .none;
    switch (socket) {
        .tls => |tls| {
            tls.deref();
        },
        .tcp => |tcp| {
            tcp.deref();
        },
        else => {},
    }

    this.named_pipe.deinit();
    bun.destroy(this);
}

const std = @import("std");

const bun = @import("bun");
const Output = bun.Output;
const jsc = bun.jsc;
const uws = bun.uws;
const BoringSSL = bun.BoringSSL.c;
const uv = bun.windows.libuv;

const TCPSocket = jsc.API.TCPSocket;
const TLSSocket = jsc.API.TLSSocket;

test "named pipe connect failure has a single socket cleanup path" {
    const asynchronous = connectFailurePlan(.asynchronous);
    try std.testing.expect(asynchronous.take_socket_from_context);
    try std.testing.expect(!asynchronous.close_callback_reenters_socket);
    try std.testing.expectEqual(@as(u8, 1), asynchronous.explicit_socket_derefs);
    try std.testing.expectEqual(@as(u8, 0), asynchronous.context_deinit_socket_derefs);

    const synchronous = connectFailurePlan(.synchronous);
    try std.testing.expect(!synchronous.take_socket_from_context);
    try std.testing.expect(!synchronous.close_callback_reenters_socket);
    try std.testing.expectEqual(@as(u8, 1), synchronous.explicit_socket_derefs);
    try std.testing.expectEqual(@as(u8, 1), synchronous.context_deinit_socket_derefs);
}
