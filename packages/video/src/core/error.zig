// Home Video Library - Error Types
// Comprehensive error handling for video/audio operations

const std = @import("std");

// ============================================================================
// Video Error Set
// ============================================================================

pub const VideoError = error{
    // ========================================================================
    // Format/Container Errors
    // ========================================================================

    /// Unknown or unrecognized format
    UnknownFormat,

    /// Format not supported for this operation
    UnsupportedFormat,

    /// Invalid or corrupted container structure
    InvalidContainer,

    /// Missing required container atoms/boxes
    MissingRequiredAtom,

    /// Container header is corrupt or invalid
    InvalidHeader,

    /// Unexpected end of file/data
    UnexpectedEof,

    /// File is truncated
    TruncatedData,

    /// Invalid magic bytes / signature
    InvalidMagicBytes,

    // ========================================================================
    // Codec Errors
    // ========================================================================

    /// Codec not supported
    UnsupportedCodec,

    /// Codec configuration error
    CodecConfigError,

    /// Decoder initialization failed
    DecoderInitFailed,

    /// Encoder initialization failed
    EncoderInitFailed,

    /// Decoding failed
    DecodeFailed,

    /// Encoding failed
    EncodeFailed,

    /// Invalid codec parameters
    InvalidCodecParameters,

    /// Codec extradata missing or invalid
    InvalidExtradata,

    /// Profile not supported
    UnsupportedProfile,

    /// Level not supported
    UnsupportedLevel,

    // ========================================================================
    // Frame Errors
    // ========================================================================

    /// Invalid frame dimensions
    InvalidDimensions,

    /// Frame dimensions too large
    DimensionsTooLarge,

    /// Pixel format not supported
    UnsupportedPixelFormat,

    /// Sample format not supported
    UnsupportedSampleFormat,

    /// Invalid frame rate
    InvalidFrameRate,

    /// Invalid sample rate
    InvalidSampleRate,

    /// Invalid channel count/layout
    InvalidChannelLayout,

    /// Frame buffer too small
    BufferTooSmall,

    /// Frame data corrupted
    CorruptFrame,

    // ========================================================================
    // I/O Errors
    // ========================================================================

    /// File not found
    FileNotFound,

    /// Permission denied
    PermissionDenied,

    /// Read error
    ReadError,

    /// Write error
    WriteError,

    /// Seek error
    SeekError,

    /// File/stream not seekable
    NotSeekable,

    /// I/O operation timed out
    IoTimeout,

    /// Network error (for streaming)
    NetworkError,

    // ========================================================================
    // Memory Errors
    // ========================================================================

    /// Out of memory
    OutOfMemory,

    /// Buffer allocation failed
    AllocationFailed,

    /// Memory limit exceeded
    MemoryLimitExceeded,

    // ========================================================================
    // Stream Errors
    // ========================================================================

    /// No video stream found
    NoVideoStream,

    /// No audio stream found
    NoAudioStream,

    /// Invalid stream index
    InvalidStreamIndex,

    /// Stream not found
    StreamNotFound,

    /// End of stream reached
    EndOfStream,

    // ========================================================================
    // Timestamp/Seeking Errors
    // ========================================================================

    /// Invalid timestamp
    InvalidTimestamp,

    /// Timestamp out of range
    TimestampOutOfRange,

    /// Seek position out of range
    SeekOutOfRange,

    /// Cannot seek to exact position
    InexactSeek,

    /// No keyframe found for seeking
    NoKeyframe,

    // ========================================================================
    // Conversion Errors
    // ========================================================================

    /// Color space conversion not supported
    UnsupportedColorConversion,

    /// Resampling failed
    ResampleFailed,

    /// Scaling failed
    ScaleFailed,

    /// Conversion cancelled
    Cancelled,

    // ========================================================================
    // Metadata Errors
    // ========================================================================

    /// Metadata format not supported
    UnsupportedMetadataFormat,

    /// Invalid metadata
    InvalidMetadata,

    /// Metadata too large
    MetadataTooLarge,

    // ========================================================================
    // Filter/Effect Errors
    // ========================================================================

    /// Filter not found
    FilterNotFound,

    /// Invalid filter parameters
    InvalidFilterParameters,

    /// Filter chain invalid
    InvalidFilterChain,

    // ========================================================================
    // General Errors
    // ========================================================================

    /// Invalid argument
    InvalidArgument,

    /// Operation not supported
    NotSupported,

    /// Invalid state (e.g., calling decode before open)
    InvalidState,

    /// Internal error (bug in library)
    InternalError,

    /// Feature not implemented yet
    NotImplemented,
};

// ============================================================================
// Error Context - Detailed error information
// ============================================================================

pub const ErrorContext = struct {
    /// The error that occurred
    err: VideoError,

    /// Human-readable message
    message: []const u8,

    /// File/stream position where error occurred
    position: ?u64,

    /// Additional context (codec name, format, etc.)
    context: ?[]const u8,

    /// Source file:line for debugging
    source_location: ?std.builtin.SourceLocation,

    const Self = @This();

    pub fn init(err: VideoError, message: []const u8) Self {
        return .{
            .err = err,
            .message = message,
            .position = null,
            .context = null,
            .source_location = null,
        };
    }

    pub fn withPosition(self: Self, pos: u64) Self {
        var ctx = self;
        ctx.position = pos;
        return ctx;
    }

    pub fn withContext(self: Self, context: []const u8) Self {
        var ctx = self;
        ctx.context = context;
        return ctx;
    }

    pub fn withSourceLocation(self: Self, loc: std.builtin.SourceLocation) Self {
        var ctx = self;
        ctx.source_location = loc;
        return ctx;
    }

    pub fn format(self: Self, writer: anytype) !void {
        try writer.print("VideoError.{s}: {s}", .{ @errorName(self.err), self.message });

        if (self.position) |pos| {
            try writer.print(" (at position {d})", .{pos});
        }

        if (self.context) |ctx| {
            try writer.print(" [{s}]", .{ctx});
        }

        if (self.source_location) |loc| {
            try writer.print(" ({s}:{d})", .{ loc.file, loc.line });
        }
    }
};

// ============================================================================
// Result Type - For operations that may fail with context
// ============================================================================

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
                .ok => |v| v,
                .err => |e| std.debug.panic("unwrap on error: {f}", .{e}),
            };
        }

        pub fn unwrapOr(self: Self, default: T) T {
            return switch (self) {
                .ok => |v| v,
                .err => default,
            };
        }

        pub fn unwrapErr(self: Self) ErrorContext {
            return switch (self) {
                .ok => std.debug.panic("unwrapErr on ok value", .{}),
                .err => |e| e,
            };
        }
    };
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Create an error with context
pub fn makeError(err: VideoError, message: []const u8) ErrorContext {
    return ErrorContext.init(err, message);
}

/// Create an error at current source location
pub fn makeErrorHere(err: VideoError, message: []const u8) ErrorContext {
    return ErrorContext.init(err, message).withSourceLocation(@src());
}

/// Check if error is recoverable (can continue processing)
pub fn isRecoverable(err: VideoError) bool {
    return switch (err) {
        VideoError.CorruptFrame,
        VideoError.InexactSeek,
        VideoError.InvalidTimestamp,
        => true,
        else => false,
    };
}

/// Check if error is a resource limit (can retry with smaller input)
pub fn isResourceLimit(err: VideoError) bool {
    return switch (err) {
        VideoError.OutOfMemory,
        VideoError.AllocationFailed,
        VideoError.MemoryLimitExceeded,
        VideoError.DimensionsTooLarge,
        VideoError.MetadataTooLarge,
        => true,
        else => false,
    };
}

/// Get a user-friendly error message
pub fn getUserMessage(err: VideoError) []const u8 {
    return switch (err) {
        VideoError.UnknownFormat => "Unknown or unsupported file format",
        VideoError.UnsupportedFormat => "This file format is not supported",
        VideoError.InvalidContainer => "The file appears to be corrupted",
        VideoError.TruncatedData => "The file is incomplete or truncated",
        VideoError.UnsupportedCodec => "This video/audio codec is not supported",
        VideoError.DecodeFailed => "Failed to decode media",
        VideoError.EncodeFailed => "Failed to encode media",
        VideoError.InvalidDimensions => "Invalid video dimensions",
        VideoError.FileNotFound => "File not found",
        VideoError.PermissionDenied => "Permission denied",
        VideoError.OutOfMemory => "Not enough memory",
        VideoError.NoVideoStream => "No video track found in file",
        VideoError.NoAudioStream => "No audio track found in file",
        VideoError.Cancelled => "Operation was cancelled",
        VideoError.NotImplemented => "This feature is not yet implemented",
        else => "An error occurred during media processing",
    };
}

// ============================================================================
// Tests
// ============================================================================

test "ErrorContext formatting" {
    const ctx = ErrorContext.init(VideoError.InvalidDimensions, "width must be positive")
        .withPosition(1234)
        .withContext("MP4");

    var buf: [256]u8 = undefined;
    const str = try std.fmt.bufPrint(&buf, "{f}", .{ctx});

    try std.testing.expect(std.mem.indexOf(u8, str, "InvalidDimensions") != null);
    try std.testing.expect(std.mem.indexOf(u8, str, "width must be positive") != null);
    try std.testing.expect(std.mem.indexOf(u8, str, "1234") != null);
    try std.testing.expect(std.mem.indexOf(u8, str, "MP4") != null);
}

test "Result type" {
    const ok_result: Result(u32) = .{ .ok = 42 };
    try std.testing.expect(ok_result.isOk());
    try std.testing.expectEqual(@as(u32, 42), ok_result.unwrap());

    const err_result: Result(u32) = .{ .err = ErrorContext.init(VideoError.InvalidArgument, "test") };
    try std.testing.expect(err_result.isErr());
    try std.testing.expectEqual(@as(u32, 0), err_result.unwrapOr(0));
}

test "isRecoverable" {
    try std.testing.expect(isRecoverable(VideoError.CorruptFrame));
    try std.testing.expect(!isRecoverable(VideoError.OutOfMemory));
    try std.testing.expect(!isRecoverable(VideoError.FileNotFound));
}
