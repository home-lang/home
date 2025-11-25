const Basics = @import("basics");
const std = @import("std"); // Used for network/time functionality
const http_router = @import("http_router.zig");

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

pub fn cors(options: CorsOptions) http_router.Middleware {
    return struct {
        fn middleware(req: *http_router.Request, res: *http_router.Response, next: *const fn () anyerror!void) !void {
            _ = req;
            _ = try res.setHeader("Access-Control-Allow-Origin", options.allow_origin);
            _ = try res.setHeader("Access-Control-Allow-Methods", options.allow_methods);
            _ = try res.setHeader("Access-Control-Allow-Headers", options.allow_headers);

            if (options.allow_credentials) {
                _ = try res.setHeader("Access-Control-Allow-Credentials", "true");
            }

            const max_age_str = try std.fmt.allocPrint(res.allocator, "{d}", .{options.max_age});
            defer res.allocator.free(max_age_str);
            _ = try res.setHeader("Access-Control-Max-Age", max_age_str);

            try next();
        }
    }.middleware;
}

/// Logger Middleware with configurable format
pub const LogFormat = enum {
    minimal,
    standard,
    verbose,
};

pub fn logger(format: LogFormat) http_router.Middleware {
    return struct {
        fn middleware(req: *http_router.Request, res: *http_router.Response, next: *const fn () anyerror!void) !void {
            const start = std.time.nanoTimestamp();

            try next();

            const end = std.time.nanoTimestamp();
            const duration_ms = @divTrunc(end - start, std.time.ns_per_ms);

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
                    const timestamp = std.time.timestamp();
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
    }.middleware;
}

/// Body Parser Middleware for JSON
pub fn jsonBodyParser() http_router.Middleware {
    return struct {
        fn middleware(req: *http_router.Request, res: *http_router.Response, next: *const fn () anyerror!void) !void {
            _ = res;
            const content_type = req.header("Content-Type");

            if (content_type != null and std.mem.indexOf(u8, content_type.?, "application/json") != null) {
                // Body is already in req.body_data
                // In production, this would parse and validate JSON
            }

            try next();
        }
    }.middleware;
}

/// Rate Limiter Middleware
pub const RateLimitConfig = struct {
    max_requests: u32 = 100,
    window_ms: u64 = 60000, // 1 minute
    message: []const u8 = "Too many requests, please try again later.",
};

pub const RateLimiter = struct {
    allocator: std.mem.Allocator,
    config: RateLimitConfig,
    requests: std.StringHashMap(RequestInfo),
    mutex: std.Thread.Mutex,

    const RequestInfo = struct {
        count: u32,
        window_start: i64,
    };

    pub fn init(allocator: std.mem.Allocator, config: RateLimitConfig) RateLimiter {
        return .{
            .allocator = allocator,
            .config = config,
            .requests = std.StringHashMap(RequestInfo).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *RateLimiter) void {
        self.requests.deinit();
    }

    pub fn middleware(self: *RateLimiter) http_router.Middleware {
        return struct {
            fn mw(req: *http_router.Request, res: *http_router.Response, next: *const fn () anyerror!void) !void {
                const ip = req.header("X-Forwarded-For") orelse req.header("X-Real-IP") orelse "unknown";

                const limiter = @fieldParentPtr(RateLimiter, "middleware", @This());
                limiter.mutex.lock();
                defer limiter.mutex.unlock();

                const now = std.time.milliTimestamp();
                const entry = limiter.requests.getPtr(ip);

                if (entry) |info| {
                    const window_elapsed = now - info.window_start;

                    if (window_elapsed > limiter.config.window_ms) {
                        // Reset window
                        info.count = 1;
                        info.window_start = now;
                    } else if (info.count >= limiter.config.max_requests) {
                        // Rate limit exceeded
                        res.status_code = 429;
                        try res.send(limiter.config.message);
                        return;
                    } else {
                        info.count += 1;
                    }
                } else {
                    try limiter.requests.put(ip, .{
                        .count = 1,
                        .window_start = now,
                    });
                }

                try next();
            }
        }.mw;
    }
};

/// Compression Middleware (gzip)
pub fn compression() http_router.Middleware {
    return struct {
        fn middleware(req: *http_router.Request, res: *http_router.Response, next: *const fn () anyerror!void) !void {
            const accept_encoding = req.header("Accept-Encoding");

            if (accept_encoding != null and std.mem.indexOf(u8, accept_encoding.?, "gzip") != null) {
                _ = try res.setHeader("Content-Encoding", "gzip");
                // In production: compress response body
            }

            try next();
        }
    }.middleware;
}

/// Security Headers Middleware
pub fn securityHeaders() http_router.Middleware {
    return struct {
        fn middleware(req: *http_router.Request, res: *http_router.Response, next: *const fn () anyerror!void) !void {
            _ = req;

            // Prevent XSS attacks
            _ = try res.setHeader("X-Content-Type-Options", "nosniff");
            _ = try res.setHeader("X-Frame-Options", "DENY");
            _ = try res.setHeader("X-XSS-Protection", "1; mode=block");

            // HSTS (HTTP Strict Transport Security)
            _ = try res.setHeader("Strict-Transport-Security", "max-age=31536000; includeSubDomains");

            // Content Security Policy
            _ = try res.setHeader("Content-Security-Policy", "default-src 'self'");

            try next();
        }
    }.middleware;
}

/// Request ID Middleware
pub fn requestId() http_router.Middleware {
    return struct {
        fn middleware(req: *http_router.Request, res: *http_router.Response, next: *const fn () anyerror!void) !void {
            // Generate UUID for request tracking
            var buf: [36]u8 = undefined;
            const id = try std.fmt.bufPrint(&buf, "{s}-{d}", .{ "req", std.time.timestamp() });

            try req.headers.put("X-Request-ID", id);
            _ = try res.setHeader("X-Request-ID", id);

            try next();
        }
    }.middleware;
}

/// Timeout Middleware
pub fn timeout(duration_ms: u64) http_router.Middleware {
    return struct {
        fn middleware(req: *http_router.Request, res: *http_router.Response, next: *const fn () anyerror!void) !void {
            _ = req;
            _ = duration_ms;

            // In production: implement timeout using async/await
            // For now, just call next
            try next();

            // If timeout exceeded:
            // res.status_code = 408;
            // try res.send("Request Timeout");
        }
    }.middleware;
}

/// ETag Middleware for caching
pub fn etag() http_router.Middleware {
    return struct {
        fn middleware(req: *http_router.Request, res: *http_router.Response, next: *const fn () anyerror!void) !void {
            try next();

            // Generate ETag from response body
            if (res.body_content.items.len > 0) {
                const hash = std.hash.Wyhash.hash(0, res.body_content.items);
                const etag_value = try std.fmt.allocPrint(res.allocator, "\"{d}\"", .{hash});
                defer res.allocator.free(etag_value);

                _ = try res.setHeader("ETag", etag_value);

                // Check If-None-Match header
                const if_none_match = req.header("If-None-Match");
                if (if_none_match != null and std.mem.eql(u8, if_none_match.?, etag_value)) {
                    res.status_code = 304; // Not Modified
                    res.body_content.clearRetainingCapacity();
                }
            }
        }
    }.middleware;
}

/// Error Handler Middleware
pub fn errorHandler() http_router.Middleware {
    return struct {
        fn middleware(req: *http_router.Request, res: *http_router.Response, next: *const fn () anyerror!void) !void {
            next() catch |err| {
                std.debug.print("Error handling request {s} {s}: {}\n", .{
                    req.method.toString(),
                    req.path,
                    err,
                });

                res.status_code = 500;
                try res.json("{\"error\": \"Internal Server Error\"}");
            };
        }
    }.middleware;
}
