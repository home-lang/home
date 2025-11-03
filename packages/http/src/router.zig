const std = @import("std");
const Method = @import("method.zig").Method;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

/// Handler function type
pub const Handler = *const fn (req: *Request, res: *Response) anyerror!void;

/// Route definition
pub const Route = struct {
    method: Method,
    path: []const u8,
    handler: Handler,
    is_pattern: bool, // true if path contains parameters like :id

    pub fn init(method: Method, path: []const u8, handler: Handler) !Route {
        const has_params = std.mem.indexOf(u8, path, ":") != null;
        return Route{
            .method = method,
            .path = path,
            .handler = handler,
            .is_pattern = has_params,
        };
    }

    /// Check if this route matches the request method and path
    pub fn matches(self: *const Route, method: Method, path: []const u8) bool {
        if (self.method != method) return false;

        if (!self.is_pattern) {
            return std.mem.eql(u8, self.path, path);
        }

        // Pattern matching for routes with parameters
        return matchPattern(self.path, path);
    }

    /// Extract route parameters from the path
    pub fn extractParams(self: *const Route, path: []const u8, allocator: std.mem.Allocator) !std.StringHashMap([]const u8) {
        var params = std.StringHashMap([]const u8).init(allocator);
        errdefer params.deinit();

        if (!self.is_pattern) return params;

        var route_it = std.mem.splitSequence(u8, self.path, "/");
        var path_it = std.mem.splitSequence(u8, path, "/");

        while (route_it.next()) |route_segment| {
            const path_segment = path_it.next() orelse break;

            if (route_segment.len > 0 and route_segment[0] == ':') {
                // This is a parameter
                const param_name = route_segment[1..];
                const owned_name = try allocator.dupe(u8, param_name);
                errdefer allocator.free(owned_name);

                const owned_value = try allocator.dupe(u8, path_segment);
                errdefer allocator.free(owned_value);

                try params.put(owned_name, owned_value);
            }
        }

        return params;
    }
};

/// Match a route pattern against a path
fn matchPattern(pattern: []const u8, path: []const u8) bool {
    var pattern_it = std.mem.splitSequence(u8, pattern, "/");
    var path_it = std.mem.splitSequence(u8, path, "/");

    while (pattern_it.next()) |pattern_segment| {
        const path_segment = path_it.next() orelse return false;

        // If pattern segment starts with ':', it matches any path segment
        if (pattern_segment.len > 0 and pattern_segment[0] == ':') {
            continue;
        }

        // Otherwise, segments must match exactly
        if (!std.mem.eql(u8, pattern_segment, path_segment)) {
            return false;
        }
    }

    // Make sure we've consumed all path segments
    return path_it.next() == null;
}

/// HTTP Router
pub const Router = struct {
    routes: std.ArrayListUnmanaged(Route),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Router {
        return Router{
            .routes = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Router) void {
        for (self.routes.items) |route| {
            self.allocator.free(route.path);
        }
        self.routes.deinit(self.allocator);
    }

    /// Register a GET route
    pub fn get(self: *Router, path: []const u8, handler: Handler) !void {
        try self.addRoute(.GET, path, handler);
    }

    /// Register a POST route
    pub fn post(self: *Router, path: []const u8, handler: Handler) !void {
        try self.addRoute(.POST, path, handler);
    }

    /// Register a PUT route
    pub fn put(self: *Router, path: []const u8, handler: Handler) !void {
        try self.addRoute(.PUT, path, handler);
    }

    /// Register a DELETE route
    pub fn delete(self: *Router, path: []const u8, handler: Handler) !void {
        try self.addRoute(.DELETE, path, handler);
    }

    /// Register a PATCH route
    pub fn patch(self: *Router, path: []const u8, handler: Handler) !void {
        try self.addRoute(.PATCH, path, handler);
    }

    /// Add a route with any HTTP method
    pub fn addRoute(self: *Router, method: Method, path: []const u8, handler: Handler) !void {
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);

        const route = try Route.init(method, owned_path, handler);
        try self.routes.append(self.allocator, route);
    }

    /// Find a matching route for the given method and path
    pub fn findRoute(self: *const Router, method: Method, path: []const u8) ?*const Route {
        for (self.routes.items) |*route| {
            if (route.matches(method, path)) {
                return route;
            }
        }
        return null;
    }

    /// Handle an incoming request
    pub fn handle(self: *const Router, req: *Request, res: *Response) !void {
        const route = self.findRoute(req.method, req.path()) orelse {
            res.setStatus(.NotFound);
            try res.send("Not Found");
            return;
        };

        // Extract and set route parameters
        var params = try route.extractParams(req.path(), req.allocator);
        defer {
            var it = params.iterator();
            while (it.next()) |entry| {
                req.allocator.free(entry.key_ptr.*);
                req.allocator.free(entry.value_ptr.*);
            }
            params.deinit();
        }

        // Merge params into request
        var param_it = params.iterator();
        while (param_it.next()) |entry| {
            const key = try req.allocator.dupe(u8, entry.key_ptr.*);
            const value = try req.allocator.dupe(u8, entry.value_ptr.*);
            try req.params.put(key, value);
        }

        // Call the handler
        try route.handler(req, res);
    }
};

test "Route matching" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const dummyHandler: Handler = struct {
        fn handler(_: *Request, _: *Response) !void {}
    }.handler;

    // Test exact match
    const route1 = try Route.init(.GET, "/users", dummyHandler);
    try testing.expect(route1.matches(.GET, "/users"));
    try testing.expect(!route1.matches(.POST, "/users"));
    try testing.expect(!route1.matches(.GET, "/posts"));

    // Test parameter match
    const route2 = try Route.init(.GET, "/users/:id", dummyHandler);
    try testing.expect(route2.matches(.GET, "/users/123"));
    try testing.expect(route2.matches(.GET, "/users/abc"));
    try testing.expect(!route2.matches(.GET, "/users"));
    try testing.expect(!route2.matches(.GET, "/users/123/posts"));

    // Test parameter extraction
    var params = try route2.extractParams("/users/123", allocator);
    defer {
        var it = params.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        params.deinit();
    }

    try testing.expectEqualStrings("123", params.get("id").?);
}

test "Router basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var router = Router.init(allocator);
    defer router.deinit();

    const getUserHandler: Handler = struct {
        fn handler(_: *Request, res: *Response) !void {
            try res.send("Get user");
        }
    }.handler;

    try router.get("/users/:id", getUserHandler);

    const route = router.findRoute(.GET, "/users/123");
    try testing.expect(route != null);
    try testing.expectEqual(Method.GET, route.?.method);
}
