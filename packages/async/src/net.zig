const std = @import("std");
const future_mod = @import("future.zig");
const Future = future_mod.Future;
const PollResult = future_mod.PollResult;
const Context = future_mod.Context;
const reactor_mod = @import("reactor.zig");
const Reactor = reactor_mod.Reactor;
const result_mod = @import("result_future.zig");
const Result = result_mod.Result;

/// Async network I/O operations
///
/// Provides async TCP/UDP networking using the async runtime's I/O reactor
/// for efficient non-blocking network operations.

/// Network error types
pub const NetError = error{
    ConnectionRefused,
    ConnectionReset,
    ConnectionAborted,
    NetworkUnreachable,
    HostUnreachable,
    AddressInUse,
    AddressNotAvailable,
    Timeout,
    InvalidAddress,
    WouldBlock,
    IoError,
};

/// IP address representation
pub const IpAddr = union(enum) {
    V4: [4]u8,
    V6: [16]u8,

    pub fn v4(a: u8, b: u8, c: u8, d: u8) IpAddr {
        return .{ .V4 = .{ a, b, c, d } };
    }

    pub fn v6(addr: [16]u8) IpAddr {
        return .{ .V6 = addr };
    }

    pub fn localhost() IpAddr {
        return v4(127, 0, 0, 1);
    }
};

/// Socket address (IP + port)
pub const SocketAddr = struct {
    ip: IpAddr,
    port: u16,

    pub fn init(ip: IpAddr, port: u16) SocketAddr {
        return .{ .ip = ip, .port = port };
    }

    pub fn toNative(self: SocketAddr) std.net.Address {
        return switch (self.ip) {
            .V4 => |octets| std.net.Address.initIp4(octets, self.port),
            .V6 => |octets| std.net.Address.initIp6(octets, self.port, 0, 0),
        };
    }

    pub fn fromNative(addr: std.net.Address) SocketAddr {
        return switch (addr.any.family) {
            std.os.AF.INET => .{
                .ip = .{ .V4 = @bitCast(addr.in.sa.addr) },
                .port = std.mem.bigToNative(u16, addr.in.sa.port),
            },
            std.os.AF.INET6 => .{
                .ip = .{ .V6 = addr.in6.sa.addr },
                .port = std.mem.bigToNative(u16, addr.in6.sa.port),
            },
            else => unreachable,
        };
    }
};

/// Async TCP stream
///
/// Represents a TCP connection that can be used for async read/write operations.
pub const TcpStream = struct {
    fd: std.os.socket_t,
    reactor: *Reactor,
    allocator: std.mem.Allocator,
    peer_addr: SocketAddr,

    /// Read data from the stream into a buffer
    pub fn read(self: *TcpStream, buffer: []u8) TcpReadFuture {
        return TcpReadFuture{
            .stream = self,
            .buffer = buffer,
            .registered: false,
        };
    }

    /// Write data from a buffer to the stream
    pub fn write(self: *TcpStream, data: []const u8) TcpWriteFuture {
        return TcpWriteFuture{
            .stream = self,
            .data = data,
            .registered = false,
        };
    }

    /// Write all data to the stream
    pub fn writeAll(self: *TcpStream, data: []const u8) TcpWriteAllFuture {
        return TcpWriteAllFuture{
            .stream = self,
            .data = data,
            .offset = 0,
            .registered = false,
        };
    }

    /// Read a line from the stream (until \n)
    pub fn readLine(self: *TcpStream, allocator: std.mem.Allocator) TcpReadLineFuture {
        return TcpReadLineFuture{
            .stream = self,
            .allocator = allocator,
            .buffer = std.ArrayList(u8).init(allocator),
            .temp_buffer = undefined,
            .registered = false,
        };
    }

    /// Shutdown the write side of the connection
    pub fn shutdown(self: *TcpStream) !void {
        try std.os.shutdown(self.fd, .send);
    }

    /// Close the connection
    pub fn close(self: *TcpStream) void {
        std.os.close(self.fd);
    }

    /// Get peer address
    pub fn peerAddr(self: *const TcpStream) SocketAddr {
        return self.peer_addr;
    }
};

/// Async TCP listener
///
/// Listens for incoming TCP connections.
pub const TcpListener = struct {
    fd: std.os.socket_t,
    reactor: *Reactor,
    allocator: std.mem.Allocator,
    local_addr: SocketAddr,

    /// Accept an incoming connection
    pub fn accept(self: *TcpListener) AcceptFuture {
        return AcceptFuture{
            .listener = self,
            .registered = false,
        };
    }

    /// Get local address
    pub fn localAddr(self: *const TcpListener) SocketAddr {
        return self.local_addr;
    }

    /// Close the listener
    pub fn close(self: *TcpListener) void {
        std.os.close(self.fd);
    }
};

/// Future for connecting to a TCP address
pub const ConnectFuture = struct {
    addr: SocketAddr,
    reactor: *Reactor,
    allocator: std.mem.Allocator,
    fd: ?std.os.socket_t = null,
    registered: bool = false,

    pub fn poll(self: *@This(), ctx: *Context) PollResult(Result(TcpStream, NetError)) {
        if (self.fd == null) {
            // Create socket
            const family: u32 = switch (self.addr.ip) {
                .V4 => std.os.AF.INET,
                .V6 => std.os.AF.INET6,
            };

            const fd = std.os.socket(family, std.os.SOCK.STREAM, std.os.IPPROTO.TCP) catch {
                return .{ .Ready = Result(TcpStream, NetError).err_value(NetError.IoError) };
            };
            errdefer std.os.close(fd);

            // Set non-blocking
            _ = std.os.fcntl(fd, std.os.F.SETFL, std.os.O.NONBLOCK) catch {
                return .{ .Ready = Result(TcpStream, NetError).err_value(NetError.IoError) };
            };

            self.fd = fd;
        }

        const fd = self.fd.?;

        // Try to connect
        const native_addr = self.addr.toNative();
        std.os.connect(fd, &native_addr.any, native_addr.getOsSockLen()) catch |err| {
            if (err == error.WouldBlock or err == error.AlreadyInProgress) {
                // Register with reactor
                if (!self.registered) {
                    self.reactor.register(fd, &ctx.waker) catch {
                        std.os.close(fd);
                        return .{ .Ready = Result(TcpStream, NetError).err_value(NetError.IoError) };
                    };
                    self.registered = true;
                }
                return .Pending;
            }

            std.os.close(fd);
            const net_err = switch (err) {
                error.ConnectionRefused => NetError.ConnectionRefused,
                error.NetworkUnreachable => NetError.NetworkUnreachable,
                error.AddressNotAvailable => NetError.AddressNotAvailable,
                error.ConnectionTimedOut => NetError.Timeout,
                else => NetError.IoError,
            };
            return .{ .Ready = Result(TcpStream, NetError).err_value(net_err) };
        };

        // Connection successful
        return .{ .Ready = Result(TcpStream, NetError).ok_value(.{
            .fd = fd,
            .reactor = self.reactor,
            .allocator = self.allocator,
            .peer_addr = self.addr,
        }) };
    }
};

/// Future for binding and listening on a TCP address
pub const BindFuture = struct {
    addr: SocketAddr,
    reactor: *Reactor,
    allocator: std.mem.Allocator,
    backlog: u31 = 128,

    pub fn poll(self: *@This(), _: *Context) PollResult(Result(TcpListener, NetError)) {
        const family: u32 = switch (self.addr.ip) {
            .V4 => std.os.AF.INET,
            .V6 => std.os.AF.INET6,
        };

        // Create socket
        const fd = std.os.socket(family, std.os.SOCK.STREAM, std.os.IPPROTO.TCP) catch {
            return .{ .Ready = Result(TcpListener, NetError).err_value(NetError.IoError) };
        };
        errdefer std.os.close(fd);

        // Set socket options
        std.os.setsockopt(fd, std.os.SOL.SOCKET, std.os.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1))) catch {};

        // Set non-blocking
        _ = std.os.fcntl(fd, std.os.F.SETFL, std.os.O.NONBLOCK) catch {
            return .{ .Ready = Result(TcpListener, NetError).err_value(NetError.IoError) };
        };

        // Bind
        const native_addr = self.addr.toNative();
        std.os.bind(fd, &native_addr.any, native_addr.getOsSockLen()) catch |err| {
            const net_err = switch (err) {
                error.AddressInUse => NetError.AddressInUse,
                error.AddressNotAvailable => NetError.AddressNotAvailable,
                else => NetError.IoError,
            };
            return .{ .Ready = Result(TcpListener, NetError).err_value(net_err) };
        };

        // Listen
        std.os.listen(fd, self.backlog) catch {
            return .{ .Ready = Result(TcpListener, NetError).err_value(NetError.IoError) };
        };

        return .{ .Ready = Result(TcpListener, NetError).ok_value(.{
            .fd = fd,
            .reactor = self.reactor,
            .allocator = self.allocator,
            .local_addr = self.addr,
        }) };
    }
};

/// Future for accepting a connection
pub const AcceptFuture = struct {
    listener: *TcpListener,
    registered: bool,

    pub fn poll(self: *@This(), ctx: *Context) PollResult(Result(TcpStream, NetError)) {
        var peer_addr: std.os.sockaddr = undefined;
        var addr_len: std.os.socklen_t = @sizeOf(std.os.sockaddr);

        const client_fd = std.os.accept(self.listener.fd, &peer_addr, &addr_len, std.os.SOCK.NONBLOCK) catch |err| {
            if (err == error.WouldBlock) {
                if (!self.registered) {
                    self.listener.reactor.register(self.listener.fd, &ctx.waker) catch {
                        return .{ .Ready = Result(TcpStream, NetError).err_value(NetError.IoError) };
                    };
                    self.registered = true;
                }
                return .Pending;
            }

            const net_err = switch (err) {
                error.ConnectionAborted => NetError.ConnectionAborted,
                else => NetError.IoError,
            };
            return .{ .Ready = Result(TcpStream, NetError).err_value(net_err) };
        };

        const native_addr = std.net.Address{ .any = peer_addr };
        const socket_addr = SocketAddr.fromNative(native_addr);

        return .{ .Ready = Result(TcpStream, NetError).ok_value(.{
            .fd = client_fd,
            .reactor = self.listener.reactor,
            .allocator = self.listener.allocator,
            .peer_addr = socket_addr,
        }) };
    }
};

/// Future for TCP read operations
pub const TcpReadFuture = struct {
    stream: *TcpStream,
    buffer: []u8,
    registered: bool,

    pub fn poll(self: *@This(), ctx: *Context) PollResult(Result(usize, NetError)) {
        const n = std.os.read(self.stream.fd, self.buffer) catch |err| {
            if (err == error.WouldBlock) {
                if (!self.registered) {
                    self.stream.reactor.register(self.stream.fd, &ctx.waker) catch {
                        return .{ .Ready = Result(usize, NetError).err_value(NetError.IoError) };
                    };
                    self.registered = true;
                }
                return .Pending;
            }

            const net_err = switch (err) {
                error.ConnectionResetByPeer => NetError.ConnectionReset,
                error.BrokenPipe => NetError.ConnectionReset,
                else => NetError.IoError,
            };
            return .{ .Ready = Result(usize, NetError).err_value(net_err) };
        };

        return .{ .Ready = Result(usize, NetError).ok_value(n) };
    }
};

/// Future for TCP write operations
pub const TcpWriteFuture = struct {
    stream: *TcpStream,
    data: []const u8,
    registered: bool,

    pub fn poll(self: *@This(), ctx: *Context) PollResult(Result(usize, NetError)) {
        const n = std.os.write(self.stream.fd, self.data) catch |err| {
            if (err == error.WouldBlock) {
                if (!self.registered) {
                    self.stream.reactor.register(self.stream.fd, &ctx.waker) catch {
                        return .{ .Ready = Result(usize, NetError).err_value(NetError.IoError) };
                    };
                    self.registered = true;
                }
                return .Pending;
            }

            const net_err = switch (err) {
                error.ConnectionResetByPeer => NetError.ConnectionReset,
                error.BrokenPipe => NetError.ConnectionReset,
                else => NetError.IoError,
            };
            return .{ .Ready = Result(usize, NetError).err_value(net_err) };
        };

        return .{ .Ready = Result(usize, NetError).ok_value(n) };
    }
};

/// Future for writing all data
pub const TcpWriteAllFuture = struct {
    stream: *TcpStream,
    data: []const u8,
    offset: usize,
    registered: bool,

    pub fn poll(self: *@This(), ctx: *Context) PollResult(Result(void, NetError)) {
        while (self.offset < self.data.len) {
            const n = std.os.write(self.stream.fd, self.data[self.offset..]) catch |err| {
                if (err == error.WouldBlock) {
                    if (!self.registered) {
                        self.stream.reactor.register(self.stream.fd, &ctx.waker) catch {
                            return .{ .Ready = Result(void, NetError).err_value(NetError.IoError) };
                        };
                        self.registered = true;
                    }
                    return .Pending;
                }

                const net_err = switch (err) {
                    error.ConnectionResetByPeer => NetError.ConnectionReset,
                    error.BrokenPipe => NetError.ConnectionReset,
                    else => NetError.IoError,
                };
                return .{ .Ready = Result(void, NetError).err_value(net_err) };
            };

            self.offset += n;
        }

        return .{ .Ready = Result(void, NetError).ok_value({}) };
    }
};

/// Future for reading a line
pub const TcpReadLineFuture = struct {
    stream: *TcpStream,
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    temp_buffer: [1]u8 = undefined,
    registered: bool,

    pub fn poll(self: *@This(), ctx: *Context) PollResult(Result([]u8, NetError)) {
        while (true) {
            const n = std.os.read(self.stream.fd, &self.temp_buffer) catch |err| {
                if (err == error.WouldBlock) {
                    if (!self.registered) {
                        self.stream.reactor.register(self.stream.fd, &ctx.waker) catch {
                            return .{ .Ready = Result([]u8, NetError).err_value(NetError.IoError) };
                        };
                        self.registered = true;
                    }
                    return .Pending;
                }

                const net_err = switch (err) {
                    error.ConnectionResetByPeer => NetError.ConnectionReset,
                    else => NetError.IoError,
                };
                return .{ .Ready = Result([]u8, NetError).err_value(net_err) };
            };

            if (n == 0) {
                // EOF
                return .{ .Ready = Result([]u8, NetError).ok_value(self.buffer.toOwnedSlice() catch {
                    return .{ .Ready = Result([]u8, NetError).err_value(NetError.IoError) };
                }) };
            }

            const byte = self.temp_buffer[0];
            if (byte == '\n') {
                // Found newline
                return .{ .Ready = Result([]u8, NetError).ok_value(self.buffer.toOwnedSlice() catch {
                    return .{ .Ready = Result([]u8, NetError).err_value(NetError.IoError) };
                }) };
            }

            self.buffer.append(byte) catch {
                return .{ .Ready = Result([]u8, NetError).err_value(NetError.IoError) };
            };
        }
    }
};

/// Connect to a TCP address
pub fn connect(addr: SocketAddr, reactor: *Reactor, allocator: std.mem.Allocator) ConnectFuture {
    return ConnectFuture{
        .addr = addr,
        .reactor = reactor,
        .allocator = allocator,
    };
}

/// Bind to a TCP address and listen for connections
pub fn bind(addr: SocketAddr, reactor: *Reactor, allocator: std.mem.Allocator) BindFuture {
    return BindFuture{
        .addr = addr,
        .reactor = reactor,
        .allocator = allocator,
    };
}

// =================================================================================
//                                    TESTS
// =================================================================================

test "TcpListener - bind" {
    // Placeholder test - requires full reactor setup
}

test "TcpStream - connect" {
    // Placeholder test - requires full reactor setup
}

test "TcpStream - read and write" {
    // Placeholder test - requires full reactor setup
}
