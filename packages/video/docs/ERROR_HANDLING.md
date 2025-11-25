# Error Handling Guide

The Home Video Library provides comprehensive error handling with detailed error types and recovery suggestions.

## VideoError Types

```zig
pub const VideoError = error{
    // Format Errors
    InvalidFormat,
    UnsupportedFormat,
    CorruptedData,
    UnexpectedEof,
    InvalidHeader,

    // Codec Errors
    CodecNotSupported,
    CodecInitFailed,
    DecodeFailed,
    EncodeFailed,
    InvalidCodecParameters,

    // I/O Errors
    FileNotFound,
    PermissionDenied,
    ReadError,
    WriteError,
    SeekError,

    // Memory Errors
    OutOfMemory,
    BufferTooSmall,
    AllocationFailed,

    // Configuration Errors
    InvalidParameter,
    InvalidResolution,
    InvalidFrameRate,
    InvalidSampleRate,
    InvalidChannelCount,

    // Pipeline Errors
    PipelineNotReady,
    StreamNotFound,
    NoVideoStream,
    NoAudioStream,

    // Hardware Errors
    HardwareNotAvailable,
    HardwareError,
    DeviceNotFound,
};
```

## Basic Error Handling

```zig
const video = @import("video");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Basic error handling
    const result = video.Mp4Reader.init(allocator, data) catch |err| {
        std.debug.print("Error: {}\n", .{err});
        std.debug.print("Message: {s}\n", .{video.getUserMessage(err)});
        return err;
    };
    defer result.deinit();
}
```

## Error Context

For detailed error information:

```zig
const ctx = video.ErrorContext{
    .error_type = .InvalidFormat,
    .file_path = "input.mp4",
    .position = 1234,
    .message = "Invalid box type at offset 1234",
};

std.debug.print("Error: {s}\n", .{ctx.message});
std.debug.print("File: {s}\n", .{ctx.file_path});
std.debug.print("Position: {d}\n", .{ctx.position});
```

## Recovery Strategies

### Format Detection Errors

```zig
// Try multiple parsers
fn loadVideo(allocator: std.mem.Allocator, data: []const u8) !void {
    // Try MP4
    if (video.mp4.isMp4(data)) {
        return video.Mp4Reader.init(allocator, data);
    }

    // Try WebM
    if (video.isWebm(data)) {
        return video.WebmReader.init(allocator, data);
    }

    // Try AVI
    if (video.isAvi(data)) {
        return video.AviReader.init(allocator, data);
    }

    return error.UnsupportedFormat;
}
```

### Codec Fallback

```zig
fn createEncoder(allocator: std.mem.Allocator, codec: video.VideoCodec) !Encoder {
    // Try hardware encoder first
    if (video.hw.isAvailable(codec)) {
        return video.hw.createEncoder(allocator, codec) catch {
            // Fallback to software
            return video.sw.createEncoder(allocator, codec);
        };
    }
    return video.sw.createEncoder(allocator, codec);
}
```

### Graceful Degradation

```zig
fn processVideo(vid: *video.Video) !void {
    // Try high-quality operation
    vid.resize(3840, 2160) catch |err| {
        if (err == error.OutOfMemory) {
            // Fallback to lower resolution
            try vid.resize(1920, 1080);
        } else {
            return err;
        }
    };
}
```

## Common Errors and Solutions

### InvalidFormat
**Cause**: File doesn't match expected format
**Solution**: Use format detection before parsing
```zig
const format = video.detectFormat(data);
```

### CodecNotSupported
**Cause**: Required codec not available
**Solution**: Check codec support before use
```zig
if (!video.canDecode(.hevc)) {
    // Use alternative codec
}
```

### OutOfMemory
**Cause**: Insufficient memory for operation
**Solution**: Process in chunks or reduce resolution
```zig
// Use streaming mode instead of loading entire file
var reader = try video.StreamingReader.init(allocator, path);
while (try reader.nextPacket()) |packet| {
    // Process packet
}
```

### HardwareNotAvailable
**Cause**: Hardware acceleration not available
**Solution**: Fallback to software processing
```zig
const hw_available = video.hw.detectAvailable();
const use_hw = hw_available.videotoolbox or hw_available.nvenc;
```

## Logging Errors

```zig
fn logError(err: anyerror, context: []const u8) void {
    const msg = video.getUserMessage(err);
    const recoverable = video.isRecoverable(err);

    std.log.err("{s}: {s} (recoverable: {})", .{
        context,
        msg,
        recoverable,
    });
}
```

## Error Propagation

```zig
fn convertVideo(input: []const u8, output: []const u8) !void {
    const source = try video.Mp4Reader.init(allocator, input);
    defer source.deinit();

    var converter = try video.Converter.init(allocator, .{
        .input = input,
        .output = output,
    });
    defer converter.deinit();

    try converter.run(null);
}

// Called with error handling
convertVideo("in.mp4", "out.webm") catch |err| switch (err) {
    error.InvalidFormat => std.debug.print("Invalid input format\n", .{}),
    error.CodecNotSupported => std.debug.print("Codec not supported\n", .{}),
    error.OutOfMemory => std.debug.print("Not enough memory\n", .{}),
    else => return err,
};
```

## Best Practices

1. **Always check format before parsing**: Use detection functions
2. **Handle OutOfMemory gracefully**: Implement fallbacks
3. **Log errors with context**: Include file path and operation
4. **Use recoverable checks**: Some errors can be retried
5. **Clean up on error**: Use defer for resource cleanup
