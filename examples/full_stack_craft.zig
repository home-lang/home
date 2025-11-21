const std = @import("std");
const http_router = @import("http_router");
const craft = @import("craft");

/// Full-stack example combining HTTP server with Craft UI
/// This demonstrates the integration of Home's HTTP router with native desktop windows

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("╔════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║     Home Full-Stack Example                    ║\n", .{});
    std.debug.print("║     HTTP Server + Craft Desktop UI             ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    // Create Craft window configuration
    var config = craft.craftConfig.init(allocator);
    _ = config.setTitle("Home Full-Stack App");
    _ = config.setSize(1280, 720);
    _ = config.setHtml(
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\    <title>Home Full-Stack</title>
        \\    <style>
        \\        body {
        \\            font-family: system-ui, -apple-system, sans-serif;
        \\            display: flex;
        \\            justify-content: center;
        \\            align-items: center;
        \\            height: 100vh;
        \\            margin: 0;
        \\            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
        \\            color: white;
        \\        }
        \\        .container {
        \\            text-align: center;
        \\            padding: 2rem;
        \\        }
        \\        h1 { font-size: 3rem; margin-bottom: 1rem; }
        \\        p { font-size: 1.2rem; opacity: 0.9; }
        \\    </style>
        \\</head>
        \\<body>
        \\    <div class="container">
        \\        <h1>Home Full-Stack</h1>
        \\        <p>HTTP Server + Native Desktop UI</p>
        \\        <p>Built with the Home programming language</p>
        \\    </div>
        \\</body>
        \\</html>
    );

    std.debug.print("Configuration created:\n", .{});
    std.debug.print("  Title: {s}\n", .{config.title});
    std.debug.print("  Size: {d}x{d}\n", .{ config.width, config.height });
    std.debug.print("\n", .{});

    // Build and display window info
    const window = try config.build();
    std.debug.print("Window created:\n", .{});
    std.debug.print("  Title: {s}\n", .{window.title});
    std.debug.print("  Dimensions: {d}x{d}\n", .{ window.width, window.height });
    std.debug.print("\n", .{});

    std.debug.print("Full-stack example completed successfully!\n", .{});
    std.debug.print("In a full implementation, this would:\n", .{});
    std.debug.print("  1. Start an HTTP server on localhost\n", .{});
    std.debug.print("  2. Open a native Craft window\n", .{});
    std.debug.print("  3. Load the web UI from the local server\n", .{});
    std.debug.print("  4. Enable IPC between web and native code\n", .{});
}
