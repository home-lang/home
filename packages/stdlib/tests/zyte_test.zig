const std = @import("std");
const testing = std.testing;
const zyte = @import("zyte");

// ============================================================================
// ZyteConfig Tests
// ============================================================================

test "ZyteConfig: init creates valid config with defaults" {
    const config = zyte.ZyteConfig.init(testing.allocator);

    try testing.expectEqualStrings("Ion + Zyte App", config.title);
    try testing.expectEqual(@as(u32, 1024), config.width);
    try testing.expectEqual(@as(u32, 768), config.height);
    try testing.expectEqual(true, config.resizable);
    try testing.expectEqual(false, config.fullscreen);
    try testing.expectEqual(false, config.frameless);
    try testing.expectEqual(false, config.transparent);
    try testing.expectEqual(true, config.dev_tools); // dev_tools defaults to true
}

test "ZyteConfig: setTitle updates title" {
    var config = zyte.ZyteConfig.init(testing.allocator);
    _ = config.setTitle("My Custom App");

    try testing.expectEqualStrings("My Custom App", config.title);
}

test "ZyteConfig: setSize updates dimensions" {
    var config = zyte.ZyteConfig.init(testing.allocator);
    _ = config.setSize(1920, 1080);

    try testing.expectEqual(@as(u32, 1920), config.width);
    try testing.expectEqual(@as(u32, 1080), config.height);
}

test "ZyteConfig: setResizable updates resizable flag" {
    var config = zyte.ZyteConfig.init(testing.allocator);
    _ = config.setResizable(false);

    try testing.expectEqual(false, config.resizable);
}

test "ZyteConfig: setFullscreen updates fullscreen flag" {
    var config = zyte.ZyteConfig.init(testing.allocator);
    _ = config.setFullscreen(true);

    try testing.expectEqual(true, config.fullscreen);
}

test "ZyteConfig: setFrameless updates frameless flag" {
    var config = zyte.ZyteConfig.init(testing.allocator);
    _ = config.setFrameless(true);

    try testing.expectEqual(true, config.frameless);
}

test "ZyteConfig: setTransparent updates transparent flag" {
    var config = zyte.ZyteConfig.init(testing.allocator);
    _ = config.setTransparent(true);

    try testing.expectEqual(true, config.transparent);
}

test "ZyteConfig: setDarkMode updates dark_mode flag" {
    var config = zyte.ZyteConfig.init(testing.allocator);
    _ = config.setDarkMode(true);

    try testing.expectEqual(true, config.dark_mode);
}

test "ZyteConfig: setAlwaysOnTop updates always_on_top flag" {
    var config = zyte.ZyteConfig.init(testing.allocator);
    _ = config.setAlwaysOnTop(true);

    try testing.expectEqual(true, config.always_on_top);
}

test "ZyteConfig: setHotReload updates enable_hot_reload flag" {
    var config = zyte.ZyteConfig.init(testing.allocator);
    _ = config.setHotReload(false);

    try testing.expectEqual(false, config.enable_hot_reload);
}

test "ZyteConfig: setDevTools updates dev_tools flag" {
    var config = zyte.ZyteConfig.init(testing.allocator);
    _ = config.setDevTools(true);

    try testing.expectEqual(true, config.dev_tools);
}

test "ZyteConfig: setHtml updates html content" {
    var config = zyte.ZyteConfig.init(testing.allocator);
    const html = "<h1>Hello</h1>";
    _ = config.setHtml(html);

    try testing.expect(config.html != null);
    try testing.expectEqualStrings(html, config.html.?);
}

test "ZyteConfig: setUrl updates url" {
    var config = zyte.ZyteConfig.init(testing.allocator);
    const url = "http://localhost:3000";
    _ = config.setUrl(url);

    try testing.expect(config.url != null);
    try testing.expectEqualStrings(url, config.url.?);
}

test "ZyteConfig: method chaining works" {
    var config = zyte.ZyteConfig.init(testing.allocator);
    _ = config.setTitle("Test App")
        .setSize(1024, 768)
        .setFrameless(true)
        .setDarkMode(true);

    try testing.expectEqualStrings("Test App", config.title);
    try testing.expectEqual(@as(u32, 1024), config.width);
    try testing.expectEqual(@as(u32, 768), config.height);
    try testing.expectEqual(true, config.frameless);
    try testing.expectEqual(true, config.dark_mode);
}

// ============================================================================
// ZyteApp Tests
// ============================================================================

test "ZyteApp: init creates valid app" {
    var config = zyte.ZyteConfig.init(testing.allocator);
    _ = config.setTitle("Test App");

    var app = try zyte.ZyteApp.init(testing.allocator, config);
    defer app.deinit();

    try testing.expectEqualStrings("Test App", app.config.title);
}

test "ZyteApp: config is properly stored" {
    var config = zyte.ZyteConfig.init(testing.allocator);
    _ = config.setTitle("Custom Title")
        .setSize(1280, 720)
        .setDarkMode(true);

    var app = try zyte.ZyteApp.init(testing.allocator, config);
    defer app.deinit();

    try testing.expectEqualStrings("Custom Title", app.config.title);
    try testing.expectEqual(@as(u32, 1280), app.config.width);
    try testing.expectEqual(@as(u32, 720), app.config.height);
    try testing.expectEqual(true, app.config.dark_mode);
}

// ============================================================================
// ZyteServer Tests
// ============================================================================

test "ZyteServer: init creates valid server" {
    const config = zyte.ZyteConfig.init(testing.allocator);
    var server = try zyte.ZyteServer.init(testing.allocator, 3000, config);
    defer server.deinit();

    try testing.expectEqual(@as(u16, 3000), server.http_port);
    try testing.expectEqual(false, server.running);
}

test "ZyteServer: port is properly stored" {
    const config = zyte.ZyteConfig.init(testing.allocator);
    var server = try zyte.ZyteServer.init(testing.allocator, 8080, config);
    defer server.deinit();

    try testing.expectEqual(@as(u16, 8080), server.http_port);
}

// ============================================================================
// SystemTray Tests
// ============================================================================

test "SystemTray: init creates valid tray" {
    const tray = zyte.SystemTray.init(testing.allocator, "Test App");

    // SystemTray doesn't expose title field directly, just verify init works
    try testing.expectEqual(@as(?[]const u8, null), tray.icon_path);
}

test "SystemTray: setIcon updates icon path" {
    var tray = zyte.SystemTray.init(testing.allocator, "Test App");
    _ = tray.setIcon("/path/to/icon.png");

    try testing.expectEqualStrings("/path/to/icon.png", tray.icon_path.?);
}

// ============================================================================
// Notification Tests
// ============================================================================

test "Notification: struct has correct fields" {
    const notification = zyte.Notification{
        .title = "Test",
        .body = "Test body",
        .icon = null,
    };

    try testing.expectEqualStrings("Test", notification.title);
    try testing.expectEqualStrings("Test body", notification.body);
    try testing.expectEqual(@as(?[]const u8, null), notification.icon);
}

test "Notification: with icon path" {
    const notification = zyte.Notification{
        .title = "Test",
        .body = "Test body",
        .icon = "/path/to/icon.png",
    };

    try testing.expectEqualStrings("/path/to/icon.png", notification.icon.?);
}

// ============================================================================
// IpcMessage Tests
// ============================================================================

test "IpcMessage: struct has correct fields" {
    const msg = zyte.IpcMessage{
        .event = "test-event",
        .data = "{\"key\":\"value\"}",
    };

    try testing.expectEqualStrings("test-event", msg.event);
    try testing.expectEqualStrings("{\"key\":\"value\"}", msg.data);
}

// ============================================================================
// Components Tests
// ============================================================================

test "Components.Button: struct has correct fields" {
    const button = zyte.Components.Button{
        .label = "Click Me",
        .onClick = null,
    };

    try testing.expectEqualStrings("Click Me", button.label);
}

test "Components.Button: toHtml generates valid HTML" {
    const button = zyte.Components.Button{
        .label = "Submit",
        .onClick = null,
    };

    const html = try button.toHtml(testing.allocator);
    defer testing.allocator.free(html);

    try testing.expect(std.mem.indexOf(u8, html, "button") != null);
    try testing.expect(std.mem.indexOf(u8, html, "Submit") != null);
}

test "Components.Input: struct has correct fields" {
    const input = zyte.Components.Input{
        .placeholder = "Enter name",
        .value = "",
    };

    try testing.expectEqualStrings("Enter name", input.placeholder);
    try testing.expectEqualStrings("", input.value);
}

test "Components.Input: toHtml generates valid HTML" {
    const input = zyte.Components.Input{
        .placeholder = "Email",
        .value = "test@example.com",
    };

    const html = try input.toHtml(testing.allocator);
    defer testing.allocator.free(html);

    try testing.expect(std.mem.indexOf(u8, html, "input") != null);
    try testing.expect(std.mem.indexOf(u8, html, "Email") != null);
    try testing.expect(std.mem.indexOf(u8, html, "test@example.com") != null);
}

test "Components.Container: toHtml generates valid HTML with children" {
    const button = zyte.Components.Button{
        .label = "Click",
        .onClick = null,
    };
    const button_html = try button.toHtml(testing.allocator);
    defer testing.allocator.free(button_html);

    const input = zyte.Components.Input{
        .placeholder = "Name",
        .value = "",
    };
    const input_html = try input.toHtml(testing.allocator);
    defer testing.allocator.free(input_html);

    const children = [_][]const u8{ button_html, input_html };
    const container = zyte.Components.Container{
        .children = &children,
    };

    const html = try container.toHtml(testing.allocator);
    defer testing.allocator.free(html);

    try testing.expect(std.mem.indexOf(u8, html, "container") != null);
    try testing.expect(std.mem.indexOf(u8, html, "Click") != null);
    try testing.expect(std.mem.indexOf(u8, html, "Name") != null);
}

// ============================================================================
// Dialog Tests
// ============================================================================

test "Dialog: alert exists and has correct type" {
    // Dialog.alert is a stub that prints to stdout, so we just verify it compiles
    const AlertFn = @TypeOf(zyte.Dialog.alert);
    _ = AlertFn; // Just verify it exists
}

test "Dialog: confirm exists and has correct type" {
    const ConfirmFn = @TypeOf(zyte.Dialog.confirm);
    _ = ConfirmFn;
}

test "Dialog: openFile exists and has correct type" {
    const OpenFileFn = @TypeOf(zyte.Dialog.openFile);
    _ = OpenFileFn;
}

test "Dialog: saveFile exists and has correct type" {
    const SaveFileFn = @TypeOf(zyte.Dialog.saveFile);
    _ = SaveFileFn;
}

// ============================================================================
// Integration Tests
// ============================================================================

test "Integration: complete Zyte app configuration" {
    var config = zyte.ZyteConfig.init(testing.allocator);
    _ = config.setTitle("Full-Stack App")
        .setSize(1200, 800)
        .setFrameless(false)
        .setTransparent(false)
        .setDarkMode(true)
        .setAlwaysOnTop(false)
        .setHotReload(true)
        .setDevTools(true)
        .setUrl("http://localhost:3000");

    var app = try zyte.ZyteApp.init(testing.allocator, config);
    defer app.deinit();

    try testing.expectEqualStrings("Full-Stack App", app.config.title);
    try testing.expectEqual(@as(u32, 1200), app.config.width);
    try testing.expectEqual(@as(u32, 800), app.config.height);
    try testing.expectEqual(true, app.config.dark_mode);
    try testing.expectEqual(true, app.config.enable_hot_reload);
    try testing.expectEqual(true, app.config.dev_tools);
    try testing.expect(app.config.url != null);
    try testing.expectEqualStrings("http://localhost:3000", app.config.url.?);
}

test "Integration: Zyte server with custom config" {
    var config = zyte.ZyteConfig.init(testing.allocator);
    _ = config.setTitle("API Server")
        .setSize(1024, 768)
        .setDarkMode(true);

    var server = try zyte.ZyteServer.init(testing.allocator, 8080, config);
    defer server.deinit();

    try testing.expectEqual(@as(u16, 8080), server.http_port);
    try testing.expectEqualStrings("API Server", server.zyte_app.config.title);
}

test "Integration: system tray with icon" {
    var tray = zyte.SystemTray.init(testing.allocator, "My App");
    _ = tray.setIcon("/usr/share/icons/app.png");

    // SystemTray doesn't expose title field directly
    try testing.expectEqualStrings("/usr/share/icons/app.png", tray.icon_path.?);
}

test "Integration: notification with all fields" {
    const notification = zyte.Notification{
        .title = "Download Complete",
        .body = "Your file has been downloaded successfully.",
        .icon = "/path/to/success.png",
    };

    try testing.expectEqualStrings("Download Complete", notification.title);
    try testing.expectEqualStrings("Your file has been downloaded successfully.", notification.body);
    try testing.expectEqualStrings("/path/to/success.png", notification.icon.?);
}

test "Integration: IPC message with JSON data" {
    const msg = zyte.IpcMessage{
        .event = "user-login",
        .data = "{\"username\":\"alice\",\"timestamp\":1234567890}",
    };

    try testing.expectEqualStrings("user-login", msg.event);
    try testing.expect(std.mem.indexOf(u8, msg.data, "alice") != null);
    try testing.expect(std.mem.indexOf(u8, msg.data, "timestamp") != null);
}

test "Integration: UI components composition" {
    // Create a button
    const button = zyte.Components.Button{
        .label = "Save",
        .onClick = null,
    };
    const button_html = try button.toHtml(testing.allocator);
    defer testing.allocator.free(button_html);

    // Create an input
    const input = zyte.Components.Input{
        .placeholder = "Username",
        .value = "",
    };
    const input_html = try input.toHtml(testing.allocator);
    defer testing.allocator.free(input_html);

    // Combine in container
    const children = [_][]const u8{ input_html, button_html };
    const container = zyte.Components.Container{
        .children = &children,
    };
    const container_html = try container.toHtml(testing.allocator);
    defer testing.allocator.free(container_html);

    // Verify container contains both components
    try testing.expect(std.mem.indexOf(u8, container_html, "Username") != null);
    try testing.expect(std.mem.indexOf(u8, container_html, "Save") != null);
}

test "Integration: frameless transparent window config" {
    var config = zyte.ZyteConfig.init(testing.allocator);
    _ = config.setTitle("Frameless Window")
        .setSize(400, 300)
        .setFrameless(true)
        .setTransparent(true)
        .setResizable(false);

    var app = try zyte.ZyteApp.init(testing.allocator, config);
    defer app.deinit();

    try testing.expectEqual(true, app.config.frameless);
    try testing.expectEqual(true, app.config.transparent);
    try testing.expectEqual(false, app.config.resizable);
}

test "Integration: fullscreen window config" {
    var config = zyte.ZyteConfig.init(testing.allocator);
    _ = config.setTitle("Fullscreen App")
        .setFullscreen(true)
        .setAlwaysOnTop(true);

    var app = try zyte.ZyteApp.init(testing.allocator, config);
    defer app.deinit();

    try testing.expectEqual(true, app.config.fullscreen);
    try testing.expectEqual(true, app.config.always_on_top);
}

test "Integration: development window with tools" {
    var config = zyte.ZyteConfig.init(testing.allocator);
    _ = config.setTitle("Development Window")
        .setSize(1920, 1080)
        .setDevTools(true)
        .setHotReload(true)
        .setDarkMode(true);

    var app = try zyte.ZyteApp.init(testing.allocator, config);
    defer app.deinit();

    try testing.expectEqual(true, app.config.dev_tools);
    try testing.expectEqual(true, app.config.enable_hot_reload);
    try testing.expectEqual(true, app.config.dark_mode);
}

// ============================================================================
// Edge Cases and Error Handling
// ============================================================================

test "Edge: empty title is allowed" {
    var config = zyte.ZyteConfig.init(testing.allocator);
    _ = config.setTitle("");

    try testing.expectEqualStrings("", config.title);
}

test "Edge: very small window size" {
    var config = zyte.ZyteConfig.init(testing.allocator);
    _ = config.setSize(100, 100);

    try testing.expectEqual(@as(u32, 100), config.width);
    try testing.expectEqual(@as(u32, 100), config.height);
}

test "Edge: very large window size" {
    var config = zyte.ZyteConfig.init(testing.allocator);
    _ = config.setSize(4096, 2160);

    try testing.expectEqual(@as(u32, 4096), config.width);
    try testing.expectEqual(@as(u32, 2160), config.height);
}

test "Edge: empty HTML content" {
    var config = zyte.ZyteConfig.init(testing.allocator);
    _ = config.setHtml("");

    try testing.expect(config.html != null);
    try testing.expectEqualStrings("", config.html.?);
}

test "Edge: empty URL" {
    var config = zyte.ZyteConfig.init(testing.allocator);
    _ = config.setUrl("");

    try testing.expect(config.url != null);
    try testing.expectEqualStrings("", config.url.?);
}

test "Edge: notification with empty body" {
    const notification = zyte.Notification{
        .title = "Alert",
        .body = "",
        .icon = null,
    };

    try testing.expectEqualStrings("Alert", notification.title);
    try testing.expectEqualStrings("", notification.body);
    // Icon is null, so no need to test it
}

test "Edge: button with empty label" {
    const button = zyte.Components.Button{
        .label = "",
        .onClick = null,
    };

    try testing.expectEqualStrings("", button.label);
}

test "Edge: input with special characters in placeholder" {
    const input = zyte.Components.Input{
        .placeholder = "Enter <name> & \"email\"",
        .value = "",
    };

    try testing.expect(std.mem.eql(u8, "Enter <name> & \"email\"", input.placeholder));
}

test "Edge: container with no children" {
    const children = [_][]const u8{};
    const container = zyte.Components.Container{
        .children = &children,
    };

    const html = try container.toHtml(testing.allocator);
    defer testing.allocator.free(html);

    try testing.expect(std.mem.indexOf(u8, html, "container") != null);
}

test "Edge: multiple config changes on same object" {
    var config = zyte.ZyteConfig.init(testing.allocator);

    _ = config.setTitle("First");
    try testing.expectEqualStrings("First", config.title);

    _ = config.setTitle("Second");
    try testing.expectEqualStrings("Second", config.title);

    _ = config.setTitle("Third");
    try testing.expectEqualStrings("Third", config.title);
}

test "Edge: toggle boolean flags" {
    var config = zyte.ZyteConfig.init(testing.allocator);

    _ = config.setDarkMode(true);
    try testing.expectEqual(true, config.dark_mode);

    _ = config.setDarkMode(false);
    try testing.expectEqual(false, config.dark_mode);

    _ = config.setDarkMode(true);
    try testing.expectEqual(true, config.dark_mode);
}
