const std = @import("std");

/// Discovers test files based on naming conventions
pub const TestFileDiscovery = struct {
    allocator: std.mem.Allocator,
    test_files: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) TestFileDiscovery {
        return .{
            .allocator = allocator,
            .test_files = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *TestFileDiscovery) void {
        for (self.test_files.items) |file| {
            self.allocator.free(file);
        }
        self.test_files.deinit();
    }

    /// Discovers test files in a directory and its subdirectories
    /// Looks for files matching: *.test.home, *.test.hm
    pub fn discoverInDirectory(self: *TestFileDiscovery, dir_path: []const u8) !void {
        var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
        defer dir.close();

        try self.walkDirectory(dir, dir_path);
    }

    fn walkDirectory(self: *TestFileDiscovery, dir: std.fs.Dir, dir_path: []const u8) !void {
        var iter = dir.iterate();

        while (try iter.next()) |entry| {
            switch (entry.kind) {
                .file => {
                    if (isTestFile(entry.name)) {
                        const full_path = try std.fs.path.join(
                            self.allocator,
                            &.{ dir_path, entry.name },
                        );
                        try self.test_files.append(full_path);
                    }
                },
                .directory => {
                    // Skip common non-test directories
                    if (shouldSkipDirectory(entry.name)) {
                        continue;
                    }

                    const subdir_path = try std.fs.path.join(
                        self.allocator,
                        &.{ dir_path, entry.name },
                    );
                    defer self.allocator.free(subdir_path);

                    var subdir = try dir.openDir(entry.name, .{ .iterate = true });
                    defer subdir.close();

                    try self.walkDirectory(subdir, subdir_path);
                },
                else => {},
            }
        }
    }

    /// Returns the list of discovered test files
    pub fn getTestFiles(self: *const TestFileDiscovery) []const []const u8 {
        return self.test_files.items;
    }

    /// Checks if a filename matches test file patterns
    fn isTestFile(filename: []const u8) bool {
        // Check for .test.home extension
        if (std.mem.endsWith(u8, filename, ".test.home")) {
            return true;
        }

        // Check for .test.hm extension
        if (std.mem.endsWith(u8, filename, ".test.hm")) {
            return true;
        }

        return false;
    }

    /// Checks if a directory should be skipped during discovery
    fn shouldSkipDirectory(dirname: []const u8) bool {
        const skip_dirs = [_][]const u8{
            "node_modules",
            ".git",
            ".zig-cache",
            "zig-out",
            "zig-cache",
            ".home",
            "target",
            "build",
            "dist",
            ".vscode",
            ".idea",
        };

        for (skip_dirs) |skip_dir| {
            if (std.mem.eql(u8, dirname, skip_dir)) {
                return true;
            }
        }

        return false;
    }
};

/// Prints discovered test files
pub fn printDiscoveredFiles(discovery: *const TestFileDiscovery, writer: anytype) !void {
    try writer.print("\n{s}Test File Discovery{s}\n", .{ "\x1b[1;36m", "\x1b[0m" });
    try writer.print("{s}Found {d} test file(s){s}\n\n", .{
        "\x1b[32m",
        discovery.test_files.items.len,
        "\x1b[0m",
    });

    if (discovery.test_files.items.len > 0) {
        for (discovery.test_files.items, 0..) |file, i| {
            try writer.print("  {d}. {s}{s}{s}\n", .{
                i + 1,
                "\x1b[33m",
                file,
                "\x1b[0m",
            });
        }
        try writer.print("\n", .{});
    }
}

// Tests
test "isTestFile detects .test.home files" {
    try std.testing.expect(TestFileDiscovery.isTestFile("my_feature.test.home"));
    try std.testing.expect(TestFileDiscovery.isTestFile("component.test.home"));
}

test "isTestFile detects .test.hm files" {
    try std.testing.expect(TestFileDiscovery.isTestFile("utils.test.hm"));
    try std.testing.expect(TestFileDiscovery.isTestFile("api.test.hm"));
}

test "isTestFile rejects non-test files" {
    try std.testing.expect(!TestFileDiscovery.isTestFile("regular.home"));
    try std.testing.expect(!TestFileDiscovery.isTestFile("file.hm"));
    try std.testing.expect(!TestFileDiscovery.isTestFile("test.txt"));
    try std.testing.expect(!TestFileDiscovery.isTestFile("mytest.home"));
}

test "shouldSkipDirectory skips common directories" {
    try std.testing.expect(TestFileDiscovery.shouldSkipDirectory("node_modules"));
    try std.testing.expect(TestFileDiscovery.shouldSkipDirectory(".git"));
    try std.testing.expect(TestFileDiscovery.shouldSkipDirectory("zig-out"));
    try std.testing.expect(!TestFileDiscovery.shouldSkipDirectory("src"));
    try std.testing.expect(!TestFileDiscovery.shouldSkipDirectory("tests"));
}
