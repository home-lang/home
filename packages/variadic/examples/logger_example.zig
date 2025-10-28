// Example: Logger with different levels and formatting

const std = @import("std");
const variadic = @import("variadic");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Logger Example ===\n\n", .{});

    // Create logger with colors and timestamps
    var logger = variadic.logger.Logger.init(allocator, .{
        .min_level = .Debug,
        .use_colors = true,
        .show_timestamp = true,
        .show_source = false,
    });

    // Log at different levels
    try logger.debug("Starting application", .{});
    try logger.info("Server listening on port %d", .{@as(u16, 8080)});
    try logger.warn("Cache miss for key '%s'", .{"user:123"});
    try logger.err("Failed to connect to database: error %d", .{@as(i32, -1)});
    try logger.fatal("Out of memory! Requested %d bytes", .{@as(usize, 1024 * 1024 * 1024)});

    // Simulate a request
    std.debug.print("\nSimulating HTTP Request:\n", .{});
    const method = "GET";
    const path = "/api/users";
    const status = @as(u16, 200);
    const duration_ms = @as(u32, 45);

    try logger.info("Request: %s %s - Status: %d - Duration: %dms", .{
        method,
        path,
        status,
        duration_ms,
    });

    // Different log levels filtered
    std.debug.print("\nFiltered Logging (min_level = Warn):\n", .{});
    var filtered_logger = variadic.logger.Logger.init(allocator, .{
        .min_level = .Warn,
        .use_colors = true,
        .show_timestamp = false,
    });

    try filtered_logger.debug("This won't appear", .{});
    try filtered_logger.info("This won't appear either", .{});
    try filtered_logger.warn("This will appear!", .{});
    try filtered_logger.err("This will appear too!", .{});

    // Structured logging
    std.debug.print("\nStructured Logging:\n", .{});
    const user_id = @as(u64, 12345);
    const session_id = "abc-def-ghi";
    const action = "login";

    try logger.info("User action: user_id=%d session_id=%s action=%s", .{
        user_id,
        session_id,
        action,
    });

    // Performance logging
    std.debug.print("\nPerformance Logging:\n", .{});
    const query = "SELECT * FROM users";
    const rows = @as(u32, 1500);
    const query_time_ms = @as(u32, 23);

    try logger.debug("Query executed: '%s' - Rows: %d - Time: %dms", .{
        query,
        rows,
        query_time_ms,
    });

    // Error with context
    std.debug.print("\nError with Context:\n", .{});
    const filename = "/etc/config.json";
    const errno = @as(i32, 2); // ENOENT

    try logger.err("Failed to open file '%s': errno=%d (No such file or directory)", .{
        filename,
        errno,
    });
}
