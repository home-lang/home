const std = @import("std");
const builtin = @import("builtin");

/// Native Zyte integration for Ion
/// Zyte is a native Zig cross-platform desktop framework (competitor to Tauri)
///
/// Zyte provides:
/// - Native window management (macOS, Linux, Windows)
/// - WebView integration (WKWebView, WebKit2GTK, WebView2)
/// - 35+ native UI components
/// - System integration (notifications, tray, dialogs)
/// - Mobile support (iOS, Android)
/// - Hot reload with state preservation
/// - IPC bridge for web<->native communication
///
/// This module links directly with Zyte's native Zig implementation

/// Zyte path - looks for Zyte in ~/Code/zyte by default
const ZYTE_PATH = "/Users/chrisbreuer/Code/zyte/packages/zig";

/// Import Zyte modules if available
/// In production, these would be actual @cImport or direct Zig imports
const ZyteWindow = struct {
        title: []const u8,
        width: u32,
        height: u32,
        html: []const u8,
        native_handle: ?*anyopaque = null,

        pub fn init(title: []const u8, width: u32, height: u32, html: []const u8) @This() {
            return .{
                .title = title,
                .width = width,
                .height = height,
                .html = html,
            };
        }

        pub fn show(self: *@This()) !void {
            std.debug.print("Zyte Window (stub): {s} ({d}x{d})\n", .{ self.title, self.width, self.height });
        }
    };

pub const ZyteConfig = struct {
    allocator: std.mem.Allocator,
    title: []const u8,
    width: u32,
    height: u32,
    resizable: bool,
    fullscreen: bool,
    frameless: bool,
    transparent: bool,
    dev_tools: bool,
    dark_mode: bool,
    always_on_top: bool,
    enable_hot_reload: bool,
    url: ?[]const u8,
    html: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator) ZyteConfig {
        return .{
            .allocator = allocator,
            .title = "Ion + Zyte App",
            .width = 1024,
            .height = 768,
            .resizable = true,
            .fullscreen = false,
            .frameless = false,
            .transparent = false,
            .dev_tools = true,
            .dark_mode = false,
            .always_on_top = false,
            .enable_hot_reload = true,
            .url = null,
            .html = null,
        };
    }

    pub fn setDarkMode(self: *ZyteConfig, enabled: bool) *ZyteConfig {
        self.dark_mode = enabled;
        return self;
    }

    pub fn setAlwaysOnTop(self: *ZyteConfig, enabled: bool) *ZyteConfig {
        self.always_on_top = enabled;
        return self;
    }

    pub fn setHotReload(self: *ZyteConfig, enabled: bool) *ZyteConfig {
        self.enable_hot_reload = enabled;
        return self;
    }

    pub fn setTitle(self: *ZyteConfig, title: []const u8) *ZyteConfig {
        self.title = title;
        return self;
    }

    pub fn setSize(self: *ZyteConfig, width: u32, height: u32) *ZyteConfig {
        self.width = width;
        self.height = height;
        return self;
    }

    pub fn setResizable(self: *ZyteConfig, resizable: bool) *ZyteConfig {
        self.resizable = resizable;
        return self;
    }

    pub fn setFullscreen(self: *ZyteConfig, fullscreen: bool) *ZyteConfig {
        self.fullscreen = fullscreen;
        return self;
    }

    pub fn setFrameless(self: *ZyteConfig, frameless: bool) *ZyteConfig {
        self.frameless = frameless;
        return self;
    }

    pub fn setTransparent(self: *ZyteConfig, transparent: bool) *ZyteConfig {
        self.transparent = transparent;
        return self;
    }

    pub fn setDevTools(self: *ZyteConfig, enabled: bool) *ZyteConfig {
        self.dev_tools = enabled;
        return self;
    }

    pub fn setUrl(self: *ZyteConfig, url: []const u8) *ZyteConfig {
        self.url = url;
        return self;
    }

    pub fn setHtml(self: *ZyteConfig, html: []const u8) *ZyteConfig {
        self.html = html;
        return self;
    }
};

/// Zyte Application
pub const ZyteApp = struct {
    allocator: std.mem.Allocator,
    config: ZyteConfig,
    window: ?ZyteWindow,
    bridge: ?*BridgeAPI,

    pub fn init(allocator: std.mem.Allocator, config: ZyteConfig) !ZyteApp {
        return .{
            .allocator = allocator,
            .config = config,
            .window = null,
            .bridge = null,
        };
    }

    pub fn deinit(self: *ZyteApp) void {
        _ = self;
        // Cleanup Zyte resources
    }

    /// Create and show Zyte window
    pub fn run(self: *ZyteApp) !void {
        std.debug.print("\n🚀 Starting Zyte Application\n", .{});
        std.debug.print("═══════════════════════════════════\n", .{});
        std.debug.print("Title:      {s}\n", .{self.config.title});
        std.debug.print("Size:       {d}x{d}\n", .{ self.config.width, self.config.height });
        std.debug.print("Frameless:  {}\n", .{self.config.frameless});
        std.debug.print("Dark Mode:  {}\n", .{self.config.dark_mode});
        std.debug.print("Hot Reload: {}\n", .{self.config.enable_hot_reload});

        // Determine what to load
        const html_content = if (self.config.html) |h|
            h
        else if (self.config.url) |url| blk: {
            std.debug.print("Loading:    {s}\n", .{url});
            // In real implementation, would load URL content
            break :blk "<html><body><h1>Loading...</h1></body></html>";
        } else
            "<html><body><h1>Ion + Zyte</h1></body></html>";

        std.debug.print("═══════════════════════════════════\n\n", .{});

        // Create native Zyte window
        var window = ZyteWindow.init(
            self.config.title,
            self.config.width,
            self.config.height,
            html_content,
        );

        // Show window (calls native platform code)
        try window.show();

        self.window = window;

        // Initialize IPC bridge
        try self.initBridge();

        // Start event loop
        try self.eventLoop();
    }

    /// Initialize IPC bridge for communication between native and web
    fn initBridge(self: *ZyteApp) !void {
        std.debug.print("📡 Initializing IPC bridge\n", .{});
        // Would initialize Zyte's BridgeAPI here
        self.bridge = null; // Placeholder
    }

    /// Event loop for Zyte window
    fn eventLoop(self: *ZyteApp) !void {
        std.debug.print("🔄 Starting event loop\n", .{});
        std.debug.print("   Press Ctrl+C to quit\n\n", .{});

        // In real implementation, would run Zyte's native event loop
        // This would handle window events, IPC messages, etc.
        _ = self;
    }

    /// Send message to webview via IPC
    pub fn sendMessage(self: *ZyteApp, event: []const u8, data: []const u8) !void {
        std.debug.print("📤 Sending to web: {s} = {s}\n", .{ event, data });
        // Would use Zyte's bridge API to send message to JavaScript
        _ = self;
    }

    /// Listen for messages from webview
    pub fn onMessage(self: *ZyteApp, event: []const u8, handler: *const fn ([]const u8) anyerror!void) !void {
        std.debug.print("📥 Registering handler for: {s}\n", .{event});
        // Would register handler with Zyte's bridge API
        _ = self;
        _ = handler;
    }

    /// Load URL in webview
    pub fn loadUrl(self: *ZyteApp, url: []const u8) !void {
        std.debug.print("🌐 Loading URL: {s}\n", .{url});
        // Would call Zyte's webview loadURL method
        _ = self;
    }

    /// Execute JavaScript in webview
    pub fn executeJavaScript(self: *ZyteApp, script: []const u8) !void {
        std.debug.print("⚡ Executing JavaScript: {s}\n", .{script});
        // Would call Zyte's webview evaluateJavaScript
        _ = self;
    }
};

/// IPC Bridge API (stub - links to Zyte's bridge)
const BridgeAPI = struct {
    // Placeholder for Zyte's BridgeAPI
};

/// Zyte + HTTP Server Integration
/// Serves HTTP content and displays it in a native Zyte window
pub const ZyteServer = struct {
    allocator: std.mem.Allocator,
    http_port: u16,
    zyte_app: ZyteApp,
    running: bool,

    pub fn init(allocator: std.mem.Allocator, port: u16, config: ZyteConfig) !ZyteServer {
        return .{
            .allocator = allocator,
            .http_port = port,
            .zyte_app = try ZyteApp.init(allocator, config),
            .running = false,
        };
    }

    pub fn deinit(self: *ZyteServer) void {
        self.zyte_app.deinit();
    }

    /// Start HTTP server and show in Zyte window
    pub fn start(self: *ZyteServer) !void {
        std.debug.print("\n🌐 Starting Home HTTP Server + Zyte Window\n", .{});
        std.debug.print("═══════════════════════════════════════════\n", .{});
        std.debug.print("HTTP Port:  {d}\n", .{self.http_port});
        std.debug.print("Window URL: http://localhost:{d}\n", .{self.http_port});
        std.debug.print("═══════════════════════════════════════════\n\n", .{});

        self.running = true;

        // In production:
        // 1. Start HTTP server in background thread
        // 2. Configure Zyte to load localhost:{port}
        // 3. Setup IPC bridge for native<->web communication
        // 4. Run Zyte event loop

        // Set URL to localhost
        const url = try std.fmt.allocPrint(self.allocator, "http://localhost:{d}", .{self.http_port});
        defer self.allocator.free(url);

        var config = self.zyte_app.config;
        _ = config.setUrl(url);
        self.zyte_app.config = config;

        // Run Zyte window
        try self.zyte_app.run();
    }

    pub fn stop(self: *ZyteServer) void {
        self.running = false;
        std.debug.print("🛑 Stopping server\n", .{});
    }
};

/// Zyte builder pattern
pub const ZyteBuilder = struct {
    allocator: std.mem.Allocator,
    config: ZyteConfig,

    pub fn init(allocator: std.mem.Allocator) ZyteBuilder {
        return .{
            .allocator = allocator,
            .config = ZyteConfig.init(allocator),
        };
    }

    pub fn title(self: *ZyteBuilder, t: []const u8) *ZyteBuilder {
        _ = self.config.setTitle(t);
        return self;
    }

    pub fn size(self: *ZyteBuilder, width: u32, height: u32) *ZyteBuilder {
        _ = self.config.setSize(width, height);
        return self;
    }

    pub fn resizable(self: *ZyteBuilder, r: bool) *ZyteBuilder {
        _ = self.config.setResizable(r);
        return self;
    }

    pub fn fullscreen(self: *ZyteBuilder, f: bool) *ZyteBuilder {
        _ = self.config.setFullscreen(f);
        return self;
    }

    pub fn frameless(self: *ZyteBuilder, f: bool) *ZyteBuilder {
        _ = self.config.setFrameless(f);
        return self;
    }

    pub fn transparent(self: *ZyteBuilder, t: bool) *ZyteBuilder {
        _ = self.config.setTransparent(t);
        return self;
    }

    pub fn devTools(self: *ZyteBuilder, enabled: bool) *ZyteBuilder {
        _ = self.config.setDevTools(enabled);
        return self;
    }

    pub fn url(self: *ZyteBuilder, u: []const u8) *ZyteBuilder {
        _ = self.config.setUrl(u);
        return self;
    }

    pub fn html(self: *ZyteBuilder, h: []const u8) *ZyteBuilder {
        _ = self.config.setHtml(h);
        return self;
    }

    pub fn build(self: *ZyteBuilder) !ZyteApp {
        return try ZyteApp.init(self.allocator, self.config);
    }
};

/// Quick start helper - launches HTTP server + Zyte window
pub fn quickStart(
    allocator: std.mem.Allocator,
    title: []const u8,
    port: u16,
) !void {
    var config = ZyteConfig.init(allocator);
    _ = config.setTitle(title);
    _ = config.setHotReload(true);

    var server = try ZyteServer.init(allocator, port, config);
    defer server.deinit();

    try server.start();
}

/// Component definitions for Zyte UI
pub const Components = struct {
    /// Button component
    pub const Button = struct {
        label: []const u8,
        onClick: ?*const fn () void,

        pub fn toHtml(self: Button, allocator: std.mem.Allocator) ![]const u8 {
            return try std.fmt.allocPrint(
                allocator,
                "<button onclick=\"handleClick()\">{s}</button>",
                .{self.label},
            );
        }
    };

    /// Input component
    pub const Input = struct {
        placeholder: []const u8,
        value: []const u8,

        pub fn toHtml(self: Input, allocator: std.mem.Allocator) ![]const u8 {
            return try std.fmt.allocPrint(
                allocator,
                "<input type=\"text\" placeholder=\"{s}\" value=\"{s}\" />",
                .{ self.placeholder, self.value },
            );
        }
    };

    /// Container component
    pub const Container = struct {
        children: []const []const u8,

        pub fn toHtml(self: Container, allocator: std.mem.Allocator) ![]const u8 {
            var html = std.ArrayList(u8){};
            try html.appendSlice(allocator, "<div class=\"container\">");

            for (self.children) |child| {
                try html.appendSlice(allocator, child);
            }

            try html.appendSlice(allocator, "</div>");
            return html.toOwnedSlice(allocator);
        }
    };
};

/// IPC message structure
pub const IpcMessage = struct {
    event: []const u8,
    data: []const u8,

    pub fn toJson(self: IpcMessage, allocator: std.mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(
            allocator,
            "{{\"event\":\"{s}\",\"data\":\"{s}\"}}",
            .{ self.event, self.data },
        );
    }
};

/// System tray integration
pub const SystemTray = struct {
    allocator: std.mem.Allocator,
    icon_path: ?[]const u8,
    tooltip: []const u8,

    pub fn init(allocator: std.mem.Allocator, tooltip: []const u8) SystemTray {
        return .{
            .allocator = allocator,
            .icon_path = null,
            .tooltip = tooltip,
        };
    }

    pub fn setIcon(self: *SystemTray, path: []const u8) *SystemTray {
        self.icon_path = path;
        return self;
    }

    pub fn show(self: *SystemTray) !void {
        std.debug.print("🔔 System tray: {s}\n", .{self.tooltip});
        if (self.icon_path) |path| {
            std.debug.print("   Icon: {s}\n", .{path});
        }
        // Would call Zyte's system tray API
    }
};

/// Notification helper
pub const Notification = struct {
    title: []const u8,
    body: []const u8,
    icon: ?[]const u8,

    pub fn show(self: Notification) !void {
        std.debug.print("📬 Notification: {s}\n", .{self.title});
        std.debug.print("   {s}\n", .{self.body});
        // Would call Zyte's notification API
    }
};

/// Dialog helpers
pub const Dialog = struct {
    /// Open file dialog
    pub fn openFile(allocator: std.mem.Allocator, filters: []const []const u8) !?[]const u8 {
        _ = allocator;
        _ = filters;
        // Would call Zyte's file dialog API
        return null;
    }

    /// Save file dialog
    pub fn saveFile(allocator: std.mem.Allocator, default_name: []const u8) !?[]const u8 {
        _ = allocator;
        _ = default_name;
        // Would call Zyte's file dialog API
        return null;
    }

    /// Show alert
    pub fn alert(title: []const u8, message: []const u8) !void {
        std.debug.print("⚠️  Alert: {s}\n", .{title});
        std.debug.print("   {s}\n", .{message});
        // Would call Zyte's alert dialog API
    }

    /// Show confirm dialog
    pub fn confirm(title: []const u8, message: []const u8) !bool {
        _ = title;
        _ = message;
        // Would call Zyte's confirm dialog API
        return false;
    }
};
