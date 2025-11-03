const std = @import("std");
const net = std.net;
const Method = @import("method.zig").Method;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Router = @import("router.zig").Router;
const Handler = @import("router.zig").Handler;
const MiddlewareStack = @import("middleware.zig").Stack;

/// HTTP Server - Laravel-inspired API
pub const Server = struct {
    router: Router,
    middleware: MiddlewareStack,
    allocator: std.mem.Allocator,
    address: net.Address,
    is_running: bool,

    pub fn init(allocator: std.mem.Allocator) !Server {
        return .{
            .router = Router.init(allocator),
            .middleware = MiddlewareStack.init(allocator),
            .allocator = allocator,
            .address = try net.Address.parseIp("127.0.0.1", 3000),
            .is_running = false,
        };
    }

    pub fn deinit(self: *Server) void {
        self.router.deinit();
        self.middleware.deinit();
    }

    /// Set the server address (Laravel-style configuration)
    pub fn setAddress(self: *Server, host: []const u8, port: u16) !void {
        self.address = try net.Address.parseIp(host, port);
    }

    /// Register a GET route (Laravel-style)
    pub fn get(self: *Server, path: []const u8, handler: Handler) !void {
        try self.router.get(path, handler);
    }

    /// Register a POST route
    pub fn post(self: *Server, path: []const u8, handler: Handler) !void {
        try self.router.post(path, handler);
    }

    /// Register a PUT route
    pub fn put(self: *Server, path: []const u8, handler: Handler) !void {
        try self.router.put(path, handler);
    }

    /// Register a DELETE route
    pub fn delete(self: *Server, path: []const u8, handler: Handler) !void {
        try self.router.delete(path, handler);
    }

    /// Register a PATCH route
    pub fn patch(self: *Server, path: []const u8, handler: Handler) !void {
        try self.router.patch(path, handler);
    }

    /// Add global middleware (Laravel-style)
    pub fn use(self: *Server, name: []const u8, handler: anytype) !void {
        try self.middleware.use(name, handler);
    }

    /// Start the server and listen for connections
    pub fn listen(self: *Server, port: u16) !void {
        self.address = try net.Address.parseIp("127.0.0.1", port);
        try self.listenAndServe();
    }

    /// Start the server on the configured address
    pub fn listenAndServe(self: *Server) !void {
        var server = try self.address.listen(.{
            .reuse_address = true,
        });
        defer server.deinit();

        self.is_running = true;

        std.debug.print("Server listening on {}\n", .{self.address});

        while (self.is_running) {
            const connection = try server.accept();
            defer connection.stream.close();

            // Handle the request
            self.handleConnection(connection) catch |err| {
                std.debug.print("Error handling connection: {}\n", .{err});
            };
        }
    }

    /// Handle a single client connection
    fn handleConnection(self: *Server, connection: net.Server.Connection) !void {
        var buffer: [4096]u8 = undefined;
        const bytes_read = try connection.stream.read(&buffer);

        if (bytes_read == 0) return;

        const request_data = buffer[0..bytes_read];

        // Parse HTTP request
        const parsed = try self.parseRequest(request_data);
        defer self.allocator.free(parsed.uri);

        var req = try Request.init(self.allocator, parsed.method, parsed.uri);
        defer req.deinit();

        // Set headers from parsed request
        var header_it = parsed.headers.iterator();
        while (header_it.next()) |entry| {
            try req.headers.set(entry.key_ptr.*, entry.value_ptr.*);
        }

        // Set body if present
        if (parsed.body.len > 0) {
            try req.setBody(parsed.body);
        }

        var res = Response.init(self.allocator);
        defer res.deinit();

        // Execute middleware stack
        const should_continue = try self.middleware.execute(req, res);

        if (should_continue) {
            // Handle the request with the router
            try self.router.handle(req, res);
        }

        // Build and send the response
        const response_bytes = try res.build();
        defer self.allocator.free(response_bytes);

        _ = try connection.stream.writeAll(response_bytes);
    }

    /// Parse HTTP request (simple implementation)
    const ParsedRequest = struct {
        method: Method,
        uri: []u8,
        headers: std.StringHashMap([]const u8),
        body: []const u8,
    };

    fn parseRequest(self: *Server, data: []const u8) !ParsedRequest {
        var headers = std.StringHashMap([]const u8).init(self.allocator);
        errdefer headers.deinit();

        // Split request into lines
        var line_it = std.mem.splitSequence(u8, data, "\r\n");

        // Parse request line (GET /path HTTP/1.1)
        const request_line = line_it.next() orelse return error.InvalidRequest;
        var parts_it = std.mem.splitSequence(u8, request_line, " ");

        const method_str = parts_it.next() orelse return error.InvalidMethod;
        const uri_str = parts_it.next() orelse return error.InvalidURI;

        const method = Method.fromString(method_str) orelse .GET;
        const uri = try self.allocator.dupe(u8, uri_str);

        // Parse headers
        while (line_it.next()) |line| {
            if (line.len == 0) break; // Empty line marks end of headers

            if (std.mem.indexOf(u8, line, ":")) |colon_idx| {
                const name = std.mem.trim(u8, line[0..colon_idx], " ");
                const value = std.mem.trim(u8, line[colon_idx + 1 ..], " ");
                try headers.put(name, value);
            }
        }

        // Remaining data is the body
        const body_start = if (std.mem.indexOf(u8, data, "\r\n\r\n")) |idx| idx + 4 else data.len;
        const body = if (body_start < data.len) data[body_start..] else "";

        return .{
            .method = method,
            .uri = uri,
            .headers = headers,
            .body = body,
        };
    }

    /// Gracefully stop the server
    pub fn stop(self: *Server) void {
        self.is_running = false;
    }
};

test "Server creation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var server = try Server.init(allocator);
    defer server.deinit();

    try testing.expect(!server.is_running);
}

test "Server route registration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var server = try Server.init(allocator);
    defer server.deinit();

    const handler: Handler = struct {
        fn handle(_: *Request, res: *Response) !void {
            try res.send("Hello");
        }
    }.handle;

    try server.get("/test", handler);

    const route = server.router.findRoute(.GET, "/test");
    try testing.expect(route != null);
}
