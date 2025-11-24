// Home Audio Library - Error Types
// Comprehensive error handling for audio operations

const std = @import("std");

// ============================================================================
// Audio Errors
// ============================================================================

pub const AudioError = error{
    // Format errors
    InvalidFormat,
    UnsupportedFormat,
    UnsupportedCodec,
    UnsupportedSampleRate,
    UnsupportedChannelCount,
    UnsupportedBitDepth,

    // Data errors
    CorruptData,
    TruncatedData,
    InvalidHeader,
    InvalidFrameData,
    ChecksumMismatch,
    SyncLost,

    // I/O errors
    ReadError,
    WriteError,
    SeekError,
    EndOfStream,
    FileNotFound,
    PermissionDenied,

    // Resource errors
    OutOfMemory,
    BufferTooSmall,
    BufferOverflow,

    // Codec errors
    DecodingFailed,
    EncodingFailed,
    InvalidBitstream,
    FrameSizeMismatch,

    // State errors
    NotInitialized,
    AlreadyInitialized,
    InvalidState,
    NotImplemented,

    // Parameter errors
    InvalidParameter,
    InvalidSampleCount,
    InvalidChannelIndex,
    InvalidTimeRange,
};

// ============================================================================
// Error Context
// ============================================================================

/// Detailed error information
pub const ErrorContext = struct {
    /// The error that occurred
    err: AudioError,

    /// Human-readable error message
    message: []const u8,

    /// Source file where error occurred
    source_file: ?[]const u8 = null,

    /// Line number where error occurred
    source_line: ?u32 = null,

    /// Additional context data
    context: ?[]const u8 = null,

    /// Byte offset in file where error occurred
    byte_offset: ?u64 = null,

    const Self = @This();

    pub fn format(
        self: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("AudioError: {s}", .{self.message});

        if (self.byte_offset) |offset| {
            try writer.print(" at byte {d}", .{offset});
        }

        if (self.context) |ctx| {
            try writer.print(" ({s})", .{ctx});
        }
    }
};

// ============================================================================
// Result Type
// ============================================================================

/// Result type for operations that can fail with context
pub fn Result(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: ErrorContext,

        const Self = @This();

        pub fn isOk(self: Self) bool {
            return self == .ok;
        }

        pub fn isErr(self: Self) bool {
            return self == .err;
        }

        pub fn unwrap(self: Self) T {
            return switch (self) {
                .ok => |value| value,
                .err => unreachable,
            };
        }

        pub fn unwrapOr(self: Self, default: T) T {
            return switch (self) {
                .ok => |value| value,
                .err => default,
            };
        }

        pub fn unwrapErr(self: Self) ErrorContext {
            return switch (self) {
                .ok => unreachable,
                .err => |e| e,
            };
        }
    };
}

// ============================================================================
// Error Helpers
// ============================================================================

/// Create an error context with message
pub fn makeError(err: AudioError, message: []const u8) ErrorContext {
    return .{
        .err = err,
        .message = message,
    };
}

/// Create an error context with byte offset
pub fn makeErrorAt(err: AudioError, message: []const u8, offset: u64) ErrorContext {
    return .{
        .err = err,
        .message = message,
        .byte_offset = offset,
    };
}

/// Check if an error is recoverable
pub fn isRecoverable(e: AudioError) bool {
    return switch (e) {
        error.SyncLost, error.ChecksumMismatch, error.InvalidFrameData => true,
        else => false,
    };
}

/// Get a user-friendly error message
pub fn getUserMessage(e: AudioError) []const u8 {
    return switch (e) {
        error.InvalidFormat => "The audio file format is invalid or corrupted",
        error.UnsupportedFormat => "This audio format is not supported",
        error.UnsupportedCodec => "This audio codec is not supported",
        error.UnsupportedSampleRate => "The sample rate is not supported",
        error.UnsupportedChannelCount => "The channel count is not supported",
        error.UnsupportedBitDepth => "The bit depth is not supported",
        error.CorruptData => "The audio data is corrupted",
        error.TruncatedData => "The audio file is incomplete or truncated",
        error.InvalidHeader => "The audio file header is invalid",
        error.InvalidFrameData => "Invalid audio frame data",
        error.ChecksumMismatch => "Data checksum verification failed",
        error.SyncLost => "Lost synchronization in audio stream",
        error.ReadError => "Failed to read from audio source",
        error.WriteError => "Failed to write to audio destination",
        error.SeekError => "Failed to seek in audio stream",
        error.EndOfStream => "Reached end of audio stream",
        error.FileNotFound => "Audio file not found",
        error.PermissionDenied => "Permission denied accessing audio file",
        error.OutOfMemory => "Not enough memory for audio operation",
        error.BufferTooSmall => "Buffer is too small for audio data",
        error.BufferOverflow => "Audio buffer overflow",
        error.DecodingFailed => "Failed to decode audio data",
        error.EncodingFailed => "Failed to encode audio data",
        error.InvalidBitstream => "Invalid audio bitstream",
        error.FrameSizeMismatch => "Audio frame size mismatch",
        error.NotInitialized => "Audio system not initialized",
        error.AlreadyInitialized => "Audio system already initialized",
        error.InvalidState => "Invalid audio system state",
        error.NotImplemented => "Feature not implemented",
        error.InvalidParameter => "Invalid parameter",
        error.InvalidSampleCount => "Invalid sample count",
        error.InvalidChannelIndex => "Invalid channel index",
        error.InvalidTimeRange => "Invalid time range",
    };
}

// ============================================================================
// Error Categories
// ============================================================================

pub const ErrorCategory = enum {
    format,
    data,
    io,
    resource,
    codec,
    state,
    parameter,
};

pub fn getCategory(e: AudioError) ErrorCategory {
    return switch (e) {
        error.InvalidFormat, error.UnsupportedFormat, error.UnsupportedCodec, error.UnsupportedSampleRate, error.UnsupportedChannelCount, error.UnsupportedBitDepth => .format,
        error.CorruptData, error.TruncatedData, error.InvalidHeader, error.InvalidFrameData, error.ChecksumMismatch, error.SyncLost => .data,
        error.ReadError, error.WriteError, error.SeekError, error.EndOfStream, error.FileNotFound, error.PermissionDenied => .io,
        error.OutOfMemory, error.BufferTooSmall, error.BufferOverflow => .resource,
        error.DecodingFailed, error.EncodingFailed, error.InvalidBitstream, error.FrameSizeMismatch => .codec,
        error.NotInitialized, error.AlreadyInitialized, error.InvalidState, error.NotImplemented => .state,
        error.InvalidParameter, error.InvalidSampleCount, error.InvalidChannelIndex, error.InvalidTimeRange => .parameter,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Error messages" {
    const msg = getUserMessage(AudioError.InvalidFormat);
    try std.testing.expect(msg.len > 0);
}

test "Error categories" {
    try std.testing.expectEqual(ErrorCategory.format, getCategory(AudioError.UnsupportedFormat));
    try std.testing.expectEqual(ErrorCategory.io, getCategory(AudioError.ReadError));
    try std.testing.expectEqual(ErrorCategory.codec, getCategory(AudioError.DecodingFailed));
}

test "Error context" {
    const ctx = makeErrorAt(AudioError.InvalidHeader, "Bad magic bytes", 0);
    try std.testing.expectEqual(AudioError.InvalidHeader, ctx.err);
    try std.testing.expectEqual(@as(u64, 0), ctx.byte_offset.?);
}

test "Recoverable errors" {
    try std.testing.expect(isRecoverable(AudioError.SyncLost));
    try std.testing.expect(!isRecoverable(AudioError.InvalidFormat));
}
