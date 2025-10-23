const std = @import("std");
const http_router = @import("http_router");
const zyte = @import("zyte");

/// Full-stack application with Home backend + Zyte native UI
///
/// This example demonstrates:
/// 1. HTTP server with Express-style routing
/// 2. Native desktop window using Zyte
/// 3. IPC bridge for native<->web communication
/// 4. Hot reload for development
/// 5. Cross-platform desktop app deployment

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n╔═══════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Home Full-Stack Example (HTTP + Zyte)    ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════╝\n\n", .{});

    // Configure HTTP server
    var server = http_router.HttpServer.init(allocator);
    defer server.deinit();

    _ = server.setPort(3000);

    // Add middleware
    _ = try server.use(http_router.cors());
    _ = try server.use(http_router.logger());

    // Homepage route
    _ = try server.get("/", homeHandler);

    // API routes
    _ = try server.get("/api/users", getUsersHandler);
    _ = try server.post("/api/users", createUserHandler);
    _ = try server.get("/api/status", statusHandler);

    std.debug.print("✅ HTTP routes configured\n", .{});
    std.debug.print("   GET  /\n", .{});
    std.debug.print("   GET  /api/users\n", .{});
    std.debug.print("   POST /api/users\n", .{});
    std.debug.print("   GET  /api/status\n\n", .{});

    // Configure Zyte window
    var config = zyte.ZyteConfig.init(allocator);
    _ = config.setTitle("Ion Full-Stack App");
    _ = config.setSize(1200, 800);
    _ = config.setDarkMode(true);
    _ = config.setHotReload(true);
    _ = config.setDevTools(true);

    std.debug.print("✅ Zyte window configured\n", .{});
    std.debug.print("   Title: {s}\n", .{config.title});
    std.debug.print("   Size: {d}x{d}\n", .{ config.width, config.height });
    std.debug.print("   Hot Reload: {}\n\n", .{config.enable_hot_reload});

    // Create Zyte server (HTTP + native window)
    var zyte_server = try zyte.ZyteServer.init(allocator, 3000, config);
    defer zyte_server.deinit();

    std.debug.print("🚀 Starting full-stack application...\n\n", .{});

    // In production, this would:
    // 1. Start HTTP server in background thread
    // 2. Open Zyte window loading localhost:3000
    // 3. Setup IPC bridge
    // 4. Enable hot reload for development
    // 5. Build native binary for distribution

    try zyte_server.start();
}

/// Home page handler
fn homeHandler(req: *http_router.Request, res: *http_router.Response) !void {
    _ = req;

    const html =
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\    <meta charset="UTF-8">
        \\    <meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\    <title>Ion Full-Stack App</title>
        \\    <style>
        \\        * { margin: 0; padding: 0; box-sizing: border-box; }
        \\        body {
        \\            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
        \\            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
        \\            min-height: 100vh;
        \\            padding: 40px;
        \\        }
        \\        .container {
        \\            max-width: 1200px;
        \\            margin: 0 auto;
        \\            background: white;
        \\            border-radius: 20px;
        \\            padding: 40px;
        \\            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
        \\        }
        \\        h1 {
        \\            font-size: 3em;
        \\            background: linear-gradient(135deg, #667eea, #764ba2);
        \\            -webkit-background-clip: text;
        \\            -webkit-text-fill-color: transparent;
        \\            margin-bottom: 20px;
        \\        }
        \\        .tech-stack {
        \\            display: grid;
        \\            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
        \\            gap: 20px;
        \\            margin: 30px 0;
        \\        }
        \\        .tech-card {
        \\            padding: 20px;
        \\            background: #f7f7f7;
        \\            border-radius: 10px;
        \\            border-left: 4px solid #667eea;
        \\        }
        \\        .tech-card h3 {
        \\            color: #333;
        \\            margin-bottom: 10px;
        \\        }
        \\        button {
        \\            padding: 15px 30px;
        \\            background: linear-gradient(135deg, #667eea, #764ba2);
        \\            color: white;
        \\            border: none;
        \\            border-radius: 10px;
        \\            font-size: 1em;
        \\            cursor: pointer;
        \\            margin: 10px 5px;
        \\            transition: transform 0.2s;
        \\        }
        \\        button:hover {
        \\            transform: translateY(-2px);
        \\        }
        \\        #output {
        \\            margin-top: 20px;
        \\            padding: 20px;
        \\            background: #f0f0f0;
        \\            border-radius: 10px;
        \\            min-height: 100px;
        \\            font-family: 'Courier New', monospace;
        \\        }
        \\    </style>
        \\</head>
        \\<body>
        \\    <div class="container">
        \\        <h1>🚀 Home Full-Stack Application</h1>
        \\        <p>A modern, safe, fast framework for building cross-platform desktop apps</p>
        \\
        \\        <div class="tech-stack">
        \\            <div class="tech-card">
        \\                <h3>⚡ Home Backend</h3>
        \\                <p>Memory-safe HTTP server with Express-style routing</p>
        \\            </div>
        \\            <div class="tech-card">
        \\                <h3>🎨 Zyte Native UI</h3>
        \\                <p>Cross-platform desktop with native webviews (Tauri competitor)</p>
        \\            </div>
        \\            <div class="tech-card">
        \\                <h3>🔥 Hot Reload</h3>
        \\                <p>Instant updates during development</p>
        \\            </div>
        \\            <div class="tech-card">
        \\                <h3>📦 Single Binary</h3>
        \\                <p>Compile to native executable (macOS, Linux, Windows)</p>
        \\            </div>
        \\        </div>
        \\
        \\        <h2>Try the API</h2>
        \\        <button onclick="fetchUsers()">Fetch Users</button>
        \\        <button onclick="createUser()">Create User</button>
        \\        <button onclick="getStatus()">Get Status</button>
        \\        <button onclick="sendNativeMessage()">Send to Native</button>
        \\
        \\        <div id="output"></div>
        \\    </div>
        \\
        \\    <script>
        \\        const output = document.getElementById('output');
        \\
        \\        async function fetchUsers() {
        \\            try {
        \\                const response = await fetch('/api/users');
        \\                const data = await response.json();
        \\                output.innerHTML = `<strong>Users:</strong><br>${JSON.stringify(data, null, 2)}`;
        \\            } catch (e) {
        \\                output.innerHTML = `<strong>Error:</strong> ${e.message}`;
        \\            }
        \\        }
        \\
        \\        async function createUser() {
        \\            try {
        \\                const response = await fetch('/api/users', {
        \\                    method: 'POST',
        \\                    headers: { 'Content-Type': 'application/json' },
        \\                    body: JSON.stringify({ name: 'New User', email: 'user@example.com' })
        \\                });
        \\                const data = await response.json();
        \\                output.innerHTML = `<strong>Created:</strong><br>${JSON.stringify(data, null, 2)}`;
        \\            } catch (e) {
        \\                output.innerHTML = `<strong>Error:</strong> ${e.message}`;
        \\            }
        \\        }
        \\
        \\        async function getStatus() {
        \\            try {
        \\                const response = await fetch('/api/status');
        \\                const data = await response.json();
        \\                output.innerHTML = `<strong>Status:</strong><br>${JSON.stringify(data, null, 2)}`;
        \\            } catch (e) {
        \\                output.innerHTML = `<strong>Error:</strong> ${e.message}`;
        \\            }
        \\        }
        \\
        \\        function sendNativeMessage() {
        \\            // IPC bridge to send message to native Home code
        \\            window.postMessage({ type: 'native-call', data: 'Hello from JavaScript!' }, '*');
        \\            output.innerHTML = '<strong>Sent message to native code via IPC bridge</strong>';
        \\        }
        \\
        \\        // Listen for messages from native
        \\        window.addEventListener('message', (event) => {
        \\            if (event.data.type === 'native-response') {
        \\                output.innerHTML += `<br><strong>Native says:</strong> ${event.data.message}`;
        \\            }
        \\        });
        \\    </script>
        \\</body>
        \\</html>
    ;

    try res.html(html);
}

/// Get users handler
fn getUsersHandler(req: *http_router.Request, res: *http_router.Response) !void {
    _ = req;
    try res.json(
        \\[
        \\  {"id": 1, "name": "Alice", "email": "alice@example.com"},
        \\  {"id": 2, "name": "Bob", "email": "bob@example.com"},
        \\  {"id": 3, "name": "Charlie", "email": "charlie@example.com"}
        \\]
    );
}

/// Create user handler
fn createUserHandler(req: *http_router.Request, res: *http_router.Response) !void {
    const body = req.body();
    std.debug.print("📝 Creating user: {s}\n", .{body});

    try res.status(201).json(
        \\{
        \\  "message": "User created successfully",
        \\  "id": 4
        \\}
    );
}

/// Status handler
fn statusHandler(req: *http_router.Request, res: *http_router.Response) !void {
    _ = req;
    const status = try std.fmt.allocPrint(res.allocator,
        \\{{
        \\  "status": "ok",
        \\  "server": "Ion HTTP Server",
        \\  "frontend": "Zyte Native",
        \\  "timestamp": {d},
        \\  "platform": "{s}"
        \\}}
    , .{ std.time.timestamp(), @tagName(@import("builtin").os.tag) });
    defer res.allocator.free(status);

    try res.json(status);
}
