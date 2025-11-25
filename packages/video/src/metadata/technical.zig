// Home Video Library - Technical Metadata
// Track, format, and timing information

const std = @import("std");
const types = @import("../core/types.zig");

pub const Timestamp = types.Timestamp;
pub const Duration = types.Duration;
pub const Rational = types.Rational;

// Technical stream metadata
pub const StreamMetadata = struct {
    index: u32,
    type: types.StreamType,
    codec: []const u8,
    codec_tag: u32 = 0,
    bit_rate: ?u32 = null,
    max_bit_rate: ?u32 = null,
    duration: ?Duration = null,
    time_base: Rational,
    start_time: ?Timestamp = null,
    frame_count: ?u64 = null,
    language: ?[]const u8 = null,
    title: ?[]const u8 = null,
    default: bool = false,
    forced: bool = false,
    // Video
    width: ?u32 = null,
    height: ?u32 = null,
    fps: ?Rational = null,
    pixel_format: ?types.PixelFormat = null,
    color_space: ?[]const u8 = null,
    color_primaries: ?[]const u8 = null,
    color_transfer: ?[]const u8 = null,
    color_range: ?[]const u8 = null,
    sample_aspect_ratio: ?Rational = null,
    display_aspect_ratio: ?Rational = null,
    // Audio
    sample_rate: ?u32 = null,
    channels: ?u16 = null,
    channel_layout: ?[]const u8 = null,
    sample_format: ?types.AudioSampleFormat = null,
    bits_per_sample: ?u8 = null,
};

// Container format metadata
pub const FormatMetadata = struct {
    container: types.VideoFormat,
    duration: ?Duration = null,
    start_time: ?Timestamp = null,
    bit_rate: ?u32 = null,
    file_size: ?u64 = null,
    creation_time: ?i64 = null,
    modification_time: ?i64 = null,
    stream_count: u32 = 0,
};

// Timing metadata
pub const TimingMetadata = struct {
    time_base: Rational,
    start_time: Timestamp,
    duration: Duration,
    avg_frame_rate: ?Rational = null,
    r_frame_rate: ?Rational = null,
};
