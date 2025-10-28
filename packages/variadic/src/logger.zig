// Home Programming Language - Logger Implementation
// Variadic logging with levels and formatting

const std = @import("std");
const printf_mod = @import("printf.zig");

// ============================================================================
// Log Levels
// ============================================================================

pub const LogLevel = enum(u8) {
    Debug = 0,
    Info = 1,
    Warn = 2,
    Error = 3,
    Fatal = 4,

    pub fn toString(self: LogLevel) []const u8 {
        return switch (self) {
            .Debug => "DEBUG",
            .Info => "INFO",
            .Warn => "WARN",
            .Error => "ERROR",
            .Fatal => "FATAL",
        };
    }

    pub fn color(self: LogLevel) []const u8 {
        return switch (self) {
            .Debug => "\x1b[36m", // Cyan
            .Info => "\x1b[32m",  // Green
            .Warn => "\x1b[33m",  // Yellow
            .Error => "\x1b[31m", // Red
            .Fatal => "\x1b[35m", // Magenta
        };
    }
};

// ============================================================================
// Logger Configuration
// ============================================================================

pub const LoggerConfig = struct {
    min_level: LogLevel = .Debug,
    use_colors: bool = true,
    show_timestamp: bool = true,
    show_source: bool = true,
    writer: ?std.io.AnyWriter = null,
};

// ============================================================================
// Logger
// ============================================================================

pub const Logger = struct {
    config: LoggerConfig,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: LoggerConfig) Logger {
        return .{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn log(
        self: *Logger,
        level: LogLevel,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        if (@intFromEnum(level) < @intFromEnum(self.config.min_level)) {
            return;
        }

        // Skip if no writer provided (for testing)
        if (self.config.writer == null) {
            return;
        }
        const writer = self.config.writer.?;

        // Write level with color
        if (self.config.use_colors) {
            try writer.writeAll(level.color());
        }

        try writer.print("[{s}]", .{level.toString()});

        if (self.config.use_colors) {
            try writer.writeAll("\x1b[0m"); // Reset
        }

        // Write timestamp
        if (self.config.show_timestamp) {
            const timestamp = std.time.timestamp();
            try writer.print(" {d}", .{timestamp});
        }

        try writer.writeAll(": ");

        // Write formatted message
        _ = try printf_mod.fprintf(writer, fmt, args);

        try writer.writeByte('\n');
    }

    pub fn debug(self: *Logger, comptime fmt: []const u8, args: anytype) !void {
        try self.log(.Debug, fmt, args);
    }

    pub fn info(self: *Logger, comptime fmt: []const u8, args: anytype) !void {
        try self.log(.Info, fmt, args);
    }

    pub fn warn(self: *Logger, comptime fmt: []const u8, args: anytype) !void {
        try self.log(.Warn, fmt, args);
    }

    pub fn err(self: *Logger, comptime fmt: []const u8, args: anytype) !void {
        try self.log(.Error, fmt, args);
    }

    pub fn fatal(self: *Logger, comptime fmt: []const u8, args: anytype) !void {
        try self.log(.Fatal, fmt, args);
    }
};

// ============================================================================
// Global Logger
// ============================================================================

var global_logger: ?Logger = null;
var global_mutex = std.Thread.Mutex{};

pub fn initGlobal(allocator: std.mem.Allocator, config: LoggerConfig) void {
    global_mutex.lock();
    defer global_mutex.unlock();

    global_logger = Logger.init(allocator, config);
}

pub fn getGlobal() ?*Logger {
    global_mutex.lock();
    defer global_mutex.unlock();

    if (global_logger) |*logger| {
        return logger;
    }
    return null;
}

pub fn debug(comptime fmt: []const u8, args: anytype) !void {
    if (getGlobal()) |logger| {
        try logger.debug(fmt, args);
    }
}

pub fn info(comptime fmt: []const u8, args: anytype) !void {
    if (getGlobal()) |logger| {
        try logger.info(fmt, args);
    }
}

pub fn warn(comptime fmt: []const u8, args: anytype) !void {
    if (getGlobal()) |logger| {
        try logger.warn(fmt, args);
    }
}

pub fn err(comptime fmt: []const u8, args: anytype) !void {
    if (getGlobal()) |logger| {
        try logger.err(fmt, args);
    }
}

pub fn fatal(comptime fmt: []const u8, args: anytype) !void {
    if (getGlobal()) |logger| {
        try logger.fatal(fmt, args);
    }
}

// ============================================================================
// Tests
// ============================================================================

test "log levels" {
    const testing = std.testing;

    try testing.expectEqual(@as(u8, 0), @intFromEnum(LogLevel.Debug));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(LogLevel.Info));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(LogLevel.Warn));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(LogLevel.Error));
    try testing.expectEqual(@as(u8, 4), @intFromEnum(LogLevel.Fatal));
}

test "log level to string" {
    const testing = std.testing;

    try testing.expect(std.mem.eql(u8, "DEBUG", LogLevel.Debug.toString()));
    try testing.expect(std.mem.eql(u8, "INFO", LogLevel.Info.toString()));
    try testing.expect(std.mem.eql(u8, "WARN", LogLevel.Warn.toString()));
    try testing.expect(std.mem.eql(u8, "ERROR", LogLevel.Error.toString()));
    try testing.expect(std.mem.eql(u8, "FATAL", LogLevel.Fatal.toString()));
}

test "logger basic" {
    const testing = std.testing;

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var logger = Logger.init(testing.allocator, .{
        .min_level = .Debug,
        .use_colors = false,
        .show_timestamp = false,
        .writer = fbs.writer().any(),
    });

    try logger.info("Test message", .{});

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "[INFO]") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Test message") != null);
}

test "logger with args" {
    const testing = std.testing;

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var logger = Logger.init(testing.allocator, .{
        .use_colors = false,
        .show_timestamp = false,
        .writer = fbs.writer().any(),
    });

    try logger.info("Value: %d", .{@as(i32, 42)});

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "Value: 42") != null);
}

test "logger min level" {
    const testing = std.testing;

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    var logger = Logger.init(testing.allocator, .{
        .min_level = .Warn,
        .use_colors = false,
        .show_timestamp = false,
        .writer = fbs.writer().any(),
    });

    // Should not log (below min level)
    try logger.debug("Debug message", .{});
    try logger.info("Info message", .{});

    // Should log (at or above min level)
    try logger.warn("Warn message", .{});

    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "Debug") == null);
    try testing.expect(std.mem.indexOf(u8, output, "Info") == null);
    try testing.expect(std.mem.indexOf(u8, output, "Warn") != null);
}
