// Networking Library for Home Language
// Provides TCP/UDP sockets using POSIX APIs directly
//
// NOTE: This is experimental - Zig 0.16-dev has significant networking API changes
// Some functionality may require updates as the Zig std evolves

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

// ==================== Core Types ====================

/// Socket address supporting both IPv4 and IPv6
pub const Address = union(enum) {
    ipv4: Ipv4Address,
    ipv6: Ipv6Address,

    pub const Ipv4Address = struct {
        port: u16,
        addr: [4]u8,
    };

    pub const Ipv6Address = struct {
        port: u16,
        addr: [16]u8,
        flowinfo: u32 = 0,
        scope_id: u32 = 0,
    };

    /// Create IPv4 address
    pub fn initIp4(ip: [4]u8, port: u16) Address {
        return .{ .ipv4 = .{
            .port = port,
            .addr = ip,
        } };
    }

    /// Create IPv6 address
    pub fn initIp6(ip: [16]u8, port: u16) Address {
        return .{ .ipv6 = .{
            .port = port,
            .addr = ip,
            .flowinfo = 0,
            .scope_id = 0,
        } };
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

    /// Parse IPv6 from string "::1" or "2001:db8::1"
    pub fn parseIp6(ip_str: []const u8, port: u16) !Address {
        var addr: [16]u8 = [_]u8{0} ** 16;

        // Handle :: notation (zero compression)
        if (std.mem.indexOf(u8, ip_str, "::")) |double_colon_pos| {
            var before = ip_str[0..double_colon_pos];
            var after = ip_str[double_colon_pos + 2 ..];

            var before_parts = std.mem.splitScalar(u8, before, ':');
            var i: usize = 0;
            while (before_parts.next()) |part| {
                if (part.len == 0) continue;
                const value = try std.fmt.parseInt(u16, part, 16);
                addr[i * 2] = @intCast((value >> 8) & 0xFF);
                addr[i * 2 + 1] = @intCast(value & 0xFF);
                i += 1;
            }

            var after_parts = std.mem.splitScalar(u8, after, ':');
            var j: usize = 15;
            var after_list = std.ArrayList(u16).init(std.heap.page_allocator);
            defer after_list.deinit();
            while (after_parts.next()) |part| {
                if (part.len == 0) continue;
                const value = try std.fmt.parseInt(u16, part, 16);
                try after_list.append(value);
            }
            var k = after_list.items.len;
            while (k > 0) {
                k -= 1;
                const value = after_list.items[k];
                addr[j - 1] = @intCast(value & 0xFF);
                addr[j - 2] = @intCast((value >> 8) & 0xFF);
                j -= 2;
            }
        } else {
            var parts = std.mem.splitScalar(u8, ip_str, ':');
            var i: usize = 0;
            while (parts.next()) |part| : (i += 1) {
                if (i >= 8) return error.InvalidIpAddress;
                const value = try std.fmt.parseInt(u16, part, 16);
                addr[i * 2] = @intCast((value >> 8) & 0xFF);
                addr[i * 2 + 1] = @intCast(value & 0xFF);
            }
            if (i != 8) return error.InvalidIpAddress;
        }

        return initIp6(addr, port);
    }

    /// Get localhost (127.0.0.1 for IPv4, ::1 for IPv6)
    pub fn localhost(port: u16) Address {
        return initIp4([_]u8{ 127, 0, 0, 1 }, port);
    }

    pub fn localhost6(port: u16) Address {
        var addr = [_]u8{0} ** 16;
        addr[15] = 1; // ::1
        return initIp6(addr, port);
    }

    /// Get any address (0.0.0.0 for IPv4, :: for IPv6)
    pub fn any(port: u16) Address {
        return initIp4([_]u8{ 0, 0, 0, 0 }, port);
    }

    pub fn any6(port: u16) Address {
        return initIp6([_]u8{0} ** 16, port);
    }

    /// Get port number
    pub fn getPort(self: Address) u16 {
        return switch (self) {
            .ipv4 => |addr| addr.port,
            .ipv6 => |addr| addr.port,
        };
    }

    /// Get address family
    pub fn getFamily(self: Address) u16 {
        return switch (self) {
            .ipv4 => posix.AF.INET,
            .ipv6 => posix.AF.INET6,
        };
    }

    /// Convert to posix sockaddr
    fn toSockAddr(self: Address) posix.sockaddr {
        var addr: posix.sockaddr = undefined;
        switch (self) {
            .ipv4 => |ipv4| {
                const addr_in = @as(*posix.sockaddr.in, @ptrCast(@alignCast(&addr)));
                addr_in.family = posix.AF.INET;
                addr_in.port = std.mem.nativeToBig(u16, ipv4.port);
                @memcpy(&addr_in.addr, &ipv4.addr);
                @memset(std.mem.asBytes(&addr_in.zero), 0);
            },
            .ipv6 => |ipv6| {
                const addr_in6 = @as(*posix.sockaddr.in6, @ptrCast(@alignCast(&addr)));
                addr_in6.family = posix.AF.INET6;
                addr_in6.port = std.mem.nativeToBig(u16, ipv6.port);
                addr_in6.flowinfo = ipv6.flowinfo;
                @memcpy(&addr_in6.addr, &ipv6.addr);
                addr_in6.scope_id = ipv6.scope_id;
            },
        }
        return addr;
    }

    /// Get sockaddr size
    fn getSockAddrSize(self: Address) usize {
        return switch (self) {
            .ipv4 => @sizeOf(posix.sockaddr.in),
            .ipv6 => @sizeOf(posix.sockaddr.in6),
        };
    }

    /// Create from posix sockaddr
    fn fromSockAddr(addr: *const posix.sockaddr) Address {
        switch (addr.family) {
            posix.AF.INET => {
                const addr_in = @as(*const posix.sockaddr.in, @ptrCast(@alignCast(addr)));
                var ip: [4]u8 = undefined;
                @memcpy(&ip, &addr_in.addr);
                return .{ .ipv4 = .{
                    .port = std.mem.bigToNative(u16, addr_in.port),
                    .addr = ip,
                } };
            },
            posix.AF.INET6 => {
                const addr_in6 = @as(*const posix.sockaddr.in6, @ptrCast(@alignCast(addr)));
                var ip: [16]u8 = undefined;
                @memcpy(&ip, &addr_in6.addr);
                return .{ .ipv6 = .{
                    .port = std.mem.bigToNative(u16, addr_in6.port),
                    .addr = ip,
                    .flowinfo = addr_in6.flowinfo,
                    .scope_id = addr_in6.scope_id,
                } };
            },
            else => unreachable,
        }
    }

    /// Format as string (caller owns memory)
    pub fn format(self: Address, allocator: Allocator) ![]u8 {
        return switch (self) {
            .ipv4 => |ipv4| try std.fmt.allocPrint(
                allocator,
                "{d}.{d}.{d}.{d}:{d}",
                .{ ipv4.addr[0], ipv4.addr[1], ipv4.addr[2], ipv4.addr[3], ipv4.port },
            ),
            .ipv6 => |ipv6| blk: {
                // Format IPv6 with zero compression
                var parts: [8]u16 = undefined;
                for (0..8) |i| {
                    parts[i] = (@as(u16, ipv6.addr[i * 2]) << 8) | ipv6.addr[i * 2 + 1];
                }

                // Simple formatting without zero compression for now
                break :blk try std.fmt.allocPrint(
                    allocator,
                    "[{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}]:{d}",
                    .{ parts[0], parts[1], parts[2], parts[3], parts[4], parts[5], parts[6], parts[7], ipv6.port },
                );
            },
        };
    }
};

// ==================== TCP Client ====================

pub const TcpStream = struct {
    socket: posix.socket_t,

    /// Connect to address
    pub fn connect(address: Address) !TcpStream {
        const sock = try posix.socket(address.getFamily(), posix.SOCK.STREAM, 0);
        errdefer posix.close(sock);

        const addr = address.toSockAddr();
        try posix.connect(sock, &addr, @intCast(address.getSockAddrSize()));

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
        const sock = try posix.socket(address.getFamily(), posix.SOCK.STREAM, 0);
        errdefer posix.close(sock);

        // Set SO_REUSEADDR
        const enable: c_int = 1;
        try posix.setsockopt(
            sock,
            posix.SOL.SOCKET,
            posix.SO.REUSEADDR,
            std.mem.asBytes(&enable),
        );

        // For IPv6, also set IPV6_V6ONLY to false for dual-stack support
        if (address.getFamily() == posix.AF.INET6) {
            const v6only: c_int = 0;
            posix.setsockopt(
                sock,
                posix.IPPROTO.IPV6,
                26, // IPV6_V6ONLY
                std.mem.asBytes(&v6only),
            ) catch {};
        }

        const addr = address.toSockAddr();
        try posix.bind(sock, &addr, @intCast(address.getSockAddrSize()));

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
        const sock = try posix.socket(address.getFamily(), posix.SOCK.DGRAM, 0);
        errdefer posix.close(sock);

        const addr = address.toSockAddr();
        try posix.bind(sock, &addr, @intCast(address.getSockAddrSize()));

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
            @intCast(address.getSockAddrSize()),
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
