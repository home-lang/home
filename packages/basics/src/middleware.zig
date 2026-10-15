const std = @import("std");
const http_router = @import("http_router.zig");
const compat = @import("compat.zig");

/// Enhanced Middleware System for Home
/// Provides comprehensive middleware for web applications
pub const MiddlewareContext = struct {
    allocator: std.mem.Allocator,
    data: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) MiddlewareContext {
        return .{
            .allocator = allocator,
            .data = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *MiddlewareContext) void {
        self.data.deinit();
    }

    pub fn set(self: *MiddlewareContext, key: []const u8, value: []const u8) !void {
        try self.data.put(key, value);
    }

    pub fn get(self: *MiddlewareContext, key: []const u8) ?[]const u8 {
        return self.data.get(key);
    }
};

/// CORS Middleware with configurable options
pub const CorsOptions = struct {
    allow_origin: []const u8 = "*",
    allow_methods: []const u8 = "GET, POST, PUT, DELETE, PATCH, OPTIONS",
    allow_headers: []const u8 = "Content-Type, Authorization",
    allow_credentials: bool = false,
    max_age: u32 = 86400, // 24 hours
};

pub fn cors(comptime options: CorsOptions) http_router.Middleware {
    return .{
        .handle_fn = struct {
            fn middleware(_: ?*anyopaque, req: *http_router.Request, res: *http_router.Response, next: http_router.Next) !void {
                _ = req;
                _ = try res.setHeader("Access-Control-Allow-Origin", options.allow_origin);
                _ = try res.setHeader("Access-Control-Allow-Methods", options.allow_methods);
                _ = try res.setHeader("Access-Control-Allow-Headers", options.allow_headers);

                if (options.allow_credentials) {
                    _ = try res.setHeader("Access-Control-Allow-Credentials", "true");
                }

                var max_age_buf: [20]u8 = undefined;
                const max_age = try std.fmt.bufPrint(&max_age_buf, "{d}", .{options.max_age});
                _ = try res.setHeaderCopy("Access-Control-Max-Age", max_age);

                try next.call();
            }
        }.middleware,
    };
}

/// Logger Middleware with configurable format
pub const LogFormat = enum {
    minimal,
    standard,
    verbose,
};

pub fn logger(comptime format: LogFormat) http_router.Middleware {
    return .{ .handle_fn = struct {
        fn middleware(_: ?*anyopaque, req: *http_router.Request, res: *http_router.Response, next: http_router.Next) !void {
            const io = compat.io();
            const start = std.Io.Clock.awake.now(io);

            try next.call();

            const duration_ms = start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();

            switch (format) {
                .minimal => {
                    std.debug.print("{s} {s} {d}\n", .{
                        req.method.toString(),
                        req.path,
                        res.status_code,
                    });
                },
                .standard => {
                    std.debug.print("[{d}ms] {s} {s} - {d}\n", .{
                        duration_ms,
                        req.method.toString(),
                        req.path,
                        res.status_code,
                    });
                },
                .verbose => {
                    const timestamp = compat.timestamp(io);
                    std.debug.print("[{d}] {s} {s} - Status: {d} - Duration: {d}ms\n", .{
                        timestamp,
                        req.method.toString(),
                        req.path,
                        res.status_code,
                        duration_ms,
                    });
                },
            }
        }
    }.middleware };
}

/// Body Parser Middleware for JSON
pub fn jsonBodyParser() http_router.Middleware {
    return .{
        .handle_fn = struct {
            fn middleware(_: ?*anyopaque, req: *http_router.Request, res: *http_router.Response, next: http_router.Next) !void {
                _ = res;
                const content_type = req.header("Content-Type");

                if (content_type != null and std.mem.indexOf(u8, content_type.?, "application/json") != null) {
                    // Body is already in req.body_data
                    // In production, this would parse and validate JSON
                }

                try next.call();
            }
        }.middleware,
    };
}

/// Rate Limiter Middleware
pub const RateLimitConfig = struct {
    max_requests: u32 = 100,
    window_ms: u64 = 60000, // 1 minute
    message: []const u8 = "Too many requests, please try again later.",
};

pub const RateLimiter = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: RateLimitConfig,
    requests: std.StringHashMap(RequestInfo),
    mutex: std.Io.Mutex,

    const RequestInfo = struct {
        count: u32,
        window_start: i64,
    };

    pub fn init(allocator: std.mem.Allocator, config: RateLimitConfig) RateLimiter {
        return initWithIo(compat.io(), allocator, config);
    }

    pub fn initWithIo(io_context: std.Io, allocator: std.mem.Allocator, config: RateLimitConfig) RateLimiter {
        return .{
            .allocator = allocator,
            .io = io_context,
            .config = config,
            .requests = std.StringHashMap(RequestInfo).init(allocator),
            .mutex = .init,
        };
    }

    pub fn deinit(self: *RateLimiter) void {
        self.requests.deinit();
    }

    pub fn middleware(self: *RateLimiter) http_router.Middleware {
        return .{
            .context = self,
            .handle_fn = struct {
                fn mw(raw_context: ?*anyopaque, req: *http_router.Request, res: *http_router.Response, next: http_router.Next) !void {
                    const limiter: *RateLimiter = @ptrCast(@alignCast(raw_context.?));
                    const ip = req.header("X-Forwarded-For") orelse req.header("X-Real-IP") orelse "unknown";

                    const is_limited = blk: {
                        limiter.mutex.lockUncancelable(limiter.io);
                        defer limiter.mutex.unlock(limiter.io);

                        const now = std.Io.Clock.real.now(limiter.io).toMilliseconds();
                        const entry = limiter.requests.getPtr(ip);

                        if (entry) |info| {
                            const window_elapsed = now - info.window_start;

                            if (window_elapsed > limiter.config.window_ms) {
                                info.count = 1;
                                info.window_start = now;
                            } else if (info.count >= limiter.config.max_requests) {
                                break :blk true;
                            } else {
                                info.count += 1;
                            }
                        } else {
                            try limiter.requests.put(ip, .{
                                .count = 1,
                                .window_start = now,
                            });
                        }
                        break :blk false;
                    };

                    if (is_limited) {
                        res.status_code = 429;
                        try res.send(limiter.config.message);
                        return;
                    }

                    try next.call();
                }
            }.mw,
        };
    }
};

/// Compression Middleware (gzip)
pub fn compression() http_router.Middleware {
    return .{
        .handle_fn = struct {
            fn middleware(_: ?*anyopaque, req: *http_router.Request, res: *http_router.Response, next: http_router.Next) !void {
                const accept_encoding = req.header("Accept-Encoding");

                if (accept_encoding != null and std.mem.indexOf(u8, accept_encoding.?, "gzip") != null) {
                    _ = try res.setHeader("Content-Encoding", "gzip");
                    // In production: compress response body
                }

                try next.call();
            }
        }.middleware,
    };
}

/// Security Headers Middleware
pub fn securityHeaders() http_router.Middleware {
    return .{
        .handle_fn = struct {
            fn middleware(_: ?*anyopaque, req: *http_router.Request, res: *http_router.Response, next: http_router.Next) !void {
                _ = req;

                // Prevent XSS attacks
                _ = try res.setHeader("X-Content-Type-Options", "nosniff");
                _ = try res.setHeader("X-Frame-Options", "DENY");
                _ = try res.setHeader("X-XSS-Protection", "1; mode=block");

                // HSTS (HTTP Strict Transport Security)
                _ = try res.setHeader("Strict-Transport-Security", "max-age=31536000; includeSubDomains");

                // Content Security Policy
                _ = try res.setHeader("Content-Security-Policy", "default-src 'self'");

                try next.call();
            }
        }.middleware,
    };
}

/// Request ID Middleware
pub fn requestId() http_router.Middleware {
    return .{
        .handle_fn = struct {
            fn middleware(_: ?*anyopaque, req: *http_router.Request, res: *http_router.Response, next: http_router.Next) !void {
                // Generate UUID for request tracking
                var buf: [36]u8 = undefined;
                const id = try std.fmt.bufPrint(&buf, "{s}-{d}", .{ "req", compat.timestamp(compat.io()) });

                try req.setHeaderCopy("X-Request-ID", id);
                _ = try res.setHeaderCopy("X-Request-ID", id);

                try next.call();
            }
        }.middleware,
    };
}

/// Timeout Middleware
pub fn timeout(comptime duration_ms: u64) http_router.Middleware {
    return .{
        .handle_fn = struct {
            fn middleware(_: ?*anyopaque, req: *http_router.Request, res: *http_router.Response, next: http_router.Next) !void {
                _ = req;
                _ = res;
                _ = duration_ms;

                // In production: implement timeout using async/await
                // For now, just call next
                try next.call();

                // If timeout exceeded:
                // res.status_code = 408;
                // try res.send("Request Timeout");
            }
        }.middleware,
    };
}

/// ETag Middleware for caching
pub fn etag() http_router.Middleware {
    return .{
        .handle_fn = struct {
            fn middleware(_: ?*anyopaque, req: *http_router.Request, res: *http_router.Response, next: http_router.Next) !void {
                try next.call();

                // Generate ETag from response body
                if (res.body_content.items.len > 0) {
                    const hash = std.hash.Wyhash.hash(0, res.body_content.items);
                    var etag_buf: [24]u8 = undefined;
                    const etag_value = try std.fmt.bufPrint(&etag_buf, "\"{d}\"", .{hash});

                    _ = try res.setHeaderCopy("ETag", etag_value);

                    // Check If-None-Match header
                    const if_none_match = req.header("If-None-Match");
                    if (if_none_match != null and std.mem.eql(u8, if_none_match.?, etag_value)) {
                        res.status_code = 304; // Not Modified
                        res.body_content.clearRetainingCapacity();
                    }
                }
            }
        }.middleware,
    };
}

/// Error Handler Middleware
pub fn errorHandler() http_router.Middleware {
    return .{ .handle_fn = struct {
        fn middleware(_: ?*anyopaque, req: *http_router.Request, res: *http_router.Response, next: http_router.Next) !void {
            next.call() catch |err| {
                std.log.err("Error handling request {s} {s}: {}", .{
                    req.method.toString(),
                    req.path,
                    err,
                });

                res.status_code = 500;
                try res.json("{\"error\": \"Internal Server Error\"}");
            };
        }
    }.middleware };
}

test "middleware constructors expose the complete surface" {
    _ = cors(.{});
    _ = logger(.minimal);
    _ = jsonBodyParser();
    _ = compression();
    _ = securityHeaders();
    _ = requestId();
    _ = timeout(1000);
    _ = etag();
    _ = errorHandler();

    var limiter = RateLimiter.initWithIo(std.testing.io, std.testing.allocator, .{});
    defer limiter.deinit();
    _ = limiter.middleware();
}

test {
    std.testing.refAllDecls(@This());
}
