// Simple Async I/O Example for Home
// TypeScript-like API

const std = @import("std");
const io = @import("io");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Home Async I/O Example ===\n\n", .{});

    // Example 1: Simple fs operations (like Node.js fs module)
    try example1_simple_fs(allocator);

    // Example 2: Using AsyncRuntime (like async/await)
    try example2_async_runtime(allocator);

    std.debug.print("\n✅ All examples completed!\n", .{});
}

/// Example 1: Simple TypeScript-like fs operations
fn example1_simple_fs(allocator: std.mem.Allocator) !void {
    std.debug.print("--- Example 1: fs module (TypeScript-like) ---\n", .{});

    const test_file = "/tmp/home_example1.txt";
    const test_data = "Hello from Home Language! 🏠";

    // Write file (like fs.writeFile in Node.js)
    try io.fs.writeFile(allocator, test_file, test_data);
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // Check if exists (like fs.existsSync)
    if (io.fs.exists(test_file)) {
        std.debug.print("✓ File exists\n", .{});
    }

    // Get file size
    const size = try io.fs.getSize(test_file);
    std.debug.print("✓ File size: {} bytes\n", .{size});

    // Read file (like fs.readFile)
    const data = try io.fs.readFile(allocator, test_file);
    defer allocator.free(data);

    std.debug.print("✓ File content: {s}\n\n", .{data});
}

/// Example 2: Using AsyncRuntime
fn example2_async_runtime(allocator: std.mem.Allocator) !void {
    std.debug.print("--- Example 2: AsyncRuntime ---\n", .{});

    // Initialize async runtime
    var runtime = io.AsyncRuntime.init(allocator);
    defer runtime.deinit();

    const test_file = "/tmp/home_example2.txt";
    const test_data = "AsyncRuntime is working! 🚀";

    // Write file
    try runtime.writeFile(test_file, test_data);
    defer std.fs.cwd().deleteFile(test_file) catch {};

    // Check existence
    if (runtime.fileExists(test_file)) {
        std.debug.print("✓ File exists (via runtime)\n", .{});
    }

    // Read file
    const data = try runtime.readFile(test_file);
    defer allocator.free(data);

    std.debug.print("✓ File content: {s}\n", .{data});
}
