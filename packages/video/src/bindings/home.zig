// Home Video Library - Home Language Bindings
// Native bindings for the Home programming language

const std = @import("std");
const video = @import("../video.zig");

// ============================================================================
// Memory Management for FFI
// ============================================================================

/// Handle for managing memory across FFI boundary
pub const Handle = struct {
    ptr: *anyopaque,
    deinit_fn: *const fn (*anyopaque) void,

    pub fn deinit(self: *Handle) void {
        self.deinit_fn(self.ptr);
    }
};

/// Global allocator for FFI allocations
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
pub const allocator = gpa.allocator();

// ============================================================================
// Error Handling
// ============================================================================

/// Error type for Home language
pub const HomeError = enum(c_int) {
    ok = 0,
    invalid_argument = -1,
    out_of_memory = -2,
    file_not_found = -3,
    invalid_format = -4,
    unsupported_codec = -5,
    decode_error = -6,
    encode_error = -7,
    io_error = -8,
    unknown_error = -999,

    pub fn fromVideoError(err: anyerror) HomeError {
        return switch (err) {
            error.OutOfMemory => .out_of_memory,
            error.FileNotFound => .file_not_found,
            error.InvalidFormat, error.UnsupportedFormat => .invalid_format,
            error.UnsupportedCodec => .unsupported_codec,
            else => .unknown_error,
        };
    }
};

/// Last error message (for debugging)
var last_error_msg: [256]u8 = undefined;
var last_error_len: usize = 0;

pub fn setLastError(msg: []const u8) void {
    last_error_len = @min(msg.len, last_error_msg.len);
    @memcpy(last_error_msg[0..last_error_len], msg[0..last_error_len]);
}

pub export fn video_get_last_error() [*:0]const u8 {
    last_error_msg[last_error_len] = 0;
    return @ptrCast(&last_error_msg);
}

// ============================================================================
// String Handling
// ============================================================================

/// C-compatible string (null-terminated)
pub const CString = [*:0]const u8;

/// Convert Home string to Zig slice
pub fn homeStringToZig(home_str: CString) []const u8 {
    return std.mem.span(home_str);
}

/// Duplicate string for Home (caller must free with video_free_string)
pub fn zigStringToHome(str: []const u8) !CString {
    const buf = try allocator.allocSentinel(u8, str.len, 0);
    @memcpy(buf[0..str.len], str);
    return buf;
}

pub export fn video_free_string(str: CString) void {
    allocator.free(std.mem.span(str));
}

// ============================================================================
// Audio Loading and Encoding
// ============================================================================

pub const HomeAudio = struct {
    audio: video.Audio,

    fn deinitVoid(ptr: *anyopaque) void {
        const self: *HomeAudio = @ptrCast(@alignCast(ptr));
        self.audio.deinit();
        allocator.destroy(self);
    }
};

/// Load audio from file path
pub export fn video_audio_load(path: CString, out_handle: *?*anyopaque) HomeError {
    const path_slice = homeStringToZig(path);

    const home_audio = allocator.create(HomeAudio) catch {
        setLastError("Out of memory");
        return .out_of_memory;
    };

    home_audio.audio = video.Audio.load(allocator, path_slice) catch |err| {
        allocator.destroy(home_audio);
        setLastError("Failed to load audio");
        return HomeError.fromVideoError(err);
    };

    out_handle.* = home_audio;
    return .ok;
}

/// Load audio from memory buffer
pub export fn video_audio_load_from_memory(
    data: [*]const u8,
    data_len: usize,
    out_handle: *?*anyopaque,
) HomeError {
    const buffer = data[0..data_len];

    const home_audio = allocator.create(HomeAudio) catch {
        setLastError("Out of memory");
        return .out_of_memory;
    };

    home_audio.audio = video.Audio.loadFromMemory(allocator, buffer) catch |err| {
        allocator.destroy(home_audio);
        setLastError("Failed to load audio from memory");
        return HomeError.fromVideoError(err);
    };

    out_handle.* = home_audio;
    return .ok;
}

/// Save audio to file
pub export fn video_audio_save(handle: *anyopaque, path: CString) HomeError {
    const self: *HomeAudio = @ptrCast(@alignCast(handle));
    const path_slice = homeStringToZig(path);

    self.audio.save(path_slice) catch |err| {
        setLastError("Failed to save audio");
        return HomeError.fromVideoError(err);
    };

    return .ok;
}

/// Encode audio to bytes in specified format
pub export fn video_audio_encode(
    handle: *anyopaque,
    format: c_int,
    out_data: *?[*]u8,
    out_len: *usize,
) HomeError {
    const self: *HomeAudio = @ptrCast(@alignCast(handle));

    const audio_format: video.AudioFormat = @enumFromInt(format);

    const encoded = self.audio.encode(audio_format) catch |err| {
        setLastError("Failed to encode audio");
        return HomeError.fromVideoError(err);
    };

    out_data.* = encoded.ptr;
    out_len.* = encoded.len;
    return .ok;
}

/// Get audio duration in seconds
pub export fn video_audio_duration(handle: *anyopaque) f64 {
    const self: *HomeAudio = @ptrCast(@alignCast(handle));
    return self.audio.duration();
}

/// Get audio sample rate
pub export fn video_audio_sample_rate(handle: *anyopaque) u32 {
    const self: *HomeAudio = @ptrCast(@alignCast(handle));
    return self.audio.sample_rate;
}

/// Get audio channel count
pub export fn video_audio_channels(handle: *anyopaque) u8 {
    const self: *HomeAudio = @ptrCast(@alignCast(handle));
    return self.audio.channels;
}

/// Get total sample count
pub export fn video_audio_total_samples(handle: *anyopaque) u64 {
    const self: *HomeAudio = @ptrCast(@alignCast(handle));
    return self.audio.totalSamples();
}

/// Free audio handle
pub export fn video_audio_free(handle: *anyopaque) void {
    const self: *HomeAudio = @ptrCast(@alignCast(handle));
    self.audio.deinit();
    allocator.destroy(self);
}

// ============================================================================
// Video Frame Operations
// ============================================================================

pub const HomeVideoFrame = struct {
    frame: video.VideoFrame,

    fn deinitVoid(ptr: *anyopaque) void {
        const self: *HomeVideoFrame = @ptrCast(@alignCast(ptr));
        self.frame.deinit();
        allocator.destroy(self);
    }
};

/// Create a new video frame
pub export fn video_frame_create(
    width: u32,
    height: u32,
    pixel_format: c_int,
    out_handle: *?*anyopaque,
) HomeError {
    const pix_fmt: video.PixelFormat = @enumFromInt(pixel_format);

    const home_frame = allocator.create(HomeVideoFrame) catch {
        setLastError("Out of memory");
        return .out_of_memory;
    };

    home_frame.frame = video.VideoFrame.init(allocator, width, height, pix_fmt) catch |err| {
        allocator.destroy(home_frame);
        setLastError("Failed to create video frame");
        return HomeError.fromVideoError(err);
    };

    out_handle.* = home_frame;
    return .ok;
}

/// Get frame width
pub export fn video_frame_width(handle: *anyopaque) u32 {
    const self: *HomeVideoFrame = @ptrCast(@alignCast(handle));
    return self.frame.width;
}

/// Get frame height
pub export fn video_frame_height(handle: *anyopaque) u32 {
    const self: *HomeVideoFrame = @ptrCast(@alignCast(handle));
    return self.frame.height;
}

/// Get frame pixel format
pub export fn video_frame_pixel_format(handle: *anyopaque) c_int {
    const self: *HomeVideoFrame = @ptrCast(@alignCast(handle));
    return @intFromEnum(self.frame.format);
}

/// Get frame data pointer for plane
pub export fn video_frame_data(handle: *anyopaque, plane: u8) ?[*]u8 {
    const self: *HomeVideoFrame = @ptrCast(@alignCast(handle));
    if (plane >= self.frame.plane_count) return null;
    return self.frame.data[plane].ptr;
}

/// Get frame linesize for plane
pub export fn video_frame_linesize(handle: *anyopaque, plane: u8) usize {
    const self: *HomeVideoFrame = @ptrCast(@alignCast(handle));
    if (plane >= self.frame.plane_count) return 0;
    return self.frame.linesize[plane];
}

/// Free video frame
pub export fn video_frame_free(handle: *anyopaque) void {
    const self: *HomeVideoFrame = @ptrCast(@alignCast(handle));
    self.frame.deinit();
    allocator.destroy(self);
}

// ============================================================================
// Video Filters
// ============================================================================

/// Apply scale filter to video frame
pub export fn video_filter_scale(
    src_handle: *anyopaque,
    dst_width: u32,
    dst_height: u32,
    algorithm: c_int,
    out_handle: *?*anyopaque,
) HomeError {
    const src: *HomeVideoFrame = @ptrCast(@alignCast(src_handle));
    const scale_algo: video.ScaleAlgorithm = @enumFromInt(algorithm);

    const home_frame = allocator.create(HomeVideoFrame) catch {
        setLastError("Out of memory");
        return .out_of_memory;
    };

    var filter = video.ScaleFilter{
        .width = dst_width,
        .height = dst_height,
        .algorithm = scale_algo,
    };

    home_frame.frame = filter.apply(allocator, &src.frame) catch |err| {
        allocator.destroy(home_frame);
        setLastError("Failed to apply scale filter");
        return HomeError.fromVideoError(err);
    };

    out_handle.* = home_frame;
    return .ok;
}

/// Apply crop filter to video frame
pub export fn video_filter_crop(
    src_handle: *anyopaque,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    out_handle: *?*anyopaque,
) HomeError {
    const src: *HomeVideoFrame = @ptrCast(@alignCast(src_handle));

    const home_frame = allocator.create(HomeVideoFrame) catch {
        setLastError("Out of memory");
        return .out_of_memory;
    };

    var filter = video.CropFilter{
        .x = x,
        .y = y,
        .width = width,
        .height = height,
    };

    home_frame.frame = filter.apply(allocator, &src.frame) catch |err| {
        allocator.destroy(home_frame);
        setLastError("Failed to apply crop filter");
        return HomeError.fromVideoError(err);
    };

    out_handle.* = home_frame;
    return .ok;
}

/// Apply grayscale filter
pub export fn video_filter_grayscale(
    src_handle: *anyopaque,
    out_handle: *?*anyopaque,
) HomeError {
    const src: *HomeVideoFrame = @ptrCast(@alignCast(src_handle));

    const home_frame = allocator.create(HomeVideoFrame) catch {
        setLastError("Out of memory");
        return .out_of_memory;
    };

    var filter = video.GrayscaleFilter{};

    home_frame.frame = filter.apply(allocator, &src.frame) catch |err| {
        allocator.destroy(home_frame);
        setLastError("Failed to apply grayscale filter");
        return HomeError.fromVideoError(err);
    };

    out_handle.* = home_frame;
    return .ok;
}

/// Apply blur filter
pub export fn video_filter_blur(
    src_handle: *anyopaque,
    sigma: f32,
    out_handle: *?*anyopaque,
) HomeError {
    const src: *HomeVideoFrame = @ptrCast(@alignCast(src_handle));

    const home_frame = allocator.create(HomeVideoFrame) catch {
        setLastError("Out of memory");
        return .out_of_memory;
    };

    var filter = video.BlurFilter{ .sigma = sigma };

    home_frame.frame = filter.apply(allocator, &src.frame) catch |err| {
        allocator.destroy(home_frame);
        setLastError("Failed to apply blur filter");
        return HomeError.fromVideoError(err);
    };

    out_handle.* = home_frame;
    return .ok;
}

/// Apply rotate filter
pub export fn video_filter_rotate(
    src_handle: *anyopaque,
    angle: c_int,
    out_handle: *?*anyopaque,
) HomeError {
    const src: *HomeVideoFrame = @ptrCast(@alignCast(src_handle));
    const rotation: video.RotationAngle = @enumFromInt(angle);

    const home_frame = allocator.create(HomeVideoFrame) catch {
        setLastError("Out of memory");
        return .out_of_memory;
    };

    var filter = video.RotateFilter{ .angle = rotation };

    home_frame.frame = filter.apply(allocator, &src.frame) catch |err| {
        allocator.destroy(home_frame);
        setLastError("Failed to apply rotate filter");
        return HomeError.fromVideoError(err);
    };

    out_handle.* = home_frame;
    return .ok;
}

// ============================================================================
// Container Demuxing
// ============================================================================

pub const HomeMediaFile = struct {
    file: video.MediaFile,

    fn deinitVoid(ptr: *anyopaque) void {
        const self: *HomeMediaFile = @ptrCast(@alignCast(ptr));
        self.file.deinit();
        allocator.destroy(self);
    }
};

/// Open media file for reading
pub export fn video_media_open(path: CString, out_handle: *?*anyopaque) HomeError {
    _ = path;
    _ = out_handle;
    // Implementation would open and parse media file
    setLastError("Not yet implemented");
    return .unknown_error;
}

/// Get stream count
pub export fn video_media_stream_count(handle: *anyopaque) u32 {
    const self: *HomeMediaFile = @ptrCast(@alignCast(handle));
    return @intCast(self.file.streams.len);
}

/// Get stream info
pub export fn video_media_stream_info(
    handle: *anyopaque,
    stream_index: u32,
    out_type: *c_int,
) HomeError {
    const self: *HomeMediaFile = @ptrCast(@alignCast(handle));

    if (stream_index >= self.file.streams.len) {
        setLastError("Stream index out of bounds");
        return .invalid_argument;
    }

    out_type.* = @intFromEnum(self.file.streams[stream_index].stream_type);
    return .ok;
}

/// Free media file
pub export fn video_media_free(handle: *anyopaque) void {
    const self: *HomeMediaFile = @ptrCast(@alignCast(handle));
    self.file.deinit();
    allocator.destroy(self);
}

// ============================================================================
// Subtitle Operations
// ============================================================================

/// Parse SRT subtitle file
pub export fn video_subtitle_parse_srt(
    data: [*]const u8,
    data_len: usize,
    out_cue_count: *usize,
) HomeError {
    const buffer = data[0..data_len];

    var parser = video.SrtParser.init(allocator);
    defer parser.deinit();

    parser.parse(buffer) catch |err| {
        setLastError("Failed to parse SRT");
        return HomeError.fromVideoError(err);
    };

    out_cue_count.* = parser.cues.items.len;
    return .ok;
}

/// Convert SRT to VTT
pub export fn video_subtitle_srt_to_vtt(
    srt_data: [*]const u8,
    srt_len: usize,
    out_vtt: *?[*]u8,
    out_len: *usize,
) HomeError {
    const srt_buffer = srt_data[0..srt_len];

    const vtt_data = video.srtToVtt(allocator, srt_buffer) catch |err| {
        setLastError("Failed to convert SRT to VTT");
        return HomeError.fromVideoError(err);
    };

    out_vtt.* = vtt_data.ptr;
    out_len.* = vtt_data.len;
    return .ok;
}

// ============================================================================
// Thumbnail Generation
// ============================================================================

/// Extract thumbnail at timestamp
pub export fn video_thumbnail_extract(
    video_path: CString,
    timestamp_us: i64,
    width: u32,
    height: u32,
    out_handle: *?*anyopaque,
) HomeError {
    _ = video_path;
    _ = timestamp_us;
    _ = width;
    _ = height;
    _ = out_handle;

    setLastError("Thumbnail extraction not yet implemented");
    return .unknown_error;
}

// ============================================================================
// Codec Information
// ============================================================================

/// Get codec name as string
pub export fn video_codec_name(codec: c_int) CString {
    const video_codec: video.VideoCodec = @enumFromInt(codec);

    const name = switch (video_codec) {
        .h264 => "H.264/AVC",
        .hevc => "H.265/HEVC",
        .vp9 => "VP9",
        .av1 => "AV1",
        .vvc => "H.266/VVC",
        else => "Unknown",
    };

    return zigStringToHome(name) catch "Unknown";
}

/// Check if codec is supported
pub export fn video_codec_is_supported(codec: c_int) bool {
    const video_codec: video.VideoCodec = @enumFromInt(codec);
    return switch (video_codec) {
        .h264, .hevc, .vp9, .av1, .vvc => true,
        else => false,
    };
}

// ============================================================================
// Version Information
// ============================================================================

pub export fn video_version_major() u32 {
    return video.VERSION.MAJOR;
}

pub export fn video_version_minor() u32 {
    return video.VERSION.MINOR;
}

pub export fn video_version_patch() u32 {
    return video.VERSION.PATCH;
}

pub export fn video_version_string() CString {
    return zigStringToHome(video.VERSION.string()) catch "0.0.0";
}

// ============================================================================
// Initialization and Cleanup
// ============================================================================

pub export fn video_init() HomeError {
    // Perform any global initialization
    return .ok;
}

pub export fn video_cleanup() void {
    // Perform any global cleanup
    _ = gpa.deinit();
}

// ============================================================================
// Memory Operations
// ============================================================================

/// Allocate memory (for use by Home)
pub export fn video_alloc(size: usize) ?[*]u8 {
    const buf = allocator.alloc(u8, size) catch return null;
    return buf.ptr;
}

/// Free memory allocated by video_alloc
pub export fn video_free(ptr: [*]u8, size: usize) void {
    allocator.free(ptr[0..size]);
}
