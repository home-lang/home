// Home Video Library - Error Handling
// Comprehensive error types and error context tracking

const std = @import("std");
const core = @import("../core.zig");

/// Video library error set
pub const VideoError = error{
    // File I/O errors
    FileNotFound,
    FileReadError,
    FileWriteError,
    FileSeekError,
    FileTooLarge,
    FileTooSmall,
    FileCorrupted,

    // Codec errors
    UnsupportedCodec,
    CodecInitializationFailed,
    EncodingFailed,
    DecodingFailed,
    InvalidCodecParameters,
    BitstreamError,

    // Container errors
    UnsupportedContainer,
    InvalidContainerFormat,
    MissingRequiredBox,
    InvalidBoxSize,
    InvalidChunk,

    // Frame errors
    InvalidFrameSize,
    InvalidPixelFormat,
    FrameSizeMismatch,
    InvalidFrameData,
    FrameAllocationFailed,

    // Timestamp errors
    InvalidTimestamp,
    NonMonotonicTimestamps,
    TimestampOverflow,

    // Hardware acceleration errors
    HardwareNotAvailable,
    HardwareInitializationFailed,
    UnsupportedHardwareOperation,

    // Resource errors
    OutOfMemory,
    ResourceLimitExceeded,
    BufferFull,
    BufferEmpty,

    // Processing errors
    FilterFailed,
    ConversionFailed,
    ScalingFailed,
    ColorSpaceConversionFailed,

    // Validation errors
    ValidationFailed,
    InvalidInput,
    InvalidConfiguration,
    IncompatibleFormats,

    // Network/Streaming errors
    NetworkError,
    ConnectionFailed,
    StreamError,
    ProtocolError,
};

/// Error context for debugging
pub const ErrorContext = struct {
    error_type: anyerror,
    message: []const u8,
    file: []const u8,
    line: u32,
    function: []const u8,
    timestamp: i64,
    additional_info: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        err: anyerror,
        message: []const u8,
        file: []const u8,
        line: u32,
        function: []const u8,
    ) !Self {
        return .{
            .allocator = allocator,
            .error_type = err,
            .message = try allocator.dupe(u8, message),
            .file = try allocator.dupe(u8, file),
            .line = line,
            .function = try allocator.dupe(u8, function),
            .timestamp = std.time.timestamp(),
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.message);
        self.allocator.free(self.file);
        self.allocator.free(self.function);
        if (self.additional_info) |info| {
            self.allocator.free(info);
        }
    }

    pub fn setAdditionalInfo(self: *Self, info: []const u8) !void {
        if (self.additional_info) |old_info| {
            self.allocator.free(old_info);
        }
        self.additional_info = try self.allocator.dupe(u8, info);
    }

    pub fn format(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        if (self.additional_info) |info| {
            return try std.fmt.allocPrint(
                allocator,
                "[{d}] Error: {} - {s}\n  at {s}:{d} in {s}\n  {s}",
                .{ self.timestamp, self.error_type, self.message, self.file, self.line, self.function, info },
            );
        } else {
            return try std.fmt.allocPrint(
                allocator,
                "[{d}] Error: {} - {s}\n  at {s}:{d} in {s}",
                .{ self.timestamp, self.error_type, self.message, self.file, self.line, self.function },
            );
        }
    }

    pub fn print(self: *const Self) void {
        if (self.additional_info) |info| {
            std.debug.print("[{d}] Error: {} - {s}\n  at {s}:{d} in {s}\n  {s}\n", .{
                self.timestamp,
                self.error_type,
                self.message,
                self.file,
                self.line,
                self.function,
                info,
            });
        } else {
            std.debug.print("[{d}] Error: {} - {s}\n  at {s}:{d} in {s}\n", .{
                self.timestamp,
                self.error_type,
                self.message,
                self.file,
                self.line,
                self.function,
            });
        }
    }
};

/// Error handler with context stack
pub const ErrorHandler = struct {
    contexts: std.ArrayList(ErrorContext),
    allocator: std.mem.Allocator,
    max_contexts: usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, max_contexts: usize) Self {
        return .{
            .contexts = std.ArrayList(ErrorContext).init(allocator),
            .allocator = allocator,
            .max_contexts = max_contexts,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.contexts.items) |*ctx| {
            ctx.deinit();
        }
        self.contexts.deinit();
    }

    pub fn push(self: *Self, context: ErrorContext) !void {
        if (self.contexts.items.len >= self.max_contexts) {
            var oldest = self.contexts.orderedRemove(0);
            oldest.deinit();
        }

        try self.contexts.append(context);
    }

    pub fn pop(self: *Self) ?ErrorContext {
        if (self.contexts.items.len > 0) {
            return self.contexts.pop();
        }
        return null;
    }

    pub fn clear(self: *Self) void {
        for (self.contexts.items) |*ctx| {
            ctx.deinit();
        }
        self.contexts.clearRetainingCapacity();
    }

    pub fn printAll(self: *const Self) void {
        std.debug.print("Error stack ({d} errors):\n", .{self.contexts.items.len});
        for (self.contexts.items, 0..) |*ctx, i| {
            std.debug.print("\n[{d}] ", .{i});
            ctx.print();
        }
    }

    pub fn getLast(self: *const Self) ?*const ErrorContext {
        if (self.contexts.items.len > 0) {
            return &self.contexts.items[self.contexts.items.len - 1];
        }
        return null;
    }
};

/// Result type for operations that can fail
pub fn Result(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: ErrorContext,

        const Self = @This();

        pub fn isOk(self: *const Self) bool {
            return self.* == .ok;
        }

        pub fn isErr(self: *const Self) bool {
            return self.* == .err;
        }

        pub fn unwrap(self: Self) T {
            return switch (self) {
                .ok => |value| value,
                .err => |ctx| {
                    ctx.print();
                    @panic("Attempted to unwrap error result");
                },
            };
        }

        pub fn unwrapOr(self: Self, default: T) T {
            return switch (self) {
                .ok => |value| value,
                .err => default,
            };
        }

        pub fn expect(self: Self, message: []const u8) T {
            return switch (self) {
                .ok => |value| value,
                .err => |ctx| {
                    std.debug.print("{s}\n", .{message});
                    ctx.print();
                    @panic("Result expectation failed");
                },
            };
        }
    };
}

/// Macro for creating error context
pub fn errorContext(
    allocator: std.mem.Allocator,
    err: anyerror,
    comptime message: []const u8,
    comptime file: []const u8,
    comptime line: u32,
    comptime function: []const u8,
) !ErrorContext {
    return try ErrorContext.init(allocator, err, message, file, line, function);
}

/// Helper to wrap errors with context
pub fn wrapError(
    allocator: std.mem.Allocator,
    err: anyerror,
    message: []const u8,
    src: std.builtin.SourceLocation,
) ErrorContext {
    return ErrorContext.init(
        allocator,
        err,
        message,
        src.file,
        src.line,
        src.fn_name,
    ) catch unreachable;
}
