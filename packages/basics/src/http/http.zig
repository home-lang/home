const std = @import("std");

/// HTTP client and server implementation
pub const Http = struct {
    /// HTTP methods
    pub const Method = enum {
        GET,
        POST,
        PUT,
        DELETE,
        PATCH,
        HEAD,
        OPTIONS,

        pub fn toString(self: Method) []const u8 {
            return switch (self) {
                .GET => "GET",
                .POST => "POST",
                .PUT => "PUT",
                .DELETE => "DELETE",
                .PATCH => "PATCH",
                .HEAD => "HEAD",
                .OPTIONS => "OPTIONS",
            };
        }
    };

    /// HTTP status codes
    pub const Status = enum(u16) {
        // 1xx Informational
        Continue = 100,
        SwitchingProtocols = 101,

        // 2xx Success
        OK = 200,
        Created = 201,
        Accepted = 202,
        NoContent = 204,

        // 3xx Redirection
        MovedPermanently = 301,
        Found = 302,
        SeeOther = 303,
        NotModified = 304,
        TemporaryRedirect = 307,
        PermanentRedirect = 308,

        // 4xx Client Error
        BadRequest = 400,
        Unauthorized = 401,
        Forbidden = 403,
        NotFound = 404,
        MethodNotAllowed = 405,
        Conflict = 409,
        Gone = 410,
        TooManyRequests = 429,

        // 5xx Server Error
        InternalServerError = 500,
        NotImplemented = 501,
        BadGateway = 502,
        ServiceUnavailable = 503,
        GatewayTimeout = 504,

        pub fn toString(self: Status) []const u8 {
            return switch (self) {
                .Continue => "Continue",
                .SwitchingProtocols => "Switching Protocols",
                .OK => "OK",
                .Created => "Created",
                .Accepted => "Accepted",
                .NoContent => "No Content",
                .MovedPermanently => "Moved Permanently",
                .Found => "Found",
                .SeeOther => "See Other",
                .NotModified => "Not Modified",
                .TemporaryRedirect => "Temporary Redirect",
                .PermanentRedirect => "Permanent Redirect",
                .BadRequest => "Bad Request",
                .Unauthorized => "Unauthorized",
                .Forbidden => "Forbidden",
                .NotFound => "Not Found",
                .MethodNotAllowed => "Method Not Allowed",
                .Conflict => "Conflict",
                .Gone => "Gone",
                .TooManyRequests => "Too Many Requests",
                .InternalServerError => "Internal Server Error",
                .NotImplemented => "Not Implemented",
                .BadGateway => "Bad Gateway",
                .ServiceUnavailable => "Service Unavailable",
                .GatewayTimeout => "Gateway Timeout",
            };
        }
    };

    /// HTTP headers
    pub const Headers = struct {
        map: std.StringHashMap([]const u8),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Headers {
            return .{
                .map = std.StringHashMap([]const u8).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Headers) void {
            self.map.deinit();
        }

        pub fn set(self: *Headers, key: []const u8, value: []const u8) !void {
            try self.map.put(key, value);
        }

        pub fn get(self: *const Headers, key: []const u8) ?[]const u8 {
            return self.map.get(key);
        }

        pub fn remove(self: *Headers, key: []const u8) bool {
            return self.map.remove(key);
        }
    };

    /// HTTP request
    pub const Request = struct {
        method: Method,
        url: []const u8,
        headers: Headers,
        body: ?[]const u8,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, method: Method, url: []const u8) Request {
            return .{
                .method = method,
                .url = url,
                .headers = Headers.init(allocator),
                .body = null,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Request) void {
            self.headers.deinit();
        }

        pub fn setHeader(self: *Request, key: []const u8, value: []const u8) !void {
            try self.headers.set(key, value);
        }

        pub fn setBody(self: *Request, body: []const u8) void {
            self.body = body;
        }
    };

    /// HTTP response
    pub const Response = struct {
        status: Status,
        headers: Headers,
        body: []const u8,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, status: Status) Response {
            return .{
                .status = status,
                .headers = Headers.init(allocator),
                .body = &[_]u8{},
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Response) void {
            self.headers.deinit();
            if (self.body.len > 0) {
                self.allocator.free(self.body);
            }
        }

        pub fn setHeader(self: *Response, key: []const u8, value: []const u8) !void {
            try self.headers.set(key, value);
        }

        pub fn setBody(self: *Response, body: []const u8) !void {
            self.body = try self.allocator.dupe(u8, body);
        }

        pub fn json(self: *Response) !std.json.Parsed(std.json.Value) {
            return try std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                self.body,
                .{},
            );
        }
    };

    /// HTTP client
    pub const Client = struct {
        allocator: std.mem.Allocator,
        client: std.http.Client,

        pub fn init(allocator: std.mem.Allocator) Client {
            return .{
                .allocator = allocator,
                .client = std.http.Client{ .allocator = allocator },
            };
        }

        pub fn deinit(self: *Client) void {
            self.client.deinit();
        }

        pub fn request(self: *Client, req: Request) !Response {
            var resp = Response.init(self.allocator, .OK);

            // Parse URL
            const uri = try std.Uri.parse(req.url);

            // Create request
            var server_header_buffer: [4096]u8 = undefined;
            var request = try self.client.open(.{
                .method = @enumFromInt(@intFromEnum(req.method)),
                .uri = uri,
                .server_header_buffer = &server_header_buffer,
            });
            defer request.deinit();

            // Set headers
            var it = req.headers.map.iterator();
            while (it.next()) |entry| {
                try request.headers.append(entry.key_ptr.*, entry.value_ptr.*);
            }

            // Send request
            try request.send();

            // Write body if present
            if (req.body) |body| {
                try request.writeAll(body);
            }

            try request.finish();

            // Wait for response
            try request.wait();

            // Read response
            resp.status = @enumFromInt(request.response.status.code());

            // Read body
            var body_buffer = std.ArrayList(u8).init(self.allocator);
            defer body_buffer.deinit();

            var buf: [4096]u8 = undefined;
            while (true) {
                const n = try request.reader().read(&buf);
                if (n == 0) break;
                try body_buffer.appendSlice(buf[0..n]);
            }

            resp.body = try body_buffer.toOwnedSlice();

            return resp;
        }

        pub fn get(self: *Client, url: []const u8) !Response {
            var req = Request.init(self.allocator, .GET, url);
            defer req.deinit();
            return try self.request(req);
        }

        pub fn post(self: *Client, url: []const u8, body: []const u8) !Response {
            var req = Request.init(self.allocator, .POST, url);
            defer req.deinit();
            req.setBody(body);
            try req.setHeader("Content-Type", "application/json");
            return try self.request(req);
        }

        pub fn put(self: *Client, url: []const u8, body: []const u8) !Response {
            var req = Request.init(self.allocator, .PUT, url);
            defer req.deinit();
            req.setBody(body);
            try req.setHeader("Content-Type", "application/json");
            return try self.request(req);
        }

        pub fn delete(self: *Client, url: []const u8) !Response {
            var req = Request.init(self.allocator, .DELETE, url);
            defer req.deinit();
            return try self.request(req);
        }
    };

    /// HTTP server
    pub const Server = struct {
        allocator: std.mem.Allocator,
        address: std.net.Address,
        server: std.net.Server,
        handler: *const fn (Request) Response,

        pub fn init(
            allocator: std.mem.Allocator,
            address: std.net.Address,
            handler: *const fn (Request) Response,
        ) !Server {
            const server = try address.listen(.{
                .reuse_address = true,
            });

            return .{
                .allocator = allocator,
                .address = address,
                .server = server,
                .handler = handler,
            };
        }

        pub fn deinit(self: *Server) void {
            self.server.deinit();
        }

        pub fn listen(self: *Server) !void {
            while (true) {
                const connection = try self.server.accept();
                defer connection.stream.close();

                try self.handleConnection(connection);
            }
        }

        fn handleConnection(self: *Server, connection: std.net.Server.Connection) !void {
            _ = connection;
            _ = self;
            // Full implementation would:
            // 1. Parse HTTP request
            // 2. Call handler
            // 3. Send HTTP response
        }
    };
};
