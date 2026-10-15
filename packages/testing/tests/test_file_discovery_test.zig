const std = @import("std");
const discovery = @import("test_file_discovery");

const TestFileDiscovery = discovery.TestFileDiscovery;

fn containsSuffix(files: []const []const u8, suffix: []const u8) bool {
    for (files) |file| {
        if (std.mem.endsWith(u8, file, suffix)) return true;
    }
    return false;
}

fn populateFixture(tmp: *std.testing.TmpDir) !void {
    try tmp.dir.createDirPath(std.testing.io, "src/nested");
    try tmp.dir.createDirPath(std.testing.io, "node_modules/dependency");
    try tmp.dir.createDirPath(std.testing.io, ".git/objects");
    try tmp.dir.createDirPath(std.testing.io, "build/generated");

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "root.test.home", .data = "test root" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/component.test.hm", .data = "test component" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/nested/deep.test.home", .data = "test deep" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/not-a-test.home", .data = "ignored" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "node_modules/dependency/ignored.test.home", .data = "ignored" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".git/objects/ignored.test.hm", .data = "ignored" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build/generated/ignored.test.home", .data = "ignored" });
}

test "discovery recursively finds test files and skips generated trees" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try populateFixture(&tmp);

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    var files = TestFileDiscovery.initWithIo(std.testing.allocator, std.testing.io);
    defer files.deinit();
    try files.discoverInDirectory(root);

    const found = files.getTestFiles();
    try std.testing.expectEqual(@as(usize, 3), found.len);
    try std.testing.expect(containsSuffix(found, "root.test.home"));
    try std.testing.expect(containsSuffix(found, "component.test.hm"));
    try std.testing.expect(containsSuffix(found, "deep.test.home"));
}

const AllocationContext = struct {
    io: std.Io,
    root: []const u8,
};

fn discoverWithAllocator(allocator: std.mem.Allocator, context: AllocationContext) !void {
    var files = TestFileDiscovery.initWithIo(allocator, context.io);
    defer files.deinit();
    try files.discoverInDirectory(context.root);
    try std.testing.expectEqual(@as(usize, 3), files.getTestFiles().len);
}

test "discovery releases every path on allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try populateFixture(&tmp);

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        discoverWithAllocator,
        .{AllocationContext{ .io = std.testing.io, .root = root }},
    );
}

test "discovery reports a missing root" {
    var files = TestFileDiscovery.initWithIo(std.testing.allocator, std.testing.io);
    defer files.deinit();
    try std.testing.expectError(
        error.FileNotFound,
        files.discoverInDirectory("does-not-exist-home-test-discovery"),
    );
}
