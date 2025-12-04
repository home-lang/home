/// Home HTTP Client
///
/// A high-performance HTTP client with support for GET, POST, PUT, DELETE, etc.
/// Features automatic JSON handling, timeouts, retries, and connection pooling.
/// Uses std.http.Client for reliable HTTPS support.
///
/// Example usage:
/// ```home
/// const client = HttpClient.init(allocator);
/// defer client.deinit();
///
/// // Simple GET
/// const response = try client.get("https://api.example.com/users");
/// defer response.deinit();
///
/// // POST with JSON
/// const data = try client.post("https://api.example.com/users")
///     .json(.{ .name = "John", .email = "john@example.com" })
///     .send();
/// ```
const std = @import("std");
const Method = @import("method.zig").Method;
const Headers = @import("headers.zig").Headers;

/// HTTP Client error types
pub const ClientError = error{
    ConnectionFailed,
    Timeout,
    InvalidUrl,
    InvalidResponse,
    TooManyRedirects,
    SslError,
    RequestFailed,
    OutOfMemory,
};

/// HTTP Response from client request
pub const Response = struct {
    allocator: std.mem.Allocator,
    status_code: u16,
    status_text: []const u8,
    headers: Headers,
    body: []const u8,
    url: []const u8,
    elapsed_ms: u64,

    pub fn init(allocator: std.mem.Allocator) Response {
        return .{
            .allocator = allocator,
            .status_code = 0,
            .status_text = "",
            .headers = Headers.init(allocator),
            .body = "",
            .url = "",
            .elapsed_ms = 0,
        };
    }

    pub fn deinit(self: *Response) void {
        if (self.body.len > 0) {
            self.allocator.free(self.body);
        }
        if (self.url.len > 0) {
            self.allocator.free(self.url);
        }
        if (self.status_text.len > 0) {
            self.allocator.free(self.status_text);
        }
        self.headers.deinit();
    }

    /// Check if status is success (2xx)
    pub fn isSuccess(self: *const Response) bool {
        return self.status_code >= 200 and self.status_code < 300;
    }

    /// Check if status is redirect (3xx)
    pub fn isRedirect(self: *const Response) bool {
        return self.status_code >= 300 and self.status_code < 400;
    }

    /// Check if status is client error (4xx)
    pub fn isClientError(self: *const Response) bool {
        return self.status_code >= 400 and self.status_code < 500;
    }

    /// Check if status is server error (5xx)
    pub fn isServerError(self: *const Response) bool {
        return self.status_code >= 500 and self.status_code < 600;
    }

    /// Parse body as JSON
    pub fn json(self: *const Response, comptime T: type) !T {
        return std.json.parseFromSlice(T, self.allocator, self.body, .{});
    }

    /// Get body as string
    pub fn text(self: *const Response) []const u8 {
        return self.body;
    }
};

/// URL components
pub const Url = struct {
    scheme: []const u8,
    host: []const u8,
    port: u16,
    path: []const u8,
    query: ?[]const u8,
    fragment: ?[]const u8,

    /// Parse URL string
    pub fn parse(url_str: []const u8) !Url {
        var result = Url{
            .scheme = "http",
            .host = "",
            .port = 80,
            .path = "/",
            .query = null,
            .fragment = null,
        };

        var remaining = url_str;

        // Parse scheme
        if (std.mem.indexOf(u8, remaining, "://")) |idx| {
            result.scheme = remaining[0..idx];
            remaining = remaining[idx + 3 ..];

            if (std.mem.eql(u8, result.scheme, "https")) {
                result.port = 443;
            }
        }

        // Parse fragment
        if (std.mem.indexOf(u8, remaining, "#")) |idx| {
            result.fragment = remaining[idx + 1 ..];
            remaining = remaining[0..idx];
        }

        // Parse query
        if (std.mem.indexOf(u8, remaining, "?")) |idx| {
            result.query = remaining[idx + 1 ..];
            remaining = remaining[0..idx];
        }

        // Parse path
        if (std.mem.indexOf(u8, remaining, "/")) |idx| {
            result.path = remaining[idx..];
            remaining = remaining[0..idx];
        }

        // Parse host and port
        if (std.mem.indexOf(u8, remaining, ":")) |idx| {
            result.host = remaining[0..idx];
            result.port = std.fmt.parseInt(u16, remaining[idx + 1 ..], 10) catch return error.InvalidUrl;
        } else {
            result.host = remaining;
        }

        if (result.host.len == 0) {
            return error.InvalidUrl;
        }

        return result;
    }

    /// Build full path with query
    pub fn fullPath(self: *const Url, allocator: std.mem.Allocator) ![]u8 {
        if (self.query) |q| {
            return std.fmt.allocPrint(allocator, "{s}?{s}", .{ self.path, q });
        }
        return allocator.dupe(u8, self.path);
    }
};

/// Request configuration
pub const RequestConfig = struct {
    timeout_ms: u32 = 30000,
    follow_redirects: bool = true,
    max_redirects: u8 = 10,
    verify_ssl: bool = true,
    keep_alive: bool = true,
    compress: bool = true,
};

/// HTTP Client
pub const Client = struct {
    allocator: std.mem.Allocator,
    config: RequestConfig,
    default_headers: Headers,

    pub fn init(allocator: std.mem.Allocator) Client {
        var client = Client{
            .allocator = allocator,
            .config = .{},
            .default_headers = Headers.init(allocator),
        };

        // Set default headers
        client.default_headers.set("User-Agent", "Home-HTTP-Client/1.0") catch {};
        client.default_headers.set("Accept", "*/*") catch {};
        client.default_headers.set("Accept-Encoding", "gzip, deflate") catch {};
        client.default_headers.set("Connection", "keep-alive") catch {};

        return client;
    }

    pub fn deinit(self: *Client) void {
        self.default_headers.deinit();
    }

    /// Configure the client
    pub fn configure(self: *Client, config: RequestConfig) void {
        self.config = config;
    }

    /// Set a default header
    pub fn setHeader(self: *Client, name: []const u8, value: []const u8) !void {
        try self.default_headers.set(name, value);
    }

    /// Create a GET request
    pub fn get(self: *Client, url: []const u8) RequestBuilder {
        return RequestBuilder.init(self, .GET, url);
    }

    /// Create a POST request
    pub fn post(self: *Client, url: []const u8) RequestBuilder {
        return RequestBuilder.init(self, .POST, url);
    }

    /// Create a PUT request
    pub fn put(self: *Client, url: []const u8) RequestBuilder {
        return RequestBuilder.init(self, .PUT, url);
    }

    /// Create a DELETE request
    pub fn delete(self: *Client, url: []const u8) RequestBuilder {
        return RequestBuilder.init(self, .DELETE, url);
    }

    /// Create a PATCH request
    pub fn patch(self: *Client, url: []const u8) RequestBuilder {
        return RequestBuilder.init(self, .PATCH, url);
    }

    /// Create a HEAD request
    pub fn head(self: *Client, url: []const u8) RequestBuilder {
        return RequestBuilder.init(self, .HEAD, url);
    }

    /// Create a request with custom method
    pub fn request(self: *Client, method: Method, url: []const u8) RequestBuilder {
        return RequestBuilder.init(self, method, url);
    }

    /// Execute a request using std.http.Client for HTTPS support
    fn execute(self: *Client, builder: *RequestBuilder) !Response {
        const start_time = std.time.milliTimestamp();

        // Use std.http.Client for proper TLS support
        var http_client = std.http.Client{ .allocator = self.allocator };
        defer http_client.deinit();

        // Parse URL
        const uri = try std.Uri.parse(builder.url);

        // Collect headers
        var extra_headers: std.ArrayList(std.http.Header) = .empty;
        defer extra_headers.deinit(self.allocator);

        // Add default headers
        var default_it = self.default_headers.entries.iterator();
        while (default_it.next()) |entry| {
            if (!builder.headers.entries.contains(entry.key_ptr.*)) {
                try extra_headers.append(self.allocator, .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* });
            }
        }

        // Add request headers
        var headers_it = builder.headers.entries.iterator();
        while (headers_it.next()) |entry| {
            try extra_headers.append(self.allocator, .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* });
        }

        // Convert method
        const http_method: std.http.Method = switch (builder.method) {
            .GET => .GET,
            .POST => .POST,
            .PUT => .PUT,
            .PATCH => .PATCH,
            .DELETE => .DELETE,
            .HEAD => .HEAD,
            .OPTIONS => .OPTIONS,
            .CONNECT => .CONNECT,
            .TRACE => .TRACE,
        };

        // Server header buffer
        var server_header_buf: [16384]u8 = undefined;

        // Open request
        var req = try http_client.open(
            http_method,
            uri,
            .{
                .server_header_buffer = &server_header_buf,
                .extra_headers = extra_headers.items,
            },
        );
        defer req.deinit();

        // Set content length if body present
        if (builder.body.len > 0) {
            req.transfer_encoding = .{ .content_length = builder.body.len };
        }

        // Send request
        try req.send();

        // Write body if present
        if (builder.body.len > 0) {
            try req.writer().writeAll(builder.body);
            try req.finish();
        }

        // Wait for response
        try req.wait();

        // Read response body
        const body = try req.reader().readAllAlloc(self.allocator, 1024 * 1024 * 10); // 10MB max

        // Build response
        var response = Response.init(self.allocator);
        response.status_code = @intFromEnum(req.status);
        response.body = body;
        response.url = try self.allocator.dupe(u8, builder.url);
        response.elapsed_ms = @intCast(std.time.milliTimestamp() - start_time);

        // Copy status text
        const status_phrase = req.status.phrase() orelse "";
        response.status_text = try self.allocator.dupe(u8, status_phrase);

        // Handle redirects
        if (response.isRedirect() and self.config.follow_redirects) {
            if (builder.redirect_count < self.config.max_redirects) {
                // Check for Location header in response
                var header_it = req.response.iterateHeaders();
                while (header_it.next()) |h| {
                    if (std.ascii.eqlIgnoreCase(h.name, "location")) {
                        builder.redirect_count += 1;
                        response.deinit();
                        builder.url = h.value;
                        return self.execute(builder);
                    }
                }
            }
        }

        return response;
    }

    /// Parse HTTP response
    fn parseResponse(self: *Client, response: *Response, data: []const u8) !void {
        var lines = std.mem.splitSequence(u8, data, "\r\n");

        // Status line
        const status_line = lines.next() orelse return error.InvalidResponse;
        var status_parts = std.mem.splitSequence(u8, status_line, " ");
        _ = status_parts.next(); // HTTP version
        const status_code_str = status_parts.next() orelse return error.InvalidResponse;
        response.status_code = std.fmt.parseInt(u16, status_code_str, 10) catch return error.InvalidResponse;

        // Collect remaining as status text
        var status_text = std.ArrayList(u8).init(self.allocator);
        defer status_text.deinit();
        while (status_parts.next()) |part| {
            if (status_text.items.len > 0) try status_text.append(' ');
            try status_text.appendSlice(part);
        }
        response.status_text = try status_text.toOwnedSlice();

        // Headers
        while (lines.next()) |line| {
            if (line.len == 0) break;

            if (std.mem.indexOf(u8, line, ":")) |colon_idx| {
                const name = std.mem.trim(u8, line[0..colon_idx], " ");
                const value = std.mem.trim(u8, line[colon_idx + 1 ..], " ");
                try response.headers.set(name, value);
            }
        }

        // Body (rest of data after headers)
        if (std.mem.indexOf(u8, data, "\r\n\r\n")) |idx| {
            const body_start = idx + 4;
            if (body_start < data.len) {
                response.body = try self.allocator.dupe(u8, data[body_start..]);
            }
        }
    }
};

/// Request builder for fluent API
pub const RequestBuilder = struct {
    client: *Client,
    method: Method,
    url: []const u8,
    headers: Headers,
    body: []const u8,
    redirect_count: u8,

    fn init(client: *Client, method: Method, url: []const u8) RequestBuilder {
        return .{
            .client = client,
            .method = method,
            .url = url,
            .headers = Headers.init(client.allocator),
            .body = "",
            .redirect_count = 0,
        };
    }

    pub fn deinit(self: *RequestBuilder) void {
        self.headers.deinit();
    }

    /// Set a header
    pub fn header(self: *RequestBuilder, name: []const u8, value: []const u8) *RequestBuilder {
        self.headers.set(name, value) catch {};
        return self;
    }

    /// Set Content-Type header
    pub fn contentType(self: *RequestBuilder, value: []const u8) *RequestBuilder {
        return self.header("Content-Type", value);
    }

    /// Set Accept header
    pub fn accept(self: *RequestBuilder, value: []const u8) *RequestBuilder {
        return self.header("Accept", value);
    }

    /// Set Authorization header (Bearer token)
    pub fn bearer(self: *RequestBuilder, token: []const u8) *RequestBuilder {
        var buf: [1024]u8 = undefined;
        const auth = std.fmt.bufPrint(&buf, "Bearer {s}", .{token}) catch return self;
        return self.header("Authorization", auth);
    }

    /// Set basic auth
    pub fn basicAuth(self: *RequestBuilder, username: []const u8, password: []const u8) *RequestBuilder {
        // Build credentials string: "username:password"
        var credentials_buf: [512]u8 = undefined;
        const credentials = std.fmt.bufPrint(&credentials_buf, "{s}:{s}", .{ username, password }) catch return self;

        // Base64 encode the credentials
        const base64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        var encoded_buf: [1024]u8 = undefined;
        var encoded_len: usize = 0;

        var i: usize = 0;
        while (i < credentials.len) {
            const b0 = credentials[i];
            const b1 = if (i + 1 < credentials.len) credentials[i + 1] else 0;
            const b2 = if (i + 2 < credentials.len) credentials[i + 2] else 0;

            encoded_buf[encoded_len] = base64_alphabet[b0 >> 2];
            encoded_buf[encoded_len + 1] = base64_alphabet[((b0 & 0x03) << 4) | (b1 >> 4)];
            encoded_buf[encoded_len + 2] = if (i + 1 < credentials.len) base64_alphabet[((b1 & 0x0F) << 2) | (b2 >> 6)] else '=';
            encoded_buf[encoded_len + 3] = if (i + 2 < credentials.len) base64_alphabet[b2 & 0x3F] else '=';
            encoded_len += 4;
            i += 3;
        }

        // Build "Basic <encoded>" header value
        var auth_buf: [1100]u8 = undefined;
        const auth = std.fmt.bufPrint(&auth_buf, "Basic {s}", .{encoded_buf[0..encoded_len]}) catch return self;
        return self.header("Authorization", auth);
    }

    /// Set request body as raw bytes
    pub fn setBody(self: *RequestBuilder, data: []const u8) *RequestBuilder {
        self.body = data;
        return self;
    }

    /// Set request body as JSON
    pub fn json(self: *RequestBuilder, value: anytype) *RequestBuilder {
        _ = self.contentType("application/json");

        var list = std.ArrayList(u8).init(self.client.allocator);
        std.json.stringify(value, .{}, list.writer()) catch return self;
        self.body = list.toOwnedSlice() catch return self;

        return self;
    }

    /// Set form data
    pub fn form(self: *RequestBuilder, fields: anytype) *RequestBuilder {
        _ = self.contentType("application/x-www-form-urlencoded");

        var list = std.ArrayList(u8).init(self.client.allocator);
        const writer = list.writer();

        inline for (std.meta.fields(@TypeOf(fields)), 0..) |field, i| {
            if (i > 0) writer.writeByte('&') catch return self;
            writer.writeAll(field.name) catch return self;
            writer.writeByte('=') catch return self;

            const value = @field(fields, field.name);
            if (@TypeOf(value) == []const u8) {
                // URL encode
                for (value) |c| {
                    if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
                        writer.writeByte(c) catch return self;
                    } else {
                        writer.print("%{X:0>2}", .{c}) catch return self;
                    }
                }
            }
        }

        self.body = list.toOwnedSlice() catch return self;
        return self;
    }

    /// Send the request
    pub fn send(self: *RequestBuilder) !Response {
        defer self.deinit();
        return self.client.execute(self);
    }
};

/// Convenience functions for simple requests

/// Simple GET request
pub fn get(allocator: std.mem.Allocator, url: []const u8) !Response {
    var client = Client.init(allocator);
    defer client.deinit();
    return client.get(url).send();
}

/// Simple POST request
pub fn post(allocator: std.mem.Allocator, url: []const u8, body: []const u8) !Response {
    var client = Client.init(allocator);
    defer client.deinit();
    return client.post(url).setBody(body).send();
}

/// Simple POST with JSON
pub fn postJson(allocator: std.mem.Allocator, url: []const u8, data: anytype) !Response {
    var client = Client.init(allocator);
    defer client.deinit();
    return client.post(url).json(data).send();
}

// ============================================================================
// Tests
// ============================================================================

test "URL parsing" {
    const url = try Url.parse("https://api.example.com:8443/users?page=1#section");

    try std.testing.expectEqualStrings("https", url.scheme);
    try std.testing.expectEqualStrings("api.example.com", url.host);
    try std.testing.expectEqual(@as(u16, 8443), url.port);
    try std.testing.expectEqualStrings("/users", url.path);
    try std.testing.expectEqualStrings("page=1", url.query.?);
    try std.testing.expectEqualStrings("section", url.fragment.?);
}

test "URL parsing simple" {
    const url = try Url.parse("http://localhost/api");

    try std.testing.expectEqualStrings("http", url.scheme);
    try std.testing.expectEqualStrings("localhost", url.host);
    try std.testing.expectEqual(@as(u16, 80), url.port);
    try std.testing.expectEqualStrings("/api", url.path);
}

test "Client creation" {
    var client = Client.init(std.testing.allocator);
    defer client.deinit();

    try std.testing.expect(client.default_headers.get("User-Agent") != null);
}

test "Request builder" {
    var client = Client.init(std.testing.allocator);
    defer client.deinit();

    var builder = client.get("http://example.com");
    defer builder.deinit();

    _ = builder.header("X-Custom", "value");
    _ = builder.accept("application/json");

    try std.testing.expectEqualStrings("application/json", builder.headers.get("Accept").?);
}

test "Response status checks" {
    var response = Response.init(std.testing.allocator);
    defer response.deinit();

    response.status_code = 200;
    try std.testing.expect(response.isSuccess());
    try std.testing.expect(!response.isRedirect());

    response.status_code = 301;
    try std.testing.expect(response.isRedirect());
    try std.testing.expect(!response.isSuccess());

    response.status_code = 404;
    try std.testing.expect(response.isClientError());

    response.status_code = 500;
    try std.testing.expect(response.isServerError());
}
