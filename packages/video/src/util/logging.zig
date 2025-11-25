// Home Video Library - Logging System
// Structured logging with levels, formatters, and multiple outputs

const std = @import("std");

/// Log level
pub const LogLevel = enum(u8) {
    trace = 0,
    debug = 1,
    info = 2,
    warn = 3,
    err = 4,
    fatal = 5,

    pub fn toString(self: LogLevel) []const u8 {
        return switch (self) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
            .fatal => "FATAL",
        };
    }

    pub fn toColor(self: LogLevel) []const u8 {
        return switch (self) {
            .trace => "\x1b[37m", // White
            .debug => "\x1b[36m", // Cyan
            .info => "\x1b[32m", // Green
            .warn => "\x1b[33m", // Yellow
            .err => "\x1b[31m", // Red
            .fatal => "\x1b[35m", // Magenta
        };
    }
};

/// Log entry
pub const LogEntry = struct {
    level: LogLevel,
    message: []const u8,
    timestamp: i64,
    file: []const u8,
    line: u32,
    function: []const u8,
    thread_id: ?std.Thread.Id = null,

    const Self = @This();

    pub fn format(
        self: *const Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("[{s}] {s}:{d} ({s}) - {s}", .{
            self.level.toString(),
            self.file,
            self.line,
            self.function,
            self.message,
        });
    }
};

/// Log output interface
pub const LogOutput = struct {
    writeFn: *const fn (*anyopaque, LogEntry) anyerror!void,
    ptr: *anyopaque,

    const Self = @This();

    pub fn write(self: Self, entry: LogEntry) !void {
        try self.writeFn(self.ptr, entry);
    }
};

/// Console output with colors
pub const ConsoleOutput = struct {
    use_colors: bool = true,
    mutex: std.Thread.Mutex = .{},

    const Self = @This();

    pub fn init(use_colors: bool) Self {
        return .{ .use_colors = use_colors };
    }

    pub fn output(self: *Self) LogOutput {
        return .{
            .ptr = self,
            .writeFn = write,
        };
    }

    fn write(ptr: *anyopaque, entry: LogEntry) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        const stderr = std.io.getStdErr().writer();

        if (self.use_colors) {
            try stderr.print("{s}[{s}] ", .{ entry.level.toColor(), entry.level.toString() });
            try stderr.print("\x1b[0m{s}:{d} ({s}) - {s}\n", .{
                entry.file,
                entry.line,
                entry.function,
                entry.message,
            });
        } else {
            try stderr.print("[{s}] {s}:{d} ({s}) - {s}\n", .{
                entry.level.toString(),
                entry.file,
                entry.line,
                entry.function,
                entry.message,
            });
        }
    }
};

/// File output
pub const FileOutput = struct {
    file: std.fs.File,
    mutex: std.Thread.Mutex = .{},
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Self {
        const file = try std.fs.cwd().createFile(path, .{ .truncate = false });
        try file.seekFromEnd(0);

        return .{
            .file = file,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.file.close();
    }

    pub fn output(self: *Self) LogOutput {
        return .{
            .ptr = self,
            .writeFn = write,
        };
    }

    fn write(ptr: *anyopaque, entry: LogEntry) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();

        const writer = self.file.writer();

        try writer.print("[{d}] [{s}] {s}:{d} ({s}) - {s}\n", .{
            entry.timestamp,
            entry.level.toString(),
            entry.file,
            entry.line,
            entry.function,
            entry.message,
        });
    }
};

/// Logger instance
pub const Logger = struct {
    outputs: std.ArrayList(LogOutput),
    min_level: LogLevel,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, min_level: LogLevel) Self {
        return .{
            .outputs = std.ArrayList(LogOutput).init(allocator),
            .min_level = min_level,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.outputs.deinit();
    }

    pub fn addOutput(self: *Self, output: LogOutput) !void {
        try self.outputs.append(output);
    }

    pub fn log(
        self: *Self,
        level: LogLevel,
        message: []const u8,
        file: []const u8,
        line: u32,
        function: []const u8,
    ) void {
        if (@intFromEnum(level) < @intFromEnum(self.min_level)) {
            return;
        }

        const entry = LogEntry{
            .level = level,
            .message = message,
            .timestamp = std.time.timestamp(),
            .file = file,
            .line = line,
            .function = function,
            .thread_id = std.Thread.getCurrentId(),
        };

        for (self.outputs.items) |output| {
            output.write(entry) catch |err| {
                std.debug.print("Failed to write log: {}\n", .{err});
            };
        }
    }

    pub fn trace(self: *Self, message: []const u8, src: std.builtin.SourceLocation) void {
        self.log(.trace, message, src.file, src.line, src.fn_name);
    }

    pub fn debug(self: *Self, message: []const u8, src: std.builtin.SourceLocation) void {
        self.log(.debug, message, src.file, src.line, src.fn_name);
    }

    pub fn info(self: *Self, message: []const u8, src: std.builtin.SourceLocation) void {
        self.log(.info, message, src.file, src.line, src.fn_name);
    }

    pub fn warn(self: *Self, message: []const u8, src: std.builtin.SourceLocation) void {
        self.log(.warn, message, src.file, src.line, src.fn_name);
    }

    pub fn err(self: *Self, message: []const u8, src: std.builtin.SourceLocation) void {
        self.log(.err, message, src.file, src.line, src.fn_name);
    }

    pub fn fatal(self: *Self, message: []const u8, src: std.builtin.SourceLocation) void {
        self.log(.fatal, message, src.file, src.line, src.fn_name);
    }

    pub fn setMinLevel(self: *Self, level: LogLevel) void {
        self.min_level = level;
    }
};

/// Global logger instance
var global_logger: ?*Logger = null;
var global_logger_mutex: std.Thread.Mutex = .{};

pub fn getGlobalLogger() ?*Logger {
    global_logger_mutex.lock();
    defer global_logger_mutex.unlock();
    return global_logger;
}

pub fn setGlobalLogger(logger: *Logger) void {
    global_logger_mutex.lock();
    defer global_logger_mutex.unlock();
    global_logger = logger;
}

/// Convenience macros
pub fn trace(message: []const u8) void {
    if (getGlobalLogger()) |logger| {
        logger.trace(message, @src());
    }
}

pub fn debug(message: []const u8) void {
    if (getGlobalLogger()) |logger| {
        logger.debug(message, @src());
    }
}

pub fn info(message: []const u8) void {
    if (getGlobalLogger()) |logger| {
        logger.info(message, @src());
    }
}

pub fn warn(message: []const u8) void {
    if (getGlobalLogger()) |logger| {
        logger.warn(message, @src());
    }
}

pub fn err(message: []const u8) void {
    if (getGlobalLogger()) |logger| {
        logger.err(message, @src());
    }
}

pub fn fatal(message: []const u8) void {
    if (getGlobalLogger()) |logger| {
        logger.fatal(message, @src());
    }
}

/// Scoped logger
pub fn ScopedLogger(comptime scope: []const u8) type {
    return struct {
        logger: *Logger,

        const Self = @This();

        pub fn init(logger: *Logger) Self {
            return .{ .logger = logger };
        }

        fn formatMessage(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
            return try std.fmt.allocPrint(allocator, "[{s}] {s}", .{ scope, message });
        }

        pub fn trace(self: *Self, message: []const u8, src: std.builtin.SourceLocation) void {
            const scoped_msg = formatMessage(self.logger.allocator, message) catch return;
            defer self.logger.allocator.free(scoped_msg);
            self.logger.trace(scoped_msg, src);
        }

        pub fn debug(self: *Self, message: []const u8, src: std.builtin.SourceLocation) void {
            const scoped_msg = formatMessage(self.logger.allocator, message) catch return;
            defer self.logger.allocator.free(scoped_msg);
            self.logger.debug(scoped_msg, src);
        }

        pub fn info(self: *Self, message: []const u8, src: std.builtin.SourceLocation) void {
            const scoped_msg = formatMessage(self.logger.allocator, message) catch return;
            defer self.logger.allocator.free(scoped_msg);
            self.logger.info(scoped_msg, src);
        }

        pub fn warn(self: *Self, message: []const u8, src: std.builtin.SourceLocation) void {
            const scoped_msg = formatMessage(self.logger.allocator, message) catch return;
            defer self.logger.allocator.free(scoped_msg);
            self.logger.warn(scoped_msg, src);
        }

        pub fn err(self: *Self, message: []const u8, src: std.builtin.SourceLocation) void {
            const scoped_msg = formatMessage(self.logger.allocator, message) catch return;
            defer self.logger.allocator.free(scoped_msg);
            self.logger.err(scoped_msg, src);
        }

        pub fn fatal(self: *Self, message: []const u8, src: std.builtin.SourceLocation) void {
            const scoped_msg = formatMessage(self.logger.allocator, message) catch return;
            defer self.logger.allocator.free(scoped_msg);
            self.logger.fatal(scoped_msg, src);
        }
    };
}
