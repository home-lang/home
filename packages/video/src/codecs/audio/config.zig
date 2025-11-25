// Home Video Library - Audio Codec Configuration
// Audio codec selection, quality presets, and format recommendations

const std = @import("std");
const types = @import("../../core/types.zig");

pub const AudioCodec = types.AudioCodec;
pub const SampleFormat = types.SampleFormat;

// ============================================================================
// Audio Quality Presets
// ============================================================================

pub const AudioQuality = enum {
    very_low,
    low,
    medium,
    high,
    very_high,
    lossless,

    /// Get bitrate for lossy codecs
    pub fn toBitrate(self: AudioQuality, codec: AudioCodec, channels: u8, sample_rate: u32) u32 {
        return switch (codec) {
            .aac => switch (self) {
                .very_low => if (channels == 1) 48000 else 64000,
                .low => if (channels == 1) 64000 else 96000,
                .medium => if (channels == 1) 96000 else 128000,
                .high => if (channels == 1) 128000 else 192000,
                .very_high => if (channels == 1) 192000 else 256000,
                .lossless => 0, // N/A for AAC
            },
            .mp3 => switch (self) {
                .very_low => if (channels == 1) 64000 else 96000,
                .low => if (channels == 1) 96000 else 128000,
                .medium => if (channels == 1) 128000 else 192000,
                .high => if (channels == 1) 192000 else 256000,
                .very_high => if (channels == 1) 256000 else 320000,
                .lossless => 0, // N/A for MP3
            },
            .opus => switch (self) {
                .very_low => if (channels == 1) 16000 else 32000,
                .low => if (channels == 1) 24000 else 48000,
                .medium => if (channels == 1) 48000 else 96000,
                .high => if (channels == 1) 96000 else 128000,
                .very_high => if (channels == 1) 128000 else 192000,
                .lossless => 0, // N/A for Opus
            },
            .vorbis => switch (self) {
                .very_low => if (channels == 1) 48000 else 64000,
                .low => if (channels == 1) 64000 else 96000,
                .medium => if (channels == 1) 96000 else 128000,
                .high => if (channels == 1) 128000 else 192000,
                .very_high => if (channels == 1) 192000 else 256000,
                .lossless => 0, // N/A for Vorbis
            },
            .ac3 => switch (self) {
                .very_low => 96000,
                .low => 128000,
                .medium => 192000,
                .high => 256000,
                .very_high => 384000,
                .lossless => 0,
            },
            .flac => 0, // Lossless, no bitrate setting
            .pcm => 0, // Uncompressed
            _ => {
                _ = sample_rate;
                return 128000; // Default
            },
        };
    }

    /// Get FLAC compression level
    pub fn toFlacLevel(self: AudioQuality) u8 {
        return switch (self) {
            .very_low => 0,
            .low => 3,
            .medium => 5,
            .high => 7,
            .very_high, .lossless => 8,
        };
    }

    /// Get Opus complexity
    pub fn toOpusComplexity(self: AudioQuality) u8 {
        return switch (self) {
            .very_low => 0,
            .low => 3,
            .medium => 6,
            .high => 8,
            .very_high, .lossless => 10,
        };
    }
};

// ============================================================================
// Audio Use Case
// ============================================================================

pub const AudioUseCase = enum {
    voice, // Voice/speech
    music, // Music
    mixed, // Mixed content
    podcast, // Podcast/audiobook
    broadcast, // Broadcasting
    telephony, // VoIP/phone
    archival, // Archival/preservation

    /// Get recommended codec
    pub fn recommendCodec(self: AudioUseCase) AudioCodec {
        return switch (self) {
            .voice, .telephony => .opus,
            .music => .aac,
            .mixed => .aac,
            .podcast => .aac,
            .broadcast => .ac3,
            .archival => .flac,
        };
    }

    /// Get recommended sample rate
    pub fn recommendSampleRate(self: AudioUseCase) u32 {
        return switch (self) {
            .voice, .telephony => 16000,
            .podcast => 44100,
            .music, .mixed => 48000,
            .broadcast => 48000,
            .archival => 96000,
        };
    }

    /// Get recommended channels
    pub fn recommendChannels(self: AudioUseCase) u8 {
        return switch (self) {
            .voice, .telephony, .podcast => 1,
            .music, .mixed, .broadcast, .archival => 2,
        };
    }

    /// Get recommended quality
    pub fn recommendQuality(self: AudioUseCase) AudioQuality {
        return switch (self) {
            .voice, .telephony => .medium,
            .podcast => .high,
            .music, .mixed => .very_high,
            .broadcast => .high,
            .archival => .lossless,
        };
    }
};

// ============================================================================
// Channel Layout Configuration
// ============================================================================

pub const ChannelLayout = enum {
    mono,
    stereo,
    stereo_downmix,
    surround_2_1,
    surround_3_0,
    surround_3_1,
    surround_4_0,
    surround_4_1,
    surround_5_0,
    surround_5_1,
    surround_6_0,
    surround_6_1,
    surround_7_0,
    surround_7_1,
    surround_7_1_wide,

    pub fn getChannelCount(self: ChannelLayout) u8 {
        return switch (self) {
            .mono => 1,
            .stereo, .stereo_downmix => 2,
            .surround_2_1 => 3,
            .surround_3_0 => 3,
            .surround_3_1 => 4,
            .surround_4_0 => 4,
            .surround_4_1 => 5,
            .surround_5_0 => 5,
            .surround_5_1 => 6,
            .surround_6_0 => 6,
            .surround_6_1 => 7,
            .surround_7_0 => 7,
            .surround_7_1, .surround_7_1_wide => 8,
        };
    }

    pub fn hasLFE(self: ChannelLayout) bool {
        return switch (self) {
            .surround_2_1,
            .surround_3_1,
            .surround_4_1,
            .surround_5_1,
            .surround_6_1,
            .surround_7_1,
            .surround_7_1_wide,
            => true,
            else => false,
        };
    }

    pub fn toString(self: ChannelLayout) []const u8 {
        return switch (self) {
            .mono => "mono",
            .stereo => "stereo",
            .stereo_downmix => "stereo (downmix)",
            .surround_2_1 => "2.1",
            .surround_3_0 => "3.0",
            .surround_3_1 => "3.1",
            .surround_4_0 => "quad",
            .surround_4_1 => "4.1",
            .surround_5_0 => "5.0",
            .surround_5_1 => "5.1",
            .surround_6_0 => "6.0",
            .surround_6_1 => "6.1",
            .surround_7_0 => "7.0",
            .surround_7_1 => "7.1",
            .surround_7_1_wide => "7.1 (wide)",
        };
    }
};

// ============================================================================
// Audio Encoder Configuration
// ============================================================================

pub const AudioEncoderConfig = struct {
    codec: AudioCodec,
    sample_rate: u32,
    channels: u8,
    channel_layout: ?ChannelLayout = null,
    sample_format: SampleFormat = .f32le,

    // Quality settings
    quality: AudioQuality = .medium,
    bitrate: ?u32 = null, // Override automatic bitrate
    use_vbr: bool = true, // Variable bitrate

    // Advanced options
    frame_size: ?u32 = null, // Codec-specific frame size
    cutoff_freq: ?u32 = null, // Low-pass filter frequency
    apply_phase_inv: bool = true, // AAC phase inversion

    pub fn validate(self: *const AudioEncoderConfig) !void {
        // Validate sample rate
        if (self.sample_rate == 0 or self.sample_rate > 384000) {
            return error.InvalidSampleRate;
        }

        // Validate channels
        if (self.channels == 0 or self.channels > 8) {
            return error.InvalidChannelLayout;
        }

        // Check channel layout matches channel count
        if (self.channel_layout) |layout| {
            if (layout.getChannelCount() != self.channels) {
                return error.ChannelLayoutMismatch;
            }
        }

        // Validate bitrate if specified
        if (self.bitrate) |br| {
            if (br < 8000 or br > 640000) {
                return error.InvalidBitrate;
            }
        }
    }

    pub fn aacDefault(sample_rate: u32, channels: u8) AudioEncoderConfig {
        return .{
            .codec = .aac,
            .sample_rate = sample_rate,
            .channels = channels,
            .quality = .high,
        };
    }

    pub fn mp3Default(sample_rate: u32, channels: u8) AudioEncoderConfig {
        return .{
            .codec = .mp3,
            .sample_rate = sample_rate,
            .channels = channels,
            .quality = .high,
        };
    }

    pub fn opusDefault(sample_rate: u32, channels: u8) AudioEncoderConfig {
        return .{
            .codec = .opus,
            .sample_rate = sample_rate,
            .channels = channels,
            .quality = .high,
        };
    }

    pub fn flacDefault(sample_rate: u32, channels: u8) AudioEncoderConfig {
        return .{
            .codec = .flac,
            .sample_rate = sample_rate,
            .channels = channels,
            .quality = .lossless,
        };
    }

    pub fn forUseCase(use_case: AudioUseCase) AudioEncoderConfig {
        return .{
            .codec = use_case.recommendCodec(),
            .sample_rate = use_case.recommendSampleRate(),
            .channels = use_case.recommendChannels(),
            .quality = use_case.recommendQuality(),
        };
    }

    pub fn getBitrate(self: *const AudioEncoderConfig) u32 {
        if (self.bitrate) |br| return br;
        return self.quality.toBitrate(self.codec, self.channels, self.sample_rate);
    }
};

// ============================================================================
// Codec Capabilities
// ============================================================================

pub const AudioCodecCapabilities = struct {
    codec: AudioCodec,
    can_encode: bool,
    can_decode: bool,
    is_lossless: bool,
    supports_vbr: bool,
    max_channels: u8,
    supported_sample_rates: []const u32,
    supported_sample_formats: []const SampleFormat,

    pub fn query(codec: AudioCodec) AudioCodecCapabilities {
        return switch (codec) {
            .aac => .{
                .codec = .aac,
                .can_encode = true,
                .can_decode = true,
                .is_lossless = false,
                .supports_vbr = true,
                .max_channels = 8,
                .supported_sample_rates = &[_]u32{ 8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000 },
                .supported_sample_formats = &[_]SampleFormat{ .s16le, .f32le },
            },
            .mp3 => .{
                .codec = .mp3,
                .can_encode = true,
                .can_decode = true,
                .is_lossless = false,
                .supports_vbr = true,
                .max_channels = 2,
                .supported_sample_rates = &[_]u32{ 8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000 },
                .supported_sample_formats = &[_]SampleFormat{ .s16le, .f32le },
            },
            .opus => .{
                .codec = .opus,
                .can_encode = true,
                .can_decode = true,
                .is_lossless = false,
                .supports_vbr = true,
                .max_channels = 255,
                .supported_sample_rates = &[_]u32{ 8000, 12000, 16000, 24000, 48000 },
                .supported_sample_formats = &[_]SampleFormat{ .s16le, .f32le },
            },
            .vorbis => .{
                .codec = .vorbis,
                .can_encode = true,
                .can_decode = true,
                .is_lossless = false,
                .supports_vbr = true,
                .max_channels = 255,
                .supported_sample_rates = &[_]u32{ 8000, 11025, 16000, 22050, 32000, 44100, 48000, 88200, 96000, 192000 },
                .supported_sample_formats = &[_]SampleFormat{ .f32le },
            },
            .flac => .{
                .codec = .flac,
                .can_encode = true,
                .can_decode = true,
                .is_lossless = true,
                .supports_vbr = false,
                .max_channels = 8,
                .supported_sample_rates = &[_]u32{ 8000, 11025, 16000, 22050, 32000, 44100, 48000, 88200, 96000, 176400, 192000 },
                .supported_sample_formats = &[_]SampleFormat{ .s16le, .s24le, .s32le },
            },
            .ac3 => .{
                .codec = .ac3,
                .can_encode = true,
                .can_decode = true,
                .is_lossless = false,
                .supports_vbr = false,
                .max_channels = 6,
                .supported_sample_rates = &[_]u32{ 32000, 44100, 48000 },
                .supported_sample_formats = &[_]SampleFormat{ .s16le, .f32le },
            },
            .pcm => .{
                .codec = .pcm,
                .can_encode = true,
                .can_decode = true,
                .is_lossless = true,
                .supports_vbr = false,
                .max_channels = 255,
                .supported_sample_rates = &[_]u32{ 8000, 11025, 16000, 22050, 32000, 44100, 48000, 88200, 96000, 176400, 192000, 384000 },
                .supported_sample_formats = &[_]SampleFormat{ .u8, .s8, .s16le, .s16be, .s24le, .s24be, .s32le, .s32be, .f32le, .f32be, .f64le, .f64be },
            },
            else => .{
                .codec = codec,
                .can_encode = false,
                .can_decode = true,
                .is_lossless = false,
                .supports_vbr = false,
                .max_channels = 2,
                .supported_sample_rates = &[_]u32{44100},
                .supported_sample_formats = &[_]SampleFormat{.s16le},
            },
        };
    }

    pub fn supportsSampleRate(self: *const AudioCodecCapabilities, sample_rate: u32) bool {
        for (self.supported_sample_rates) |sr| {
            if (sr == sample_rate) return true;
        }
        return false;
    }

    pub fn supportsSampleFormat(self: *const AudioCodecCapabilities, format: SampleFormat) bool {
        for (self.supported_sample_formats) |fmt| {
            if (fmt == format) return true;
        }
        return false;
    }

    pub fn getNearestSampleRate(self: *const AudioCodecCapabilities, target: u32) u32 {
        if (self.supported_sample_rates.len == 0) return target;

        var nearest = self.supported_sample_rates[0];
        var min_diff: u32 = @intCast(@abs(@as(i64, target) - @as(i64, nearest)));

        for (self.supported_sample_rates) |sr| {
            const diff: u32 = @intCast(@abs(@as(i64, target) - @as(i64, sr)));
            if (diff < min_diff) {
                min_diff = diff;
                nearest = sr;
            }
        }

        return nearest;
    }
};

// ============================================================================
// Container Format Recommendations
// ============================================================================

pub const ContainerRecommendation = struct {
    pub fn bestCodecForContainer(container: types.VideoFormat) AudioCodec {
        return switch (container) {
            .mp4, .mov => .aac,
            .webm => .opus,
            .mkv => .aac,
            .avi => .mp3,
            .flv => .aac,
            .ogg => .vorbis,
            .wav => .pcm,
            .flac => .flac,
            else => .aac,
        };
    }

    pub fn isCodecCompatible(codec: AudioCodec, container: types.VideoFormat) bool {
        return switch (container) {
            .mp4, .mov => codec == .aac or codec == .mp3 or codec == .ac3,
            .webm => codec == .opus or codec == .vorbis,
            .mkv => true, // Supports all codecs
            .avi => codec == .mp3 or codec == .ac3 or codec == .pcm,
            .flv => codec == .aac or codec == .mp3,
            .ogg => codec == .opus or codec == .vorbis or codec == .flac,
            .wav => codec == .pcm,
            .flac => codec == .flac,
            else => false,
        };
    }
};
