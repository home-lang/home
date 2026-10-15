const std = @import("std");
const compat = @import("compat.zig");

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
    owned_header_values: std.ArrayList([]u8),
    body_data: []const u8,

    pub fn init(allocator: std.mem.Allocator, method: Method, path: []const u8) Request {
        return .{
            .allocator = allocator,
            .method = method,
            .path = path,
            .params = std.StringHashMap([]const u8).init(allocator),
            .query = std.StringHashMap([]const u8).init(allocator),
            .headers = std.StringHashMap([]const u8).init(allocator),
            .owned_header_values = .empty,
            .body_data = &[_]u8{},
        };
    }

    pub fn deinit(self: *Request) void {
        self.params.deinit();
        self.query.deinit();
        self.headers.deinit();
        for (self.owned_header_values.items) |value| self.allocator.free(value);
        self.owned_header_values.deinit(self.allocator);
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

    pub fn setHeaderCopy(self: *Request, key: []const u8, value: []const u8) !void {
        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);
        try self.owned_header_values.append(self.allocator, value_copy);
        errdefer _ = self.owned_header_values.pop();
        try self.headers.put(key, value_copy);
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
    owned_header_values: std.ArrayList([]u8),
    body_content: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) Response {
        return .{
            .allocator = allocator,
            .status_code = 200,
            .headers = std.StringHashMap([]const u8).init(allocator),
            .owned_header_values = .empty,
            .body_content = std.ArrayList(u8).empty,
        };
    }

    pub fn deinit(self: *Response) void {
        self.headers.deinit();
        for (self.owned_header_values.items) |value| self.allocator.free(value);
        self.owned_header_values.deinit(self.allocator);
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

    pub fn setHeaderCopy(self: *Response, key: []const u8, value: []const u8) !*Response {
        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);
        try self.owned_header_values.append(self.allocator, value_copy);
        errdefer _ = self.owned_header_values.pop();
        try self.headers.put(key, value_copy);
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

pub const Next = struct {
    context: *anyopaque,
    call_fn: *const fn (*anyopaque) anyerror!void,

    pub fn call(self: Next) !void {
        try self.call_fn(self.context);
    }
};

/// Middleware handler with optional caller-owned state.
pub const Middleware = struct {
    context: ?*anyopaque = null,
    handle_fn: *const fn (?*anyopaque, *Request, *Response, Next) anyerror!void,

    pub fn handle(self: Middleware, req: *Request, res: *Response, next: Next) !void {
        try self.handle_fn(self.context, req, res, next);
    }
};

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
            .routes = std.ArrayList(Route).empty,
            .middleware_stack = std.ArrayList(Middleware).empty,
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
        var param_names = std.ArrayList([]const u8).empty;

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

        const Continuation = struct {
            router: *Router,
            index: usize,
            request: *Request,
            response: *Response,
            route_handler: Handler,

            fn call(raw_context: *anyopaque) !void {
                const context: *@This() = @ptrCast(@alignCast(raw_context));
                try context.router.executeMiddleware(
                    context.index,
                    context.request,
                    context.response,
                    context.route_handler,
                );
            }
        };
        var continuation = Continuation{
            .router = self,
            .index = idx + 1,
            .request = req,
            .response = res,
            .route_handler = handler,
        };

        try self.middleware_stack.items[idx].handle(req, res, .{
            .context = &continuation,
            .call_fn = Continuation.call,
        });
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
            .middleware = std.ArrayList(Middleware).empty,
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
    return .{ .handle_fn = struct {
        fn middleware(_: ?*anyopaque, req: *Request, res: *Response, next: Next) !void {
            _ = req;
            _ = try res.setHeader("Access-Control-Allow-Origin", "*");
            _ = try res.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, PATCH, OPTIONS");
            _ = try res.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");
            try next.call();
        }
    }.middleware };
}

/// Logger middleware
pub fn logger() Middleware {
    return .{ .handle_fn = struct {
        fn middleware(_: ?*anyopaque, req: *Request, res: *Response, next: Next) !void {
            const io = compat.io();
            const start = std.Io.Clock.awake.now(io);
            try next.call();
            const duration_ms = start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();

            std.debug.print("{s} {s} - {d} ({d}ms)\n", .{
                req.method.toString(),
                req.path,
                res.status_code,
                duration_ms,
            });
        }
    }.middleware };
}

/// Body parser middleware (JSON)
pub fn bodyParser() Middleware {
    return .{
        .handle_fn = struct {
            fn middleware(_: ?*anyopaque, req: *Request, res: *Response, next: Next) !void {
                _ = req;
                _ = res;
                // In production: parse req.body_data as JSON
                try next.call();
            }
        }.middleware,
    };
}

fn headerCopyAllocationProbe(allocator: std.mem.Allocator) !void {
    var request = Request.init(allocator, .GET, "/");
    defer request.deinit();
    try request.setHeaderCopy("X-Request-ID", "first");
    try request.setHeaderCopy("X-Request-ID", "replacement");
    try std.testing.expectEqualStrings("replacement", request.header("X-Request-ID").?);

    var response = Response.init(allocator);
    defer response.deinit();
    _ = try response.setHeaderCopy("Set-Cookie", "first");
    _ = try response.setHeaderCopy("Set-Cookie", "replacement");
    try std.testing.expectEqualStrings("replacement", response.headers.get("Set-Cookie").?);
}

test "copied headers release every allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        headerCopyAllocationProbe,
        .{},
    );
}

test "middleware next preserves nesting order" {
    const Chain = struct {
        fn first(_: ?*anyopaque, _: *Request, res: *Response, next: Next) !void {
            try res.send("a");
            try next.call();
            try res.send("d");
        }

        fn second(_: ?*anyopaque, _: *Request, res: *Response, next: Next) !void {
            try res.send("b");
            try next.call();
            try res.send("c");
        }

        fn handler(_: *Request, res: *Response) !void {
            try res.send("h");
        }
    };

    var router = Router.init(std.testing.allocator);
    defer router.deinit();
    try router.use(.{ .handle_fn = Chain.first });
    try router.use(.{ .handle_fn = Chain.second });
    try router.get("/", Chain.handler);

    var request = Request.init(std.testing.allocator, .GET, "/");
    defer request.deinit();
    var response = Response.init(std.testing.allocator);
    defer response.deinit();

    try router.handle(&request, &response);
    try std.testing.expectEqualStrings("abhcd", response.body_content.items);
}
