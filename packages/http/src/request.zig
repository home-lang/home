const std = @import("std");
const Method = @import("method.zig").Method;
const Version = @import("method.zig").Version;
const Headers = @import("headers.zig").Headers;

/// HTTP Request
pub const Request = struct {
    method: Method,
    uri: []const u8,
    version: Version,
    headers: Headers,
    body: []const u8,
    params: std.StringHashMap([]const u8), // Route parameters like :id
    query: std.StringHashMap([]const u8), // Query string parameters
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, method: Method, uri: []const u8) !*Request {
        const req = try allocator.create(Request);
        req.* = .{
            .method = method,
            .uri = try allocator.dupe(u8, uri),
            .version = .HTTP_1_1,
            .headers = Headers.init(allocator),
            .body = &.{},
            .params = std.StringHashMap([]const u8).init(allocator),
            .query = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };

        // Parse query string from URI
        try req.parseQueryString();

        return req;
    }

    pub fn deinit(self: *Request) void {
        self.allocator.free(self.uri);
        self.headers.deinit();
        if (self.body.len > 0) {
            self.allocator.free(self.body);
        }

        // Free params
        var param_it = self.params.iterator();
        while (param_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.params.deinit();

        // Free query
        var query_it = self.query.iterator();
        while (query_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.query.deinit();

        self.allocator.destroy(self);
    }

    /// Set the request body
    pub fn setBody(self: *Request, body: []const u8) !void {
        if (self.body.len > 0) {
            self.allocator.free(self.body);
        }
        self.body = try self.allocator.dupe(u8, body);
    }

    /// Get the path without query string
    pub fn path(self: *const Request) []const u8 {
        if (std.mem.indexOf(u8, self.uri, "?")) |idx| {
            return self.uri[0..idx];
        }
        return self.uri;
    }

    /// Get a route parameter by name
    pub fn param(self: *const Request, name: []const u8) ?[]const u8 {
        return self.params.get(name);
    }

    /// Get a query parameter by name
    pub fn queryParam(self: *const Request, name: []const u8) ?[]const u8 {
        return self.query.get(name);
    }

    /// Get a header value
    pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
        return self.headers.get(name);
    }

    /// Check if request has a specific header
    pub fn hasHeader(self: *const Request, name: []const u8) bool {
        return self.headers.has(name);
    }

    /// Parse JSON body into a type
    pub fn json(self: *const Request, comptime T: type) !T {
        return try std.json.parseFromSlice(T, self.allocator, self.body, .{});
    }

    /// Get content type
    pub fn contentType(self: *const Request) ?[]const u8 {
        return self.header("Content-Type");
    }

    /// Check if content type is JSON
    pub fn isJSON(self: *const Request) bool {
        if (self.contentType()) |ct| {
            return std.mem.startsWith(u8, ct, "application/json");
        }
        return false;
    }

    /// Parse query string from URI
    fn parseQueryString(self: *Request) !void {
        const query_start = std.mem.indexOf(u8, self.uri, "?") orelse return;
        if (query_start + 1 >= self.uri.len) return;

        const query_string = self.uri[query_start + 1 ..];
        var it = std.mem.splitSequence(u8, query_string, "&");

        while (it.next()) |pair| {
            if (std.mem.indexOf(u8, pair, "=")) |eq_idx| {
                const key = pair[0..eq_idx];
                const value = pair[eq_idx + 1 ..];

                const owned_key = try self.allocator.dupe(u8, key);
                errdefer self.allocator.free(owned_key);

                const owned_value = try self.allocator.dupe(u8, value);
                errdefer self.allocator.free(owned_value);

                try self.query.put(owned_key, owned_value);
            }
        }
    }
};

test "Request creation and query parsing" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var req = try Request.init(allocator, .GET, "/users?name=john&age=30");
    defer req.deinit();

    try testing.expectEqual(Method.GET, req.method);
    try testing.expectEqualStrings("/users", req.path());
    try testing.expectEqualStrings("john", req.queryParam("name").?);
    try testing.expectEqualStrings("30", req.queryParam("age").?);
}

test "Request headers" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var req = try Request.init(allocator, .POST, "/api/data");
    defer req.deinit();

    try req.headers.set("Content-Type", "application/json");
    try testing.expectEqualStrings("application/json", req.header("Content-Type").?);
    try testing.expect(req.isJSON());
}
