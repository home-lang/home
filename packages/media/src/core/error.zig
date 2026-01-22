// Home Media Library - Error Types
// Unified error handling for media operations

const std = @import("std");

// ============================================================================
// Media Error Enumeration
// ============================================================================

pub const MediaError = error{
    // General errors
    Ok,
    UnknownError,
    NotImplemented,
    InvalidArgument,
    OutOfMemory,
    Cancelled,

    // Input/Output errors
    InvalidInput,
    InvalidOutput,
    FileNotFound,
    PermissionDenied,
    IoError,
    EndOfStream,

    // Format errors
    UnsupportedFormat,
    UnsupportedCodec,
    InvalidFormat,
    CorruptData,
    TruncatedData,
    InvalidHeader,

    // Codec errors
    DecodeError,
    EncodeError,
    CodecNotFound,
    CodecInitFailed,
    CodecConfigError,

    // Filter errors
    FilterError,
    FilterNotFound,
    FilterConfigError,
    FilterChainError,

    // Pipeline errors
    PipelineError,
    PipelineNotReady,
    PipelineAlreadyRunning,
    InputNotSet,
    OutputNotSet,

    // Resource errors
    ResourceBusy,
    ResourceExhausted,
    BufferTooSmall,
    AllocationFailed,

    // Hardware errors
    HardwareError,
    DeviceNotFound,
    DeviceNotSupported,
};

// ============================================================================
// Error Code Mapping
// ============================================================================

pub const ErrorCode = enum(i32) {
    ok = 0,
    unknown_error = -1,
    not_implemented = -2,
    invalid_argument = -3,
    out_of_memory = -4,
    cancelled = -5,
    invalid_input = -10,
    invalid_output = -11,
    file_not_found = -12,
    permission_denied = -13,
    io_error = -14,
    end_of_stream = -15,
    unsupported_format = -20,
    unsupported_codec = -21,
    invalid_format = -22,
    corrupt_data = -23,
    truncated_data = -24,
    invalid_header = -25,
    decode_error = -30,
    encode_error = -31,
    codec_not_found = -32,
    codec_init_failed = -33,
    codec_config_error = -34,
    filter_error = -40,
    filter_not_found = -41,
    filter_config_error = -42,
    filter_chain_error = -43,
    pipeline_error = -50,
    pipeline_not_ready = -51,
    pipeline_already_running = -52,
    input_not_set = -53,
    output_not_set = -54,
    resource_busy = -60,
    resource_exhausted = -61,
    buffer_too_small = -62,
    allocation_failed = -63,
    hardware_error = -70,
    device_not_found = -71,
    device_not_supported = -72,

    pub fn toError(self: ErrorCode) MediaError {
        return switch (self) {
            .ok => MediaError.Ok,
            .unknown_error => MediaError.UnknownError,
            .not_implemented => MediaError.NotImplemented,
            .invalid_argument => MediaError.InvalidArgument,
            .out_of_memory => MediaError.OutOfMemory,
            .cancelled => MediaError.Cancelled,
            .invalid_input => MediaError.InvalidInput,
            .invalid_output => MediaError.InvalidOutput,
            .file_not_found => MediaError.FileNotFound,
            .permission_denied => MediaError.PermissionDenied,
            .io_error => MediaError.IoError,
            .end_of_stream => MediaError.EndOfStream,
            .unsupported_format => MediaError.UnsupportedFormat,
            .unsupported_codec => MediaError.UnsupportedCodec,
            .invalid_format => MediaError.InvalidFormat,
            .corrupt_data => MediaError.CorruptData,
            .truncated_data => MediaError.TruncatedData,
            .invalid_header => MediaError.InvalidHeader,
            .decode_error => MediaError.DecodeError,
            .encode_error => MediaError.EncodeError,
            .codec_not_found => MediaError.CodecNotFound,
            .codec_init_failed => MediaError.CodecInitFailed,
            .codec_config_error => MediaError.CodecConfigError,
            .filter_error => MediaError.FilterError,
            .filter_not_found => MediaError.FilterNotFound,
            .filter_config_error => MediaError.FilterConfigError,
            .filter_chain_error => MediaError.FilterChainError,
            .pipeline_error => MediaError.PipelineError,
            .pipeline_not_ready => MediaError.PipelineNotReady,
            .pipeline_already_running => MediaError.PipelineAlreadyRunning,
            .input_not_set => MediaError.InputNotSet,
            .output_not_set => MediaError.OutputNotSet,
            .resource_busy => MediaError.ResourceBusy,
            .resource_exhausted => MediaError.ResourceExhausted,
            .buffer_too_small => MediaError.BufferTooSmall,
            .allocation_failed => MediaError.AllocationFailed,
            .hardware_error => MediaError.HardwareError,
            .device_not_found => MediaError.DeviceNotFound,
            .device_not_supported => MediaError.DeviceNotSupported,
        };
    }

    pub fn fromError(err: MediaError) ErrorCode {
        return switch (err) {
            MediaError.Ok => .ok,
            MediaError.UnknownError => .unknown_error,
            MediaError.NotImplemented => .not_implemented,
            MediaError.InvalidArgument => .invalid_argument,
            MediaError.OutOfMemory => .out_of_memory,
            MediaError.Cancelled => .cancelled,
            MediaError.InvalidInput => .invalid_input,
            MediaError.InvalidOutput => .invalid_output,
            MediaError.FileNotFound => .file_not_found,
            MediaError.PermissionDenied => .permission_denied,
            MediaError.IoError => .io_error,
            MediaError.EndOfStream => .end_of_stream,
            MediaError.UnsupportedFormat => .unsupported_format,
            MediaError.UnsupportedCodec => .unsupported_codec,
            MediaError.InvalidFormat => .invalid_format,
            MediaError.CorruptData => .corrupt_data,
            MediaError.TruncatedData => .truncated_data,
            MediaError.InvalidHeader => .invalid_header,
            MediaError.DecodeError => .decode_error,
            MediaError.EncodeError => .encode_error,
            MediaError.CodecNotFound => .codec_not_found,
            MediaError.CodecInitFailed => .codec_init_failed,
            MediaError.CodecConfigError => .codec_config_error,
            MediaError.FilterError => .filter_error,
            MediaError.FilterNotFound => .filter_not_found,
            MediaError.FilterConfigError => .filter_config_error,
            MediaError.FilterChainError => .filter_chain_error,
            MediaError.PipelineError => .pipeline_error,
            MediaError.PipelineNotReady => .pipeline_not_ready,
            MediaError.PipelineAlreadyRunning => .pipeline_already_running,
            MediaError.InputNotSet => .input_not_set,
            MediaError.OutputNotSet => .output_not_set,
            MediaError.ResourceBusy => .resource_busy,
            MediaError.ResourceExhausted => .resource_exhausted,
            MediaError.BufferTooSmall => .buffer_too_small,
            MediaError.AllocationFailed => .allocation_failed,
            MediaError.HardwareError => .hardware_error,
            MediaError.DeviceNotFound => .device_not_found,
            MediaError.DeviceNotSupported => .device_not_supported,
        };
    }
};

// ============================================================================
// Error Context
// ============================================================================

pub const ErrorContext = struct {
    error_code: ErrorCode,
    message: []const u8,
    source_file: ?[]const u8 = null,
    source_line: ?u32 = null,
    timestamp_us: i64 = 0,

    pub fn init(code: ErrorCode, msg: []const u8) ErrorContext {
        return .{
            .error_code = code,
            .message = msg,
            .timestamp_us = std.time.microTimestamp(),
        };
    }

    pub fn withSource(self: ErrorContext, file: []const u8, line: u32) ErrorContext {
        var ctx = self;
        ctx.source_file = file;
        ctx.source_line = line;
        return ctx;
    }
};

// ============================================================================
// Error Category
// ============================================================================

pub const ErrorCategory = enum {
    none,
    general,
    io,
    format,
    codec,
    filter,
    pipeline,
    resource,
    hardware,

    pub fn fromError(err: MediaError) ErrorCategory {
        return switch (err) {
            MediaError.Ok => .none,
            MediaError.UnknownError, MediaError.NotImplemented, MediaError.InvalidArgument, MediaError.OutOfMemory, MediaError.Cancelled => .general,
            MediaError.InvalidInput, MediaError.InvalidOutput, MediaError.FileNotFound, MediaError.PermissionDenied, MediaError.IoError, MediaError.EndOfStream => .io,
            MediaError.UnsupportedFormat, MediaError.UnsupportedCodec, MediaError.InvalidFormat, MediaError.CorruptData, MediaError.TruncatedData, MediaError.InvalidHeader => .format,
            MediaError.DecodeError, MediaError.EncodeError, MediaError.CodecNotFound, MediaError.CodecInitFailed, MediaError.CodecConfigError => .codec,
            MediaError.FilterError, MediaError.FilterNotFound, MediaError.FilterConfigError, MediaError.FilterChainError => .filter,
            MediaError.PipelineError, MediaError.PipelineNotReady, MediaError.PipelineAlreadyRunning, MediaError.InputNotSet, MediaError.OutputNotSet => .pipeline,
            MediaError.ResourceBusy, MediaError.ResourceExhausted, MediaError.BufferTooSmall, MediaError.AllocationFailed => .resource,
            MediaError.HardwareError, MediaError.DeviceNotFound, MediaError.DeviceNotSupported => .hardware,
        };
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Check if an error is recoverable (can retry)
pub fn isRecoverable(err: MediaError) bool {
    return switch (err) {
        MediaError.ResourceBusy,
        MediaError.BufferTooSmall,
        MediaError.EndOfStream,
        => true,
        else => false,
    };
}

/// Get user-friendly error message
pub fn getUserMessage(err: MediaError) []const u8 {
    return switch (err) {
        MediaError.Ok => "Success",
        MediaError.UnknownError => "An unknown error occurred",
        MediaError.NotImplemented => "This feature is not yet implemented",
        MediaError.InvalidArgument => "Invalid argument provided",
        MediaError.OutOfMemory => "Out of memory",
        MediaError.Cancelled => "Operation was cancelled",
        MediaError.InvalidInput => "Invalid input file or stream",
        MediaError.InvalidOutput => "Invalid output file or stream",
        MediaError.FileNotFound => "File not found",
        MediaError.PermissionDenied => "Permission denied",
        MediaError.IoError => "I/O error occurred",
        MediaError.EndOfStream => "End of stream reached",
        MediaError.UnsupportedFormat => "Unsupported format",
        MediaError.UnsupportedCodec => "Unsupported codec",
        MediaError.InvalidFormat => "Invalid format",
        MediaError.CorruptData => "Data is corrupt",
        MediaError.TruncatedData => "Data is truncated",
        MediaError.InvalidHeader => "Invalid header",
        MediaError.DecodeError => "Decoding failed",
        MediaError.EncodeError => "Encoding failed",
        MediaError.CodecNotFound => "Codec not found",
        MediaError.CodecInitFailed => "Codec initialization failed",
        MediaError.CodecConfigError => "Codec configuration error",
        MediaError.FilterError => "Filter error",
        MediaError.FilterNotFound => "Filter not found",
        MediaError.FilterConfigError => "Filter configuration error",
        MediaError.FilterChainError => "Filter chain error",
        MediaError.PipelineError => "Pipeline error",
        MediaError.PipelineNotReady => "Pipeline is not ready",
        MediaError.PipelineAlreadyRunning => "Pipeline is already running",
        MediaError.InputNotSet => "Input not set",
        MediaError.OutputNotSet => "Output not set",
        MediaError.ResourceBusy => "Resource is busy",
        MediaError.ResourceExhausted => "Resource exhausted",
        MediaError.BufferTooSmall => "Buffer too small",
        MediaError.AllocationFailed => "Memory allocation failed",
        MediaError.HardwareError => "Hardware error",
        MediaError.DeviceNotFound => "Device not found",
        MediaError.DeviceNotSupported => "Device not supported",
    };
}

/// Create an error with context
pub fn makeError(comptime code: ErrorCode, comptime msg: []const u8) ErrorContext {
    return ErrorContext.init(code, msg);
}

// ============================================================================
// Result Type
// ============================================================================

/// Result type for operations that may fail
pub fn Result(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: MediaError,

        const Self = @This();

        pub fn unwrap(self: Self) !T {
            return switch (self) {
                .ok => |value| value,
                .err => |e| e,
            };
        }

        pub fn isOk(self: Self) bool {
            return self == .ok;
        }

        pub fn isErr(self: Self) bool {
            return self == .err;
        }

        pub fn map(self: Self, comptime func: fn (T) anytype) Result(@TypeOf(func(undefined))) {
            return switch (self) {
                .ok => |value| .{ .ok = func(value) },
                .err => |e| .{ .err = e },
            };
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "ErrorCode conversion" {
    const code = ErrorCode.unsupported_format;
    const err = code.toError();
    try std.testing.expectEqual(MediaError.UnsupportedFormat, err);

    const back = ErrorCode.fromError(err);
    try std.testing.expectEqual(code, back);
}

test "Error category" {
    try std.testing.expectEqual(ErrorCategory.io, ErrorCategory.fromError(MediaError.FileNotFound));
    try std.testing.expectEqual(ErrorCategory.codec, ErrorCategory.fromError(MediaError.DecodeError));
    try std.testing.expectEqual(ErrorCategory.pipeline, ErrorCategory.fromError(MediaError.InputNotSet));
}

test "Recoverable errors" {
    try std.testing.expect(isRecoverable(MediaError.ResourceBusy));
    try std.testing.expect(!isRecoverable(MediaError.UnsupportedFormat));
}
