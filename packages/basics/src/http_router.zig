const std = @import("std");

/// HTTP Router for Home - Express.js/Laravel-style routing
/// Provides high-level routing with middleware support

pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    OPTIONS,
    HEAD,

    pub fn fromString(str: []const u8) ?Method {
        if (std.mem.eql(u8, str, "GET")) return .GET;
        if (std.mem.eql(u8, str, "POST")) return .POST;
        if (std.mem.eql(u8, str, "PUT")) return .PUT;
        if (std.mem.eql(u8, str, "DELETE")) return .DELETE;
        if (std.mem.eql(u8, str, "PATCH")) return .PATCH;
        if (std.mem.eql(u8, str, "OPTIONS")) return .OPTIONS;
        if (std.mem.eql(u8, str, "HEAD")) return .HEAD;
        return null;
    }

    pub fn toString(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .PATCH => "PATCH",
            .OPTIONS => "OPTIONS",
            .HEAD => "HEAD",
        };
    }
};

/// HTTP Request
pub const Request = struct {
    allocator: std.mem.Allocator,
    method: Method,
    path: []const u8,
    params: std.StringHashMap([]const u8),
    query: std.StringHashMap([]const u8),
    headers: std.StringHashMap([]const u8),
    body_data: []const u8,

    pub fn init(allocator: std.mem.Allocator, method: Method, path: []const u8) Request {
        return .{
            .allocator = allocator,
            .method = method,
            .path = path,
            .params = std.StringHashMap([]const u8).init(allocator),
            .query = std.StringHashMap([]const u8).init(allocator),
            .headers = std.StringHashMap([]const u8).init(allocator),
            .body_data = &[_]u8{},
        };
    }

    pub fn deinit(self: *Request) void {
        self.params.deinit();
        self.query.deinit();
        self.headers.deinit();
    }

    pub fn param(self: *Request, key: []const u8) ?[]const u8 {
        return self.params.get(key);
    }

    pub fn queryParam(self: *Request, key: []const u8) ?[]const u8 {
        return self.query.get(key);
    }

    pub fn header(self: *Request, key: []const u8) ?[]const u8 {
        return self.headers.get(key);
    }

    pub fn body(self: *Request) []const u8 {
        return self.body_data;
    }
};

/// HTTP Response
pub const Response = struct {
    allocator: std.mem.Allocator,
    status_code: u16,
    headers: std.StringHashMap([]const u8),
    body_content: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) Response {
        return .{
            .allocator = allocator,
            .status_code = 200,
            .headers = std.StringHashMap([]const u8).init(allocator),
            .body_content = std.ArrayList(u8){},
        };
    }

    pub fn deinit(self: *Response) void {
        self.headers.deinit();
        self.body_content.deinit(self.allocator);
    }

    pub fn status(self: *Response, code: u16) *Response {
        self.status_code = code;
        return self;
    }

    pub fn setHeader(self: *Response, key: []const u8, value: []const u8) !*Response {
        try self.headers.put(key, value);
        return self;
    }

    pub fn send(self: *Response, content: []const u8) !void {
        try self.body_content.appendSlice(self.allocator, content);
    }

    pub fn json(self: *Response, content: []const u8) !void {
        _ = try self.setHeader("Content-Type", "application/json");
        try self.body_content.appendSlice(self.allocator, content);
    }

    pub fn html(self: *Response, content: []const u8) !void {
        _ = try self.setHeader("Content-Type", "text/html; charset=utf-8");
        try self.body_content.appendSlice(self.allocator, content);
    }

    pub fn redirect(self: *Response, location: []const u8) !void {
        self.status_code = 302;
        _ = try self.setHeader("Location", location);
    }
};

/// Handler function type
pub const Handler = *const fn (*Request, *Response) anyerror!void;

/// Middleware function type
pub const Middleware = *const fn (*Request, *Response, *const fn () anyerror!void) anyerror!void;

/// Route definition
pub const Route = struct {
    allocator: std.mem.Allocator,
    method: Method,
    pattern: []const u8,
    handler: Handler,
    param_names: std.ArrayList([]const u8),
    owns_pattern: bool,

    pub fn deinit(self: *Route) void {
        if (self.owns_pattern) {
            self.allocator.free(self.pattern);
        }
        self.param_names.deinit(self.allocator);
    }
};

/// Router
pub const Router = struct {
    allocator: std.mem.Allocator,
    routes: std.ArrayList(Route),
    middleware_stack: std.ArrayList(Middleware),
    base_path: []const u8,

    pub fn init(allocator: std.mem.Allocator) Router {
        return .{
            .allocator = allocator,
            .routes = std.ArrayList(Route){},
            .middleware_stack = std.ArrayList(Middleware){},
            .base_path = "",
        };
    }

    pub fn deinit(self: *Router) void {
        for (self.routes.items) |*route| {
            route.deinit();
        }
        self.routes.deinit(self.allocator);
        self.middleware_stack.deinit(self.allocator);
    }

    /// Add GET route
    pub fn get(self: *Router, pattern: []const u8, handler: Handler) !void {
        try self.addRoute(.GET, pattern, handler);
    }

    /// Add POST route
    pub fn post(self: *Router, pattern: []const u8, handler: Handler) !void {
        try self.addRoute(.POST, pattern, handler);
    }

    /// Add PUT route
    pub fn put(self: *Router, pattern: []const u8, handler: Handler) !void {
        try self.addRoute(.PUT, pattern, handler);
    }

    /// Add DELETE route
    pub fn delete(self: *Router, pattern: []const u8, handler: Handler) !void {
        try self.addRoute(.DELETE, pattern, handler);
    }

    /// Add PATCH route
    pub fn patch(self: *Router, pattern: []const u8, handler: Handler) !void {
        try self.addRoute(.PATCH, pattern, handler);
    }

    /// Add OPTIONS route
    pub fn options(self: *Router, pattern: []const u8, handler: Handler) !void {
        try self.addRoute(.OPTIONS, pattern, handler);
    }

    /// Add HEAD route
    pub fn head(self: *Router, pattern: []const u8, handler: Handler) !void {
        try self.addRoute(.HEAD, pattern, handler);
    }

    /// Add route for any method
    pub fn any(self: *Router, pattern: []const u8, handler: Handler) !void {
        try self.addRoute(.GET, pattern, handler);
        try self.addRoute(.POST, pattern, handler);
        try self.addRoute(.PUT, pattern, handler);
        try self.addRoute(.DELETE, pattern, handler);
        try self.addRoute(.PATCH, pattern, handler);
    }

    /// Add middleware
    pub fn use(self: *Router, middleware: Middleware) !void {
        try self.middleware_stack.append(self.allocator, middleware);
    }

    /// Add route
    fn addRoute(self: *Router, method: Method, pattern: []const u8, handler: Handler) !void {
        var param_names = std.ArrayList([]const u8){};

        // Parse route pattern for parameters (:param)
        var iter = std.mem.splitSequence(u8, pattern, "/");
        while (iter.next()) |segment| {
            if (segment.len > 0 and segment[0] == ':') {
                try param_names.append(self.allocator, segment[1..]);
            }
        }

        // Duplicate the pattern so we own it
        const owned_pattern = try self.allocator.dupe(u8, pattern);

        try self.routes.append(self.allocator, .{
            .allocator = self.allocator,
            .method = method,
            .pattern = owned_pattern,
            .handler = handler,
            .param_names = param_names,
            .owns_pattern = true,
        });
    }

    /// Match and handle request
    pub fn handle(self: *Router, req: *Request, res: *Response) !void {
        // Find matching route
        for (self.routes.items) |*route| {
            if (route.method != req.method) continue;

            if (try self.matchRoute(route, req)) {
                // Execute middleware chain
                try self.executeMiddleware(0, req, res, route.handler);
                return;
            }
        }

        // No route found - 404
        res.status_code = 404;
        try res.send("Not Found");
    }

    /// Match route pattern against request path
    fn matchRoute(_: *Router, route: *Route, req: *Request) !bool {
        var pattern_parts = std.mem.splitSequence(u8, route.pattern, "/");
        var path_parts = std.mem.splitSequence(u8, req.path, "/");

        var param_idx: usize = 0;

        while (true) {
            const pattern_part = pattern_parts.next();
            const path_part = path_parts.next();

            if (pattern_part == null and path_part == null) {
                return true; // Exact match
            }

            if (pattern_part == null or path_part == null) {
                return false; // Length mismatch
            }

            const p_part = pattern_part.?;
            const path_segment = path_part.?;

            if (p_part.len > 0 and p_part[0] == ':') {
                // Parameter segment
                if (param_idx < route.param_names.items.len) {
                    try req.params.put(route.param_names.items[param_idx], path_segment);
                    param_idx += 1;
                }
            } else if (!std.mem.eql(u8, p_part, path_segment)) {
                return false; // Segment mismatch
            }
        }
    }

    /// Execute middleware chain
    fn executeMiddleware(self: *Router, idx: usize, req: *Request, res: *Response, handler: Handler) !void {
        if (idx >= self.middleware_stack.items.len) {
            // All middleware executed, call handler
            try handler(req, res);
            return;
        }

        const middleware = self.middleware_stack.items[idx];
        const next = struct {
            fn call() !void {
                // This would be replaced with actual context
            }
        }.call;

        try middleware(req, res, next);
        try self.executeMiddleware(idx + 1, req, res, handler);
    }
};

/// HTTP Server with routing
pub const HttpServer = struct {
    allocator: std.mem.Allocator,
    router: Router,
    port: u16,
    host: []const u8,

    pub fn init(allocator: std.mem.Allocator) HttpServer {
        return .{
            .allocator = allocator,
            .router = Router.init(allocator),
            .port = 3000,
            .host = "127.0.0.1",
        };
    }

    pub fn deinit(self: *HttpServer) void {
        self.router.deinit();
    }

    /// Set server port
    pub fn setPort(self: *HttpServer, port: u16) *HttpServer {
        self.port = port;
        return self;
    }

    /// Set server host
    pub fn setHost(self: *HttpServer, host: []const u8) *HttpServer {
        self.host = host;
        return self;
    }

    /// Add GET route
    pub fn get(self: *HttpServer, pattern: []const u8, handler: Handler) !*HttpServer {
        try self.router.get(pattern, handler);
        return self;
    }

    /// Add POST route
    pub fn post(self: *HttpServer, pattern: []const u8, handler: Handler) !*HttpServer {
        try self.router.post(pattern, handler);
        return self;
    }

    /// Add PUT route
    pub fn put(self: *HttpServer, pattern: []const u8, handler: Handler) !*HttpServer {
        try self.router.put(pattern, handler);
        return self;
    }

    /// Add DELETE route
    pub fn delete(self: *HttpServer, pattern: []const u8, handler: Handler) !*HttpServer {
        try self.router.delete(pattern, handler);
        return self;
    }

    /// Add PATCH route
    pub fn patch(self: *HttpServer, pattern: []const u8, handler: Handler) !*HttpServer {
        try self.router.patch(pattern, handler);
        return self;
    }

    /// Add middleware
    pub fn use(self: *HttpServer, middleware: Middleware) !*HttpServer {
        try self.router.use(middleware);
        return self;
    }

    /// Start listening (simplified - would integrate with actual TCP server)
    pub fn listen(self: *HttpServer) !void {
        std.debug.print("🚀 Server listening on http://{s}:{d}\n", .{ self.host, self.port });

        // In production, this would:
        // 1. Create TCP listener
        // 2. Accept connections
        // 3. Parse HTTP requests
        // 4. Call router.handle()
        // 5. Send responses

        // For now, this is a framework - actual TCP integration would go here
    }
};

/// Router group for organizing routes
pub const RouteGroup = struct {
    allocator: std.mem.Allocator,
    router: *Router,
    prefix: []const u8,
    middleware: std.ArrayList(Middleware),

    pub fn init(allocator: std.mem.Allocator, router: *Router, prefix: []const u8) RouteGroup {
        return .{
            .allocator = allocator,
            .router = router,
            .prefix = prefix,
            .middleware = std.ArrayList(Middleware){},
        };
    }

    pub fn deinit(self: *RouteGroup) void {
        self.middleware.deinit(self.allocator);
    }

    /// Add middleware to group
    pub fn use(self: *RouteGroup, middleware: Middleware) !*RouteGroup {
        try self.middleware.append(self.allocator, middleware);
        return self;
    }

    /// Add GET route to group
    pub fn get(self: *RouteGroup, pattern: []const u8, handler: Handler) !void {
        const full_pattern = try std.fmt.allocPrint(self.router.allocator, "{s}{s}", .{ self.prefix, pattern });
        defer self.router.allocator.free(full_pattern);
        try self.router.get(full_pattern, handler);
    }

    /// Add POST route to group
    pub fn post(self: *RouteGroup, pattern: []const u8, handler: Handler) !void {
        const full_pattern = try std.fmt.allocPrint(self.router.allocator, "{s}{s}", .{ self.prefix, pattern });
        defer self.router.allocator.free(full_pattern);
        try self.router.post(full_pattern, handler);
    }
};

/// Common middleware functions

/// CORS middleware
pub fn cors() Middleware {
    return struct {
        fn middleware(req: *Request, res: *Response, next: *const fn () anyerror!void) !void {
            _ = req;
            _ = try res.setHeader("Access-Control-Allow-Origin", "*");
            _ = try res.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, PATCH, OPTIONS");
            _ = try res.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");
            try next();
        }
    }.middleware;
}

/// Logger middleware
pub fn logger() Middleware {
    return struct {
        fn getNanoTimestamp() u64 {
            var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
            _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
            return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
        }

        fn middleware(req: *Request, res: *Response, next: *const fn () anyerror!void) !void {
            const start = getNanoTimestamp();
            try next();
            const end = getNanoTimestamp();
            const duration_ms = (end - start) / std.time.ns_per_ms;

            std.debug.print("{s} {s} - {d} ({d}ms)\n", .{
                req.method.toString(),
                req.path,
                res.status_code,
                duration_ms,
            });
        }
    }.middleware;
}

/// Body parser middleware (JSON)
pub fn bodyParser() Middleware {
    return struct {
        fn middleware(req: *Request, res: *Response, next: *const fn () anyerror!void) !void {
            _ = req;
            _ = res;
            // In production: parse req.body_data as JSON
            try next();
        }
    }.middleware;
}
