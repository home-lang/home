const std = @import("std");
const posix = std.posix;
const fs = std.fs;

/// Log levels
pub const Level = enum(u8) {
    trace = 0,
    debug = 1,
    info = 2,
    warn = 3,
    err = 4,
    fatal = 5,

    pub fn toString(self: Level) []const u8 {
        return switch (self) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
            .fatal => "FATAL",
        };
    }

    pub fn toColor(self: Level) []const u8 {
        return switch (self) {
            .trace => "\x1b[90m", // Gray
            .debug => "\x1b[36m", // Cyan
            .info => "\x1b[32m", // Green
            .warn => "\x1b[33m", // Yellow
            .err => "\x1b[31m", // Red
            .fatal => "\x1b[35m", // Magenta
        };
    }
};

/// Structured log field
pub const Field = struct {
    key: []const u8,
    value: Value,

    pub const Value = union(enum) {
        string: []const u8,
        int: i64,
        uint: u64,
        float: f64,
        boolean: bool,
        null_val: void,
    };

    pub fn string(key: []const u8, value: []const u8) Field {
        return .{ .key = key, .value = .{ .string = value } };
    }

    pub fn int(key: []const u8, value: i64) Field {
        return .{ .key = key, .value = .{ .int = value } };
    }

    pub fn uint(key: []const u8, value: u64) Field {
        return .{ .key = key, .value = .{ .uint = value } };
    }

    pub fn float(key: []const u8, value: f64) Field {
        return .{ .key = key, .value = .{ .float = value } };
    }

    pub fn boolean(key: []const u8, value: bool) Field {
        return .{ .key = key, .value = .{ .boolean = value } };
    }

    pub fn @"null"(key: []const u8) Field {
        return .{ .key = key, .value = .{ .null_val = {} } };
    }

    pub fn formatValue(self: Field, writer: anytype) !void {
        switch (self.value) {
            .string => |s| try writer.print("\"{s}\"", .{s}),
            .int => |i| try writer.print("{d}", .{i}),
            .uint => |u| try writer.print("{d}", .{u}),
            .float => |f| try writer.print("{d:.6}", .{f}),
            .boolean => |b| try writer.print("{}", .{b}),
            .null_val => try writer.writeAll("null"),
        }
    }
};

/// Log record
pub const Record = struct {
    level: Level,
    message: []const u8,
    timestamp: i64,
    fields: []const Field,
    logger_name: ?[]const u8 = null,
};

/// Output handler interface
pub const Handler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        write: *const fn (ptr: *anyopaque, record: Record) anyerror!void,
        flush: *const fn (ptr: *anyopaque) anyerror!void,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn write(self: Handler, record: Record) !void {
        return self.vtable.write(self.ptr, record);
    }

    pub fn flush(self: Handler) !void {
        return self.vtable.flush(self.ptr);
    }

    pub fn deinit(self: Handler) void {
        self.vtable.deinit(self.ptr);
    }
};

/// Console handler with optional colors
pub const ConsoleHandler = struct {
    allocator: std.mem.Allocator,
    use_colors: bool,
    use_stderr: bool,
    min_level: Level,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .use_colors = true,
            .use_stderr = false,
            .min_level = .trace,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }

    pub fn handler(self: *Self) Handler {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn write(ptr: *anyopaque, record: Record) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        if (@intFromEnum(record.level) < @intFromEnum(self.min_level)) {
            return;
        }

        const writer = if (self.use_stderr) std.io.getStdErr().writer() else std.io.getStdOut().writer();

        // Format: [LEVEL] timestamp message {fields}
        if (self.use_colors) {
            try writer.print("{s}[{s}]\x1b[0m ", .{ record.level.toColor(), record.level.toString() });
        } else {
            try writer.print("[{s}] ", .{record.level.toString()});
        }

        // Timestamp
        const dt = timestampToDateTime(record.timestamp);
        try writer.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} ", .{
            dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second,
        });

        // Logger name
        if (record.logger_name) |name| {
            try writer.print("[{s}] ", .{name});
        }

        // Message
        try writer.print("{s}", .{record.message});

        // Fields
        if (record.fields.len > 0) {
            try writer.writeAll(" {");
            for (record.fields, 0..) |field, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("{s}=", .{field.key});
                try field.formatValue(writer);
            }
            try writer.writeAll("}");
        }

        try writer.writeAll("\n");
    }

    fn flush(_: *anyopaque) anyerror!void {
        // Console is auto-flushed
    }

    fn deinitFn(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    const vtable = Handler.VTable{
        .write = write,
        .flush = flush,
        .deinit = deinitFn,
    };
};

/// JSON handler for structured logging
pub const JsonHandler = struct {
    allocator: std.mem.Allocator,
    writer: std.fs.File.Writer,
    min_level: Level,
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, file: std.fs.File) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .writer = file.writer(),
            .min_level = .trace,
            .mutex = .{},
        };
        return self;
    }

    pub fn initStdout(allocator: std.mem.Allocator) !*Self {
        return init(allocator, std.io.getStdOut());
    }

    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }

    pub fn handler(self: *Self) Handler {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn write(ptr: *anyopaque, record: Record) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        if (@intFromEnum(record.level) < @intFromEnum(self.min_level)) {
            return;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        const dt = timestampToDateTime(record.timestamp);

        try self.writer.writeAll("{");
        try self.writer.print("\"level\":\"{s}\",", .{record.level.toString()});
        try self.writer.print("\"timestamp\":\"{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z\",", .{
            dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second,
        });

        if (record.logger_name) |name| {
            try self.writer.print("\"logger\":\"{s}\",", .{name});
        }

        try self.writer.print("\"message\":\"{s}\"", .{record.message});

        for (record.fields) |field| {
            try self.writer.print(",\"{s}\":", .{field.key});
            try field.formatValue(self.writer);
        }

        try self.writer.writeAll("}\n");
    }

    fn flush(ptr: *anyopaque) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();
        // File writers are typically buffered, but std doesn't expose flush
    }

    fn deinitFn(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    const vtable = Handler.VTable{
        .write = write,
        .flush = flush,
        .deinit = deinitFn,
    };
};

/// File handler with optional rotation
pub const FileHandler = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    path: []const u8,
    min_level: Level,
    mutex: std.Thread.Mutex,
    max_size: ?u64 = null,
    current_size: u64 = 0,
    rotate_count: u8 = 5,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !*Self {
        const file = try std.fs.cwd().createFile(path, .{ .truncate = false });

        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .file = file,
            .path = try allocator.dupe(u8, path),
            .min_level = .trace,
            .mutex = .{},
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.file.close();
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    pub fn handler(self: *Self) Handler {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    pub fn setMaxSize(self: *Self, max_bytes: u64) void {
        self.max_size = max_bytes;
    }

    fn write(ptr: *anyopaque, record: Record) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        if (@intFromEnum(record.level) < @intFromEnum(self.min_level)) {
            return;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        const writer = self.file.writer();

        // Format log line
        const dt = timestampToDateTime(record.timestamp);

        var line_len: u64 = 0;

        // Write and count bytes
        const level_str = record.level.toString();
        try writer.print("[{s}] {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} ", .{
            level_str, dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second,
        });
        line_len += 30 + level_str.len;

        if (record.logger_name) |name| {
            try writer.print("[{s}] ", .{name});
            line_len += name.len + 3;
        }

        try writer.print("{s}", .{record.message});
        line_len += record.message.len;

        if (record.fields.len > 0) {
            try writer.writeAll(" {");
            for (record.fields, 0..) |field, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("{s}=", .{field.key});
                try field.formatValue(writer);
            }
            try writer.writeAll("}");
        }

        try writer.writeAll("\n");
        line_len += 1;

        self.current_size += line_len;

        // Check rotation
        if (self.max_size) |max| {
            if (self.current_size >= max) {
                try self.rotate();
            }
        }
    }

    fn rotate(self: *Self) !void {
        self.file.close();

        // Rotate files: log.4 -> log.5, log.3 -> log.4, etc.
        var i: u8 = self.rotate_count;
        while (i > 0) : (i -= 1) {
            var old_buf: [256]u8 = undefined;
            var new_buf: [256]u8 = undefined;

            const old_name = if (i == 1)
                self.path
            else blk: {
                const old_suffix = std.fmt.bufPrint(&old_buf, "{s}.{d}", .{ self.path, i - 1 }) catch continue;
                break :blk old_suffix;
            };

            const new_name = std.fmt.bufPrint(&new_buf, "{s}.{d}", .{ self.path, i }) catch continue;

            std.fs.cwd().rename(old_name, new_name) catch {};
        }

        // Create new file
        self.file = try std.fs.cwd().createFile(self.path, .{ .truncate = true });
        self.current_size = 0;
    }

    fn flush(ptr: *anyopaque) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.file.sync();
    }

    fn deinitFn(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    const vtable = Handler.VTable{
        .write = write,
        .flush = flush,
        .deinit = deinitFn,
    };
};

/// Memory handler for testing
pub const MemoryHandler = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayListUnmanaged(StoredRecord),
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub const StoredRecord = struct {
        level: Level,
        message: []const u8,
        timestamp: i64,
        logger_name: ?[]const u8,
    };

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .records = .empty,
            .mutex = .{},
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.records.items) |rec| {
            self.allocator.free(rec.message);
            if (rec.logger_name) |n| self.allocator.free(n);
        }
        self.records.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn handler(self: *Self) Handler {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    pub fn getRecords(self: *Self) []const StoredRecord {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.records.items;
    }

    pub fn clear(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.records.items) |rec| {
            self.allocator.free(rec.message);
            if (rec.logger_name) |n| self.allocator.free(n);
        }
        self.records.clearRetainingCapacity();
    }

    fn write(ptr: *anyopaque, record: Record) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.records.append(self.allocator, .{
            .level = record.level,
            .message = try self.allocator.dupe(u8, record.message),
            .timestamp = record.timestamp,
            .logger_name = if (record.logger_name) |n| try self.allocator.dupe(u8, n) else null,
        });
    }

    fn flush(_: *anyopaque) anyerror!void {}

    fn deinitFn(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    const vtable = Handler.VTable{
        .write = write,
        .flush = flush,
        .deinit = deinitFn,
    };
};

/// Logger
pub const Logger = struct {
    allocator: std.mem.Allocator,
    name: ?[]const u8,
    handlers: std.ArrayListUnmanaged(Handler),
    min_level: Level,
    parent: ?*Logger = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, name: ?[]const u8) Self {
        return .{
            .allocator = allocator,
            .name = name,
            .handlers = .empty,
            .min_level = .trace,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.handlers.items) |h| {
            h.deinit();
        }
        self.handlers.deinit(self.allocator);
    }

    pub fn addHandler(self: *Self, h: Handler) !void {
        try self.handlers.append(self.allocator, h);
    }

    pub fn setLevel(self: *Self, level: Level) void {
        self.min_level = level;
    }

    fn getTimestamp() i64 {
        const ts = posix.clock_gettime(.REALTIME) catch return 0;
        return ts.sec;
    }

    pub fn log(self: *Self, level: Level, message: []const u8, fields: []const Field) void {
        if (@intFromEnum(level) < @intFromEnum(self.min_level)) {
            return;
        }

        const record = Record{
            .level = level,
            .message = message,
            .timestamp = getTimestamp(),
            .fields = fields,
            .logger_name = self.name,
        };

        for (self.handlers.items) |h| {
            h.write(record) catch {};
        }

        // Propagate to parent
        if (self.parent) |p| {
            for (p.handlers.items) |h| {
                h.write(record) catch {};
            }
        }
    }

    // Convenience methods
    pub fn trace(self: *Self, message: []const u8) void {
        self.log(.trace, message, &.{});
    }

    pub fn debug(self: *Self, message: []const u8) void {
        self.log(.debug, message, &.{});
    }

    pub fn info(self: *Self, message: []const u8) void {
        self.log(.info, message, &.{});
    }

    pub fn warn(self: *Self, message: []const u8) void {
        self.log(.warn, message, &.{});
    }

    pub fn err(self: *Self, message: []const u8) void {
        self.log(.err, message, &.{});
    }

    pub fn fatal(self: *Self, message: []const u8) void {
        self.log(.fatal, message, &.{});
    }

    // With fields
    pub fn traceWith(self: *Self, message: []const u8, fields: []const Field) void {
        self.log(.trace, message, fields);
    }

    pub fn debugWith(self: *Self, message: []const u8, fields: []const Field) void {
        self.log(.debug, message, fields);
    }

    pub fn infoWith(self: *Self, message: []const u8, fields: []const Field) void {
        self.log(.info, message, fields);
    }

    pub fn warnWith(self: *Self, message: []const u8, fields: []const Field) void {
        self.log(.warn, message, fields);
    }

    pub fn errWith(self: *Self, message: []const u8, fields: []const Field) void {
        self.log(.err, message, fields);
    }

    pub fn fatalWith(self: *Self, message: []const u8, fields: []const Field) void {
        self.log(.fatal, message, fields);
    }

    pub fn flush(self: *Self) void {
        for (self.handlers.items) |h| {
            h.flush() catch {};
        }
    }

    /// Create a child logger
    pub fn child(self: *Self, name: []const u8) Self {
        var c = Logger.init(self.allocator, name);
        c.parent = self;
        c.min_level = self.min_level;
        return c;
    }
};

/// Global default logger
var global_logger: ?*Logger = null;
var global_mutex: std.Thread.Mutex = .{};

pub fn getGlobalLogger() ?*Logger {
    global_mutex.lock();
    defer global_mutex.unlock();
    return global_logger;
}

pub fn setGlobalLogger(logger: *Logger) void {
    global_mutex.lock();
    defer global_mutex.unlock();
    global_logger = logger;
}

// Helper: timestamp to date/time
const DateTime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

fn timestampToDateTime(timestamp: i64) DateTime {
    var remaining = timestamp;

    const second: u8 = @intCast(@mod(remaining, 60));
    remaining = @divTrunc(remaining, 60);
    const minute: u8 = @intCast(@mod(remaining, 60));
    remaining = @divTrunc(remaining, 60);
    const hour: u8 = @intCast(@mod(remaining, 24));
    remaining = @divTrunc(remaining, 24);

    var days = remaining;
    var year: u16 = 1970;
    while (true) {
        const days_in_year: i64 = if (isLeapYear(year)) 366 else 365;
        if (days < days_in_year) break;
        days -= days_in_year;
        year += 1;
    }

    const days_in_months = if (isLeapYear(year))
        [_]u8{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    else
        [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    var month: u8 = 1;
    for (days_in_months) |dim| {
        if (days < dim) break;
        days -= dim;
        month += 1;
    }

    return .{
        .year = year,
        .month = month,
        .day = @intCast(days + 1),
        .hour = hour,
        .minute = minute,
        .second = second,
    };
}

fn isLeapYear(year: u16) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
}

// Tests
test "log levels" {
    try std.testing.expectEqualStrings("DEBUG", Level.debug.toString());
    try std.testing.expectEqualStrings("ERROR", Level.err.toString());
}

test "field creation" {
    const f1 = Field.string("name", "test");
    try std.testing.expectEqualStrings("name", f1.key);

    const f2 = Field.int("count", 42);
    try std.testing.expectEqual(@as(i64, 42), f2.value.int);

    const f3 = Field.boolean("enabled", true);
    try std.testing.expect(f3.value.boolean);
}

test "memory handler" {
    const allocator = std.testing.allocator;

    const mem_handler = try MemoryHandler.init(allocator);

    var logger = Logger.init(allocator, "test");
    defer logger.deinit();

    try logger.addHandler(mem_handler.handler());

    logger.info("Hello");
    logger.warn("Warning message");
    logger.errWith("Error occurred", &.{
        Field.string("code", "E001"),
        Field.int("line", 42),
    });

    const records = mem_handler.getRecords();
    try std.testing.expectEqual(@as(usize, 3), records.len);
    try std.testing.expectEqual(Level.info, records[0].level);
    try std.testing.expectEqualStrings("Hello", records[0].message);
    try std.testing.expectEqual(Level.warn, records[1].level);
    try std.testing.expectEqual(Level.err, records[2].level);
}

test "log level filtering" {
    const allocator = std.testing.allocator;

    const mem_handler = try MemoryHandler.init(allocator);

    var logger = Logger.init(allocator, null);
    defer logger.deinit();

    try logger.addHandler(mem_handler.handler());
    logger.setLevel(.warn);

    logger.debug("Debug message"); // Should be filtered
    logger.info("Info message"); // Should be filtered
    logger.warn("Warn message"); // Should pass
    logger.err("Error message"); // Should pass

    const records = mem_handler.getRecords();
    try std.testing.expectEqual(@as(usize, 2), records.len);
    try std.testing.expectEqual(Level.warn, records[0].level);
    try std.testing.expectEqual(Level.err, records[1].level);
}

test "child logger" {
    const allocator = std.testing.allocator;

    const mem_handler = try MemoryHandler.init(allocator);

    var parent = Logger.init(allocator, "parent");
    defer parent.deinit();

    try parent.addHandler(mem_handler.handler());

    var child_logger = parent.child("child");
    defer child_logger.deinit();

    child_logger.info("Child message");

    const records = mem_handler.getRecords();
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqualStrings("child", records[0].logger_name.?);
}

test "timestamp to datetime" {
    // Jan 1, 2024 00:00:00 UTC
    const dt = timestampToDateTime(1704067200);
    try std.testing.expectEqual(@as(u16, 2024), dt.year);
    try std.testing.expectEqual(@as(u8, 1), dt.month);
    try std.testing.expectEqual(@as(u8, 1), dt.day);
    try std.testing.expectEqual(@as(u8, 0), dt.hour);
}
