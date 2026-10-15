const std = @import("std");
const craft = @import("craft");

fn tempPath(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, parts: []const []const u8) ![]u8 {
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);

    var all_parts = try allocator.alloc([]const u8, parts.len + 1);
    defer allocator.free(all_parts);
    all_parts[0] = root_buffer[0..root_len];
    @memcpy(all_parts[1..], parts);
    return std.fs.path.join(allocator, all_parts);
}

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

test "Craft path resolution prefers local, then global, then fallback" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(testing.io, "workspace/pantry_modules/craft/1.2.3/packages/zig");
    try tmp.dir.createDirPath(testing.io, "home/.local/share/pantry/global/packages/craft/2.0.0/packages/zig");

    const home = try tempPath(allocator, &tmp, &.{"home"});
    defer allocator.free(home);
    const workspace = try tempPath(allocator, &tmp, &.{"workspace"});
    defer allocator.free(workspace);
    const expected_local = try tempPath(allocator, &tmp, &.{ "workspace", "pantry_modules", "craft", "1.2.3", "packages", "zig" });
    defer allocator.free(expected_local);
    const expected_global = try tempPath(allocator, &tmp, &.{ "home", ".local", "share", "pantry", "global", "packages", "craft", "2.0.0", "packages", "zig" });
    defer allocator.free(expected_global);
    const expected_fallback = try tempPath(allocator, &tmp, &.{ "home", "Code", "craft", "packages", "zig" });
    defer allocator.free(expected_fallback);

    const local = try craft.resolveCraftPathFromRoots(allocator, testing.io, home, workspace);
    defer allocator.free(local);
    try testing.expectEqualStrings(expected_local, local);

    try tmp.dir.deleteTree(testing.io, "workspace/pantry_modules");
    const global = try craft.resolveCraftPathFromRoots(allocator, testing.io, home, workspace);
    defer allocator.free(global);
    try testing.expectEqualStrings(expected_global, global);

    try tmp.dir.deleteTree(testing.io, "home/.local/share/pantry/global/packages/craft");
    const fallback = try craft.resolveCraftPathFromRoots(allocator, testing.io, home, workspace);
    defer allocator.free(fallback);
    try testing.expectEqualStrings(expected_fallback, fallback);
}
