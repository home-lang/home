const std = @import("std");
const net = std.net;
const fs = std.fs;
const Method = @import("method.zig").Method;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Router = @import("router.zig").Router;
const Handler = @import("router.zig").Handler;
const MiddlewareStack = @import("middleware.zig").Stack;

/// MIME type mappings for static file serving
const MimeTypes = struct {
    const map = std.StaticStringMap([]const u8).initComptime(.{
        .{ ".html", "text/html" },
        .{ ".htm", "text/html" },
        .{ ".css", "text/css" },
        .{ ".js", "application/javascript" },
        .{ ".json", "application/json" },
        .{ ".xml", "application/xml" },
        .{ ".txt", "text/plain" },
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".jpeg", "image/jpeg" },
        .{ ".gif", "image/gif" },
        .{ ".svg", "image/svg+xml" },
        .{ ".ico", "image/x-icon" },
        .{ ".webp", "image/webp" },
        .{ ".woff", "font/woff" },
        .{ ".woff2", "font/woff2" },
        .{ ".ttf", "font/ttf" },
        .{ ".eot", "application/vnd.ms-fontobject" },
        .{ ".pdf", "application/pdf" },
        .{ ".zip", "application/zip" },
        .{ ".mp3", "audio/mpeg" },
        .{ ".mp4", "video/mp4" },
        .{ ".webm", "video/webm" },
        .{ ".wasm", "application/wasm" },
    });

    pub fn get(extension: []const u8) []const u8 {
        return map.get(extension) orelse "application/octet-stream";
    }
};

/// WebSocket frame opcodes
pub const WebSocketOpcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
};

/// WebSocket connection handler
pub const WebSocketHandler = *const fn (*WebSocketConnection) void;

/// WebSocket connection for bidirectional communication
pub const WebSocketConnection = struct {
    stream: net.Stream,
    allocator: std.mem.Allocator,
    is_open: bool,

    pub fn init(stream: net.Stream, allocator: std.mem.Allocator) WebSocketConnection {
        return .{
            .stream = stream,
            .allocator = allocator,
            .is_open = true,
        };
    }

    /// Send a text message
    pub fn sendText(self: *WebSocketConnection, message: []const u8) !void {
        try self.sendFrame(.text, message);
    }

    /// Send a binary message
    pub fn sendBinary(self: *WebSocketConnection, data: []const u8) !void {
        try self.sendFrame(.binary, data);
    }

    /// Send a ping frame
    pub fn ping(self: *WebSocketConnection) !void {
        try self.sendFrame(.ping, "");
    }

    /// Send a pong frame
    pub fn pong(self: *WebSocketConnection) !void {
        try self.sendFrame(.pong, "");
    }

    /// Close the connection
    pub fn close(self: *WebSocketConnection) !void {
        if (self.is_open) {
            try self.sendFrame(.close, "");
            self.is_open = false;
        }
    }

    /// Receive the next message
    pub fn receive(self: *WebSocketConnection) !?WebSocketMessage {
        if (!self.is_open) return null;

        var header: [2]u8 = undefined;
        const header_read = self.stream.read(&header) catch return null;
        if (header_read < 2) return null;

        const fin = (header[0] & 0x80) != 0;
        const opcode: WebSocketOpcode = @enumFromInt(@as(u4, @truncate(header[0] & 0x0F)));
        const masked = (header[1] & 0x80) != 0;
        var payload_len: u64 = header[1] & 0x7F;

        // Handle extended payload length
        if (payload_len == 126) {
            var len_bytes: [2]u8 = undefined;
            _ = try self.stream.read(&len_bytes);
            payload_len = std.mem.readInt(u16, &len_bytes, .big);
        } else if (payload_len == 127) {
            var len_bytes: [8]u8 = undefined;
            _ = try self.stream.read(&len_bytes);
            payload_len = std.mem.readInt(u64, &len_bytes, .big);
        }

        // Read mask key if present
        var mask_key: [4]u8 = undefined;
        if (masked) {
            _ = try self.stream.read(&mask_key);
        }

        // Read payload
        const payload = try self.allocator.alloc(u8, @intCast(payload_len));
        errdefer self.allocator.free(payload);

        var total_read: usize = 0;
        while (total_read < payload_len) {
            const read = self.stream.read(payload[total_read..]) catch break;
            if (read == 0) break;
            total_read += read;
        }

        // Unmask payload
        if (masked) {
            for (payload, 0..) |*byte, i| {
                byte.* ^= mask_key[i % 4];
            }
        }

        // Handle control frames
        if (opcode == .close) {
            self.is_open = false;
            self.allocator.free(payload);
            return null;
        }

        if (opcode == .ping) {
            try self.pong();
            self.allocator.free(payload);
            return self.receive();
        }

        _ = fin; // For continuation frames (not fully implemented)

        return WebSocketMessage{
            .opcode = opcode,
            .data = payload,
            .allocator = self.allocator,
        };
    }

    fn sendFrame(self: *WebSocketConnection, opcode: WebSocketOpcode, data: []const u8) !void {
        var frame = std.ArrayList(u8).init(self.allocator);
        defer frame.deinit();

        // First byte: FIN bit + opcode
        try frame.append(0x80 | @as(u8, @intFromEnum(opcode)));

        // Second byte: payload length (server frames are not masked)
        if (data.len < 126) {
            try frame.append(@intCast(data.len));
        } else if (data.len <= 65535) {
            try frame.append(126);
            try frame.writer().writeInt(u16, @intCast(data.len), .big);
        } else {
            try frame.append(127);
            try frame.writer().writeInt(u64, data.len, .big);
        }

        // Payload
        try frame.appendSlice(data);

        _ = try self.stream.writeAll(frame.items);
    }
};

/// WebSocket message
pub const WebSocketMessage = struct {
    opcode: WebSocketOpcode,
    data: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *WebSocketMessage) void {
        self.allocator.free(self.data);
    }

    pub fn asText(self: *const WebSocketMessage) []const u8 {
        return self.data;
    }
};

/// Static file server configuration
pub const StaticConfig = struct {
    root_path: []const u8,
    index_file: []const u8 = "index.html",
    cache_control: ?[]const u8 = null,
    enable_directory_listing: bool = false,
};

/// HTTP Server - Laravel-inspired API
pub const Server = struct {
    router: Router,
    middleware: MiddlewareStack,
    allocator: std.mem.Allocator,
    address: net.Address,
    is_running: bool,
    static_config: ?StaticConfig,
    websocket_handlers: std.StringHashMap(WebSocketHandler),
    shutdown_requested: std.atomic.Value(bool),
    active_connections: std.atomic.Value(u32),

    pub fn init(allocator: std.mem.Allocator) !Server {
        return .{
            .router = Router.init(allocator),
            .middleware = MiddlewareStack.init(allocator),
            .allocator = allocator,
            .address = try net.Address.parseIp("127.0.0.1", 3000),
            .is_running = false,
            .static_config = null,
            .websocket_handlers = std.StringHashMap(WebSocketHandler).init(allocator),
            .shutdown_requested = std.atomic.Value(bool).init(false),
            .active_connections = std.atomic.Value(u32).init(0),
        };
    }

    pub fn deinit(self: *Server) void {
        self.router.deinit();
        self.middleware.deinit();
        self.websocket_handlers.deinit();
    }

    /// Set the server address (Laravel-style configuration)
    pub fn setAddress(self: *Server, host: []const u8, port: u16) !void {
        self.address = try net.Address.parseIp(host, port);
    }

    /// Configure static file serving (Express-style)
    pub fn static(self: *Server, root_path: []const u8) void {
        self.static_config = .{
            .root_path = root_path,
        };
    }

    /// Configure static file serving with options
    pub fn staticWithConfig(self: *Server, config: StaticConfig) void {
        self.static_config = config;
    }

    /// Register a WebSocket handler for a path
    pub fn ws(self: *Server, path: []const u8, handler: WebSocketHandler) !void {
        try self.websocket_handlers.put(path, handler);
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
        _ = self.active_connections.fetchAdd(1, .monotonic);
        defer _ = self.active_connections.fetchSub(1, .monotonic);

        var buffer: [8192]u8 = undefined;
        const bytes_read = try connection.stream.read(&buffer);

        if (bytes_read == 0) return;

        const request_data = buffer[0..bytes_read];

        // Parse HTTP request
        const parsed = try self.parseRequest(request_data);
        defer self.allocator.free(parsed.uri);
        defer parsed.headers.deinit();

        // Check for WebSocket upgrade
        if (self.isWebSocketUpgrade(&parsed)) {
            try self.handleWebSocketUpgrade(connection, &parsed);
            return;
        }

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
            // Try static file serving first
            if (self.static_config != null and parsed.method == .GET) {
                if (try self.tryServeStaticFile(parsed.uri, res)) {
                    const response_bytes = try res.build();
                    defer self.allocator.free(response_bytes);
                    _ = try connection.stream.writeAll(response_bytes);
                    return;
                }
            }

            // Handle the request with the router
            try self.router.handle(req, res);
        }

        // Build and send the response
        const response_bytes = try res.build();
        defer self.allocator.free(response_bytes);

        _ = try connection.stream.writeAll(response_bytes);
    }

    /// Check if request is a WebSocket upgrade
    fn isWebSocketUpgrade(self: *Server, parsed: *const ParsedRequest) bool {
        _ = self;
        const upgrade = parsed.headers.get("Upgrade") orelse return false;
        const connection_header = parsed.headers.get("Connection") orelse return false;

        return std.ascii.eqlIgnoreCase(upgrade, "websocket") and
            std.mem.indexOf(u8, connection_header, "Upgrade") != null;
    }

    /// Handle WebSocket upgrade
    fn handleWebSocketUpgrade(self: *Server, connection: net.Server.Connection, parsed: *const ParsedRequest) !void {
        const ws_key = parsed.headers.get("Sec-WebSocket-Key") orelse return error.MissingWebSocketKey;

        // Check if we have a handler for this path
        const handler = self.websocket_handlers.get(parsed.uri) orelse {
            // No handler, send 404
            const response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
            _ = try connection.stream.writeAll(response);
            return;
        };

        // Generate accept key
        const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
        var key_with_magic: [60 + magic.len]u8 = undefined;
        @memcpy(key_with_magic[0..ws_key.len], ws_key);
        @memcpy(key_with_magic[ws_key.len..][0..magic.len], magic);

        var hash: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(key_with_magic[0 .. ws_key.len + magic.len], &hash, .{});

        const encoder = std.base64.standard;
        var accept_key: [28]u8 = undefined;
        _ = encoder.encode(&accept_key, &hash);

        // Send upgrade response
        var response_buf: [256]u8 = undefined;
        const response = std.fmt.bufPrint(&response_buf,
            \\HTTP/1.1 101 Switching Protocols
            \\Upgrade: websocket
            \\Connection: Upgrade
            \\Sec-WebSocket-Accept: {s}
            \\
            \\
        , .{accept_key}) catch return error.BufferTooSmall;

        _ = try connection.stream.writeAll(response);

        // Create WebSocket connection and call handler
        var ws_conn = WebSocketConnection.init(connection.stream, self.allocator);
        handler(&ws_conn);
    }

    /// Try to serve a static file
    fn tryServeStaticFile(self: *Server, uri: []const u8, res: *Response) !bool {
        const config = self.static_config orelse return false;

        // Security: prevent directory traversal
        if (std.mem.indexOf(u8, uri, "..") != null) {
            _ = res.setStatus(.Forbidden);
            try res.send("Forbidden");
            return true;
        }

        // Build file path
        var path_buf: [4096]u8 = undefined;
        var file_path: []const u8 = undefined;

        if (std.mem.eql(u8, uri, "/")) {
            file_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ config.root_path, config.index_file }) catch return false;
        } else {
            // Remove leading slash
            const clean_uri = if (uri.len > 0 and uri[0] == '/') uri[1..] else uri;
            file_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ config.root_path, clean_uri }) catch return false;
        }

        // Try to open and read the file
        const file = fs.cwd().openFile(file_path, .{}) catch |err| {
            switch (err) {
                error.FileNotFound => return false, // Let router handle it
                else => {
                    _ = res.setStatus(.InternalServerError);
                    try res.send("Internal Server Error");
                    return true;
                },
            }
        };
        defer file.close();

        // Get file size
        const stat = file.stat() catch {
            _ = res.setStatus(.InternalServerError);
            try res.send("Internal Server Error");
            return true;
        };

        // Read file content
        const content = self.allocator.alloc(u8, @intCast(stat.size)) catch {
            _ = res.setStatus(.InternalServerError);
            try res.send("Internal Server Error");
            return true;
        };
        defer self.allocator.free(content);

        _ = file.readAll(content) catch {
            _ = res.setStatus(.InternalServerError);
            try res.send("Internal Server Error");
            return true;
        };

        // Determine MIME type from extension
        const extension = std.fs.path.extension(file_path);
        const mime_type = MimeTypes.get(extension);

        _ = try res.setHeader("Content-Type", mime_type);

        // Set cache control if configured
        if (config.cache_control) |cache_control| {
            _ = try res.setHeader("Cache-Control", cache_control);
        }

        try res.body.appendSlice(self.allocator, content);
        return true;
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
        self.shutdown_requested.store(true, .release);
    }

    /// Gracefully shutdown with timeout (waits for active connections)
    pub fn gracefulShutdown(self: *Server, timeout_ms: u64) void {
        self.shutdown_requested.store(true, .release);
        self.is_running = false;

        // Wait for active connections to complete
        const start = std.time.milliTimestamp();
        while (self.active_connections.load(.acquire) > 0) {
            if (std.time.milliTimestamp() - start > @as(i64, @intCast(timeout_ms))) {
                std.debug.print("Graceful shutdown timeout, forcing close\n", .{});
                break;
            }
            std.time.sleep(10 * std.time.ns_per_ms);
        }
    }

    /// Get the number of active connections
    pub fn getActiveConnections(self: *Server) u32 {
        return self.active_connections.load(.acquire);
    }

    /// Check if shutdown was requested
    pub fn isShuttingDown(self: *Server) bool {
        return self.shutdown_requested.load(.acquire);
    }

    /// Create a route group with a prefix
    pub fn group(self: *Server, prefix: []const u8) RouteGroup {
        return RouteGroup{
            .server = self,
            .prefix = prefix,
        };
    }
};

/// Route group for organizing routes with a common prefix
pub const RouteGroup = struct {
    server: *Server,
    prefix: []const u8,

    pub fn get(self: *RouteGroup, path: []const u8, handler: Handler) !void {
        var full_path: [256]u8 = undefined;
        const len = std.fmt.bufPrint(&full_path, "{s}{s}", .{ self.prefix, path }) catch return error.PathTooLong;
        try self.server.router.get(len, handler);
    }

    pub fn post(self: *RouteGroup, path: []const u8, handler: Handler) !void {
        var full_path: [256]u8 = undefined;
        const len = std.fmt.bufPrint(&full_path, "{s}{s}", .{ self.prefix, path }) catch return error.PathTooLong;
        try self.server.router.post(len, handler);
    }

    pub fn put(self: *RouteGroup, path: []const u8, handler: Handler) !void {
        var full_path: [256]u8 = undefined;
        const len = std.fmt.bufPrint(&full_path, "{s}{s}", .{ self.prefix, path }) catch return error.PathTooLong;
        try self.server.router.put(len, handler);
    }

    pub fn delete(self: *RouteGroup, path: []const u8, handler: Handler) !void {
        var full_path: [256]u8 = undefined;
        const len = std.fmt.bufPrint(&full_path, "{s}{s}", .{ self.prefix, path }) catch return error.PathTooLong;
        try self.server.router.delete(len, handler);
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

test "Server static file configuration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var server = try Server.init(allocator);
    defer server.deinit();

    server.static("./public");
    try testing.expect(server.static_config != null);
    try testing.expectEqualStrings("./public", server.static_config.?.root_path);
    try testing.expectEqualStrings("index.html", server.static_config.?.index_file);
}

test "Server static file configuration with options" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var server = try Server.init(allocator);
    defer server.deinit();

    server.staticWithConfig(.{
        .root_path = "./static",
        .index_file = "main.html",
        .cache_control = "max-age=3600",
        .enable_directory_listing = true,
    });

    try testing.expect(server.static_config != null);
    try testing.expectEqualStrings("./static", server.static_config.?.root_path);
    try testing.expectEqualStrings("main.html", server.static_config.?.index_file);
    try testing.expectEqualStrings("max-age=3600", server.static_config.?.cache_control.?);
    try testing.expect(server.static_config.?.enable_directory_listing);
}

test "Server WebSocket handler registration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var server = try Server.init(allocator);
    defer server.deinit();

    const ws_handler: WebSocketHandler = struct {
        fn handle(_: *WebSocketConnection) void {}
    }.handle;

    try server.ws("/chat", ws_handler);
    try testing.expect(server.websocket_handlers.get("/chat") != null);
}

test "Server graceful shutdown" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var server = try Server.init(allocator);
    defer server.deinit();

    try testing.expect(!server.isShuttingDown());
    server.stop();
    try testing.expect(server.isShuttingDown());
    try testing.expect(!server.is_running);
}

test "Server active connections tracking" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var server = try Server.init(allocator);
    defer server.deinit();

    try testing.expectEqual(@as(u32, 0), server.getActiveConnections());
}

test "MIME types" {
    try std.testing.expectEqualStrings("text/html", MimeTypes.get(".html"));
    try std.testing.expectEqualStrings("text/css", MimeTypes.get(".css"));
    try std.testing.expectEqualStrings("application/javascript", MimeTypes.get(".js"));
    try std.testing.expectEqualStrings("application/json", MimeTypes.get(".json"));
    try std.testing.expectEqualStrings("image/png", MimeTypes.get(".png"));
    try std.testing.expectEqualStrings("application/wasm", MimeTypes.get(".wasm"));
    try std.testing.expectEqualStrings("application/octet-stream", MimeTypes.get(".unknown"));
}

test "WebSocket message" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const data = try allocator.dupe(u8, "Hello, WebSocket!");
    var msg = WebSocketMessage{
        .opcode = .text,
        .data = data,
        .allocator = allocator,
    };
    defer msg.deinit();

    try testing.expectEqualStrings("Hello, WebSocket!", msg.asText());
}
