const std = @import("std");
const http = @import("../src/http.zig");

/// Example HTTP server demonstrating Laravel-inspired API
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create server
    var server = try http.Server.init(allocator);
    defer server.deinit();

    // Add global middleware (Laravel-style)
    try server.use("logger", http.middleware.logger);
    try server.use("cors", http.middleware.cors);

    // Define routes
    try server.get("/", indexHandler);
    try server.get("/users/:id", getUserHandler);
    try server.post("/users", createUserHandler);
    try server.get("/api/data", apiDataHandler);
    try server.get("/protected", protectedHandler);

    // Start server
    std.debug.print("Starting server on http://127.0.0.1:3000\n", .{});
    std.debug.print("Try:\n", .{});
    std.debug.print("  curl http://127.0.0.1:3000/\n", .{});
    std.debug.print("  curl http://127.0.0.1:3000/users/123\n", .{});
    std.debug.print("  curl http://127.0.0.1:3000/api/data\n", .{});

    try server.listen(3000);
}

fn indexHandler(req: *http.Request, res: *http.Response) !void {
    _ = req;
    try res.html("<h1>Welcome to Home HTTP Framework</h1><p>A Laravel-inspired HTTP framework for Zig</p>");
}

fn getUserHandler(req: *http.Request, res: *http.Response) !void {
    const user_id = req.param("id") orelse "unknown";

    const User = struct {
        id: []const u8,
        name: []const u8,
    };

    const user = User{
        .id = user_id,
        .name = "John Doe",
    };

    try res.json(user);
}

fn createUserHandler(req: *http.Request, res: *http.Response) !void {
    _ = req;
    _ = res.setStatus(.Created);
    try res.send("User created");
}

fn apiDataHandler(req: *http.Request, res: *http.Response) !void {
    _ = req;

    const Data = struct {
        message: []const u8,
        timestamp: i64,
    };

    const data = Data{
        .message = "Hello from API",
        .timestamp = std.time.timestamp(),
    };

    try res.json(data);
}

fn protectedHandler(req: *http.Request, res: *http.Response) !void {
    // Check authorization
    if (req.header("Authorization")) |token| {
        const Response = struct {
            message: []const u8,
            token: []const u8,
        };

        const response = Response{
            .message = "Access granted",
            .token = token,
        };

        try res.json(response);
    } else {
        _ = res.setStatus(.Unauthorized);
        try res.send("Unauthorized - Please provide Authorization header");
    }
}
