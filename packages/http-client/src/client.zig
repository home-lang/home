const std = @import("std");
const net = std.net;
const posix = std.posix;

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

/// HTTP headers
pub const Headers = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMapUnmanaged([]const u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .map = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit(self.allocator);
    }

    pub fn set(self: *Self, name: []const u8, value: []const u8) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        const value_copy = try self.allocator.dupe(u8, value);
        try self.map.put(self.allocator, name_copy, value_copy);
    }

    pub fn get(self: *const Self, name: []const u8) ?[]const u8 {
        return self.map.get(name);
    }

    pub fn remove(self: *Self, name: []const u8) void {
        if (self.map.fetchRemove(name)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
    }

    pub fn count(self: *const Self) usize {
        return self.map.count();
    }
};

/// URL components
pub const Url = struct {
    scheme: []const u8 = "http",
    host: []const u8,
    port: ?u16 = null,
    path: []const u8 = "/",
    query: ?[]const u8 = null,

    pub fn getPort(self: Url) u16 {
        if (self.port) |p| return p;
        if (std.mem.eql(u8, self.scheme, "https")) return 443;
        return 80;
    }

    pub fn parse(url: []const u8) !Url {
        var result = Url{ .host = "" };

        var remaining = url;

        // Parse scheme
        if (std.mem.indexOf(u8, remaining, "://")) |idx| {
            result.scheme = remaining[0..idx];
            remaining = remaining[idx + 3 ..];
        }

        // Parse host and port
        const path_start = std.mem.indexOfScalar(u8, remaining, '/') orelse remaining.len;
        const host_port = remaining[0..path_start];

        if (std.mem.indexOfScalar(u8, host_port, ':')) |colon| {
            result.host = host_port[0..colon];
            result.port = std.fmt.parseInt(u16, host_port[colon + 1 ..], 10) catch null;
        } else {
            result.host = host_port;
        }

        remaining = remaining[path_start..];

        // Parse path and query
        if (remaining.len > 0) {
            if (std.mem.indexOfScalar(u8, remaining, '?')) |q_idx| {
                result.path = remaining[0..q_idx];
                result.query = remaining[q_idx + 1 ..];
            } else {
                result.path = remaining;
            }
        }

        if (result.host.len == 0) return error.InvalidUrl;

        return result;
    }

    pub fn format(self: Url, allocator: std.mem.Allocator) ![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(allocator);

        try buf.appendSlice(allocator, self.path);
        if (self.query) |q| {
            try buf.append(allocator, '?');
            try buf.appendSlice(allocator, q);
        }

        return buf.toOwnedSlice(allocator);
    }
};

/// HTTP request
pub const Request = struct {
    allocator: std.mem.Allocator,
    method: Method = .GET,
    url: Url,
    headers: Headers,
    body: ?[]const u8 = null,
    timeout_ms: u32 = 30000,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, url_str: []const u8) !Self {
        const url = try Url.parse(url_str);
        var headers = Headers.init(allocator);

        // Set default headers
        try headers.set("Host", url.host);
        try headers.set("User-Agent", "Zig-HTTP-Client/1.0");
        try headers.set("Accept", "*/*");
        try headers.set("Connection", "close");

        return .{
            .allocator = allocator,
            .url = url,
            .headers = headers,
        };
    }

    pub fn deinit(self: *Self) void {
        self.headers.deinit();
    }

    pub fn setMethod(self: *Self, method: Method) *Self {
        self.method = method;
        return self;
    }

    pub fn setHeader(self: *Self, name: []const u8, value: []const u8) !*Self {
        try self.headers.set(name, value);
        return self;
    }

    pub fn setBody(self: *Self, body: []const u8) *Self {
        self.body = body;
        return self;
    }

    pub fn setJson(self: *Self, body: []const u8) !*Self {
        try self.headers.set("Content-Type", "application/json");
        self.body = body;
        return self;
    }

    pub fn setFormData(self: *Self, body: []const u8) !*Self {
        try self.headers.set("Content-Type", "application/x-www-form-urlencoded");
        self.body = body;
        return self;
    }

    pub fn setTimeout(self: *Self, timeout_ms: u32) *Self {
        self.timeout_ms = timeout_ms;
        return self;
    }

    pub fn setBasicAuth(self: *Self, username: []const u8, password: []const u8) !*Self {
        var auth_buf: [512]u8 = undefined;
        const auth_str = std.fmt.bufPrint(&auth_buf, "{s}:{s}", .{ username, password }) catch return error.AuthTooLong;

        var encoded_buf: [1024]u8 = undefined;
        const encoded = std.base64.standard.Encoder.encode(&encoded_buf, auth_str);

        var header_buf: [1100]u8 = undefined;
        const header_value = std.fmt.bufPrint(&header_buf, "Basic {s}", .{encoded}) catch return error.AuthTooLong;

        try self.headers.set("Authorization", header_value);
        return self;
    }

    pub fn setBearerToken(self: *Self, token: []const u8) !*Self {
        var buf: [2048]u8 = undefined;
        const value = std.fmt.bufPrint(&buf, "Bearer {s}", .{token}) catch return error.TokenTooLong;
        try self.headers.set("Authorization", value);
        return self;
    }
};

/// HTTP response
pub const Response = struct {
    allocator: std.mem.Allocator,
    status_code: u16,
    status_text: []const u8,
    headers: Headers,
    body: []const u8,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.headers.deinit();
        self.allocator.free(self.status_text);
        self.allocator.free(self.body);
    }

    pub fn isSuccess(self: Self) bool {
        return self.status_code >= 200 and self.status_code < 300;
    }

    pub fn isRedirect(self: Self) bool {
        return self.status_code >= 300 and self.status_code < 400;
    }

    pub fn isClientError(self: Self) bool {
        return self.status_code >= 400 and self.status_code < 500;
    }

    pub fn isServerError(self: Self) bool {
        return self.status_code >= 500;
    }

    pub fn json(self: Self) !std.json.Parsed(std.json.Value) {
        return std.json.parseFromSlice(std.json.Value, self.allocator, self.body, .{});
    }
};

/// HTTP Client
pub const Client = struct {
    allocator: std.mem.Allocator,
    default_headers: Headers,
    base_url: ?[]const u8 = null,
    default_timeout_ms: u32 = 30000,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .default_headers = Headers.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.default_headers.deinit();
        if (self.base_url) |url| {
            self.allocator.free(url);
        }
    }

    pub fn setBaseUrl(self: *Self, url: []const u8) !void {
        if (self.base_url) |old| {
            self.allocator.free(old);
        }
        self.base_url = try self.allocator.dupe(u8, url);
    }

    pub fn setDefaultHeader(self: *Self, name: []const u8, value: []const u8) !void {
        try self.default_headers.set(name, value);
    }

    pub fn setDefaultTimeout(self: *Self, timeout_ms: u32) void {
        self.default_timeout_ms = timeout_ms;
    }

    /// Execute a request (stub implementation - actual TCP/TLS would need more work)
    pub fn execute(self: *Self, request: *Request) !Response {
        _ = self;

        // Build raw HTTP request
        var raw_request: std.ArrayListUnmanaged(u8) = .empty;
        defer raw_request.deinit(request.allocator);

        const path = try request.url.format(request.allocator);
        defer request.allocator.free(path);

        // Request line
        try raw_request.appendSlice(request.allocator, request.method.toString());
        try raw_request.append(request.allocator, ' ');
        try raw_request.appendSlice(request.allocator, path);
        try raw_request.appendSlice(request.allocator, " HTTP/1.1\r\n");

        // Headers
        var iter = request.headers.map.iterator();
        while (iter.next()) |entry| {
            try raw_request.appendSlice(request.allocator, entry.key_ptr.*);
            try raw_request.appendSlice(request.allocator, ": ");
            try raw_request.appendSlice(request.allocator, entry.value_ptr.*);
            try raw_request.appendSlice(request.allocator, "\r\n");
        }

        // Content-Length for body
        if (request.body) |body| {
            var len_buf: [32]u8 = undefined;
            const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{body.len}) catch unreachable;
            try raw_request.appendSlice(request.allocator, "Content-Length: ");
            try raw_request.appendSlice(request.allocator, len_str);
            try raw_request.appendSlice(request.allocator, "\r\n");
        }

        try raw_request.appendSlice(request.allocator, "\r\n");

        // Body
        if (request.body) |body| {
            try raw_request.appendSlice(request.allocator, body);
        }

        // For now, return a mock response
        // Real implementation would:
        // 1. Resolve DNS
        // 2. Create TCP connection
        // 3. Optionally wrap in TLS for HTTPS
        // 4. Send request
        // 5. Read and parse response

        return Response{
            .allocator = request.allocator,
            .status_code = 200,
            .status_text = try request.allocator.dupe(u8, "OK"),
            .headers = Headers.init(request.allocator),
            .body = try request.allocator.dupe(u8, ""),
        };
    }

    // Convenience methods
    pub fn get(self: *Self, url: []const u8) !Response {
        var req = try Request.init(self.allocator, url);
        defer req.deinit();
        return self.execute(&req);
    }

    pub fn post(self: *Self, url: []const u8, body: []const u8) !Response {
        var req = try Request.init(self.allocator, url);
        defer req.deinit();
        _ = req.setMethod(.POST);
        _ = req.setBody(body);
        return self.execute(&req);
    }

    pub fn postJson(self: *Self, url: []const u8, json_body: []const u8) !Response {
        var req = try Request.init(self.allocator, url);
        defer req.deinit();
        _ = req.setMethod(.POST);
        _ = try req.setJson(json_body);
        return self.execute(&req);
    }

    pub fn put(self: *Self, url: []const u8, body: []const u8) !Response {
        var req = try Request.init(self.allocator, url);
        defer req.deinit();
        _ = req.setMethod(.PUT);
        _ = req.setBody(body);
        return self.execute(&req);
    }

    pub fn delete(self: *Self, url: []const u8) !Response {
        var req = try Request.init(self.allocator, url);
        defer req.deinit();
        _ = req.setMethod(.DELETE);
        return self.execute(&req);
    }

    pub fn patch(self: *Self, url: []const u8, body: []const u8) !Response {
        var req = try Request.init(self.allocator, url);
        defer req.deinit();
        _ = req.setMethod(.PATCH);
        _ = req.setBody(body);
        return self.execute(&req);
    }
};

/// URL encoding utilities
pub const UrlEncoding = struct {
    pub fn encode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(allocator);

        for (input) |c| {
            if (isUnreserved(c)) {
                try result.append(allocator, c);
            } else {
                try result.append(allocator, '%');
                const hex = "0123456789ABCDEF";
                try result.append(allocator, hex[c >> 4]);
                try result.append(allocator, hex[c & 0x0F]);
            }
        }

        return result.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(allocator);

        var i: usize = 0;
        while (i < input.len) {
            if (input[i] == '%' and i + 2 < input.len) {
                const hi = hexValue(input[i + 1]) orelse {
                    try result.append(allocator, input[i]);
                    i += 1;
                    continue;
                };
                const lo = hexValue(input[i + 2]) orelse {
                    try result.append(allocator, input[i]);
                    i += 1;
                    continue;
                };
                try result.append(allocator, (hi << 4) | lo);
                i += 3;
            } else if (input[i] == '+') {
                try result.append(allocator, ' ');
                i += 1;
            } else {
                try result.append(allocator, input[i]);
                i += 1;
            }
        }

        return result.toOwnedSlice(allocator);
    }

    fn isUnreserved(c: u8) bool {
        return (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '_' or c == '.' or c == '~';
    }

    fn hexValue(c: u8) ?u8 {
        if (c >= '0' and c <= '9') return c - '0';
        if (c >= 'A' and c <= 'F') return c - 'A' + 10;
        if (c >= 'a' and c <= 'f') return c - 'a' + 10;
        return null;
    }
};

/// Query string builder
pub const QueryBuilder = struct {
    allocator: std.mem.Allocator,
    params: std.ArrayListUnmanaged(Param),

    const Self = @This();

    const Param = struct {
        key: []const u8,
        value: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .params = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.params.items) |p| {
            self.allocator.free(p.key);
            self.allocator.free(p.value);
        }
        self.params.deinit(self.allocator);
    }

    pub fn add(self: *Self, key: []const u8, value: []const u8) !*Self {
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const value_copy = try self.allocator.dupe(u8, value);
        try self.params.append(self.allocator, .{ .key = key_copy, .value = value_copy });
        return self;
    }

    pub fn addInt(self: *Self, key: []const u8, value: i64) !*Self {
        var buf: [32]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
        return self.add(key, str);
    }

    pub fn build(self: *Self) ![]const u8 {
        if (self.params.items.len == 0) return try self.allocator.dupe(u8, "");

        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(self.allocator);

        for (self.params.items, 0..) |p, i| {
            if (i > 0) try result.append(self.allocator, '&');

            const encoded_key = try UrlEncoding.encode(self.allocator, p.key);
            defer self.allocator.free(encoded_key);
            const encoded_value = try UrlEncoding.encode(self.allocator, p.value);
            defer self.allocator.free(encoded_value);

            try result.appendSlice(self.allocator, encoded_key);
            try result.append(self.allocator, '=');
            try result.appendSlice(self.allocator, encoded_value);
        }

        return result.toOwnedSlice(self.allocator);
    }
};

// Tests
test "url parsing" {
    const url1 = try Url.parse("http://example.com/path");
    try std.testing.expectEqualStrings("http", url1.scheme);
    try std.testing.expectEqualStrings("example.com", url1.host);
    try std.testing.expectEqualStrings("/path", url1.path);
    try std.testing.expectEqual(@as(u16, 80), url1.getPort());

    const url2 = try Url.parse("https://api.example.com:8443/v1/users?limit=10");
    try std.testing.expectEqualStrings("https", url2.scheme);
    try std.testing.expectEqualStrings("api.example.com", url2.host);
    try std.testing.expectEqual(@as(u16, 8443), url2.port.?);
    try std.testing.expectEqualStrings("/v1/users", url2.path);
    try std.testing.expectEqualStrings("limit=10", url2.query.?);
}

test "headers" {
    const allocator = std.testing.allocator;

    var headers = Headers.init(allocator);
    defer headers.deinit();

    try headers.set("Content-Type", "application/json");
    try headers.set("Authorization", "Bearer token123");

    try std.testing.expectEqualStrings("application/json", headers.get("Content-Type").?);
    try std.testing.expectEqualStrings("Bearer token123", headers.get("Authorization").?);
    try std.testing.expectEqual(@as(usize, 2), headers.count());
}

test "request builder" {
    const allocator = std.testing.allocator;

    var req = try Request.init(allocator, "https://api.example.com/users");
    defer req.deinit();

    _ = req.setMethod(.POST);
    _ = try req.setJson("{\"name\": \"test\"}");
    _ = req.setTimeout(5000);

    try std.testing.expectEqual(Method.POST, req.method);
    try std.testing.expectEqualStrings("application/json", req.headers.get("Content-Type").?);
    try std.testing.expectEqual(@as(u32, 5000), req.timeout_ms);
}

test "response status checks" {
    const allocator = std.testing.allocator;

    var resp = Response{
        .allocator = allocator,
        .status_code = 200,
        .status_text = try allocator.dupe(u8, "OK"),
        .headers = Headers.init(allocator),
        .body = try allocator.dupe(u8, ""),
    };
    defer resp.deinit();

    try std.testing.expect(resp.isSuccess());
    try std.testing.expect(!resp.isRedirect());
    try std.testing.expect(!resp.isClientError());
    try std.testing.expect(!resp.isServerError());
}

test "url encoding" {
    const allocator = std.testing.allocator;

    const encoded = try UrlEncoding.encode(allocator, "hello world");
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("hello%20world", encoded);

    const decoded = try UrlEncoding.decode(allocator, "hello%20world");
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("hello world", decoded);
}

test "query builder" {
    const allocator = std.testing.allocator;

    var builder = QueryBuilder.init(allocator);
    defer builder.deinit();

    _ = try builder.add("name", "John Doe");
    _ = try builder.addInt("page", 1);
    _ = try builder.add("sort", "asc");

    const query = try builder.build();
    defer allocator.free(query);

    try std.testing.expectEqualStrings("name=John%20Doe&page=1&sort=asc", query);
}

test "client convenience methods" {
    const allocator = std.testing.allocator;

    var client = Client.init(allocator);
    defer client.deinit();

    var resp = try client.get("http://example.com/api/test");
    defer resp.deinit();

    try std.testing.expect(resp.isSuccess());
}
