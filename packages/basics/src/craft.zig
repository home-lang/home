const std = @import("std");
const builtin = @import("builtin");

/// Native Craft integration for Home
/// Craft is a native Zig cross-platform desktop framework
///
/// Craft provides:
/// - Native window management (macOS, Linux, Windows)
/// - WebView integration (WKWebView, WebKit2GTK, WebView2)
/// - 35+ native UI components
/// - System integration (notifications, tray, dialogs)
/// - Mobile support (iOS, Android)
/// - Hot reload with state preservation
/// - IPC bridge for web<->native communication
///
/// This module uses Pantry to resolve Craft's path dynamically
/// Craft is installed via: pantry install craft
///
/// Path resolution:
/// 1. Check .freezer lockfile for craft package
/// 2. Resolve to ~/.local/share/launchpad/global/packages/craft/{version}
/// 3. Use packages/zig subpath for Zig bindings

/// Resolve Craft path from pantry
/// Resolution order:
/// 1. ./pantry_modules/craft/{version}/packages/zig (local install)
/// 2. ~/.local/share/pantry/global/packages/craft/{version} (global install)
/// 3. ~/Code/craft/packages/zig (development fallback)
fn resolveCraftPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.HomeNotSet;

    // Try current directory first (for local pantry_modules)
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.fs.cwd().realpath(".", &buf) catch {
        // If we can't get cwd, skip to global check
        return tryGlobalOrFallback(allocator, home);
    };

    // Check ./pantry_modules/craft/{version}/packages/zig
    const local_craft_base = try std.fs.path.join(allocator, &.{ cwd, "pantry_modules", "craft" });
    defer allocator.free(local_craft_base);

    if (std.fs.openDirAbsolute(local_craft_base, .{ .iterate = true })) |*dir| {
        defer dir.close();
        var iter = dir.iterate();
        if (try iter.next()) |entry| {
            if (entry.kind == .directory) {
                return try std.fs.path.join(allocator, &.{
                    local_craft_base,
                    entry.name,
                    "packages",
                    "zig",
                });
            }
        }
    } else |_| {}

    // Not in local modules, try global/fallback
    return tryGlobalOrFallback(allocator, home);
}

fn tryGlobalOrFallback(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
    // Check ~/.local/share/pantry/global/packages/craft/{version}
    const global_craft_base = try std.fs.path.join(allocator, &.{
        home,
        ".local",
        "share",
        "pantry",
        "global",
        "packages",
        "craft",
    });
    defer allocator.free(global_craft_base);

    if (std.fs.openDirAbsolute(global_craft_base, .{ .iterate = true })) |*dir| {
        defer dir.close();
        var iter = dir.iterate();
        if (try iter.next()) |entry| {
            if (entry.kind == .directory) {
                return try std.fs.path.join(allocator, &.{
                    global_craft_base,
                    entry.name,
                    "packages",
                    "zig",
                });
            }
        }
    } else |_| {}

    // Fall back to ~/Code/craft/packages/zig for development
    return try std.fs.path.join(allocator, &.{ home, "Code", "craft", "packages", "zig" });
}

/// Import Craft modules if available
/// In production, these would be actual @cImport or direct Zig imports

/// Craft configuration builder for creating windows
pub const craftConfig = struct {
    allocator: std.mem.Allocator,
    title: []const u8 = "Home + Craft App",
    width: u32 = 800,
    height: u32 = 600,
    html: []const u8 = "",
    resizable: bool = true,
    devtools: bool = false,

    pub fn init(allocator: std.mem.Allocator) craftConfig {
        return .{ .allocator = allocator };
    }

    pub fn setTitle(self: *craftConfig, title: []const u8) *craftConfig {
        self.title = title;
        return self;
    }

    pub fn setSize(self: *craftConfig, width: u32, height: u32) *craftConfig {
        self.width = width;
        self.height = height;
        return self;
    }

    pub fn setHtml(self: *craftConfig, html: []const u8) *craftConfig {
        self.html = html;
        return self;
    }

    pub fn setResizable(self: *craftConfig, resizable: bool) *craftConfig {
        self.resizable = resizable;
        return self;
    }

    pub fn enableDevTools(self: *craftConfig, enable: bool) *craftConfig {
        self.devtools = enable;
        return self;
    }

    pub fn setDevTools(self: *craftConfig, enable: bool) *craftConfig {
        self.devtools = enable;
        return self;
    }

    pub fn setFrameless(self: *craftConfig, frameless: bool) *craftConfig {
        _ = frameless; // Frameless mode would be implemented in actual Craft
        return self;
    }

    pub fn setTransparent(self: *craftConfig, transparent: bool) *craftConfig {
        _ = transparent; // Transparent mode would be implemented in actual Craft
        return self;
    }

    pub fn setAlwaysOnTop(self: *craftConfig, always_on_top: bool) *craftConfig {
        _ = always_on_top; // Always-on-top would be implemented in actual Craft
        return self;
    }

    pub fn setUrl(self: *craftConfig, url: []const u8) *craftConfig {
        _ = url; // URL loading would be implemented in actual Craft
        return self;
    }

    pub fn setMinSize(self: *craftConfig, width: u32, height: u32) *craftConfig {
        _ = width;
        _ = height;
        return self;
    }

    pub fn setMaxSize(self: *craftConfig, width: u32, height: u32) *craftConfig {
        _ = width;
        _ = height;
        return self;
    }

    pub fn build(self: *craftConfig) !CraftWindow {
        return CraftWindow.init(self.title, self.width, self.height, self.html);
    }
};

/// Craft application builder (alias for craftConfig for API compatibility)
pub const craftApp = struct {
    allocator: std.mem.Allocator,
    config: craftConfig,
    window: ?CraftWindow = null,

    pub fn init(allocator: std.mem.Allocator, config: craftConfig) !craftApp {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn run(self: *craftApp) !void {
        self.window = try self.config.build();
        if (self.window) |*w| {
            try w.show();
        }
    }

    pub fn onMessage(self: *craftApp, channel: []const u8, handler: anytype) !void {
        _ = self;
        _ = handler;
        std.debug.print("IPC: Registered handler for channel '{s}'\n", .{channel});
    }

    pub fn sendMessage(self: *craftApp, channel: []const u8, data: []const u8) !void {
        _ = self;
        std.debug.print("IPC: Sending to '{s}': {s}\n", .{ channel, data });
    }

    pub fn deinit(self: *craftApp) void {
        if (self.window) |*w| {
            w.deinit();
        }
    }
};

pub const CraftWindow = struct {
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
        std.debug.print("Craft Window: {s} ({d}x{d})\n", .{ self.title, self.width, self.height });
        std.debug.print("Rendering HTML: {s}\n", .{self.html});

        // Platform-specific implementation would go here
    }

    pub fn deinit(self: *@This()) void {
        _ = self;
    }
};

/// Craft Application
pub const CraftApp = struct {
    allocator: std.mem.Allocator,
    windows: std.ArrayList(*CraftWindow),

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .allocator = allocator,
            .windows = .{},
        };
    }

    pub fn createWindow(self: *@This(), title: []const u8, width: u32, height: u32, html: []const u8) !*CraftWindow {
        const window = try self.allocator.create(CraftWindow);
        window.* = CraftWindow.init(title, width, height, html);
        try self.windows.append(self.allocator, window);
        return window;
    }

    pub fn run(self: *@This()) !void {
        std.debug.print("\nStarting Craft Application...\n", .{});
        std.debug.print("Windows: {d}\n", .{self.windows.items.len});

        for (self.windows.items) |window| {
            try window.show();
        }
    }

    pub fn deinit(self: *@This()) void {
        for (self.windows.items) |window| {
            window.deinit();
            self.allocator.destroy(window);
        }
        self.windows.deinit(self.allocator);
    }
};

/// System integration
pub const System = struct {
    pub fn showNotification(title: []const u8, message: []const u8) !void {
        std.debug.print("Notification: {s}\n{s}\n", .{ title, message });
    }

    pub fn showDialog(title: []const u8, message: []const u8) !bool {
        std.debug.print("Dialog: {s}\n{s}\n", .{ title, message });
        return true;
    }
};

/// IPC Bridge for web<->native communication
pub const IPCBridge = struct {
    pub fn send(channel: []const u8, data: []const u8) !void {
        std.debug.print("IPC: {s} -> {s}\n", .{ channel, data });
    }

    pub fn on(channel: []const u8, callback: *const fn ([]const u8) void) !void {
        std.debug.print("IPC Listener: {s}\n", .{channel});
        _ = callback;
    }
};

/// System tray integration
pub const SystemTray = struct {
    allocator: std.mem.Allocator,
    title: []const u8,
    icon_path: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, title: []const u8) SystemTray {
        return .{
            .allocator = allocator,
            .title = title,
        };
    }

    pub fn setIcon(self: *SystemTray, icon_path: []const u8) *SystemTray {
        self.icon_path = icon_path;
        return self;
    }

    pub fn show(self: *SystemTray) !void {
        std.debug.print("SystemTray: {s} (icon: {s})\n", .{
            self.title,
            self.icon_path orelse "none",
        });
    }
};

/// Notification
pub const Notification = struct {
    title: []const u8,
    body: []const u8,
    icon: ?[]const u8 = null,

    pub fn show(self: *const Notification) !void {
        std.debug.print("Notification: {s}\n{s}\n", .{ self.title, self.body });
    }
};

/// Dialog utilities
pub const Dialog = struct {
    pub fn alert(title: []const u8, message: []const u8) !void {
        std.debug.print("Dialog Alert: {s}\n{s}\n", .{ title, message });
    }

    pub fn confirm(title: []const u8, message: []const u8) !bool {
        std.debug.print("Dialog Confirm: {s}\n{s}\n", .{ title, message });
        return true;
    }

    pub fn openFile(allocator: std.mem.Allocator, extensions: []const []const u8) !?[]const u8 {
        _ = extensions;
        // In a real implementation, this would open a file picker dialog
        std.debug.print("Dialog: Open file picker\n", .{});
        return try allocator.dupe(u8, "/path/to/selected/file.txt");
    }

    pub fn saveFile(allocator: std.mem.Allocator, default_name: []const u8) !?[]const u8 {
        // In a real implementation, this would open a save dialog
        std.debug.print("Dialog: Save file picker (default: {s})\n", .{default_name});
        return try allocator.dupe(u8, default_name);
    }
};

/// Quick start helper - opens a window pointing to a local server
pub fn quickStart(allocator: std.mem.Allocator, title: []const u8, port: u16) !void {
    var config = craftConfig.init(allocator);
    _ = config.setTitle(title);
    _ = config.setSize(1280, 720);

    // In a real implementation, this would open a WebView pointing to localhost:port
    std.debug.print("QuickStart: Opening {s} pointing to http://localhost:{d}\n", .{ title, port });

    const window = try config.build();
    std.debug.print("Window ready: {s} ({d}x{d})\n", .{ window.title, window.width, window.height });
}

// Tests
test "Craft window creation" {
    const allocator = std.testing.allocator;

    var app = CraftApp.init(allocator);
    defer app.deinit();

    const window = try app.createWindow("Test Window", 800, 600, "<h1>Hello Craft!</h1>");

    try std.testing.expectEqualStrings("Test Window", window.title);
    try std.testing.expectEqual(@as(u32, 800), window.width);
    try std.testing.expectEqual(@as(u32, 600), window.height);
}

test "Craft app initialization" {
    const allocator = std.testing.allocator;

    var app = CraftApp.init(allocator);
    defer app.deinit();

    try std.testing.expectEqual(@as(usize, 0), app.windows.items.len);
}

test "System notifications" {
    try System.showNotification("Test", "This is a test notification");
}

/// UI Components namespace for craft
pub const Components = struct {
    /// Button component
    pub const Button = struct {
        label: []const u8 = "Button",
        onClick: ?*const fn () void = null,

        pub fn render(self: *const Button) void {
            std.debug.print("Button: {s}\n", .{self.label});
        }

        pub fn toHtml(self: *const Button, allocator: std.mem.Allocator) ![]const u8 {
            return try std.fmt.allocPrint(allocator, "<button>{s}</button>", .{self.label});
        }
    };

    /// Text input component
    pub const TextInput = struct {
        placeholder: []const u8 = "",
        value: []const u8 = "",
        onChange: ?*const fn ([]const u8) void = null,

        pub fn render(self: *const TextInput) void {
            std.debug.print("TextInput: placeholder={s} value={s}\n", .{ self.placeholder, self.value });
        }

        pub fn toHtml(self: *const TextInput, allocator: std.mem.Allocator) ![]const u8 {
            return try std.fmt.allocPrint(allocator, "<input type=\"text\" placeholder=\"{s}\" value=\"{s}\" />", .{ self.placeholder, self.value });
        }
    };

    /// Input alias for TextInput
    pub const Input = TextInput;

    /// Label component
    pub const Label = struct {
        text: []const u8 = "",

        pub fn render(self: *const Label) void {
            std.debug.print("Label: {s}\n", .{self.text});
        }

        pub fn toHtml(self: *const Label, allocator: std.mem.Allocator) ![]const u8 {
            return try std.fmt.allocPrint(allocator, "<label>{s}</label>", .{self.text});
        }
    };

    /// Container component
    pub const Container = struct {
        children: []const []const u8 = &.{},

        pub fn render(self: *const Container) void {
            _ = self;
            std.debug.print("Container\n", .{});
        }

        pub fn toHtml(self: *const Container, allocator: std.mem.Allocator) ![]const u8 {
            var result = std.ArrayList(u8){};
            defer result.deinit(allocator);

            try result.appendSlice(allocator, "<div class=\"container\">");
            for (self.children) |child| {
                try result.appendSlice(allocator, child);
            }
            try result.appendSlice(allocator, "</div>");

            return try allocator.dupe(u8, result.items);
        }
    };
};
