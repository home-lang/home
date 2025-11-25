// Home Programming Language - Socket API
// POSIX-compatible socket interface for TCP and UDP networking

const Basics = @import("basics");
const protocols = @import("protocols.zig");
const netdev = @import("netdev.zig");
const sync = @import("sync.zig");

// ============================================================================
// Socket Types and Constants
// ============================================================================

pub const AddressFamily = enum(u16) {
    Unspec = 0,
    Unix = 1,
    Inet = 2, // IPv4
    Inet6 = 10, // IPv6
};

pub const SocketType = enum(u32) {
    Stream = 1, // TCP
    Dgram = 2, // UDP
    Raw = 3, // Raw IP
};

pub const Protocol = enum(u32) {
    Default = 0,
    TCP = 6,
    UDP = 17,
    ICMP = 1,
};

/// Socket address for IPv4
pub const SockAddrIn = struct {
    family: AddressFamily = .Inet,
    port: u16,
    addr: protocols.IPv4Address,
    _zero: [8]u8 = [_]u8{0} ** 8,

    pub fn init(addr: protocols.IPv4Address, port: u16) SockAddrIn {
        return .{
            .family = .Inet,
            .port = port,
            .addr = addr,
        };
    }

    pub fn any(port: u16) SockAddrIn {
        return init(protocols.IPv4Address.init(0, 0, 0, 0), port);
    }

    pub fn loopback(port: u16) SockAddrIn {
        return init(protocols.IPv4Address.init(127, 0, 0, 1), port);
    }
};

/// Generic socket address
pub const SockAddr = union(AddressFamily) {
    Unspec: void,
    Unix: struct { path: [108]u8 },
    Inet: SockAddrIn,
    Inet6: struct { port: u16, flowinfo: u32, addr: [16]u8, scope_id: u32 },
};

/// Socket options
pub const SockOpt = enum(u32) {
    ReuseAddr = 2,
    ReusePort = 15,
    KeepAlive = 9,
    NoDelay = 1, // TCP_NODELAY
    Linger = 13,
    RecvBufSize = 8,
    SendBufSize = 7,
    RecvTimeout = 20,
    SendTimeout = 21,
    Broadcast = 6,
};

pub const SockOptLevel = enum(u32) {
    Socket = 1,
    Tcp = 6,
    Udp = 17,
    Ip = 0,
};

/// Linger option structure
pub const Linger = struct {
    l_onoff: i32,
    l_linger: i32,
};

/// Poll events
pub const PollEvents = packed struct(u16) {
    in: bool = false, // Data to read
    pri: bool = false, // Priority data
    out: bool = false, // Can write
    err: bool = false, // Error condition
    hup: bool = false, // Hang up
    nval: bool = false, // Invalid fd
    _padding: u10 = 0,
};

pub const PollFd = struct {
    fd: i32,
    events: PollEvents,
    revents: PollEvents,
};

// ============================================================================
// Socket Structure
// ============================================================================

pub const Socket = struct {
    fd: i32,
    family: AddressFamily,
    socket_type: SocketType,
    protocol: Protocol,
    state: SocketState,
    local_addr: ?SockAddrIn,
    remote_addr: ?SockAddrIn,
    tcp_socket: ?*protocols.TcpSocket,
    udp_socket: ?*protocols.UdpSocket,
    device: ?*netdev.NetDevice,
    allocator: Basics.Allocator,
    mutex: sync.Mutex,

    // Socket options
    options: SocketOptions,

    // Buffers
    recv_buffer: Basics.ArrayList(u8),
    send_buffer: Basics.ArrayList(u8),

    const SocketState = enum {
        Unbound,
        Bound,
        Listening,
        Connecting,
        Connected,
        Closing,
        Closed,
    };

    const SocketOptions = struct {
        reuse_addr: bool = false,
        reuse_port: bool = false,
        keep_alive: bool = false,
        no_delay: bool = false,
        broadcast: bool = false,
        recv_buf_size: u32 = 65536,
        send_buf_size: u32 = 65536,
        recv_timeout_ms: u32 = 0, // 0 = blocking
        send_timeout_ms: u32 = 0,
        linger: ?Linger = null,
    };

    pub fn init(allocator: Basics.Allocator, family: AddressFamily, socket_type: SocketType, protocol: Protocol, fd: i32) Socket {
        return .{
            .fd = fd,
            .family = family,
            .socket_type = socket_type,
            .protocol = protocol,
            .state = .Unbound,
            .local_addr = null,
            .remote_addr = null,
            .tcp_socket = null,
            .udp_socket = null,
            .device = null,
            .allocator = allocator,
            .mutex = sync.Mutex.init(),
            .options = .{},
            .recv_buffer = Basics.ArrayList(u8).init(allocator),
            .send_buffer = Basics.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Socket) void {
        self.recv_buffer.deinit();
        self.send_buffer.deinit();

        if (self.tcp_socket) |tcp| {
            tcp.deinit();
            self.allocator.destroy(tcp);
        }
        if (self.udp_socket) |udp| {
            _ = udp;
            // UdpSocket cleanup
        }
    }
};

// ============================================================================
// Global Socket Table
// ============================================================================

const MAX_SOCKETS = 1024;
var socket_table: [MAX_SOCKETS]?*Socket = [_]?*Socket{null} ** MAX_SOCKETS;
var next_fd: i32 = 3; // Start after stdin/stdout/stderr
var socket_table_lock: sync.Mutex = sync.Mutex.init();

fn allocateFd() !i32 {
    socket_table_lock.lock();
    defer socket_table_lock.unlock();

    for (&socket_table, 0..) |*slot, i| {
        if (slot.* == null) {
            return @intCast(i + 3);
        }
    }
    return error.TooManyOpenSockets;
}

fn registerSocket(sock: *Socket) void {
    socket_table_lock.lock();
    defer socket_table_lock.unlock();

    const idx = @as(usize, @intCast(sock.fd - 3));
    if (idx < MAX_SOCKETS) {
        socket_table[idx] = sock;
    }
}

fn unregisterSocket(fd: i32) void {
    socket_table_lock.lock();
    defer socket_table_lock.unlock();

    const idx = @as(usize, @intCast(fd - 3));
    if (idx < MAX_SOCKETS) {
        socket_table[idx] = null;
    }
}

fn getSocket(fd: i32) ?*Socket {
    socket_table_lock.lock();
    defer socket_table_lock.unlock();

    const idx = @as(usize, @intCast(fd - 3));
    if (idx < MAX_SOCKETS) {
        return socket_table[idx];
    }
    return null;
}

// ============================================================================
// Socket API Functions (POSIX-compatible)
// ============================================================================

/// Create a new socket
pub fn socket(allocator: Basics.Allocator, family: AddressFamily, socket_type: SocketType, protocol: Protocol) !i32 {
    const fd = try allocateFd();

    const sock = try allocator.create(Socket);
    sock.* = Socket.init(allocator, family, socket_type, protocol, fd);

    // Create underlying protocol socket
    switch (socket_type) {
        .Stream => {
            const tcp = try allocator.create(protocols.TcpSocket);
            tcp.* = protocols.TcpSocket.init(allocator);
            sock.tcp_socket = tcp;
        },
        .Dgram => {
            const udp = try allocator.create(protocols.UdpSocket);
            udp.* = protocols.UdpSocket.init(allocator);
            sock.udp_socket = udp;
        },
        .Raw => {
            // Raw sockets don't need underlying protocol socket
        },
    }

    registerSocket(sock);
    return fd;
}

/// Bind socket to an address
pub fn bind(fd: i32, addr: SockAddrIn) !void {
    const sock = getSocket(fd) orelse return error.BadFileDescriptor;

    sock.mutex.lock();
    defer sock.mutex.unlock();

    if (sock.state != .Unbound) return error.InvalidArgument;

    sock.local_addr = addr;
    sock.state = .Bound;

    // Bind underlying protocol socket
    switch (sock.socket_type) {
        .Stream => {
            // TCP bind is handled at listen/connect time
        },
        .Dgram => {
            if (sock.udp_socket) |udp| {
                try udp.bind(addr.port);
            }
        },
        .Raw => {},
    }
}

/// Listen for connections (TCP only)
pub fn listen(fd: i32, backlog: u16) !void {
    const sock = getSocket(fd) orelse return error.BadFileDescriptor;

    sock.mutex.lock();
    defer sock.mutex.unlock();

    if (sock.socket_type != .Stream) return error.OperationNotSupported;
    if (sock.state != .Bound) return error.InvalidArgument;

    if (sock.tcp_socket) |tcp| {
        const port = if (sock.local_addr) |addr| addr.port else return error.InvalidArgument;
        try tcp.listen(port, backlog);
    }

    sock.state = .Listening;
}

/// Accept a connection (TCP only)
pub fn accept(allocator: Basics.Allocator, fd: i32) !struct { fd: i32, addr: SockAddrIn } {
    const sock = getSocket(fd) orelse return error.BadFileDescriptor;

    sock.mutex.lock();
    defer sock.mutex.unlock();

    if (sock.socket_type != .Stream) return error.OperationNotSupported;
    if (sock.state != .Listening) return error.InvalidArgument;

    // Accept on underlying TCP socket
    const tcp = sock.tcp_socket orelse return error.InvalidArgument;

    // Use timeout if set
    const new_tcp = if (sock.options.recv_timeout_ms > 0)
        try tcp.acceptTimeout(allocator, sock.options.recv_timeout_ms) orelse return error.WouldBlock
    else
        try tcp.accept(allocator);

    // Create new socket for accepted connection
    const new_fd = try allocateFd();
    const new_sock = try allocator.create(Socket);
    new_sock.* = Socket.init(allocator, sock.family, sock.socket_type, sock.protocol, new_fd);
    new_sock.tcp_socket = new_tcp;
    new_sock.state = .Connected;
    new_sock.local_addr = sock.local_addr;
    new_sock.remote_addr = SockAddrIn.init(new_tcp.remote_ip, new_tcp.remote_port);
    new_sock.device = sock.device;

    registerSocket(new_sock);

    return .{
        .fd = new_fd,
        .addr = new_sock.remote_addr.?,
    };
}

/// Connect to a remote address
pub fn connect(fd: i32, addr: SockAddrIn) !void {
    const sock = getSocket(fd) orelse return error.BadFileDescriptor;

    sock.mutex.lock();
    defer sock.mutex.unlock();

    if (sock.state != .Unbound and sock.state != .Bound) return error.InvalidArgument;

    sock.remote_addr = addr;
    sock.state = .Connecting;

    switch (sock.socket_type) {
        .Stream => {
            if (sock.tcp_socket) |tcp| {
                // Get network device
                const dev = sock.device orelse getDefaultDevice() orelse return error.NetworkUnreachable;

                // Allocate local port if not bound
                const local_port = if (sock.local_addr) |local| local.port else try allocateEphemeralPort();
                if (sock.local_addr == null) {
                    sock.local_addr = SockAddrIn.init(protocols.IPv4Address.init(0, 0, 0, 0), local_port);
                }

                try tcp.connect(dev, addr.addr, addr.port, local_port);
            }
        },
        .Dgram => {
            // UDP "connect" just sets default destination
            sock.state = .Connected;
        },
        .Raw => {},
    }
}

/// Send data on connected socket
pub fn send(fd: i32, data: []const u8, flags: u32) !usize {
    _ = flags;
    const sock = getSocket(fd) orelse return error.BadFileDescriptor;

    sock.mutex.lock();
    defer sock.mutex.unlock();

    if (sock.state != .Connected) return error.NotConnected;

    switch (sock.socket_type) {
        .Stream => {
            if (sock.tcp_socket) |tcp| {
                const dev = sock.device orelse getDefaultDevice() orelse return error.NetworkUnreachable;
                try tcp.send(dev, data);
                return data.len;
            }
        },
        .Dgram => {
            if (sock.udp_socket) |udp| {
                const remote = sock.remote_addr orelse return error.NotConnected;
                const dev = sock.device orelse getDefaultDevice() orelse return error.NetworkUnreachable;
                try udp.sendTo(dev, remote.addr, remote.port, data);
                return data.len;
            }
        },
        .Raw => {},
    }

    return error.OperationNotSupported;
}

/// Send data to a specific address (UDP)
pub fn sendto(fd: i32, data: []const u8, flags: u32, dest: SockAddrIn) !usize {
    _ = flags;
    const sock = getSocket(fd) orelse return error.BadFileDescriptor;

    sock.mutex.lock();
    defer sock.mutex.unlock();

    if (sock.socket_type != .Dgram) return error.OperationNotSupported;

    if (sock.udp_socket) |udp| {
        const dev = sock.device orelse getDefaultDevice() orelse return error.NetworkUnreachable;
        try udp.sendTo(dev, dest.addr, dest.port, data);
        return data.len;
    }

    return error.InvalidArgument;
}

/// Receive data from socket
pub fn recv(fd: i32, buffer: []u8, flags: u32) !usize {
    _ = flags;
    const sock = getSocket(fd) orelse return error.BadFileDescriptor;

    sock.mutex.lock();
    defer sock.mutex.unlock();

    switch (sock.socket_type) {
        .Stream => {
            if (sock.tcp_socket) |tcp| {
                return tcp.receive(buffer) catch |err| switch (err) {
                    error.WouldBlock => return 0,
                    else => return err,
                };
            }
        },
        .Dgram => {
            if (sock.udp_socket) |udp| {
                return udp.receive(buffer) catch |err| switch (err) {
                    error.WouldBlock => return 0,
                    else => return err,
                };
            }
        },
        .Raw => {},
    }

    return error.OperationNotSupported;
}

/// Receive data with source address (UDP)
pub fn recvfrom(fd: i32, buffer: []u8, flags: u32) !struct { len: usize, addr: SockAddrIn } {
    _ = flags;
    const sock = getSocket(fd) orelse return error.BadFileDescriptor;

    sock.mutex.lock();
    defer sock.mutex.unlock();

    if (sock.socket_type != .Dgram) return error.OperationNotSupported;

    if (sock.udp_socket) |udp| {
        const len = udp.receive(buffer) catch |err| switch (err) {
            error.WouldBlock => return .{ .len = 0, .addr = undefined },
            else => return err,
        };

        // Get source address from last received packet
        // Note: This is simplified - real implementation tracks per-packet source
        return .{
            .len = len,
            .addr = SockAddrIn.init(protocols.IPv4Address.init(0, 0, 0, 0), 0),
        };
    }

    return error.InvalidArgument;
}

/// Close a socket
pub fn close(fd: i32) !void {
    const sock = getSocket(fd) orelse return error.BadFileDescriptor;

    sock.mutex.lock();
    defer sock.mutex.unlock();

    // Close underlying protocol socket
    if (sock.tcp_socket) |tcp| {
        if (sock.device) |dev| {
            tcp.close(dev) catch {};
        }
    }

    sock.state = .Closed;
    unregisterSocket(fd);

    // Cleanup
    sock.deinit();
    sock.allocator.destroy(sock);
}

/// Shutdown socket (half-close)
pub fn shutdown(fd: i32, how: ShutdownHow) !void {
    const sock = getSocket(fd) orelse return error.BadFileDescriptor;

    sock.mutex.lock();
    defer sock.mutex.unlock();

    _ = how;
    // Implement half-close for TCP
    sock.state = .Closing;
}

pub const ShutdownHow = enum(u32) {
    Read = 0,
    Write = 1,
    Both = 2,
};

/// Set socket option
pub fn setsockopt(fd: i32, level: SockOptLevel, optname: SockOpt, value: anytype) !void {
    const sock = getSocket(fd) orelse return error.BadFileDescriptor;

    sock.mutex.lock();
    defer sock.mutex.unlock();

    _ = level;
    switch (optname) {
        .ReuseAddr => sock.options.reuse_addr = value,
        .ReusePort => sock.options.reuse_port = value,
        .KeepAlive => sock.options.keep_alive = value,
        .NoDelay => sock.options.no_delay = value,
        .Broadcast => sock.options.broadcast = value,
        .RecvBufSize => sock.options.recv_buf_size = value,
        .SendBufSize => sock.options.send_buf_size = value,
        .RecvTimeout => sock.options.recv_timeout_ms = value,
        .SendTimeout => sock.options.send_timeout_ms = value,
        .Linger => sock.options.linger = value,
    }
}

/// Get socket option
pub fn getsockopt(fd: i32, level: SockOptLevel, optname: SockOpt, comptime T: type) !T {
    const sock = getSocket(fd) orelse return error.BadFileDescriptor;

    sock.mutex.lock();
    defer sock.mutex.unlock();

    _ = level;
    return switch (optname) {
        .ReuseAddr => sock.options.reuse_addr,
        .ReusePort => sock.options.reuse_port,
        .KeepAlive => sock.options.keep_alive,
        .NoDelay => sock.options.no_delay,
        .Broadcast => sock.options.broadcast,
        .RecvBufSize => sock.options.recv_buf_size,
        .SendBufSize => sock.options.send_buf_size,
        .RecvTimeout => sock.options.recv_timeout_ms,
        .SendTimeout => sock.options.send_timeout_ms,
        .Linger => sock.options.linger,
    };
}

/// Get local address
pub fn getsockname(fd: i32) !SockAddrIn {
    const sock = getSocket(fd) orelse return error.BadFileDescriptor;

    sock.mutex.lock();
    defer sock.mutex.unlock();

    return sock.local_addr orelse error.InvalidArgument;
}

/// Get remote address
pub fn getpeername(fd: i32) !SockAddrIn {
    const sock = getSocket(fd) orelse return error.BadFileDescriptor;

    sock.mutex.lock();
    defer sock.mutex.unlock();

    return sock.remote_addr orelse error.NotConnected;
}

/// Poll multiple sockets
pub fn poll(fds: []PollFd, timeout_ms: i32) !u32 {
    const deadline = if (timeout_ms >= 0)
        protocols.getMonotonicTime() + @as(u64, @intCast(timeout_ms)) * 1_000_000
    else
        0; // Infinite timeout

    var ready_count: u32 = 0;

    while (true) {
        ready_count = 0;

        for (fds) |*pfd| {
            pfd.revents = .{};

            const sock = getSocket(pfd.fd) orelse {
                pfd.revents.nval = true;
                ready_count += 1;
                continue;
            };

            // Check requested events
            if (pfd.events.in) {
                // Check if data available to read
                const has_data = switch (sock.socket_type) {
                    .Stream => if (sock.tcp_socket) |tcp| tcp.recv_buffer.items.len > 0 else false,
                    .Dgram => if (sock.udp_socket) |udp| udp.receive_queue.items.len > 0 else false,
                    else => false,
                };
                if (has_data) {
                    pfd.revents.in = true;
                    ready_count += 1;
                }
            }

            if (pfd.events.out) {
                // Can always write (for now)
                if (sock.state == .Connected) {
                    pfd.revents.out = true;
                    ready_count += 1;
                }
            }

            // Check for errors/hangup
            if (sock.state == .Closed) {
                pfd.revents.hup = true;
                ready_count += 1;
            }
        }

        if (ready_count > 0) return ready_count;

        // Check timeout
        if (timeout_ms == 0) return 0; // Non-blocking
        if (timeout_ms > 0 and protocols.getMonotonicTime() >= deadline) return 0;

        // Yield to allow other processing
    }
}

// ============================================================================
// Helper Functions
// ============================================================================

var ephemeral_port_counter: u16 = 49152; // Start of ephemeral range
var ephemeral_port_lock: sync.Mutex = sync.Mutex.init();

fn allocateEphemeralPort() !u16 {
    ephemeral_port_lock.lock();
    defer ephemeral_port_lock.unlock();

    const port = ephemeral_port_counter;
    ephemeral_port_counter += 1;
    if (ephemeral_port_counter >= 65535) {
        ephemeral_port_counter = 49152;
    }
    return port;
}

var default_device: ?*netdev.NetDevice = null;

pub fn setDefaultDevice(dev: *netdev.NetDevice) void {
    default_device = dev;
}

fn getDefaultDevice() ?*netdev.NetDevice {
    return default_device;
}

// ============================================================================
// High-Level Convenience Functions
// ============================================================================

/// Create a TCP client and connect to server
pub fn tcpConnect(allocator: Basics.Allocator, host: protocols.IPv4Address, port: u16) !i32 {
    const fd = try socket(allocator, .Inet, .Stream, .TCP);
    errdefer close(fd) catch {};

    try connect(fd, SockAddrIn.init(host, port));
    return fd;
}

/// Create a TCP server listening on port
pub fn tcpListen(allocator: Basics.Allocator, port: u16, backlog: u16) !i32 {
    const fd = try socket(allocator, .Inet, .Stream, .TCP);
    errdefer close(fd) catch {};

    try bind(fd, SockAddrIn.any(port));
    try listen(fd, backlog);
    return fd;
}

/// Create a UDP socket bound to port
pub fn udpBind(allocator: Basics.Allocator, port: u16) !i32 {
    const fd = try socket(allocator, .Inet, .Dgram, .UDP);
    errdefer close(fd) catch {};

    try bind(fd, SockAddrIn.any(port));
    return fd;
}

// ============================================================================
// Tests
// ============================================================================

test "socket creation" {
    const allocator = Basics.testing.allocator;

    const fd = try socket(allocator, .Inet, .Stream, .TCP);
    try Basics.testing.expect(fd >= 3);

    try close(fd);
}

test "socket bind" {
    const allocator = Basics.testing.allocator;

    const fd = try socket(allocator, .Inet, .Stream, .TCP);
    defer close(fd) catch {};

    try bind(fd, SockAddrIn.any(8080));

    const local = try getsockname(fd);
    try Basics.testing.expectEqual(@as(u16, 8080), local.port);
}

test "socket options" {
    const allocator = Basics.testing.allocator;

    const fd = try socket(allocator, .Inet, .Stream, .TCP);
    defer close(fd) catch {};

    try setsockopt(fd, .Socket, .ReuseAddr, true);
    const reuse = try getsockopt(fd, .Socket, .ReuseAddr, bool);
    try Basics.testing.expect(reuse);
}

test "UDP socket" {
    const allocator = Basics.testing.allocator;

    const fd = try socket(allocator, .Inet, .Dgram, .UDP);
    defer close(fd) catch {};

    try bind(fd, SockAddrIn.any(9999));
}

test "poll with timeout" {
    const allocator = Basics.testing.allocator;

    const fd = try socket(allocator, .Inet, .Stream, .TCP);
    defer close(fd) catch {};

    var fds = [_]PollFd{.{
        .fd = fd,
        .events = .{ .in = true },
        .revents = .{},
    }};

    const ready = try poll(&fds, 0); // Non-blocking
    try Basics.testing.expectEqual(@as(u32, 0), ready);
}
