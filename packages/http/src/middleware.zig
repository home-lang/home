const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

/// Middleware handler function type
/// Similar to Laravel's middleware handle($request, $next) signature
pub const MiddlewareHandler = *const fn (req: *Request, res: *Response) anyerror!bool;

/// Middleware definition
pub const Middleware = struct {
    name: []const u8,
    handler: MiddlewareHandler,

    pub fn init(name: []const u8, handler: MiddlewareHandler) Middleware {
        return .{
            .name = name,
            .handler = handler,
        };
    }
};

/// Middleware stack - simpler than pipeline
pub const Stack = struct {
    middlewares: std.ArrayListUnmanaged(Middleware),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Stack {
        return .{
            .middlewares = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Stack) void {
        self.middlewares.deinit(self.allocator);
    }

    /// Add middleware to the stack
    pub fn use(self: *Stack, name: []const u8, handler: MiddlewareHandler) !void {
        try self.middlewares.append(self.allocator, Middleware.init(name, handler));
    }

    /// Execute all middleware in order
    /// Returns true if all middleware passed, false if any middleware stopped the request
    pub fn execute(self: *const Stack, req: *Request, res: *Response) !bool {
        for (self.middlewares.items) |middleware| {
            const should_continue = try middleware.handler(req, res);
            if (!should_continue) {
                return false; // Middleware stopped the request
            }
        }
        return true; // All middleware passed
    }
};

/// Built-in middleware: CORS
pub const corsMiddleware: MiddlewareHandler = struct {
    fn handle(req: *Request, res: *Response) !bool {
        _ = req;
        _ = res.setHeader("Access-Control-Allow-Origin", "*") catch {};
        _ = res.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, PATCH") catch {};
        _ = res.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization") catch {};
        return true; // Continue to next middleware
    }
}.handle;

/// Built-in middleware: Logging (Laravel-style)
pub const loggerMiddleware: MiddlewareHandler = struct {
    fn handle(req: *Request, res: *Response) !bool {
        _ = res;
        std.debug.print("[{s}] {s}\n", .{ @tagName(req.method), req.uri });
        return true; // Continue to next middleware
    }
}.handle;

/// Built-in middleware: Authentication check
pub const authMiddleware: MiddlewareHandler = struct {
    fn handle(req: *Request, res: *Response) !bool {
        // Check for Authorization header
        if (req.header("Authorization")) |_| {
            // Token exists, proceed
            return true;
        } else {
            // No token, return 401 and stop
            _ = res.setStatus(.Unauthorized);
            try res.send("Unauthorized");
            return false; // Stop execution
        }
    }
}.handle;

/// Built-in middleware: JSON body parser
pub const jsonParserMiddleware: MiddlewareHandler = struct {
    fn handle(req: *Request, res: *Response) !bool {
        _ = res;
        // In a real implementation, we'd parse the body here
        // For now, just validate content type
        if (req.isJSON()) {
            // Body is already available in req.body
            return true;
        }
        return true; // Continue even if not JSON
    }
}.handle;

/// Built-in middleware: Rate limiting (simple version)
/// Note: This is a simple in-memory rate limiter for demonstration.
/// In production, use a distributed cache like Redis.
pub const RateLimiter = struct {
    max_requests: u32,
    window_seconds: u32,
    // In a real implementation, this would use a proper cache/store
    // For now, we just track counts (simplified)

    pub fn init(max_requests: u32, window_seconds: u32) RateLimiter {
        return .{
            .max_requests = max_requests,
            .window_seconds = window_seconds,
        };
    }

    /// Create a middleware handler for this rate limiter
    /// Note: In a real implementation, this would maintain state properly
    pub fn createMiddleware(self: RateLimiter) MiddlewareHandler {
        _ = self;
        // For now, return a simple middleware that always passes
        // A real implementation would need to track state across requests
        return struct {
            fn handle(req: *Request, res: *Response) !bool {
                _ = req;
                _ = res;
                // TODO: Implement actual rate limiting logic
                return true;
            }
        }.handle;
    }
};

/// Middleware group - Laravel-style grouped middleware
pub const MiddlewareGroup = struct {
    name: []const u8,
    middlewares: []const MiddlewareHandler,

    pub fn init(name: []const u8, middlewares: []const MiddlewareHandler) MiddlewareGroup {
        return .{
            .name = name,
            .middlewares = middlewares,
        };
    }
};

test "Middleware basic execution" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var stack = Stack.init(allocator);
    defer stack.deinit();

    // Simple middleware that adds a header
    const addHeaderMiddleware: MiddlewareHandler = struct {
        fn handle(req: *Request, res: *Response) !bool {
            _ = req;
            _ = try res.setHeader("X-Custom", "test");
            return true;
        }
    }.handle;

    try stack.use("addHeader", addHeaderMiddleware);

    var req = try Request.init(allocator, .GET, "/test");
    defer req.deinit();

    var res = Response.init(allocator);
    defer res.deinit();

    const should_continue = try stack.execute(req, res);

    try testing.expect(should_continue);
    try testing.expect(res.headers.has("X-Custom"));
    try testing.expectEqualStrings("test", res.headers.get("X-Custom").?);
}

test "Middleware chain execution order" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var stack = Stack.init(allocator);
    defer stack.deinit();

    const middleware1: MiddlewareHandler = struct {
        fn handle(req: *Request, res: *Response) !bool {
            _ = req;
            _ = try res.setHeader("X-First", "1");
            return true;
        }
    }.handle;

    const middleware2: MiddlewareHandler = struct {
        fn handle(req: *Request, res: *Response) !bool {
            _ = req;
            _ = try res.setHeader("X-Second", "2");
            return true;
        }
    }.handle;

    try stack.use("first", middleware1);
    try stack.use("second", middleware2);

    var req = try Request.init(allocator, .GET, "/test");
    defer req.deinit();

    var res = Response.init(allocator);
    defer res.deinit();

    const should_continue = try stack.execute(req, res);

    try testing.expect(should_continue);
    try testing.expectEqualStrings("1", res.headers.get("X-First").?);
    try testing.expectEqualStrings("2", res.headers.get("X-Second").?);
}

test "Auth middleware blocks unauthorized requests" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var req = try Request.init(allocator, .GET, "/protected");
    defer req.deinit();

    var res = Response.init(allocator);
    defer res.deinit();

    const should_continue = try authMiddleware(req, res);

    try testing.expect(!should_continue); // Should stop execution
    try testing.expectEqual(@as(u16, 401), @intFromEnum(res.status));
}

test "Auth middleware allows authorized requests" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var req = try Request.init(allocator, .GET, "/protected");
    defer req.deinit();

    try req.headers.set("Authorization", "Bearer token123");

    var res = Response.init(allocator);
    defer res.deinit();

    const should_continue = try authMiddleware(req, res);

    try testing.expect(should_continue); // Should continue
}
