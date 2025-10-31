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
/// This module links directly with Craft's native Zig implementation
/// Craft path - looks for Craft in ~/Code/craft by default
const CRAFT_PATH = "/Users/chrisbreuer/Code/craft/packages/zig";

/// Import Craft modules if available
/// In production, these would be actual @cImport or direct Zig imports
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
