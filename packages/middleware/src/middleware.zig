const std = @import("std");

/// HTTP Request context
pub const Request = struct {
    method: Method,
    path: []const u8,
    query: ?[]const u8 = null,
    headers: std.StringHashMapUnmanaged([]const u8),
    body: ?[]const u8 = null,
    params: std.StringHashMapUnmanaged([]const u8),
    allocator: std.mem.Allocator,

    // Request metadata
    id: ?[]const u8 = null,
    start_time: i64 = 0,

    pub const Method = enum {
        GET,
        POST,
        PUT,
        DELETE,
        PATCH,
        HEAD,
        OPTIONS,

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
            };
        }
    };

    pub fn init(allocator: std.mem.Allocator) Request {
        return .{
            .method = .GET,
            .path = "/",
            .headers = .empty,
            .params = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Request) void {
        self.headers.deinit(self.allocator);
        self.params.deinit(self.allocator);
    }

    pub fn getHeader(self: *const Request, name: []const u8) ?[]const u8 {
        return self.headers.get(name);
    }

    pub fn getParam(self: *const Request, name: []const u8) ?[]const u8 {
        return self.params.get(name);
    }

    pub fn isJson(self: *const Request) bool {
        const content_type = self.getHeader("Content-Type") orelse return false;
        return std.mem.indexOf(u8, content_type, "application/json") != null;
    }
};

/// HTTP Response context
pub const Response = struct {
    status_code: u16 = 200,
    headers: std.StringHashMapUnmanaged([]const u8),
    body: std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    sent: bool = false,

    pub fn init(allocator: std.mem.Allocator) Response {
        return .{
            .headers = .empty,
            .body = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Response) void {
        self.headers.deinit(self.allocator);
        self.body.deinit(self.allocator);
    }

    pub fn setStatus(self: *Response, code: u16) *Response {
        self.status_code = code;
        return self;
    }

    pub fn setHeader(self: *Response, name: []const u8, value: []const u8) !*Response {
        try self.headers.put(self.allocator, name, value);
        return self;
    }

    pub fn setContentType(self: *Response, content_type: []const u8) !*Response {
        return self.setHeader("Content-Type", content_type);
    }

    pub fn write(self: *Response, data: []const u8) !*Response {
        try self.body.appendSlice(self.allocator, data);
        return self;
    }

    pub fn json(self: *Response, data: []const u8) !*Response {
        _ = try self.setContentType("application/json");
        return self.write(data);
    }

    pub fn html(self: *Response, data: []const u8) !*Response {
        _ = try self.setContentType("text/html; charset=utf-8");
        return self.write(data);
    }

    pub fn text(self: *Response, data: []const u8) !*Response {
        _ = try self.setContentType("text/plain; charset=utf-8");
        return self.write(data);
    }

    pub fn redirect(self: *Response, location: []const u8, permanent: bool) !*Response {
        _ = self.setStatus(if (permanent) 301 else 302);
        _ = try self.setHeader("Location", location);
        return self;
    }

    pub fn notFound(self: *Response) !*Response {
        _ = self.setStatus(404);
        return self.text("Not Found");
    }

    pub fn badRequest(self: *Response, message: []const u8) !*Response {
        _ = self.setStatus(400);
        return self.text(message);
    }

    pub fn unauthorized(self: *Response) !*Response {
        _ = self.setStatus(401);
        return self.text("Unauthorized");
    }

    pub fn forbidden(self: *Response) !*Response {
        _ = self.setStatus(403);
        return self.text("Forbidden");
    }

    pub fn internalError(self: *Response) !*Response {
        _ = self.setStatus(500);
        return self.text("Internal Server Error");
    }
};

/// Context passed through middleware chain
pub const Context = struct {
    request: *Request,
    response: *Response,
    allocator: std.mem.Allocator,
    state: std.StringHashMapUnmanaged(*anyopaque),
    aborted: bool = false,

    pub fn init(allocator: std.mem.Allocator, request: *Request, response: *Response) Context {
        return .{
            .request = request,
            .response = response,
            .allocator = allocator,
            .state = .empty,
        };
    }

    pub fn deinit(self: *Context) void {
        self.state.deinit(self.allocator);
    }

    pub fn set(self: *Context, key: []const u8, value: *anyopaque) !void {
        try self.state.put(self.allocator, key, value);
    }

    pub fn get(self: *Context, comptime T: type, key: []const u8) ?*T {
        const ptr = self.state.get(key) orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    pub fn abort(self: *Context) void {
        self.aborted = true;
    }

    pub fn isAborted(self: *Context) bool {
        return self.aborted;
    }
};

/// Middleware function type
pub const MiddlewareFn = *const fn (*Context, NextFn) anyerror!void;
pub const NextFn = *const fn (*Context) anyerror!void;

/// Middleware handler interface
pub const Handler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        handle: *const fn (ptr: *anyopaque, ctx: *Context, next: NextFn) anyerror!void,
    };

    pub fn handle(self: Handler, ctx: *Context, next: NextFn) !void {
        return self.vtable.handle(self.ptr, ctx, next);
    }
};

/// Middleware pipeline
pub const Pipeline = struct {
    allocator: std.mem.Allocator,
    middlewares: std.ArrayListUnmanaged(MiddlewareFn),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .middlewares = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        self.middlewares.deinit(self.allocator);
    }

    pub fn use(self: *Self, middleware: MiddlewareFn) !*Self {
        try self.middlewares.append(self.allocator, middleware);
        return self;
    }

    pub fn execute(self: *Self, ctx: *Context) !void {
        var chain = Chain{
            .middlewares = self.middlewares.items,
            .index = 0,
        };
        try chain.next(ctx);
    }

    const Chain = struct {
        middlewares: []const MiddlewareFn,
        index: usize,

        fn next(self: *Chain, ctx: *Context) anyerror!void {
            if (ctx.isAborted()) return;
            if (self.index >= self.middlewares.len) return;

            const middleware = self.middlewares[self.index];
            self.index += 1;

            const next_fn = struct {
                fn call(c: *Context) anyerror!void {
                    // This is a simplified version - real impl would capture chain state
                    _ = c;
                }
            }.call;

            try middleware(ctx, next_fn);

            // Continue to next middleware
            try self.next(ctx);
        }
    };
};

// ============================================================================
// Built-in Middlewares
// ============================================================================

/// CORS middleware configuration
pub const CorsConfig = struct {
    allowed_origins: []const []const u8 = &.{"*"},
    allowed_methods: []const []const u8 = &.{ "GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS" },
    allowed_headers: []const []const u8 = &.{ "Content-Type", "Authorization", "X-Requested-With" },
    exposed_headers: []const []const u8 = &.{},
    allow_credentials: bool = false,
    max_age: u32 = 86400, // 24 hours

    pub fn allowAll() CorsConfig {
        return .{
            .allowed_origins = &.{"*"},
            .allow_credentials = false,
        };
    }
};

/// CORS middleware
pub const Cors = struct {
    config: CorsConfig,

    const Self = @This();

    pub fn init(config: CorsConfig) Self {
        return .{ .config = config };
    }

    pub fn middleware(self: *const Self) MiddlewareFn {
        _ = self;
        return struct {
            fn handle(ctx: *Context, next: NextFn) anyerror!void {
                // Set CORS headers
                _ = try ctx.response.setHeader("Access-Control-Allow-Origin", "*");
                _ = try ctx.response.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, PATCH, OPTIONS");
                _ = try ctx.response.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");

                // Handle preflight
                if (ctx.request.method == .OPTIONS) {
                    _ = ctx.response.setStatus(204);
                    ctx.abort();
                    return;
                }

                try next(ctx);
            }
        }.handle;
    }
};

/// Logger middleware
pub const Logger = struct {
    pub fn middleware() MiddlewareFn {
        return struct {
            fn handle(ctx: *Context, next: NextFn) anyerror!void {
                // In real implementation, would log request details
                // For now just pass through
                try next(ctx);
            }
        }.handle;
    }
};

/// Request ID middleware
pub const RequestId = struct {
    pub fn middleware() MiddlewareFn {
        return struct {
            var counter: u64 = 0;

            fn handle(ctx: *Context, next: NextFn) anyerror!void {
                // Generate simple request ID
                counter += 1;
                var buf: [32]u8 = undefined;
                const id = std.fmt.bufPrint(&buf, "req-{d}", .{counter}) catch "req-unknown";
                _ = id;

                _ = try ctx.response.setHeader("X-Request-ID", "req-id");

                try next(ctx);
            }
        }.handle;
    }
};

/// Security headers middleware
pub const SecurityHeaders = struct {
    pub fn middleware() MiddlewareFn {
        return struct {
            fn handle(ctx: *Context, next: NextFn) anyerror!void {
                _ = try ctx.response.setHeader("X-Content-Type-Options", "nosniff");
                _ = try ctx.response.setHeader("X-Frame-Options", "DENY");
                _ = try ctx.response.setHeader("X-XSS-Protection", "1; mode=block");
                _ = try ctx.response.setHeader("Referrer-Policy", "strict-origin-when-cross-origin");

                try next(ctx);
            }
        }.handle;
    }
};

/// Content-Type validation middleware
pub const ContentType = struct {
    pub fn requireJson() MiddlewareFn {
        return struct {
            fn handle(ctx: *Context, next: NextFn) anyerror!void {
                if (ctx.request.method != .GET and ctx.request.method != .HEAD and ctx.request.method != .OPTIONS) {
                    if (!ctx.request.isJson()) {
                        _ = try ctx.response.badRequest("Content-Type must be application/json");
                        ctx.abort();
                        return;
                    }
                }
                try next(ctx);
            }
        }.handle;
    }
};

/// Recovery middleware (panic handler)
pub const Recovery = struct {
    pub fn middleware() MiddlewareFn {
        return struct {
            fn handle(ctx: *Context, next: NextFn) anyerror!void {
                next(ctx) catch |err| {
                    _ = try ctx.response.internalError();
                    _ = err;
                    return;
                };
            }
        }.handle;
    }
};

/// Timeout middleware configuration
pub const TimeoutConfig = struct {
    timeout_ms: u64 = 30000,
};

/// Method override middleware (for forms that can only POST)
pub const MethodOverride = struct {
    pub fn middleware() MiddlewareFn {
        return struct {
            fn handle(ctx: *Context, next: NextFn) anyerror!void {
                if (ctx.request.method == .POST) {
                    // Check for _method in query or header
                    if (ctx.request.getHeader("X-HTTP-Method-Override")) |method_str| {
                        if (Request.Method.fromString(method_str)) |method| {
                            ctx.request.method = method;
                        }
                    }
                }
                try next(ctx);
            }
        }.handle;
    }
};

/// Compression configuration
pub const CompressionConfig = struct {
    min_size: usize = 1024, // Minimum size to compress
    level: Level = .default,

    pub const Level = enum { none, fast, default, best };
};

/// ETag middleware for caching
pub const ETag = struct {
    pub fn middleware() MiddlewareFn {
        return struct {
            fn handle(ctx: *Context, next: NextFn) anyerror!void {
                try next(ctx);

                // Generate simple ETag from response body
                if (ctx.response.body.items.len > 0) {
                    var hash: u64 = 0;
                    for (ctx.response.body.items) |byte| {
                        hash = hash *% 31 +% byte;
                    }
                    var etag_buf: [32]u8 = undefined;
                    const etag = std.fmt.bufPrint(&etag_buf, "\"{x}\"", .{hash}) catch return;

                    _ = try ctx.response.setHeader("ETag", etag);

                    // Check If-None-Match
                    if (ctx.request.getHeader("If-None-Match")) |client_etag| {
                        if (std.mem.eql(u8, client_etag, etag)) {
                            _ = ctx.response.setStatus(304);
                            ctx.response.body.clearRetainingCapacity();
                        }
                    }
                }
            }
        }.handle;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "request and response" {
    const allocator = std.testing.allocator;

    var req = Request.init(allocator);
    defer req.deinit();

    req.method = .POST;
    req.path = "/api/users";

    try std.testing.expectEqual(Request.Method.POST, req.method);
    try std.testing.expectEqualStrings("/api/users", req.path);

    var resp = Response.init(allocator);
    defer resp.deinit();

    _ = resp.setStatus(201);
    _ = try resp.json("{\"id\": 1}");

    try std.testing.expectEqual(@as(u16, 201), resp.status_code);
    try std.testing.expectEqualStrings("{\"id\": 1}", resp.body.items);
}

test "context state" {
    const allocator = std.testing.allocator;

    var req = Request.init(allocator);
    defer req.deinit();

    var resp = Response.init(allocator);
    defer resp.deinit();

    var ctx = Context.init(allocator, &req, &resp);
    defer ctx.deinit();

    var user_id: u32 = 42;
    try ctx.set("user_id", &user_id);

    const retrieved = ctx.get(u32, "user_id");
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(@as(u32, 42), retrieved.?.*);
}

test "pipeline execution" {
    const allocator = std.testing.allocator;

    var pipeline = Pipeline.init(allocator);
    defer pipeline.deinit();

    // Add middleware that sets a header
    _ = try pipeline.use(struct {
        fn handle(ctx: *Context, next: NextFn) anyerror!void {
            _ = try ctx.response.setHeader("X-Test", "middleware1");
            try next(ctx);
        }
    }.handle);

    // Add another middleware
    _ = try pipeline.use(struct {
        fn handle(ctx: *Context, next: NextFn) anyerror!void {
            _ = try ctx.response.setHeader("X-Test-2", "middleware2");
            try next(ctx);
        }
    }.handle);

    var req = Request.init(allocator);
    defer req.deinit();

    var resp = Response.init(allocator);
    defer resp.deinit();

    var ctx = Context.init(allocator, &req, &resp);
    defer ctx.deinit();

    try pipeline.execute(&ctx);

    try std.testing.expectEqualStrings("middleware1", resp.headers.get("X-Test").?);
    try std.testing.expectEqualStrings("middleware2", resp.headers.get("X-Test-2").?);
}

test "response helpers" {
    const allocator = std.testing.allocator;

    var resp = Response.init(allocator);
    defer resp.deinit();

    _ = try resp.redirect("/login", false);
    try std.testing.expectEqual(@as(u16, 302), resp.status_code);
    try std.testing.expectEqualStrings("/login", resp.headers.get("Location").?);
}

test "method from string" {
    try std.testing.expectEqual(Request.Method.GET, Request.Method.fromString("GET").?);
    try std.testing.expectEqual(Request.Method.POST, Request.Method.fromString("POST").?);
    try std.testing.expect(Request.Method.fromString("INVALID") == null);
}
