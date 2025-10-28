const std = @import("std");

/// TCP Client
pub const TcpClient = struct {
    stream: std.net.Stream,
    allocator: std.mem.Allocator,

    pub fn connect(allocator: std.mem.Allocator, host: []const u8, port: u16) !*TcpClient {
        const address = try std.net.Address.parseIp(host, port);

        const client = try allocator.create(TcpClient);
        client.* = .{
            .stream = try std.net.tcpConnectToAddress(address),
            .allocator = allocator,
        };

        return client;
    }

    pub fn close(self: *TcpClient) void {
        self.stream.close();
        self.allocator.destroy(self);
    }

    pub fn read(self: *TcpClient, buffer: []u8) !usize {
        return try self.stream.read(buffer);
    }

    pub fn write(self: *TcpClient, data: []const u8) !usize {
        return try self.stream.write(data);
    }

    pub fn writeAll(self: *TcpClient, data: []const u8) !void {
        try self.stream.writeAll(data);
    }
};

/// TCP Server
pub const TcpServer = struct {
    server: std.net.Server,
    allocator: std.mem.Allocator,

    pub fn listen(allocator: std.mem.Allocator, host: []const u8, port: u16) !*TcpServer {
        const address = try std.net.Address.parseIp(host, port);

        var server = try address.listen(.{
            .reuse_address = true,
        });

        const tcp_server = try allocator.create(TcpServer);
        tcp_server.* = .{
            .server = server,
            .allocator = allocator,
        };

        return tcp_server;
    }

    pub fn close(self: *TcpServer) void {
        self.server.deinit();
        self.allocator.destroy(self);
    }

    pub fn accept(self: *TcpServer) !TcpConnection {
        const conn = try self.server.accept();
        return TcpConnection{
            .stream = conn.stream,
            .address = conn.address,
        };
    }
};

pub const TcpConnection = struct {
    stream: std.net.Stream,
    address: std.net.Address,

    pub fn close(self: *TcpConnection) void {
        self.stream.close();
    }

    pub fn read(self: *TcpConnection, buffer: []u8) !usize {
        return try self.stream.read(buffer);
    }

    pub fn write(self: *TcpConnection, data: []const u8) !usize {
        return try self.stream.write(data);
    }
};

/// UDP Socket
pub const UdpSocket = struct {
    socket: std.posix.socket_t,
    address: std.net.Address,
    allocator: std.mem.Allocator,

    pub fn bind(allocator: std.mem.Allocator, host: []const u8, port: u16) !*UdpSocket {
        const address = try std.net.Address.parseIp(host, port);

        const socket = try std.posix.socket(
            address.any.family,
            std.posix.SOCK.DGRAM,
            std.posix.IPPROTO.UDP,
        );

        try std.posix.bind(socket, &address.any, address.getOsSockLen());

        const udp_socket = try allocator.create(UdpSocket);
        udp_socket.* = .{
            .socket = socket,
            .address = address,
            .allocator = allocator,
        };

        return udp_socket;
    }

    pub fn close(self: *UdpSocket) void {
        std.posix.close(self.socket);
        self.allocator.destroy(self);
    }

    pub fn sendTo(self: *UdpSocket, data: []const u8, dest: std.net.Address) !usize {
        return try std.posix.sendto(
            self.socket,
            data,
            0,
            &dest.any,
            dest.getOsSockLen(),
        );
    }

    pub fn recvFrom(self: *UdpSocket, buffer: []u8) !struct { usize, std.net.Address } {
        var addr: std.posix.sockaddr = undefined;
        var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

        const len = try std.posix.recvfrom(
            self.socket,
            buffer,
            0,
            &addr,
            &addr_len,
        );

        const address = std.net.Address.initPosix(@alignCast(&addr));

        return .{ len, address };
    }
};

/// HTTP client
pub const HttpClient = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HttpClient {
        return .{ .allocator = allocator };
    }

    /// Perform HTTP GET request
    pub fn get(self: *HttpClient, url: []const u8) !HttpResponse {
        return try self.request(.GET, url, null, null);
    }

    /// Perform HTTP POST request
    pub fn post(self: *HttpClient, url: []const u8, body: []const u8, content_type: ?[]const u8) !HttpResponse {
        var headers = std.ArrayList(HttpHeader).init(self.allocator);
        defer headers.deinit();

        if (content_type) |ct| {
            try headers.append(.{
                .name = "Content-Type",
                .value = ct,
            });
        }

        return try self.request(.POST, url, body, headers.items);
    }

    /// Perform HTTP request
    pub fn request(
        self: *HttpClient,
        method: HttpMethod,
        url: []const u8,
        body: ?[]const u8,
        headers: ?[]HttpHeader,
    ) !HttpResponse {
        // Parse URL
        const uri = try std.Uri.parse(url);

        // Connect to server
        const port = uri.port orelse (if (std.mem.eql(u8, uri.scheme, "https")) @as(u16, 443) else @as(u16, 80));

        const host = uri.host.?.percent_encoded;

        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();

        // Create request
        var req_headers = std.http.Headers{ .allocator = self.allocator };
        defer req_headers.deinit();

        try req_headers.append("Host", host);
        try req_headers.append("User-Agent", "Home/0.1.0");
        try req_headers.append("Accept", "*/*");

        if (headers) |h| {
            for (h) |header| {
                try req_headers.append(header.name, header.value);
            }
        }

        // Send request
        var request_buffer: [8192]u8 = undefined;
        var req = try client.open(
            switch (method) {
                .GET => .GET,
                .POST => .POST,
                .PUT => .PUT,
                .DELETE => .DELETE,
                .PATCH => .PATCH,
            },
            try std.Uri.parse(url),
            .{
                .server_header_buffer = &request_buffer,
                .extra_headers = req_headers.list.items,
            },
        );
        defer req.deinit();

        if (body) |b| {
            req.transfer_encoding = .{ .content_length = b.len };
        } else {
            req.transfer_encoding = .{ .content_length = 0 };
        }

        try req.send();

        if (body) |b| {
            try req.writeAll(b);
        }
        try req.finish();

        try req.wait();

        // Read response
        var response_body = std.ArrayList(u8).init(self.allocator);

        const max_read = 10 * 1024 * 1024; // 10MB
        try req.reader().readAllArrayList(&response_body, max_read);

        return HttpResponse{
            .status = @intFromEnum(req.response.status),
            .body = try response_body.toOwnedSlice(),
            .allocator = self.allocator,
        };
    }
};

pub const HttpMethod = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
};

pub const HttpHeader = struct {
    name: []const u8,
    value: []const u8,
};

pub const HttpResponse = struct {
    status: u16,
    body: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *HttpResponse) void {
        self.allocator.free(self.body);
    }

    pub fn text(self: *HttpResponse) []const u8 {
        return self.body;
    }
};

/// DNS resolution
pub fn resolve(allocator: std.mem.Allocator, hostname: []const u8) ![]std.net.Address {
    const addresses = try std.net.getAddressList(allocator, hostname, 0);
    defer addresses.deinit();

    var result = std.ArrayList(std.net.Address).init(allocator);

    for (addresses.addrs) |addr| {
        try result.append(addr);
    }

    return result.toOwnedSlice();
}
