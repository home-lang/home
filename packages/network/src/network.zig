// Networking Library for Home Language
// Provides TCP/UDP sockets using POSIX APIs directly
//
// NOTE: This is experimental - Zig 0.16-dev has significant networking API changes
// Some functionality may require updates as the Zig std evolves

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

// ==================== Core Types ====================

/// Socket address
pub const Address = struct {
    family: u16,
    port: u16,
    addr: [4]u8, // IPv4 for now

    /// Create IPv4 address
    pub fn initIp4(ip: [4]u8, port: u16) Address {
        return Address{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = ip,
        };
    }

    /// Parse IPv4 from string "127.0.0.1"
    pub fn parseIp4(ip_str: []const u8, port: u16) !Address {
        var parts: [4]u8 = undefined;
        var iter = std.mem.splitScalar(u8, ip_str, '.');
        var i: usize = 0;

        while (iter.next()) |part| : (i += 1) {
            if (i >= 4) return error.InvalidIpAddress;
            parts[i] = try std.fmt.parseInt(u8, part, 10);
        }

        if (i != 4) return error.InvalidIpAddress;

        return initIp4(parts, port);
    }

    /// Get localhost (127.0.0.1)
    pub fn localhost(port: u16) Address {
        return initIp4([_]u8{ 127, 0, 0, 1 }, port);
    }

    /// Get any address (0.0.0.0)
    pub fn any(port: u16) Address {
        return initIp4([_]u8{ 0, 0, 0, 0 }, port);
    }

    /// Get port number
    pub fn getPort(self: Address) u16 {
        return std.mem.bigToNative(u16, self.port);
    }

    /// Convert to posix sockaddr
    fn toSockAddr(self: Address) posix.sockaddr {
        var addr: posix.sockaddr = undefined;
        const addr_in = @as(*posix.sockaddr.in, @ptrCast(@alignCast(&addr)));
        addr_in.family = self.family;
        addr_in.port = self.port;
        @memcpy(&addr_in.addr, &self.addr);
        @memset(std.mem.asBytes(&addr_in.zero), 0);
        return addr;
    }

    /// Create from posix sockaddr
    fn fromSockAddr(addr: *const posix.sockaddr) Address {
        const addr_in = @as(*const posix.sockaddr.in, @ptrCast(@alignCast(addr)));
        var ip: [4]u8 = undefined;
        @memcpy(&ip, &addr_in.addr);
        return Address{
            .family = addr_in.family,
            .port = addr_in.port,
            .addr = ip,
        };
    }

    /// Format as string (caller owns memory)
    pub fn format(self: Address, allocator: Allocator) ![]u8 {
        return try std.fmt.allocPrint(
            allocator,
            "{d}.{d}.{d}.{d}:{d}",
            .{ self.addr[0], self.addr[1], self.addr[2], self.addr[3], self.getPort() },
        );
    }
};

// ==================== TCP Client ====================

pub const TcpStream = struct {
    socket: posix.socket_t,

    /// Connect to address
    pub fn connect(address: Address) !TcpStream {
        const sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        errdefer posix.close(sock);

        const addr = address.toSockAddr();
        try posix.connect(sock, &addr, @sizeOf(posix.sockaddr.in));

        return TcpStream{ .socket = sock };
    }

    /// Close connection
    pub fn close(self: *TcpStream) void {
        posix.close(self.socket);
    }

    /// Read bytes (returns number read)
    pub fn read(self: *TcpStream, buffer: []u8) !usize {
        return try posix.read(self.socket, buffer);
    }

    /// Read exact number of bytes
    pub fn readAll(self: *TcpStream, buffer: []u8) !void {
        var total: usize = 0;
        while (total < buffer.len) {
            const n = try posix.read(self.socket, buffer[total..]);
            if (n == 0) return error.EndOfStream;
            total += n;
        }
    }

    /// Write bytes
    pub fn write(self: *TcpStream, bytes: []const u8) !void {
        var written: usize = 0;
        while (written < bytes.len) {
            const n = try posix.write(self.socket, bytes[written..]);
            written += n;
        }
    }

    /// Write string
    pub fn writeString(self: *TcpStream, str: []const u8) !void {
        try self.write(str);
    }

    /// Write line (adds newline)
    pub fn writeLine(self: *TcpStream, line: []const u8) !void {
        try self.write(line);
        try self.write("\n");
    }

    /// Set read timeout (milliseconds)
    pub fn setReadTimeout(self: *TcpStream, timeout_ms: u64) !void {
        const timeout = posix.timeval{
            .tv_sec = @intCast(timeout_ms / 1000),
            .tv_usec = @intCast((timeout_ms % 1000) * 1000),
        };
        try posix.setsockopt(
            self.socket,
            posix.SOL.SOCKET,
            posix.SO.RCVTIMEO,
            std.mem.asBytes(&timeout),
        );
    }

    /// Get local address
    pub fn localAddress(self: *TcpStream) !Address {
        var addr: posix.sockaddr = undefined;
        var len: posix.socklen_t = @sizeOf(posix.sockaddr);
        try posix.getsockname(self.socket, &addr, &len);
        return Address.fromSockAddr(&addr);
    }

    /// Get remote address
    pub fn remoteAddress(self: *TcpStream) !Address {
        var addr: posix.sockaddr = undefined;
        var len: posix.socklen_t = @sizeOf(posix.sockaddr);
        try posix.getpeername(self.socket, &addr, &len);
        return Address.fromSockAddr(&addr);
    }
};

// ==================== TCP Server ====================

pub const TcpListener = struct {
    socket: posix.socket_t,
    address: Address,

    /// Bind to address and listen
    pub fn bind(address: Address) !TcpListener {
        const sock = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        errdefer posix.close(sock);

        // Set SO_REUSEADDR
        const enable: c_int = 1;
        try posix.setsockopt(
            sock,
            posix.SOL.SOCKET,
            posix.SO.REUSEADDR,
            std.mem.asBytes(&enable),
        );

        const addr = address.toSockAddr();
        try posix.bind(sock, &addr, @sizeOf(posix.sockaddr.in));

        try posix.listen(sock, 128);

        return TcpListener{
            .socket = sock,
            .address = address,
        };
    }

    /// Bind to any address
    pub fn bindAny(port: u16) !TcpListener {
        return try bind(Address.any(port));
    }

    /// Bind to localhost
    pub fn bindLocalhost(port: u16) !TcpListener {
        return try bind(Address.localhost(port));
    }

    /// Close listener
    pub fn deinit(self: *TcpListener) void {
        posix.close(self.socket);
    }

    /// Accept connection
    pub fn accept(self: *TcpListener) !TcpConnection {
        var addr: posix.sockaddr = undefined;
        var len: posix.socklen_t = @sizeOf(posix.sockaddr);

        const client_sock = try posix.accept(self.socket, &addr, &len, 0);

        return TcpConnection{
            .stream = TcpStream{ .socket = client_sock },
            .address = Address.fromSockAddr(&addr),
        };
    }

    /// Get local address
    pub fn localAddress(self: *TcpListener) !Address {
        var addr: posix.sockaddr = undefined;
        var len: posix.socklen_t = @sizeOf(posix.sockaddr);
        try posix.getsockname(self.socket, &addr, &len);
        return Address.fromSockAddr(&addr);
    }
};

/// Incoming TCP connection
pub const TcpConnection = struct {
    stream: TcpStream,
    address: Address,

    pub fn close(self: *TcpConnection) void {
        self.stream.close();
    }
};

// ==================== UDP Socket ====================

pub const UdpSocket = struct {
    socket: posix.socket_t,

    /// Bind to address
    pub fn bind(address: Address) !UdpSocket {
        const sock = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
        errdefer posix.close(sock);

        const addr = address.toSockAddr();
        try posix.bind(sock, &addr, @sizeOf(posix.sockaddr.in));

        return UdpSocket{ .socket = sock };
    }

    /// Bind to any address
    pub fn bindAny(port: u16) !UdpSocket {
        return try bind(Address.any(port));
    }

    /// Bind to localhost
    pub fn bindLocalhost(port: u16) !UdpSocket {
        return try bind(Address.localhost(port));
    }

    /// Close socket
    pub fn close(self: *UdpSocket) void {
        posix.close(self.socket);
    }

    /// Send datagram
    pub fn sendTo(self: *UdpSocket, data: []const u8, address: Address) !usize {
        const addr = address.toSockAddr();
        return try posix.sendto(
            self.socket,
            data,
            0,
            &addr,
            @sizeOf(posix.sockaddr.in),
        );
    }

    /// Receive datagram
    pub fn recvFrom(self: *UdpSocket, buffer: []u8) !struct { size: usize, address: Address } {
        var addr: posix.sockaddr = undefined;
        var len: posix.socklen_t = @sizeOf(posix.sockaddr);

        const size = try posix.recvfrom(
            self.socket,
            buffer,
            0,
            &addr,
            &len,
        );

        return .{
            .size = size,
            .address = Address.fromSockAddr(&addr),
        };
    }

    /// Set read timeout
    pub fn setReadTimeout(self: *UdpSocket, timeout_ms: u64) !void {
        const timeout = posix.timeval{
            .tv_sec = @intCast(timeout_ms / 1000),
            .tv_usec = @intCast((timeout_ms % 1000) * 1000),
        };
        try posix.setsockopt(
            self.socket,
            posix.SOL.SOCKET,
            posix.SO.RCVTIMEO,
            std.mem.asBytes(&timeout),
        );
    }

    /// Get local address
    pub fn localAddress(self: *UdpSocket) !Address {
        var addr: posix.sockaddr = undefined;
        var len: posix.socklen_t = @sizeOf(posix.sockaddr);
        try posix.getsockname(self.socket, &addr, &len);
        return Address.fromSockAddr(&addr);
    }
};

// ==================== Utility Functions ====================

/// Check if port is available
pub fn isPortAvailable(port: u16) bool {
    var listener = TcpListener.bindAny(port) catch return false;
    listener.deinit();
    return true;
}

/// Find available port in range
pub fn findAvailablePort(start: u16, end: u16) ?u16 {
    var port = start;
    while (port <= end) : (port += 1) {
        if (isPortAvailable(port)) return port;
    }
    return null;
}

// ==================== Tests ====================

test "Address - parse and format" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const addr = try Address.parseIp4("127.0.0.1", 8080);
    try testing.expectEqual(@as(u16, 8080), addr.getPort());

    const str = try addr.format(allocator);
    defer allocator.free(str);

    try testing.expectEqualStrings("127.0.0.1:8080", str);
}

test "Address - localhost and any" {
    const testing = std.testing;

    const local = Address.localhost(8080);
    try testing.expectEqual(@as(u16, 8080), local.getPort());
    try testing.expectEqual(@as(u8, 127), local.addr[0]);

    const any = Address.any(9000);
    try testing.expectEqual(@as(u16, 9000), any.getPort());
    try testing.expectEqual(@as(u8, 0), any.addr[0]);
}

test "TcpListener - bind and local address" {
    const testing = std.testing;

    var listener = try TcpListener.bindLocalhost(0);
    defer listener.deinit();

    const addr = try listener.localAddress();
    const port = addr.getPort();
    try testing.expect(port > 0);
}

test "TCP - client server echo" {
    const testing = std.testing;

    // Start server
    var listener = try TcpListener.bindLocalhost(0);
    defer listener.deinit();

    const addr = try listener.localAddress();
    const port = addr.getPort();

    // Server thread
    const ServerThread = struct {
        fn run(l: *TcpListener) void {
            var conn = l.accept() catch return;
            defer conn.close();

            var buffer: [1024]u8 = undefined;
            const n = conn.stream.read(&buffer) catch return;
            _ = conn.stream.write(buffer[0..n]) catch return;
        }
    };

    const thread = try std.Thread.spawn(.{}, ServerThread.run, .{&listener});
    defer thread.join();

    // Give server time to start
    std.time.sleep(10 * std.time.ns_per_ms);

    // Connect client
    var client = try TcpStream.connect(Address.localhost(port));
    defer client.close();

    // Send and receive
    const message = "Hello, TCP!";
    try client.write(message);

    var buffer: [1024]u8 = undefined;
    const n = try client.read(&buffer);

    try testing.expectEqualStrings(message, buffer[0..n]);
}

test "UDP - send and receive" {
    const testing = std.testing;

    var socket1 = try UdpSocket.bindLocalhost(0);
    defer socket1.close();

    var socket2 = try UdpSocket.bindLocalhost(0);
    defer socket2.close();

    const addr1 = try socket1.localAddress();
    const addr2 = try socket2.localAddress();

    // Send from socket1 to socket2
    const message = "UDP Message";
    _ = try socket1.sendTo(message, addr2);

    // Receive on socket2
    var buffer: [1024]u8 = undefined;
    const result = try socket2.recvFrom(&buffer);

    try testing.expectEqualStrings(message, buffer[0..result.size]);
    try testing.expectEqual(addr1.getPort(), result.address.getPort());
}

test "Port availability" {
    const testing = std.testing;

    var listener = try TcpListener.bindLocalhost(0);
    defer listener.deinit();

    const addr = try listener.localAddress();
    const port = addr.getPort();

    // Port should not be available
    try testing.expect(!isPortAvailable(port));
}

test "Find available port" {
    const testing = std.testing;

    const port = findAvailablePort(50000, 50100);
    try testing.expect(port != null);

    if (port) |p| {
        try testing.expect(p >= 50000);
        try testing.expect(p <= 50100);
    }
}
