const std = @import("std");
const http_router = @import("http_router");

/// Example 1: Basic Express-style routing
pub fn basicRoutingExample(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Example 1: Basic Routing ===\n\n", .{});

    var server = http_router.HttpServer.init(allocator);
    defer server.deinit();

    // Simple GET route
    _ = try server.get("/", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            _ = req;
            try res.html("<h1>Welcome to Ion!</h1>");
        }
    }.handler);

    // Route with parameter
    _ = try server.get("/users/:id", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            const id = req.param("id") orelse "unknown";
            const json = try std.fmt.allocPrint(req.allocator, "{{\"user_id\":\"{s}\"}}", .{id});
            defer req.allocator.free(json);
            try res.json(json);
        }
    }.handler);

    // POST route
    _ = try server.post("/users", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            _ = req;
            try res.status(201).json("{\"message\":\"User created\"}");
        }
    }.handler);

    std.debug.print("✅ Routes registered:\n", .{});
    std.debug.print("   GET  /\n", .{});
    std.debug.print("   GET  /users/:id\n", .{});
    std.debug.print("   POST /users\n", .{});
}

/// Example 2: REST API with CRUD operations
pub fn restApiExample(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Example 2: REST API ===\n\n", .{});

    var server = http_router.HttpServer.init(allocator);
    defer server.deinit();

    // List all users
    _ = try server.get("/api/users", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            _ = req;
            try res.json("[{\"id\":1,\"name\":\"Alice\"},{\"id\":2,\"name\":\"Bob\"}]");
        }
    }.handler);

    // Get single user
    _ = try server.get("/api/users/:id", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            const id = req.param("id") orelse "0";
            const json = try std.fmt.allocPrint(req.allocator, "{{\"id\":{s},\"name\":\"User {s}\"}}", .{ id, id });
            defer req.allocator.free(json);
            try res.json(json);
        }
    }.handler);

    // Create user
    _ = try server.post("/api/users", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            const body = req.body();
            const json = try std.fmt.allocPrint(req.allocator, "{{\"message\":\"User created\",\"data\":{s}}}", .{body});
            defer req.allocator.free(json);
            try res.status(201).json(json);
        }
    }.handler);

    // Update user
    _ = try server.put("/api/users/:id", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            const id = req.param("id") orelse "0";
            const json = try std.fmt.allocPrint(req.allocator, "{{\"message\":\"User {s} updated\"}}", .{id});
            defer req.allocator.free(json);
            try res.json(json);
        }
    }.handler);

    // Delete user
    _ = try server.delete("/api/users/:id", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            const id = req.param("id") orelse "0";
            const json = try std.fmt.allocPrint(req.allocator, "{{\"message\":\"User {s} deleted\"}}", .{id});
            defer req.allocator.free(json);
            try res.status(204).json(json);
        }
    }.handler);

    std.debug.print("✅ REST API routes:\n", .{});
    std.debug.print("   GET    /api/users       (List)\n", .{});
    std.debug.print("   GET    /api/users/:id   (Show)\n", .{});
    std.debug.print("   POST   /api/users       (Create)\n", .{});
    std.debug.print("   PUT    /api/users/:id   (Update)\n", .{});
    std.debug.print("   DELETE /api/users/:id   (Delete)\n", .{});
}

/// Example 3: Middleware usage
pub fn middlewareExample(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Example 3: Middleware ===\n\n", .{});

    var server = http_router.HttpServer.init(allocator);
    defer server.deinit();

    // Add CORS middleware
    _ = try server.use(http_router.cors());

    // Add logger middleware
    _ = try server.use(http_router.logger());

    // Add body parser
    _ = try server.use(http_router.bodyParser());

    _ = try server.get("/api/data", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            _ = req;
            try res.json("{\"message\":\"Data with middleware\"}");
        }
    }.handler);

    std.debug.print("✅ Middleware stack:\n", .{});
    std.debug.print("   1. CORS (allow all origins)\n", .{});
    std.debug.print("   2. Logger (request timing)\n", .{});
    std.debug.print("   3. Body Parser (JSON)\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("   GET /api/data\n", .{});
}

/// Example 4: Laravel-style route grouping
pub fn routeGroupExample(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Example 4: Route Groups ===\n\n", .{});

    var router = http_router.Router.init(allocator);
    defer router.deinit();

    // API v1 routes
    var api_v1 = http_router.RouteGroup.init(allocator, &router, "/api/v1");
    defer api_v1.deinit();

    try api_v1.get("/users", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            _ = req;
            try res.json("{\"version\":\"v1\",\"users\":[]}");
        }
    }.handler);

    try api_v1.get("/posts", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            _ = req;
            try res.json("{\"version\":\"v1\",\"posts\":[]}");
        }
    }.handler);

    // API v2 routes
    var api_v2 = http_router.RouteGroup.init(allocator, &router, "/api/v2");
    defer api_v2.deinit();

    try api_v2.get("/users", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            _ = req;
            try res.json("{\"version\":\"v2\",\"users\":[]}");
        }
    }.handler);

    std.debug.print("✅ Route groups:\n", .{});
    std.debug.print("   /api/v1/users\n", .{});
    std.debug.print("   /api/v1/posts\n", .{});
    std.debug.print("   /api/v2/users\n", .{});
}

/// Example 5: Full web application
pub fn fullWebAppExample(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Example 5: Full Web Application ===\n\n", .{});

    var server = http_router.HttpServer.init(allocator);
    defer server.deinit();

    // Configure server
    _ = server.setPort(3000).setHost("0.0.0.0");

    // Middleware
    _ = try server.use(http_router.cors());
    _ = try server.use(http_router.logger());
    _ = try server.use(http_router.bodyParser());

    // Homepage
    _ = try server.get("/", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            _ = req;
            const html =
                \\<!DOCTYPE html>
                \\<html>
                \\<head>
                \\    <title>Ion Web App</title>
                \\    <style>
                \\        body { font-family: system-ui; max-width: 800px; margin: 50px auto; padding: 20px; }
                \\        h1 { color: #333; }
                \\    </style>
                \\</head>
                \\<body>
                \\    <h1>Welcome to Home + Zyte!</h1>
                \\    <p>A modern web framework built with safety and speed.</p>
                \\    <ul>
                \\        <li><a href="/api/users">View Users API</a></li>
                \\        <li><a href="/about">About Page</a></li>
                \\    </ul>
                \\</body>
                \\</html>
            ;
            try res.html(html);
        }
    }.handler);

    // About page
    _ = try server.get("/about", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            _ = req;
            try res.html("<h1>About</h1><p>Built with Home programming language</p>");
        }
    }.handler);

    // API endpoints
    _ = try server.get("/api/users", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            _ = req;
            try res.json("[{\"id\":1,\"name\":\"Alice\",\"email\":\"alice@example.com\"}]");
        }
    }.handler);

    _ = try server.post("/api/users", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            std.debug.print("Creating user with body: {s}\n", .{req.body()});
            try res.status(201).json("{\"message\":\"User created successfully\"}");
        }
    }.handler);

    // 404 handler
    _ = try server.get("*", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            const html = try std.fmt.allocPrint(req.allocator,
                \\<!DOCTYPE html>
                \\<html>
                \\<head><title>404 Not Found</title></head>
                \\<body>
                \\    <h1>404 - Page Not Found</h1>
                \\    <p>The page {s} was not found.</p>
                \\    <a href="/">Go Home</a>
                \\</body>
                \\</html>
            , .{req.path});
            defer req.allocator.free(html);

            try res.status(404).html(html);
        }
    }.handler);

    std.debug.print("✅ Full web application configured\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Routes:\n", .{});
    std.debug.print("   GET  /              (Homepage)\n", .{});
    std.debug.print("   GET  /about         (About page)\n", .{});
    std.debug.print("   GET  /api/users     (List users)\n", .{});
    std.debug.print("   POST /api/users     (Create user)\n", .{});
    std.debug.print("   GET  *              (404 handler)\n", .{});

    // try server.listen();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n╔════════════════════════════════════════╗\n", .{});
    std.debug.print("║   Home HTTP Router Examples            ║\n", .{});
    std.debug.print("╚════════════════════════════════════════╝\n", .{});

    try basicRoutingExample(allocator);
    try restApiExample(allocator);
    try middlewareExample(allocator);
    try routeGroupExample(allocator);
    try fullWebAppExample(allocator);

    std.debug.print("\n✅ All examples completed successfully!\n", .{});
    std.debug.print("\nNext steps:\n", .{});
    std.debug.print("1. Integrate with actual TCP server\n", .{});
    std.debug.print("2. Add database connectivity\n", .{});
    std.debug.print("3. Build a real web application\n", .{});
    std.debug.print("\n", .{});
}
