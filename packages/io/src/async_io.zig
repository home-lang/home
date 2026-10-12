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
            .io_impl = std.Io.Threaded.init(allocator, .{}),
        };
    }

    /// Initialize with specific thread count
    pub fn initWithThreads(allocator: Allocator, thread_count: usize) AsyncRuntime {
        return .{
            .allocator = allocator,
            .io_impl = std.Io.Threaded.init(allocator, .{
                .async_limit = .limited(thread_count),
            }),
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

    /// Read file asynchronously (TypeScript-like API).
    /// Capped at 256 MiB so a malicious/huge file can't exhaust memory.
    pub fn readFile(self: *AsyncRuntime, path: []const u8) ![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(
            self.io(),
            path,
            self.allocator,
            .limited(256 * 1024 * 1024),
        );
    }

    /// Write file asynchronously (TypeScript-like API)
    pub fn writeFile(self: *AsyncRuntime, path: []const u8, data: []const u8) !void {
        const active_io = self.io();
        const file = try std.Io.Dir.cwd().createFile(active_io, path, .{});
        defer file.close(active_io);
        try file.writeStreamingAll(active_io, data);
    }

    /// Check if file exists
    pub fn fileExists(self: *AsyncRuntime, path: []const u8) bool {
        std.Io.Dir.cwd().access(self.io(), path, .{}) catch return false;
        return true;
    }
};

/// Simple async file operations (no runtime needed)
/// TypeScript-like fs module
pub const fs = struct {
    fn io() std.Io {
        return std.Io.Threaded.global_single_threaded.io();
    }

    /// Read file contents. Capped at 256 MiB to prevent runaway allocation.
    pub fn readFile(allocator: Allocator, path: []const u8) ![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(
            io(),
            path,
            allocator,
            .limited(256 * 1024 * 1024),
        );
    }

    /// Write file contents
    pub fn writeFile(_: Allocator, path: []const u8, data: []const u8) !void {
        const active_io = io();
        const file = try std.Io.Dir.cwd().createFile(active_io, path, .{});
        defer file.close(active_io);
        try file.writeStreamingAll(active_io, data);
    }

    /// Check if file exists
    pub fn exists(path: []const u8) bool {
        std.Io.Dir.cwd().access(io(), path, .{}) catch return false;
        return true;
    }

    /// Get file size
    pub fn getSize(path: []const u8) !u64 {
        const active_io = io();
        const file = try std.Io.Dir.cwd().openFile(active_io, path, .{});
        defer file.close(active_io);
        const stat = try file.stat(active_io);
        return stat.size;
    }
};

// Tests
test "fs.readFile and fs.writeFile" {
    const allocator = std.testing.allocator;

    const test_file = "home_async_test.txt";
    const test_data = "Hello from Home!";

    // Write
    try fs.writeFile(allocator, test_file, test_data);
    defer std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), test_file) catch {};

    // Read
    const data = try fs.readFile(allocator, test_file);
    defer allocator.free(data);

    try std.testing.expectEqualStrings(test_data, data);
}

test "fs.exists" {
    const test_file = "home_exists_test.txt";

    // Should not exist
    try std.testing.expect(!fs.exists(test_file));

    // Create it
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = try std.Io.Dir.cwd().createFile(io, test_file, .{});
    file.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, test_file) catch {};

    // Should exist
    try std.testing.expect(fs.exists(test_file));
}

test "AsyncRuntime basic operations" {
    const allocator = std.testing.allocator;

    var runtime = AsyncRuntime.init(allocator);
    defer runtime.deinit();

    const test_file = "home_runtime_test.txt";
    const test_data = "AsyncRuntime test";

    // Write
    try runtime.writeFile(test_file, test_data);
    defer std.Io.Dir.cwd().deleteFile(runtime.io(), test_file) catch {};

    // Read
    const data = try runtime.readFile(test_file);
    defer allocator.free(data);

    try std.testing.expectEqualStrings(test_data, data);
    try std.testing.expect(runtime.fileExists(test_file));
}
