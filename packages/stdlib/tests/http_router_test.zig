const std = @import("std");
const testing = std.testing;
const http_router = @import("http_router");

// ============================================================================
// Method Tests
// ============================================================================

test "Method: fromString converts valid strings" {
    try testing.expectEqual(http_router.Method.GET, http_router.Method.fromString("GET").?);
    try testing.expectEqual(http_router.Method.POST, http_router.Method.fromString("POST").?);
    try testing.expectEqual(http_router.Method.PUT, http_router.Method.fromString("PUT").?);
    try testing.expectEqual(http_router.Method.DELETE, http_router.Method.fromString("DELETE").?);
    try testing.expectEqual(http_router.Method.PATCH, http_router.Method.fromString("PATCH").?);
    try testing.expectEqual(http_router.Method.OPTIONS, http_router.Method.fromString("OPTIONS").?);
    try testing.expectEqual(http_router.Method.HEAD, http_router.Method.fromString("HEAD").?);
}

test "Method: fromString returns null for invalid strings" {
    try testing.expectEqual(@as(?http_router.Method, null), http_router.Method.fromString("INVALID"));
    try testing.expectEqual(@as(?http_router.Method, null), http_router.Method.fromString("get"));
    try testing.expectEqual(@as(?http_router.Method, null), http_router.Method.fromString(""));
}

test "Method: toString returns correct strings" {
    try testing.expectEqualStrings("GET", http_router.Method.GET.toString());
    try testing.expectEqualStrings("POST", http_router.Method.POST.toString());
    try testing.expectEqualStrings("PUT", http_router.Method.PUT.toString());
    try testing.expectEqualStrings("DELETE", http_router.Method.DELETE.toString());
    try testing.expectEqualStrings("PATCH", http_router.Method.PATCH.toString());
    try testing.expectEqualStrings("OPTIONS", http_router.Method.OPTIONS.toString());
    try testing.expectEqualStrings("HEAD", http_router.Method.HEAD.toString());
}

// ============================================================================
// Request Tests
// ============================================================================

test "Request: init creates valid request" {
    var req = http_router.Request.init(testing.allocator, .GET, "/test");
    defer req.deinit();

    try testing.expectEqual(http_router.Method.GET, req.method);
    try testing.expectEqualStrings("/test", req.path);
}

test "Request: param returns correct value" {
    var req = http_router.Request.init(testing.allocator, .GET, "/users/123");
    defer req.deinit();

    try req.params.put("id", "123");

    const id = req.param("id");
    try testing.expect(id != null);
    try testing.expectEqualStrings("123", id.?);
}

test "Request: param returns null for missing parameter" {
    var req = http_router.Request.init(testing.allocator, .GET, "/test");
    defer req.deinit();

    const missing = req.param("nonexistent");
    try testing.expectEqual(@as(?[]const u8, null), missing);
}

test "Request: query returns correct value" {
    var req = http_router.Request.init(testing.allocator, .GET, "/search?q=test");
    defer req.deinit();

    try req.query.put("q", "test");

    const q = req.queryParam("q");
    try testing.expect(q != null);
    try testing.expectEqualStrings("test", q.?);
}

test "Request: header returns correct value" {
    var req = http_router.Request.init(testing.allocator, .GET, "/test");
    defer req.deinit();

    try req.headers.put("Content-Type", "application/json");

    const ct = req.header("Content-Type");
    try testing.expect(ct != null);
    try testing.expectEqualStrings("application/json", ct.?);
}

test "Request: body returns correct data" {
    var req = http_router.Request.init(testing.allocator, .POST, "/api/data");
    defer req.deinit();

    req.body_data = "{\"test\":\"value\"}";

    try testing.expectEqualStrings("{\"test\":\"value\"}", req.body());
}

// ============================================================================
// Response Tests
// ============================================================================

test "Response: init creates valid response" {
    var res = http_router.Response.init(testing.allocator);
    defer res.deinit();

    try testing.expectEqual(@as(u16, 200), res.status_code);
}

test "Response: status sets status code" {
    var res = http_router.Response.init(testing.allocator);
    defer res.deinit();

    const result = res.status(404);
    try testing.expectEqual(@as(u16, 404), result.status_code);
}

test "Response: setHeader adds header" {
    var res = http_router.Response.init(testing.allocator);
    defer res.deinit();

    _ = try res.setHeader("Content-Type", "application/json");

    const ct = res.headers.get("Content-Type");
    try testing.expect(ct != null);
    try testing.expectEqualStrings("application/json", ct.?);
}

test "Response: send appends to body" {
    var res = http_router.Response.init(testing.allocator);
    defer res.deinit();

    try res.send("Hello, ");
    try res.send("World!");

    try testing.expectEqualStrings("Hello, World!", res.body_content.items);
}

test "Response: json sets content type and body" {
    var res = http_router.Response.init(testing.allocator);
    defer res.deinit();

    try res.json("{\"status\":\"ok\"}");

    const ct = res.headers.get("Content-Type");
    try testing.expect(ct != null);
    try testing.expectEqualStrings("application/json", ct.?);
    try testing.expectEqualStrings("{\"status\":\"ok\"}", res.body_content.items);
}

test "Response: html sets content type and body" {
    var res = http_router.Response.init(testing.allocator);
    defer res.deinit();

    try res.html("<h1>Hello</h1>");

    const ct = res.headers.get("Content-Type");
    try testing.expect(ct != null);
    try testing.expectEqualStrings("text/html; charset=utf-8", ct.?);
    try testing.expectEqualStrings("<h1>Hello</h1>", res.body_content.items);
}

test "Response: redirect sets status and location" {
    var res = http_router.Response.init(testing.allocator);
    defer res.deinit();

    try res.redirect("/home");

    try testing.expectEqual(@as(u16, 302), res.status_code);
    const location = res.headers.get("Location");
    try testing.expect(location != null);
    try testing.expectEqualStrings("/home", location.?);
}

test "Response: chaining works correctly" {
    var res = http_router.Response.init(testing.allocator);
    defer res.deinit();

    _ = try res.status(201).setHeader("X-Custom", "value");

    try testing.expectEqual(@as(u16, 201), res.status_code);
    const custom = res.headers.get("X-Custom");
    try testing.expect(custom != null);
    try testing.expectEqualStrings("value", custom.?);
}

// ============================================================================
// Router Tests
// ============================================================================

test "Router: init creates valid router" {
    var router = http_router.Router.init(testing.allocator);
    defer router.deinit();

    try testing.expectEqual(@as(usize, 0), router.routes.items.len);
    try testing.expectEqual(@as(usize, 0), router.middleware_stack.items.len);
}

test "Router: get adds GET route" {
    var router = http_router.Router.init(testing.allocator);
    defer router.deinit();

    try router.get("/test", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            _ = req;
            try res.send("test");
        }
    }.handler);

    try testing.expectEqual(@as(usize, 1), router.routes.items.len);
    try testing.expectEqual(http_router.Method.GET, router.routes.items[0].method);
    try testing.expectEqualStrings("/test", router.routes.items[0].pattern);
}

test "Router: post adds POST route" {
    var router = http_router.Router.init(testing.allocator);
    defer router.deinit();

    try router.post("/test", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            _ = req;
            try res.send("test");
        }
    }.handler);

    try testing.expectEqual(@as(usize, 1), router.routes.items.len);
    try testing.expectEqual(http_router.Method.POST, router.routes.items[0].method);
}

test "Router: put adds PUT route" {
    var router = http_router.Router.init(testing.allocator);
    defer router.deinit();

    try router.put("/test", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            _ = req;
            try res.send("test");
        }
    }.handler);

    try testing.expectEqual(@as(usize, 1), router.routes.items.len);
    try testing.expectEqual(http_router.Method.PUT, router.routes.items[0].method);
}

test "Router: delete adds DELETE route" {
    var router = http_router.Router.init(testing.allocator);
    defer router.deinit();

    try router.delete("/test", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            _ = req;
            try res.send("test");
        }
    }.handler);

    try testing.expectEqual(@as(usize, 1), router.routes.items.len);
    try testing.expectEqual(http_router.Method.DELETE, router.routes.items[0].method);
}

test "Router: patch adds PATCH route" {
    var router = http_router.Router.init(testing.allocator);
    defer router.deinit();

    try router.patch("/test", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            _ = req;
            try res.send("test");
        }
    }.handler);

    try testing.expectEqual(@as(usize, 1), router.routes.items.len);
    try testing.expectEqual(http_router.Method.PATCH, router.routes.items[0].method);
}

test "Router: multiple methods can be added to same path" {
    var router = http_router.Router.init(testing.allocator);
    defer router.deinit();

    try router.get("/test", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            _ = req;
            try res.send("test");
        }
    }.handler);

    try router.post("/test", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            _ = req;
            try res.send("test");
        }
    }.handler);

    // Should have 2 routes for same path with different methods
    try testing.expectEqual(@as(usize, 2), router.routes.items.len);
}

test "Router: use adds middleware" {
    var router = http_router.Router.init(testing.allocator);
    defer router.deinit();

    const middleware = struct {
        fn mw(req: *http_router.Request, res: *http_router.Response, next: *const fn () anyerror!void) !void {
            _ = req;
            _ = res;
            try next();
        }
    }.mw;

    try router.use(middleware);

    try testing.expectEqual(@as(usize, 1), router.middleware_stack.items.len);
}

test "Router: route parameters are extracted" {
    var router = http_router.Router.init(testing.allocator);
    defer router.deinit();

    try router.get("/users/:id", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            _ = req;
            _ = res;
        }
    }.handler);

    try testing.expectEqual(@as(usize, 1), router.routes.items.len);
    try testing.expectEqual(@as(usize, 1), router.routes.items[0].param_names.items.len);
    try testing.expectEqualStrings("id", router.routes.items[0].param_names.items[0]);
}

test "Router: multiple route parameters are extracted" {
    var router = http_router.Router.init(testing.allocator);
    defer router.deinit();

    try router.get("/users/:userId/posts/:postId", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            _ = req;
            _ = res;
        }
    }.handler);

    try testing.expectEqual(@as(usize, 1), router.routes.items.len);
    try testing.expectEqual(@as(usize, 2), router.routes.items[0].param_names.items.len);
    try testing.expectEqualStrings("userId", router.routes.items[0].param_names.items[0]);
    try testing.expectEqualStrings("postId", router.routes.items[0].param_names.items[1]);
}

// ============================================================================
// HttpServer Tests
// ============================================================================

test "HttpServer: init creates valid server" {
    var server = http_router.HttpServer.init(testing.allocator);
    defer server.deinit();

    try testing.expectEqual(@as(u16, 3000), server.port);
    try testing.expectEqualStrings("127.0.0.1", server.host);
}

test "HttpServer: setPort updates port" {
    var server = http_router.HttpServer.init(testing.allocator);
    defer server.deinit();

    _ = server.setPort(3000);
    try testing.expectEqual(@as(u16, 3000), server.port);
}

test "HttpServer: setHost updates host" {
    var server = http_router.HttpServer.init(testing.allocator);
    defer server.deinit();

    _ = server.setHost("0.0.0.0");
    try testing.expectEqualStrings("0.0.0.0", server.host);
}

test "HttpServer: method chaining works" {
    var server = http_router.HttpServer.init(testing.allocator);
    defer server.deinit();

    _ = server.setPort(3000).setHost("0.0.0.0");

    try testing.expectEqual(@as(u16, 3000), server.port);
    try testing.expectEqualStrings("0.0.0.0", server.host);
}

test "HttpServer: get adds route to internal router" {
    var server = http_router.HttpServer.init(testing.allocator);
    defer server.deinit();

    _ = try server.get("/test", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            _ = req;
            _ = res;
        }
    }.handler);

    try testing.expectEqual(@as(usize, 1), server.router.routes.items.len);
}

test "HttpServer: use adds middleware to internal router" {
    var server = http_router.HttpServer.init(testing.allocator);
    defer server.deinit();

    const middleware = struct {
        fn mw(req: *http_router.Request, res: *http_router.Response, next: *const fn () anyerror!void) !void {
            _ = req;
            _ = res;
            try next();
        }
    }.mw;

    _ = try server.use(middleware);

    try testing.expectEqual(@as(usize, 1), server.router.middleware_stack.items.len);
}

// ============================================================================
// RouteGroup Tests
// ============================================================================

test "RouteGroup: init creates valid group" {
    var router = http_router.Router.init(testing.allocator);
    defer router.deinit();

    var group = http_router.RouteGroup.init(testing.allocator, &router, "/api");
    defer group.deinit();

    try testing.expectEqualStrings("/api", group.prefix);
}

test "RouteGroup: get adds prefixed route" {
    var router = http_router.Router.init(testing.allocator);
    defer router.deinit();

    var group = http_router.RouteGroup.init(testing.allocator, &router, "/api");
    defer group.deinit();

    try group.get("/users", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            _ = req;
            _ = res;
        }
    }.handler);

    try testing.expectEqual(@as(usize, 1), router.routes.items.len);
    try testing.expectEqualStrings("/api/users", router.routes.items[0].pattern);
}

test "RouteGroup: use adds middleware to group" {
    var router = http_router.Router.init(testing.allocator);
    defer router.deinit();

    var group = http_router.RouteGroup.init(testing.allocator, &router, "/api");
    defer group.deinit();

    const middleware = struct {
        fn mw(req: *http_router.Request, res: *http_router.Response, next: *const fn () anyerror!void) !void {
            _ = req;
            _ = res;
            try next();
        }
    }.mw;

    _ = try group.use(middleware);

    try testing.expectEqual(@as(usize, 1), group.middleware.items.len);
}

// ============================================================================
// Middleware Tests
// ============================================================================

test "Middleware: cors creates valid middleware function" {
    const middleware = http_router.cors();
    // Middleware is a function pointer type, just verify it compiles
    try testing.expect(@TypeOf(middleware) == http_router.Middleware);
}

test "Middleware: logger creates valid middleware function" {
    const middleware = http_router.logger();
    try testing.expect(@TypeOf(middleware) == http_router.Middleware);
}

test "Middleware: bodyParser creates valid middleware function" {
    const middleware = http_router.bodyParser();
    try testing.expect(@TypeOf(middleware) == http_router.Middleware);
}

// ============================================================================
// Integration Tests
// ============================================================================

test "Integration: complete request handling flow" {
    var server = http_router.HttpServer.init(testing.allocator);
    defer server.deinit();

    // Add middleware
    _ = try server.use(http_router.cors());

    // Add route with handler
    _ = try server.get("/users/:id", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            const id = req.param("id");
            if (id) |user_id| {
                const json = try std.fmt.allocPrint(req.allocator, "{{\"id\":\"{s}\"}}", .{user_id});
                defer req.allocator.free(json);
                try res.json(json);
            }
        }
    }.handler);

    // Verify setup
    try testing.expectEqual(@as(usize, 1), server.router.routes.items.len);
    try testing.expectEqual(@as(usize, 1), server.router.middleware_stack.items.len);
}

test "Integration: multiple routes different methods" {
    var server = http_router.HttpServer.init(testing.allocator);
    defer server.deinit();

    _ = try server.get("/users", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            _ = req;
            try res.json("[]");
        }
    }.handler);

    _ = try server.post("/users", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            _ = req;
            _ = res.status(201);
        }
    }.handler);

    _ = try server.put("/users/:id", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            _ = req;
            _ = res;
        }
    }.handler);

    _ = try server.delete("/users/:id", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            _ = req;
            _ = res.status(204);
        }
    }.handler);

    try testing.expectEqual(@as(usize, 4), server.router.routes.items.len);
}

test "Integration: route groups with versioning" {
    var router = http_router.Router.init(testing.allocator);
    defer router.deinit();

    var api_v1 = http_router.RouteGroup.init(testing.allocator, &router, "/api/v1");
    defer api_v1.deinit();

    try api_v1.get("/users", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            _ = req;
            _ = res;
        }
    }.handler);

    var api_v2 = http_router.RouteGroup.init(testing.allocator, &router, "/api/v2");
    defer api_v2.deinit();

    try api_v2.get("/users", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            _ = req;
            _ = res;
        }
    }.handler);

    try testing.expectEqual(@as(usize, 2), router.routes.items.len);
    try testing.expectEqualStrings("/api/v1/users", router.routes.items[0].pattern);
    try testing.expectEqualStrings("/api/v2/users", router.routes.items[1].pattern);
}
