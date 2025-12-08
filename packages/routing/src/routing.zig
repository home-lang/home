const std = @import("std");

/// HTTP methods
pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,
    ANY,

    pub fn fromString(s: []const u8) ?Method {
        const methods = std.StaticStringMap(Method).initComptime(.{
            .{ "GET", .GET },
            .{ "POST", .POST },
            .{ "PUT", .PUT },
            .{ "DELETE", .DELETE },
            .{ "PATCH", .PATCH },
            .{ "HEAD", .HEAD },
            .{ "OPTIONS", .OPTIONS },
        });
        return methods.get(s);
    }

    pub fn toString(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .PATCH => "PATCH",
            .HEAD => "HEAD",
            .OPTIONS => "OPTIONS",
            .ANY => "*",
        };
    }
};

/// Route parameters extracted from URL
pub const Params = struct {
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

    pub fn set(self: *Self, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const value_copy = try self.allocator.dupe(u8, value);
        try self.map.put(self.allocator, key_copy, value_copy);
    }

    pub fn get(self: *const Self, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }

    pub fn getInt(self: *const Self, key: []const u8) ?i64 {
        const value = self.get(key) orelse return null;
        return std.fmt.parseInt(i64, value, 10) catch null;
    }
};

/// Handler context
pub const Context = struct {
    method: Method,
    path: []const u8,
    params: Params,
    query: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, method: Method, path: []const u8) Context {
        return .{
            .method = method,
            .path = path,
            .params = Params.init(allocator),
        };
    }

    pub fn deinit(self: *Context) void {
        self.params.deinit();
    }
};

/// Route handler function type
pub const HandlerFn = *const fn (*Context) anyerror!void;

/// Middleware function type
pub const MiddlewareFn = *const fn (*Context, HandlerFn) anyerror!void;

/// Route definition
pub const Route = struct {
    method: Method,
    pattern: []const u8,
    handler: HandlerFn,
    name: ?[]const u8 = null,
    middlewares: []const MiddlewareFn = &.{},
};

/// Pattern segment for matching
const Segment = union(enum) {
    static: []const u8,
    param: []const u8,
    wildcard: void,
};

/// Compiled route pattern
const CompiledPattern = struct {
    segments: []Segment,
    param_names: []const []const u8,
};

/// Router
pub const Router = struct {
    allocator: std.mem.Allocator,
    routes: std.ArrayListUnmanaged(StoredRoute),
    groups: std.ArrayListUnmanaged(Group),
    not_found_handler: ?HandlerFn = null,
    global_middlewares: std.ArrayListUnmanaged(MiddlewareFn),

    const Self = @This();

    const StoredRoute = struct {
        method: Method,
        pattern: []const u8,
        segments: []Segment,
        handler: HandlerFn,
        name: ?[]const u8,
        middlewares: []const MiddlewareFn,
    };

    const Group = struct {
        prefix: []const u8,
        middlewares: []const MiddlewareFn,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .routes = .empty,
            .groups = .empty,
            .global_middlewares = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.routes.items) |route| {
            self.allocator.free(route.pattern);
            self.allocator.free(route.segments);
            if (route.name) |n| self.allocator.free(n);
        }
        self.routes.deinit(self.allocator);

        for (self.groups.items) |grp| {
            self.allocator.free(grp.prefix);
        }
        self.groups.deinit(self.allocator);
        self.global_middlewares.deinit(self.allocator);
    }

    /// Add global middleware
    pub fn use(self: *Self, middleware: MiddlewareFn) !void {
        try self.global_middlewares.append(self.allocator, middleware);
    }

    /// Register a route
    pub fn add(self: *Self, method: Method, pattern: []const u8, handler: HandlerFn) !void {
        const pattern_copy = try self.allocator.dupe(u8, pattern);
        errdefer self.allocator.free(pattern_copy);
        const segments = try self.compilePattern(pattern_copy);

        try self.routes.append(self.allocator, .{
            .method = method,
            .pattern = pattern_copy,
            .segments = segments,
            .handler = handler,
            .name = null,
            .middlewares = &.{},
        });
    }

    /// Register a named route
    pub fn addNamed(self: *Self, method: Method, pattern: []const u8, handler: HandlerFn, name: []const u8) !void {
        const pattern_copy = try self.allocator.dupe(u8, pattern);
        errdefer self.allocator.free(pattern_copy);
        const segments = try self.compilePattern(pattern_copy);
        const name_copy = try self.allocator.dupe(u8, name);

        try self.routes.append(self.allocator, .{
            .method = method,
            .pattern = pattern_copy,
            .segments = segments,
            .handler = handler,
            .name = name_copy,
            .middlewares = &.{},
        });
    }

    // Convenience methods
    pub fn get(self: *Self, pattern: []const u8, handler: HandlerFn) !void {
        try self.add(.GET, pattern, handler);
    }

    pub fn post(self: *Self, pattern: []const u8, handler: HandlerFn) !void {
        try self.add(.POST, pattern, handler);
    }

    pub fn put(self: *Self, pattern: []const u8, handler: HandlerFn) !void {
        try self.add(.PUT, pattern, handler);
    }

    pub fn delete(self: *Self, pattern: []const u8, handler: HandlerFn) !void {
        try self.add(.DELETE, pattern, handler);
    }

    pub fn patch(self: *Self, pattern: []const u8, handler: HandlerFn) !void {
        try self.add(.PATCH, pattern, handler);
    }

    pub fn head(self: *Self, pattern: []const u8, handler: HandlerFn) !void {
        try self.add(.HEAD, pattern, handler);
    }

    pub fn options(self: *Self, pattern: []const u8, handler: HandlerFn) !void {
        try self.add(.OPTIONS, pattern, handler);
    }

    pub fn any(self: *Self, pattern: []const u8, handler: HandlerFn) !void {
        try self.add(.ANY, pattern, handler);
    }

    /// Set 404 handler
    pub fn notFound(self: *Self, handler: HandlerFn) void {
        self.not_found_handler = handler;
    }

    /// Create a route group with prefix
    pub fn group(self: *Self, prefix: []const u8) !RouteGroup {
        return RouteGroup.init(self, prefix);
    }

    /// Match a request to a route
    pub fn match(self: *Self, method: Method, path: []const u8) ?MatchResult {
        for (self.routes.items) |route| {
            if (route.method != .ANY and route.method != method) continue;

            if (self.matchPattern(route.segments, path)) |params| {
                return .{
                    .route = route,
                    .params = params,
                };
            }
        }
        return null;
    }

    /// Dispatch a request
    pub fn dispatch(self: *Self, ctx: *Context) !void {
        if (self.match(ctx.method, ctx.path)) |result| {
            // Copy params to context
            for (result.params.items) |param| {
                try ctx.params.set(param.name, param.value);
            }

            // Execute handler
            try result.route.handler(ctx);
        } else if (self.not_found_handler) |handler| {
            try handler(ctx);
        } else {
            return error.RouteNotFound;
        }
    }

    /// Get route by name
    pub fn getByName(self: *Self, name: []const u8) ?StoredRoute {
        for (self.routes.items) |route| {
            if (route.name) |n| {
                if (std.mem.eql(u8, n, name)) {
                    return route;
                }
            }
        }
        return null;
    }

    /// Generate URL for named route
    pub fn urlFor(self: *Self, name: []const u8, params: std.StringHashMap([]const u8)) !?[]const u8 {
        const route = self.getByName(name) orelse return null;

        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(self.allocator);

        for (route.segments) |segment| {
            try result.append(self.allocator, '/');
            switch (segment) {
                .static => |s| try result.appendSlice(self.allocator, s),
                .param => |p| {
                    const value = params.get(p) orelse return error.MissingParam;
                    try result.appendSlice(self.allocator, value);
                },
                .wildcard => try result.append(self.allocator, '*'),
            }
        }

        if (result.items.len == 0) {
            try result.append(self.allocator, '/');
        }

        return result.toOwnedSlice(self.allocator);
    }

    fn compilePattern(self: *Self, pattern: []const u8) ![]Segment {
        var segments: std.ArrayListUnmanaged(Segment) = .empty;
        errdefer segments.deinit(self.allocator);

        var iter = std.mem.splitScalar(u8, pattern, '/');
        while (iter.next()) |part| {
            if (part.len == 0) continue;

            if (part[0] == ':') {
                // Parameter segment
                try segments.append(self.allocator, .{ .param = part[1..] });
            } else if (std.mem.eql(u8, part, "*")) {
                // Wildcard segment
                try segments.append(self.allocator, .{ .wildcard = {} });
            } else {
                // Static segment
                try segments.append(self.allocator, .{ .static = part });
            }
        }

        return segments.toOwnedSlice(self.allocator);
    }

    const MatchParam = struct {
        name: []const u8,
        value: []const u8,
    };

    const MatchResult = struct {
        route: StoredRoute,
        params: std.ArrayListUnmanaged(MatchParam),
    };

    fn matchPattern(self: *Self, segments: []const Segment, path: []const u8) ?std.ArrayListUnmanaged(MatchParam) {
        var params: std.ArrayListUnmanaged(MatchParam) = .empty;

        var path_iter = std.mem.splitScalar(u8, path, '/');
        var seg_idx: usize = 0;

        while (path_iter.next()) |part| {
            if (part.len == 0) continue;

            if (seg_idx >= segments.len) {
                params.deinit(self.allocator);
                return null;
            }

            const segment = segments[seg_idx];
            switch (segment) {
                .static => |s| {
                    if (!std.mem.eql(u8, s, part)) {
                        params.deinit(self.allocator);
                        return null;
                    }
                },
                .param => |name| {
                    params.append(self.allocator, .{ .name = name, .value = part }) catch {
                        params.deinit(self.allocator);
                        return null;
                    };
                },
                .wildcard => {
                    // Wildcard matches rest of path
                    return params;
                },
            }
            seg_idx += 1;
        }

        // Check if all segments were matched
        if (seg_idx != segments.len) {
            params.deinit(self.allocator);
            return null;
        }

        return params;
    }
};

/// Route group for prefixed routes
pub const RouteGroup = struct {
    router: *Router,
    prefix: []const u8,
    middlewares: std.ArrayListUnmanaged(MiddlewareFn),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(router: *Router, prefix: []const u8) Self {
        return .{
            .router = router,
            .prefix = prefix,
            .middlewares = .empty,
            .allocator = router.allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.middlewares.deinit(self.allocator);
    }

    pub fn use(self: *Self, middleware: MiddlewareFn) !*Self {
        try self.middlewares.append(self.allocator, middleware);
        return self;
    }

    fn fullPath(self: *Self, pattern: []const u8) ![]const u8 {
        if (self.prefix.len == 0) {
            return self.allocator.dupe(u8, pattern);
        }
        return std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.prefix, pattern });
    }

    pub fn add(self: *Self, method: Method, pattern: []const u8, handler: HandlerFn) !void {
        const full = try self.fullPath(pattern);
        defer self.allocator.free(full);
        try self.router.add(method, full, handler);
    }

    pub fn get(self: *Self, pattern: []const u8, handler: HandlerFn) !void {
        try self.add(.GET, pattern, handler);
    }

    pub fn post(self: *Self, pattern: []const u8, handler: HandlerFn) !void {
        try self.add(.POST, pattern, handler);
    }

    pub fn put(self: *Self, pattern: []const u8, handler: HandlerFn) !void {
        try self.add(.PUT, pattern, handler);
    }

    pub fn delete(self: *Self, pattern: []const u8, handler: HandlerFn) !void {
        try self.add(.DELETE, pattern, handler);
    }

    pub fn patch(self: *Self, pattern: []const u8, handler: HandlerFn) !void {
        try self.add(.PATCH, pattern, handler);
    }
};

/// Resource routes (RESTful)
pub const Resource = struct {
    router: *Router,
    name: []const u8,
    prefix: []const u8,

    const Self = @This();

    pub fn init(router: *Router, name: []const u8, prefix: []const u8) Self {
        return .{
            .router = router,
            .name = name,
            .prefix = prefix,
        };
    }

    pub fn index(self: *Self, handler: HandlerFn) !void {
        const pattern = try std.fmt.allocPrint(self.router.allocator, "{s}", .{self.prefix});
        defer self.router.allocator.free(pattern);
        try self.router.get(pattern, handler);
    }

    pub fn show(self: *Self, handler: HandlerFn) !void {
        const pattern = try std.fmt.allocPrint(self.router.allocator, "{s}/:id", .{self.prefix});
        defer self.router.allocator.free(pattern);
        try self.router.get(pattern, handler);
    }

    pub fn create(self: *Self, handler: HandlerFn) !void {
        const pattern = try std.fmt.allocPrint(self.router.allocator, "{s}", .{self.prefix});
        defer self.router.allocator.free(pattern);
        try self.router.post(pattern, handler);
    }

    pub fn update(self: *Self, handler: HandlerFn) !void {
        const pattern = try std.fmt.allocPrint(self.router.allocator, "{s}/:id", .{self.prefix});
        defer self.router.allocator.free(pattern);
        try self.router.put(pattern, handler);
    }

    pub fn destroy(self: *Self, handler: HandlerFn) !void {
        const pattern = try std.fmt.allocPrint(self.router.allocator, "{s}/:id", .{self.prefix});
        defer self.router.allocator.free(pattern);
        try self.router.delete(pattern, handler);
    }
};

// Tests
test "method from string" {
    try std.testing.expectEqual(Method.GET, Method.fromString("GET").?);
    try std.testing.expectEqual(Method.POST, Method.fromString("POST").?);
    try std.testing.expect(Method.fromString("INVALID") == null);
}

test "params storage" {
    const allocator = std.testing.allocator;

    var params = Params.init(allocator);
    defer params.deinit();

    try params.set("id", "123");
    try params.set("name", "john");

    try std.testing.expectEqualStrings("123", params.get("id").?);
    try std.testing.expectEqualStrings("john", params.get("name").?);
    try std.testing.expectEqual(@as(i64, 123), params.getInt("id").?);
}

test "router basic route" {
    const allocator = std.testing.allocator;

    var router = Router.init(allocator);
    defer router.deinit();

    const handler = struct {
        fn handle(_: *Context) anyerror!void {}
    }.handle;

    try router.get("/users", handler);
    try router.post("/users", handler);
    try router.get("/users/:id", handler);

    // Test matching
    const match1 = router.match(.GET, "/users");
    try std.testing.expect(match1 != null);

    const match2 = router.match(.POST, "/users");
    try std.testing.expect(match2 != null);

    var match3 = router.match(.GET, "/users/123");
    try std.testing.expect(match3 != null);
    if (match3) |*m| {
        try std.testing.expectEqual(@as(usize, 1), m.params.items.len);
        try std.testing.expectEqualStrings("id", m.params.items[0].name);
        try std.testing.expectEqualStrings("123", m.params.items[0].value);
        m.params.deinit(allocator);
    }

    // Non-matching
    const match4 = router.match(.DELETE, "/users");
    try std.testing.expect(match4 == null);

    const match5 = router.match(.GET, "/posts");
    try std.testing.expect(match5 == null);
}

test "router with params" {
    const allocator = std.testing.allocator;

    var router = Router.init(allocator);
    defer router.deinit();

    const handler = struct {
        fn handle(_: *Context) anyerror!void {}
    }.handle;

    try router.get("/posts/:post_id/comments/:comment_id", handler);

    var match_result = router.match(.GET, "/posts/42/comments/7");
    try std.testing.expect(match_result != null);

    if (match_result) |*m| {
        defer m.params.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 2), m.params.items.len);

        try std.testing.expectEqualStrings("post_id", m.params.items[0].name);
        try std.testing.expectEqualStrings("42", m.params.items[0].value);

        try std.testing.expectEqualStrings("comment_id", m.params.items[1].name);
        try std.testing.expectEqualStrings("7", m.params.items[1].value);
    }
}

test "router named routes" {
    const allocator = std.testing.allocator;

    var router = Router.init(allocator);
    defer router.deinit();

    const handler = struct {
        fn handle(_: *Context) anyerror!void {}
    }.handle;

    try router.addNamed(.GET, "/users/:id", handler, "user.show");

    const route = router.getByName("user.show");
    try std.testing.expect(route != null);
    try std.testing.expectEqualStrings("/users/:id", route.?.pattern);
}

test "route group" {
    const allocator = std.testing.allocator;

    var router = Router.init(allocator);
    defer router.deinit();

    const handler = struct {
        fn handle(_: *Context) anyerror!void {}
    }.handle;

    var api = try router.group("/api/v1");
    defer api.deinit();

    try api.get("/users", handler);
    try api.post("/users", handler);
    try api.get("/users/:id", handler);

    // Test matching grouped routes
    const match1 = router.match(.GET, "/api/v1/users");
    try std.testing.expect(match1 != null);

    var match2 = router.match(.GET, "/api/v1/users/123");
    try std.testing.expect(match2 != null);
    if (match2) |*m| {
        m.params.deinit(allocator);
    }

    // Non-grouped path shouldn't match
    const match3 = router.match(.GET, "/users");
    try std.testing.expect(match3 == null);
}

test "context with params" {
    const allocator = std.testing.allocator;

    var ctx = Context.init(allocator, .GET, "/users/123");
    defer ctx.deinit();

    try ctx.params.set("id", "123");
    try ctx.params.set("format", "json");

    try std.testing.expectEqualStrings("123", ctx.params.get("id").?);
    try std.testing.expectEqual(@as(i64, 123), ctx.params.getInt("id").?);
    try std.testing.expectEqualStrings("json", ctx.params.get("format").?);
}
