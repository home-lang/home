const std = @import("std");
const zyte = @import("zyte");
const http_router = @import("http_router");

/// Example 1: Basic Zyte window
pub fn basicWindowExample(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Example 1: Basic Zyte Window ===\n\n", .{});

    var config = zyte.ZyteConfig.init(allocator);
    _ = config.setTitle("My First Home + Zyte App");
    _ = config.setSize(1024, 768);
    _ = config.setHtml(
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\    <title>Home + Zyte</title>
        \\    <style>
        \\        body {
        \\            font-family: system-ui;
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
        \\        }
        \\        h1 {
        \\            font-size: 3em;
        \\            margin: 0;
        \\        }
        \\    </style>
        \\</head>
        \\<body>
        \\    <div class="container">
        \\        <h1>Hello from Home + Zyte! 🚀</h1>
        \\        <p>Cross-platform desktop app built with web technologies</p>
        \\    </div>
        \\</body>
        \\</html>
    );

    var app = try zyte.ZyteApp.init(allocator, config);
    defer app.deinit();

    try app.run();
}

/// Example 2: Frameless transparent window
pub fn framelessWindowExample(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Example 2: Frameless Transparent Window ===\n\n", .{});

    var config = zyte.ZyteConfig.init(allocator);
    _ = config.setTitle("Frameless App");
    _ = config.setSize(400, 300);
    _ = config.setFrameless(true);
    _ = config.setTransparent(true);
    _ = config.setHtml(
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\    <style>
        \\        body {
        \\            margin: 0;
        \\            background: rgba(30, 30, 30, 0.95);
        \\            color: white;
        \\            font-family: system-ui;
        \\            padding: 20px;
        \\            border-radius: 10px;
        \\        }
        \\        .drag-region {
        \\            -webkit-app-region: drag;
        \\            padding: 10px;
        \\            background: rgba(255, 255, 255, 0.1);
        \\            border-radius: 5px;
        \\        }
        \\    </style>
        \\</head>
        \\<body>
        \\    <div class="drag-region">
        \\        <h2>Frameless Window</h2>
        \\    </div>
        \\    <p>This window has no frame and is semi-transparent!</p>
        \\</body>
        \\</html>
    );

    var app = try zyte.ZyteApp.init(allocator, config);
    defer app.deinit();

    try app.run();
}

/// Example 3: Home HTTP server + Zyte frontend
pub fn httpServerWithZyteExample(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Example 3: HTTP Server + Zyte Frontend ===\n\n", .{});

    // Setup HTTP server (would run in background thread)
    var server = http_router.HttpServer.init(allocator);
    defer server.deinit();

    _ = server.setPort(8080);

    _ = try server.get("/", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            _ = req;
            const html =
                \\<!DOCTYPE html>
                \\<html>
                \\<head>
                \\    <title>Home + Zyte App</title>
                \\    <style>
                \\        body { font-family: system-ui; padding: 40px; }
                \\        .button { padding: 10px 20px; background: #667eea; color: white; border: none; border-radius: 5px; cursor: pointer; }
                \\    </style>
                \\    <script>
                \\        async function fetchData() {
                \\            const response = await fetch('/api/data');
                \\            const data = await response.json();
                \\            document.getElementById('result').textContent = JSON.stringify(data, null, 2);
                \\        }
                \\    </script>
                \\</head>
                \\<body>
                \\    <h1>Home Backend + Zyte Frontend</h1>
                \\    <button class="button" onclick="fetchData()">Fetch Data from Backend</button>
                \\    <pre id="result"></pre>
                \\</body>
                \\</html>
            ;
            try res.html(html);
        }
    }.handler);

    _ = try server.get("/api/data", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            _ = req;
            try res.json("{\"message\":\"Hello from Home backend!\",\"timestamp\":1234567890}");
        }
    }.handler);

    std.debug.print("✅ HTTP server configured on port 8080\n", .{});
    std.debug.print("✅ Zyte window will connect to http://localhost:8080\n", .{});

    // Create Zyte window pointing to the server
    var config = zyte.ZyteConfig.init(allocator);
    _ = config.setTitle("Home + Zyte Full Stack");
    _ = config.setSize(1200, 800);
    _ = config.setUrl("http://localhost:8080");
    _ = config.setDevTools(true);

    var app = try zyte.ZyteApp.init(allocator, config);
    defer app.deinit();

    std.debug.print("\n", .{});
    try app.run();
}

/// Example 4: Using Zyte components
pub fn componentsExample(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Example 4: Zyte Components ===\n\n", .{});

    // Create UI components
    const button = zyte.Components.Button{
        .label = "Click Me",
        .onClick = null,
    };

    const input = zyte.Components.Input{
        .placeholder = "Enter your name",
        .value = "",
    };

    const button_html = try button.toHtml(allocator);
    defer allocator.free(button_html);

    const input_html = try input.toHtml(allocator);
    defer allocator.free(input_html);

    const container = zyte.Components.Container{
        .children = &[_][]const u8{ button_html, input_html },
    };

    const container_html = try container.toHtml(allocator);
    defer allocator.free(container_html);

    std.debug.print("✅ Generated component HTML:\n", .{});
    std.debug.print("{s}\n", .{container_html});
}

/// Example 5: System integration
pub fn systemIntegrationExample(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Example 5: System Integration ===\n\n", .{});

    // System tray
    var tray = zyte.SystemTray.init(allocator, "Home App");
    _ = tray.setIcon("/path/to/icon.png");
    try tray.show();

    // Notification
    const notification = zyte.Notification{
        .title = "Home App",
        .body = "Your task is complete!",
        .icon = null,
    };
    try notification.show();

    // Dialog
    try zyte.Dialog.alert("Welcome", "Welcome to Home + Zyte!");

    // File picker
    const file_path = try zyte.Dialog.openFile(allocator, &[_][]const u8{ ".txt", ".md" });
    if (file_path) |path| {
        defer allocator.free(path);
        std.debug.print("Selected file: {s}\n", .{path});
    }
}

/// Example 6: IPC communication
pub fn ipcExample(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Example 6: IPC Communication ===\n\n", .{});

    var config = zyte.ZyteConfig.init(allocator);
    _ = config.setTitle("IPC Example");
    _ = config.setHtml(
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\    <script>
        \\        // Listen for messages from native side
        \\        window.addEventListener('native-message', (event) => {
        \\            console.log('Received from native:', event.detail);
        \\            document.getElementById('messages').textContent += event.detail.data + '\n';
        \\        });
        \\
        \\        // Send message to native side
        \\        function sendToNative() {
        \\            window.postMessage({ event: 'web-message', data: 'Hello from web!' }, '*');
        \\        }
        \\    </script>
        \\</head>
        \\<body>
        \\    <h1>IPC Communication</h1>
        \\    <button onclick="sendToNative()">Send to Native</button>
        \\    <pre id="messages"></pre>
        \\</body>
        \\</html>
    );

    var app = try zyte.ZyteApp.init(allocator, config);
    defer app.deinit();

    // Setup IPC handlers
    try app.onMessage("web-message", struct {
        fn handler(data: []const u8) !void {
            std.debug.print("📨 Received from web: {s}\n", .{data});
        }
    }.handler);

    // Send message to web
    try app.sendMessage("native-message", "{\"data\":\"Hello from native!\"}");

    try app.run();
}

/// Example 7: Full-stack Todo App
pub fn todoAppExample(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Example 7: Full-Stack Todo App ===\n\n", .{});

    // Backend
    var server = http_router.HttpServer.init(allocator);
    defer server.deinit();

    _ = server.setPort(3000);

    _ = try server.get("/", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            _ = req;
            const html =
                \\<!DOCTYPE html>
                \\<html>
                \\<head>
                \\    <title>Home Todo App</title>
                \\    <style>
                \\        body { font-family: system-ui; max-width: 600px; margin: 50px auto; padding: 20px; }
                \\        .todo { padding: 10px; margin: 5px 0; background: #f0f0f0; border-radius: 5px; }
                \\        button { padding: 10px 20px; background: #667eea; color: white; border: none; border-radius: 5px; cursor: pointer; }
                \\        input { padding: 10px; width: 70%; border: 1px solid #ddd; border-radius: 5px; }
                \\    </style>
                \\    <script>
                \\        let todos = [];
                \\
                \\        async function loadTodos() {
                \\            const response = await fetch('/api/todos');
                \\            todos = await response.json();
                \\            renderTodos();
                \\        }
                \\
                \\        async function addTodo() {
                \\            const input = document.getElementById('newTodo');
                \\            const response = await fetch('/api/todos', {
                \\                method: 'POST',
                \\                headers: { 'Content-Type': 'application/json' },
                \\                body: JSON.stringify({ text: input.value })
                \\            });
                \\            input.value = '';
                \\            loadTodos();
                \\        }
                \\
                \\        function renderTodos() {
                \\            const list = document.getElementById('todoList');
                \\            list.innerHTML = todos.map(todo => `<div class="todo">${todo.text}</div>`).join('');
                \\        }
                \\
                \\        window.onload = loadTodos;
                \\    </script>
                \\</head>
                \\<body>
                \\    <h1>📝 Home Todo App</h1>
                \\    <div>
                \\        <input type="text" id="newTodo" placeholder="Enter a new todo...">
                \\        <button onclick="addTodo()">Add</button>
                \\    </div>
                \\    <div id="todoList"></div>
                \\</body>
                \\</html>
            ;
            try res.html(html);
        }
    }.handler);

    _ = try server.get("/api/todos", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            _ = req;
            try res.json("[{\"id\":1,\"text\":\"Learn Home\"},{\"id\":2,\"text\":\"Build awesome apps\"}]");
        }
    }.handler);

    _ = try server.post("/api/todos", struct {
        fn handler(req: *http_router.Request, res: *http_router.Response) !void {
            std.debug.print("New todo: {s}\n", .{req.body()});
            try res.status(201).json("{\"message\":\"Todo created\"}");
        }
    }.handler);

    std.debug.print("✅ Todo app backend ready on port 3000\n", .{});

    // Frontend
    try zyte.quickStart(allocator, "Home Todo App", 3000);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n╔════════════════════════════════════════╗\n", .{});
    std.debug.print("║   Home + Zyte Integration Examples     ║\n", .{});
    std.debug.print("╚════════════════════════════════════════╝\n", .{});

    try basicWindowExample(allocator);
    try framelessWindowExample(allocator);
    try httpServerWithZyteExample(allocator);
    try componentsExample(allocator);
    try systemIntegrationExample(allocator);
    try ipcExample(allocator);
    try todoAppExample(allocator);

    std.debug.print("\n✅ All Zyte examples completed!\n", .{});
    std.debug.print("\nTo use Zyte in production:\n", .{});
    std.debug.print("1. Link against Zyte library: ~/Code/zyte\n", .{});
    std.debug.print("2. @cImport Zyte headers\n", .{});
    std.debug.print("3. Call Zyte's init() and window creation functions\n", .{});
    std.debug.print("4. Build cross-platform: macOS, Linux, Windows, iOS, Android\n", .{});
    std.debug.print("\n", .{});
}
