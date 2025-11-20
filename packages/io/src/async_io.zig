// TypeScript-like Async I/O for Home Language
// Built on Zig 0.16.0-dev std.Io API
//
// Simple, familiar API inspired by TypeScript/Node.js

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Async Runtime - manages I/O operations
pub const AsyncRuntime = struct {
    allocator: Allocator,
    io_impl: std.Io.Threaded,

    /// Initialize the async runtime
    pub fn init(allocator: Allocator) AsyncRuntime {
        return .{
            .allocator = allocator,
            .io_impl = std.Io.Threaded.init(allocator),
        };
    }

    /// Initialize with specific thread count
    pub fn initWithThreads(allocator: Allocator, thread_count: usize) AsyncRuntime {
        var io_impl = std.Io.Threaded.init(allocator);
        io_impl.cpu_count = thread_count;
        return .{
            .allocator = allocator,
            .io_impl = io_impl,
        };
    }

    /// Cleanup resources
    pub fn deinit(self: *AsyncRuntime) void {
        self.io_impl.deinit();
    }

    /// Get the I/O interface
    pub fn io(self: *AsyncRuntime) std.Io {
        return self.io_impl.io();
    }

    /// Read file asynchronously (TypeScript-like API)
    pub fn readFile(self: *AsyncRuntime, path: []const u8) ![]u8 {
        return try std.fs.cwd().readFileAlloc(path, self.allocator, .unlimited);
    }

    /// Write file asynchronously (TypeScript-like API)
    pub fn writeFile(_: *AsyncRuntime, path: []const u8, data: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(data);
    }

    /// Check if file exists
    pub fn fileExists(self: *AsyncRuntime, path: []const u8) bool {
        _ = self;
        std.fs.cwd().access(path, .{}) catch return false;
        return true;
    }
};

/// Simple async file operations (no runtime needed)
/// TypeScript-like fs module
pub const fs = struct {
    /// Read file contents
    pub fn readFile(allocator: Allocator, path: []const u8) ![]u8 {
        return try std.fs.cwd().readFileAlloc(path, allocator, .unlimited);
    }

    /// Write file contents
    pub fn writeFile(_: Allocator, path: []const u8, data: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(data);
    }

    /// Check if file exists
    pub fn exists(path: []const u8) bool {
        std.fs.cwd().access(path, .{}) catch return false;
        return true;
    }

    /// Get file size
    pub fn getSize(path: []const u8) !u64 {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const stat = try file.stat();
        return stat.size;
    }
};

// Tests
test "fs.readFile and fs.writeFile" {
    const allocator = std.testing.allocator;

    const test_file = "/tmp/home_async_test.txt";
    const test_data = "Hello from Home!";

    // Write
    try fs.writeFile(allocator, test_file, test_data);
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // Read
    const data = try fs.readFile(allocator, test_file);
    defer allocator.free(data);

    try std.testing.expectEqualStrings(test_data, data);
}

test "fs.exists" {
    const test_file = "/tmp/home_exists_test.txt";

    // Should not exist
    try std.testing.expect(!fs.exists(test_file));

    // Create it
    const file = try std.fs.cwd().createFile(test_file, .{});
    file.close();
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // Should exist
    try std.testing.expect(fs.exists(test_file));
}

test "AsyncRuntime basic operations" {
    const allocator = std.testing.allocator;

    var runtime = AsyncRuntime.init(allocator);
    defer runtime.deinit();

    const test_file = "/tmp/home_runtime_test.txt";
    const test_data = "AsyncRuntime test";

    // Write
    try runtime.writeFile(test_file, test_data);
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // Read
    const data = try runtime.readFile(test_file);
    defer allocator.free(data);

    try std.testing.expectEqualStrings(test_data, data);
    try std.testing.expect(runtime.fileExists(test_file));
}
