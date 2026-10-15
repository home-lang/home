// Networking Library for Home Language
// Provides TCP/UDP sockets through Zig's injectable std.Io networking APIs.

const std = @import("std");
const posix = std.posix;
const net = std.Io.net;
const Allocator = std.mem.Allocator;
const compat = @import("compat.zig");

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
        var addr: [16]u8 = @splat(0);

        // Handle :: notation (zero compression)
        if (std.mem.indexOf(u8, ip_str, "::")) |double_colon_pos| {
            const before = ip_str[0..double_colon_pos];
            const after = ip_str[double_colon_pos + 2 ..];

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
            var after_list: std.ArrayList(u16) = .empty;
            defer after_list.deinit(std.heap.page_allocator);
            while (after_parts.next()) |part| {
                if (part.len == 0) continue;
                const value = try std.fmt.parseInt(u16, part, 16);
                try after_list.append(std.heap.page_allocator, value);
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
        var addr: [16]u8 = @splat(0);
        addr[15] = 1; // ::1
        return initIp6(addr, port);
    }

    /// Get any address (0.0.0.0 for IPv4, :: for IPv6)
    pub fn any(port: u16) Address {
        return initIp4([_]u8{ 0, 0, 0, 0 }, port);
    }

    pub fn any6(port: u16) Address {
        return initIp6(@splat(0), port);
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

    /// Convert to Zig's injectable I/O address representation.
    pub fn toIo(self: Address) net.IpAddress {
        return switch (self) {
            .ipv4 => |address| .{ .ip4 = .{
                .bytes = address.addr,
                .port = address.port,
            } },
            .ipv6 => |address| .{ .ip6 = .{
                .bytes = address.addr,
                .port = address.port,
                .flow = address.flowinfo,
                .interface = .{ .index = address.scope_id },
            } },
        };
    }

    /// Convert from Zig's injectable I/O address representation.
    pub fn fromIo(address: net.IpAddress) Address {
        return switch (address) {
            .ip4 => |ip4| initIp4(ip4.bytes, ip4.port),
            .ip6 => |ip6| .{ .ipv6 = .{
                .port = ip6.port,
                .addr = ip6.bytes,
                .flowinfo = ip6.flow,
                .scope_id = ip6.interface.index,
            } },
        };
    }

    /// Convert to posix sockaddr
    pub fn toSockAddr(self: Address) posix.sockaddr {
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
    pub fn getSockAddrSize(self: Address) usize {
        return switch (self) {
            .ipv4 => @sizeOf(posix.sockaddr.in),
            .ipv6 => @sizeOf(posix.sockaddr.in6),
        };
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
    io: std.Io,
    stream: net.Stream,
    local_address: Address,
    remote_address: Address,
    read_timeout: std.Io.Timeout = .none,

    /// Connect to address
    pub fn connect(address: Address) !TcpStream {
        return connectWithIo(compat.io(), address);
    }

    /// Connect using an explicitly supplied I/O implementation.
    pub fn connectWithIo(io: std.Io, address: Address) !TcpStream {
        const remote_address = address.toIo();
        const stream = try remote_address.connect(io, .{
            .mode = .stream,
            .protocol = .tcp,
        });
        return .{
            .io = io,
            .stream = stream,
            .local_address = .fromIo(stream.socket.address),
            .remote_address = address,
        };
    }

    /// Close connection
    pub fn close(self: *TcpStream) void {
        self.stream.close(self.io);
    }

    /// Read bytes (returns number read)
    pub fn read(self: *TcpStream, buffer: []u8) !usize {
        var data = [1][]u8{buffer};
        if (self.read_timeout == .none) return self.stream.read(self.io, &data);

        const result = try self.io.operateTimeout(.{ .net_read = .{
            .socket_handle = self.stream.socket.handle,
            .data = &data,
        } }, self.read_timeout);
        return compat.netReadLength(try result.net_read);
    }

    /// Read exact number of bytes
    pub fn readAll(self: *TcpStream, buffer: []u8) !void {
        var total: usize = 0;
        while (total < buffer.len) {
            const n = try self.read(buffer[total..]);
            if (n == 0) return error.EndOfStream;
            total += n;
        }
    }

    /// Write bytes
    pub fn write(self: *TcpStream, bytes: []const u8) !void {
        var written: usize = 0;
        while (written < bytes.len) {
            const data = [1][]const u8{bytes[written..]};
            const result = try self.io.operate(.{ .net_write = .{
                .socket_handle = self.stream.socket.handle,
                .data = &data,
            } });
            const n = try result.net_write;
            if (n == 0) return error.WriteZero;
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
        const milliseconds = std.math.cast(i64, timeout_ms) orelse return error.InvalidTimeout;
        self.read_timeout = compat.timeoutMilliseconds(milliseconds);
    }

    /// Get local address
    pub fn localAddress(self: *TcpStream) !Address {
        return self.local_address;
    }

    /// Get remote address
    pub fn remoteAddress(self: *TcpStream) !Address {
        return self.remote_address;
    }
};

// ==================== TCP Server ====================

pub const TcpListener = struct {
    io: std.Io,
    server: net.Server,
    address: Address,

    /// Bind to address and listen
    pub fn bind(address: Address) !TcpListener {
        return bindWithIo(compat.io(), address);
    }

    /// Bind using an explicitly supplied I/O implementation.
    pub fn bindWithIo(io: std.Io, address: Address) !TcpListener {
        const io_address = address.toIo();
        const server = try io_address.listen(io, .{
            .kernel_backlog = 128,
            // std.Io enables SO_REUSEPORT together with SO_REUSEADDR here,
            // which would allow another listener to claim the same live port.
            .reuse_address = false,
        });
        return .{
            .io = io,
            .server = server,
            .address = .fromIo(server.socket.address),
        };
    }

    /// Bind to any address
    pub fn bindAny(port: u16) !TcpListener {
        return bind(Address.any(port));
    }

    pub fn bindAnyWithIo(io: std.Io, port: u16) !TcpListener {
        return bindWithIo(io, Address.any(port));
    }

    /// Bind to localhost
    pub fn bindLocalhost(port: u16) !TcpListener {
        return bind(Address.localhost(port));
    }

    pub fn bindLocalhostWithIo(io: std.Io, port: u16) !TcpListener {
        return bindWithIo(io, Address.localhost(port));
    }

    /// Close listener
    pub fn deinit(self: *TcpListener) void {
        self.server.deinit(self.io);
    }

    /// Accept connection
    pub fn accept(self: *TcpListener) !TcpConnection {
        const stream = try self.server.accept(self.io);
        const remote_address: Address = .fromIo(stream.socket.address);
        return .{
            .stream = .{
                .io = self.io,
                .stream = stream,
                .local_address = self.address,
                .remote_address = remote_address,
            },
            .address = remote_address,
        };
    }

    /// Get local address
    pub fn localAddress(self: *TcpListener) !Address {
        return self.address;
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
    io: std.Io,
    socket: net.Socket,
    read_timeout: std.Io.Timeout = .none,

    /// Bind to address
    pub fn bind(address: Address) !UdpSocket {
        return bindWithIo(compat.io(), address);
    }

    /// Bind using an explicitly supplied I/O implementation.
    pub fn bindWithIo(io: std.Io, address: Address) !UdpSocket {
        const io_address = address.toIo();
        return .{
            .io = io,
            .socket = try io_address.bind(io, .{
                .mode = .dgram,
                .protocol = .udp,
            }),
        };
    }

    /// Bind to any address
    pub fn bindAny(port: u16) !UdpSocket {
        return bind(Address.any(port));
    }

    pub fn bindAnyWithIo(io: std.Io, port: u16) !UdpSocket {
        return bindWithIo(io, Address.any(port));
    }

    /// Bind to localhost
    pub fn bindLocalhost(port: u16) !UdpSocket {
        return bind(Address.localhost(port));
    }

    pub fn bindLocalhostWithIo(io: std.Io, port: u16) !UdpSocket {
        return bindWithIo(io, Address.localhost(port));
    }

    /// Close socket
    pub fn close(self: *UdpSocket) void {
        self.socket.close(self.io);
    }

    /// Send datagram
    pub fn sendTo(self: *UdpSocket, data: []const u8, address: Address) !usize {
        const destination = address.toIo();
        try self.socket.send(self.io, &destination, data);
        return data.len;
    }

    /// Receive datagram
    pub fn recvFrom(self: *UdpSocket, buffer: []u8) !struct { size: usize, address: Address } {
        const message = if (self.read_timeout == .none)
            try self.socket.receive(self.io, buffer)
        else
            try self.socket.receiveTimeout(self.io, buffer, self.read_timeout);

        return .{
            .size = message.data.len,
            .address = .fromIo(message.from),
        };
    }

    /// Set read timeout
    pub fn setReadTimeout(self: *UdpSocket, timeout_ms: u64) !void {
        const milliseconds = std.math.cast(i64, timeout_ms) orelse return error.InvalidTimeout;
        self.read_timeout = compat.timeoutMilliseconds(milliseconds);
    }

    /// Get local address
    pub fn localAddress(self: *UdpSocket) !Address {
        return .fromIo(self.socket.address);
    }
};

// ==================== Utility Functions ====================

/// Check if port is available
pub fn isPortAvailable(port: u16) bool {
    return isPortAvailableWithIo(compat.io(), port);
}

pub fn isPortAvailableWithIo(io: std.Io, port: u16) bool {
    var listener = TcpListener.bindAnyWithIo(io, port) catch return false;
    listener.deinit();
    return true;
}

/// Find available port in range
pub fn findAvailablePort(start: u16, end: u16) ?u16 {
    return findAvailablePortWithIo(compat.io(), start, end);
}

pub fn findAvailablePortWithIo(io: std.Io, start: u16, end: u16) ?u16 {
    var port = start;
    while (port <= end) : (port += 1) {
        if (isPortAvailableWithIo(io, port)) return port;
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
    try testing.expectEqual(@as(u8, 127), local.ipv4.addr[0]);

    const any = Address.any(9000);
    try testing.expectEqual(@as(u16, 9000), any.getPort());
    try testing.expectEqual(@as(u8, 0), any.ipv4.addr[0]);
}

test "TcpListener - bind and local address" {
    const testing = std.testing;

    var listener = try TcpListener.bindLocalhostWithIo(std.testing.io, 0);
    defer listener.deinit();

    const addr = try listener.localAddress();
    const port = addr.getPort();
    try testing.expect(port > 0);
}

test "TCP - client server echo" {
    const testing = std.testing;

    // Start server
    var listener = try TcpListener.bindLocalhostWithIo(std.testing.io, 0);
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

    // Connect client
    var client = try TcpStream.connectWithIo(std.testing.io, Address.localhost(port));
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

    var socket1 = try UdpSocket.bindLocalhostWithIo(std.testing.io, 0);
    defer socket1.close();

    var socket2 = try UdpSocket.bindLocalhostWithIo(std.testing.io, 0);
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

test "TCP and UDP read timeouts remain observable" {
    const testing = std.testing;

    var listener = try TcpListener.bindLocalhostWithIo(testing.io, 0);
    defer listener.deinit();

    var client = try TcpStream.connectWithIo(testing.io, Address.localhost(listener.address.getPort()));
    defer client.close();
    var connection = try listener.accept();
    defer connection.close();

    try client.setReadTimeout(1);
    var tcp_buffer: [1]u8 = undefined;
    try testing.expectError(error.Timeout, client.read(&tcp_buffer));

    var socket = try UdpSocket.bindLocalhostWithIo(testing.io, 0);
    defer socket.close();
    try socket.setReadTimeout(1);
    var udp_buffer: [1]u8 = undefined;
    try testing.expectError(error.Timeout, socket.recvFrom(&udp_buffer));
}

test "Port availability" {
    const testing = std.testing;

    var listener = try TcpListener.bindLocalhostWithIo(std.testing.io, 0);
    defer listener.deinit();

    const addr = try listener.localAddress();
    const port = addr.getPort();

    // Port should not be available
    try testing.expect(!isPortAvailableWithIo(std.testing.io, port));
}

test "Find available port" {
    const testing = std.testing;

    const port = findAvailablePortWithIo(std.testing.io, 50000, 50100);
    try testing.expect(port != null);

    if (port) |p| {
        try testing.expect(p >= 50000);
        try testing.expect(p <= 50100);
    }
}
