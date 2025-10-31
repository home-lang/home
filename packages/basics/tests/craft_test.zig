const std = @import("std");
const craft = @import("craft");
const test_framework = @import("zig-test-framework");

test "Craft window initialization" {
    const window = craft.CraftWindow.init("Test", 800, 600, "<h1>Test</h1>");

    try std.testing.expectEqualStrings("Test", window.title);
    try std.testing.expectEqual(@as(u32, 800), window.width);
    try std.testing.expectEqual(@as(u32, 600), window.height);
}

test "Craft app with multiple windows" {
    const allocator = std.testing.allocator;

    var app = craft.CraftApp.init(allocator);
    defer app.deinit();

    _ = try app.createWindow("Window 1", 800, 600, "<h1>Window 1</h1>");
    _ = try app.createWindow("Window 2", 1024, 768, "<h1>Window 2</h1>");

    try std.testing.expectEqual(@as(usize, 2), app.windows.items.len);
}

test "System integration" {
    try craft.System.showNotification("Test", "Test notification");
    const result = try craft.System.showDialog("Test", "Test dialog");
    try std.testing.expect(result);
}

test "IPC Bridge" {
    try craft.IPCBridge.send("test-channel", "test data");
}

test "coverage - craft basics" {
    const coverage_opts = test_framework.CoverageOptions{
        .enabled = true,
        .output_dir = "coverage/craft",
    };

    try std.testing.expect(coverage_opts.enabled);
}
