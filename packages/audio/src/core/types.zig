// Home Audio Library - Core Types
// Common types used throughout the audio library

const std = @import("std");

// ============================================================================
// Audio Format Types
// ============================================================================

/// Supported audio container formats
pub const AudioFormat = enum {
    wav, // Waveform Audio File Format
    mp3, // MPEG Audio Layer III
    flac, // Free Lossless Audio Codec
    ogg, // Ogg Vorbis
    aac, // Advanced Audio Coding
    m4a, // MPEG-4 Audio (AAC container)
    aiff, // Audio Interchange File Format
    opus, // Opus Interactive Audio Codec
    wma, // Windows Media Audio
    alac, // Apple Lossless Audio Codec
    unknown,

    pub fn fromExtension(ext: []const u8) AudioFormat {
        if (std.mem.eql(u8, ext, ".wav") or std.mem.eql(u8, ext, ".wave")) return .wav;
        if (std.mem.eql(u8, ext, ".mp3")) return .mp3;
        if (std.mem.eql(u8, ext, ".flac")) return .flac;
        if (std.mem.eql(u8, ext, ".ogg") or std.mem.eql(u8, ext, ".oga")) return .ogg;
        if (std.mem.eql(u8, ext, ".aac")) return .aac;
        if (std.mem.eql(u8, ext, ".m4a")) return .m4a;
        if (std.mem.eql(u8, ext, ".aiff") or std.mem.eql(u8, ext, ".aif")) return .aiff;
        if (std.mem.eql(u8, ext, ".opus")) return .opus;
        if (std.mem.eql(u8, ext, ".wma")) return .wma;
        if (std.mem.eql(u8, ext, ".alac")) return .alac;
        return .unknown;
    }

    pub fn fromMagicBytes(data: []const u8) AudioFormat {
        if (data.len < 4) return .unknown;

        // WAV: RIFF....WAVE
        if (data.len >= 12 and std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WAVE")) {
            return .wav;
        }

        // AIFF: FORM....AIFF
        if (data.len >= 12 and std.mem.eql(u8, data[0..4], "FORM") and std.mem.eql(u8, data[8..12], "AIFF")) {
            return .aiff;
        }

        // FLAC: fLaC
        if (std.mem.eql(u8, data[0..4], "fLaC")) {
            return .flac;
        }

        // Ogg: OggS
        if (std.mem.eql(u8, data[0..4], "OggS")) {
            return .ogg;
        }

        // MP3: ID3 tag or frame sync
        if (data.len >= 3 and std.mem.eql(u8, data[0..3], "ID3")) {
            return .mp3;
        }
        // MP3 frame sync: 0xFF 0xFB, 0xFF 0xFA, 0xFF 0xF3, 0xFF 0xF2
        if (data.len >= 2 and data[0] == 0xFF and (data[1] & 0xE0) == 0xE0) {
            return .mp3;
        }

        // M4A/AAC: ftyp box
        if (data.len >= 8 and std.mem.eql(u8, data[4..8], "ftyp")) {
            if (data.len >= 12) {
                if (std.mem.eql(u8, data[8..12], "M4A ") or
                    std.mem.eql(u8, data[8..12], "mp42") or
                    std.mem.eql(u8, data[8..12], "isom"))
                {
                    return .m4a;
                }
            }
            return .aac;
        }

        // AAC ADTS header
        if (data.len >= 2 and data[0] == 0xFF and (data[1] & 0xF0) == 0xF0) {
            return .aac;
        }

        // WMA/ASF: ASF header GUID (30 26 B2 75 8E 66 CF 11 A6 D9 00 AA 00 62 CE 6C)
        if (data.len >= 16) {
            const asf_header: [16]u8 = .{
                0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11,
                0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C,
            };
            if (std.mem.eql(u8, data[0..16], &asf_header)) {
                return .wma;
            }
        }

        return .unknown;
    }

    pub fn mimeType(self: AudioFormat) []const u8 {
        return switch (self) {
            .wav => "audio/wav",
            .mp3 => "audio/mpeg",
            .flac => "audio/flac",
            .ogg => "audio/ogg",
            .aac => "audio/aac",
            .m4a => "audio/mp4",
            .aiff => "audio/aiff",
            .opus => "audio/opus",
            .wma => "audio/x-ms-wma",
            .alac => "audio/mp4",
            .unknown => "application/octet-stream",
        };
    }

    pub fn fileExtension(self: AudioFormat) []const u8 {
        return switch (self) {
            .wav => ".wav",
            .mp3 => ".mp3",
            .flac => ".flac",
            .ogg => ".ogg",
            .aac => ".aac",
            .m4a => ".m4a",
            .aiff => ".aiff",
            .opus => ".opus",
            .wma => ".wma",
            .alac => ".alac",
            .unknown => "",
        };
    }

    pub fn isLossless(self: AudioFormat) bool {
        return switch (self) {
            .wav, .flac, .aiff, .alac => true,
            else => false,
        };
    }
};

// ============================================================================
// Sample Format
// ============================================================================

/// Audio sample format
pub const SampleFormat = enum {
    // Unsigned
    u8, // 8-bit unsigned

    // Signed little-endian
    s16le, // 16-bit signed little-endian
    s24le, // 24-bit signed little-endian
    s32le, // 32-bit signed little-endian

    // Signed big-endian
    s16be, // 16-bit signed big-endian
    s24be, // 24-bit signed big-endian
    s32be, // 32-bit signed big-endian

    // Floating point
    f32le, // 32-bit float little-endian
    f64le, // 64-bit float little-endian
    f32be, // 32-bit float big-endian
    f64be, // 64-bit float big-endian

    // Compressed/encoded
    alaw, // A-law encoded
    ulaw, // μ-law encoded

    pub fn bytesPerSample(self: SampleFormat) u8 {
        return switch (self) {
            .u8, .alaw, .ulaw => 1,
            .s16le, .s16be => 2,
            .s24le, .s24be => 3,
            .s32le, .s32be, .f32le, .f32be => 4,
            .f64le, .f64be => 8,
        };
    }

    pub fn bitsPerSample(self: SampleFormat) u8 {
        return self.bytesPerSample() * 8;
    }

    pub fn isFloat(self: SampleFormat) bool {
        return switch (self) {
            .f32le, .f64le, .f32be, .f64be => true,
            else => false,
        };
    }

    pub fn isBigEndian(self: SampleFormat) bool {
        return switch (self) {
            .s16be, .s24be, .s32be, .f32be, .f64be => true,
            else => false,
        };
    }

    pub fn isSigned(self: SampleFormat) bool {
        return switch (self) {
            .u8, .alaw, .ulaw => false,
            else => true,
        };
    }
};

// ============================================================================
// Channel Layout
// ============================================================================

/// Standard channel layouts
pub const ChannelLayout = enum {
    mono, // 1 channel
    stereo, // 2 channels (L, R)
    stereo_21, // 2.1 channels (L, R, LFE)
    surround_30, // 3.0 channels (L, R, C)
    surround_31, // 3.1 channels (L, R, C, LFE)
    quad, // 4.0 channels (L, R, SL, SR)
    surround_50, // 5.0 channels (L, R, C, SL, SR)
    surround_51, // 5.1 channels (L, R, C, LFE, SL, SR)
    surround_61, // 6.1 channels
    surround_71, // 7.1 channels
    custom, // Custom layout

    pub fn channelCount(self: ChannelLayout) u8 {
        return switch (self) {
            .mono => 1,
            .stereo => 2,
            .stereo_21 => 3,
            .surround_30 => 3,
            .surround_31 => 4,
            .quad => 4,
            .surround_50 => 5,
            .surround_51 => 6,
            .surround_61 => 7,
            .surround_71 => 8,
            .custom => 0,
        };
    }

    pub fn fromChannelCount(count: u8) ChannelLayout {
        return switch (count) {
            1 => .mono,
            2 => .stereo,
            3 => .surround_30,
            4 => .quad,
            5 => .surround_50,
            6 => .surround_51,
            7 => .surround_61,
            8 => .surround_71,
            else => .custom,
        };
    }
};

/// Individual channel types
pub const ChannelType = enum {
    front_left,
    front_right,
    front_center,
    lfe, // Low Frequency Effects (subwoofer)
    back_left,
    back_right,
    back_center,
    side_left,
    side_right,
    top_center,
    top_front_left,
    top_front_center,
    top_front_right,
    top_back_left,
    top_back_center,
    top_back_right,
};

// ============================================================================
// Audio Codec
// ============================================================================

/// Audio codec identifiers
pub const AudioCodec = enum {
    // Uncompressed
    pcm_s16le,
    pcm_s16be,
    pcm_s24le,
    pcm_s24be,
    pcm_s32le,
    pcm_s32be,
    pcm_f32le,
    pcm_f32be,
    pcm_f64le,
    pcm_f64be,
    pcm_u8,
    pcm_alaw,
    pcm_ulaw,

    // Lossy compressed
    mp3,
    aac,
    vorbis,
    opus,
    wma,
    ac3,
    eac3,
    dts,

    // Lossless compressed
    flac,
    alac,
    ape,
    wavpack,

    unknown,

    pub fn isLossless(self: AudioCodec) bool {
        return switch (self) {
            .pcm_s16le, .pcm_s16be, .pcm_s24le, .pcm_s24be, .pcm_s32le, .pcm_s32be, .pcm_f32le, .pcm_f32be, .pcm_f64le, .pcm_f64be, .pcm_u8, .pcm_alaw, .pcm_ulaw, .flac, .alac, .ape, .wavpack => true,
            else => false,
        };
    }
};

// ============================================================================
// Time Types
// ============================================================================

/// Timestamp in microseconds
pub const Timestamp = struct {
    us: i64,

    const Self = @This();

    pub const ZERO = Self{ .us = 0 };
    pub const INVALID = Self{ .us = std.math.minInt(i64) };

    pub fn fromMicroseconds(us: i64) Self {
        return .{ .us = us };
    }

    pub fn fromMilliseconds(ms: i64) Self {
        return .{ .us = ms * 1000 };
    }

    pub fn fromSeconds(s: f64) Self {
        return .{ .us = @intFromFloat(s * 1_000_000.0) };
    }

    pub fn fromSamples(samples: u64, sample_rate: u32) Self {
        const us = @divFloor(samples * 1_000_000, sample_rate);
        return .{ .us = @intCast(us) };
    }

    pub fn toMicroseconds(self: Self) i64 {
        return self.us;
    }

    pub fn toMilliseconds(self: Self) i64 {
        return @divFloor(self.us, 1000);
    }

    pub fn toSeconds(self: Self) f64 {
        return @as(f64, @floatFromInt(self.us)) / 1_000_000.0;
    }

    pub fn toSamples(self: Self, sample_rate: u32) u64 {
        if (self.us < 0) return 0;
        return @intCast(@divFloor(@as(u64, @intCast(self.us)) * sample_rate, 1_000_000));
    }

    pub fn add(self: Self, other: Self) Self {
        return .{ .us = self.us + other.us };
    }

    pub fn sub(self: Self, other: Self) Self {
        return .{ .us = self.us - other.us };
    }

    pub fn isValid(self: Self) bool {
        return self.us != std.math.minInt(i64);
    }
};

/// Duration in microseconds
pub const Duration = struct {
    us: u64,

    const Self = @This();

    pub const ZERO = Self{ .us = 0 };

    pub fn fromMicroseconds(us: u64) Self {
        return .{ .us = us };
    }

    pub fn fromMilliseconds(ms: u64) Self {
        return .{ .us = ms * 1000 };
    }

    pub fn fromSeconds(s: f64) Self {
        return .{ .us = @intFromFloat(s * 1_000_000.0) };
    }

    pub fn fromSamples(samples: u64, sample_rate: u32) Self {
        return .{ .us = @divFloor(samples * 1_000_000, sample_rate) };
    }

    pub fn toMicroseconds(self: Self) u64 {
        return self.us;
    }

    pub fn toMilliseconds(self: Self) u64 {
        return @divFloor(self.us, 1000);
    }

    pub fn toSeconds(self: Self) f64 {
        return @as(f64, @floatFromInt(self.us)) / 1_000_000.0;
    }

    pub fn toSamples(self: Self, sample_rate: u32) u64 {
        return @divFloor(self.us * sample_rate, 1_000_000);
    }
};

// ============================================================================
// Quality Settings
// ============================================================================

/// Quality preset for encoding
pub const QualityPreset = enum {
    lowest, // Smallest file size
    low,
    medium,
    high,
    highest, // Best quality
    lossless, // Lossless encoding

    pub fn toBitrate(self: QualityPreset) u32 {
        return switch (self) {
            .lowest => 64_000, // 64 kbps
            .low => 128_000, // 128 kbps
            .medium => 192_000, // 192 kbps
            .high => 256_000, // 256 kbps
            .highest => 320_000, // 320 kbps
            .lossless => 0, // N/A for lossless
        };
    }
};

/// Encoding options
pub const EncoderOptions = struct {
    /// Quality preset
    quality: QualityPreset = .medium,

    /// Target bitrate in bits per second (0 = VBR based on quality)
    bitrate: u32 = 0,

    /// Variable bitrate mode
    vbr: bool = true,

    /// Sample rate (0 = keep original)
    sample_rate: u32 = 0,

    /// Number of channels (0 = keep original)
    channels: u8 = 0,

    /// Enable metadata writing
    write_metadata: bool = true,
};

// ============================================================================
// Metadata
// ============================================================================

/// Audio file metadata
pub const Metadata = struct {
    title: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    album_artist: ?[]const u8 = null,
    composer: ?[]const u8 = null,
    genre: ?[]const u8 = null,
    year: ?u16 = null,
    track_number: ?u16 = null,
    track_total: ?u16 = null,
    disc_number: ?u16 = null,
    disc_total: ?u16 = null,
    comment: ?[]const u8 = null,
    lyrics: ?[]const u8 = null,
    copyright: ?[]const u8 = null,
    encoder: ?[]const u8 = null,

    // Album art
    cover_art: ?[]const u8 = null,
    cover_art_mime: ?[]const u8 = null,

    allocator: ?std.mem.Allocator = null,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        if (self.allocator) |alloc| {
            if (self.title) |t| alloc.free(t);
            if (self.artist) |a| alloc.free(a);
            if (self.album) |a| alloc.free(a);
            if (self.album_artist) |a| alloc.free(a);
            if (self.composer) |c| alloc.free(c);
            if (self.genre) |g| alloc.free(g);
            if (self.comment) |c| alloc.free(c);
            if (self.lyrics) |l| alloc.free(l);
            if (self.copyright) |c| alloc.free(c);
            if (self.encoder) |e| alloc.free(e);
            if (self.cover_art) |c| alloc.free(c);
            if (self.cover_art_mime) |m| alloc.free(m);
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "AudioFormat detection" {
    const wav_magic = [_]u8{ 'R', 'I', 'F', 'F', 0, 0, 0, 0, 'W', 'A', 'V', 'E' };
    try std.testing.expectEqual(AudioFormat.wav, AudioFormat.fromMagicBytes(&wav_magic));

    const flac_magic = [_]u8{ 'f', 'L', 'a', 'C' };
    try std.testing.expectEqual(AudioFormat.flac, AudioFormat.fromMagicBytes(&flac_magic));

    const ogg_magic = [_]u8{ 'O', 'g', 'g', 'S' };
    try std.testing.expectEqual(AudioFormat.ogg, AudioFormat.fromMagicBytes(&ogg_magic));
}

test "SampleFormat properties" {
    try std.testing.expectEqual(@as(u8, 2), SampleFormat.s16le.bytesPerSample());
    try std.testing.expectEqual(@as(u8, 4), SampleFormat.f32le.bytesPerSample());
    try std.testing.expect(SampleFormat.f32le.isFloat());
    try std.testing.expect(!SampleFormat.s16le.isFloat());
}

test "Timestamp conversions" {
    const ts = Timestamp.fromSeconds(1.5);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), ts.toSeconds(), 0.0001);
    try std.testing.expectEqual(@as(i64, 1500), ts.toMilliseconds());
}

test "Duration conversions" {
    const d = Duration.fromSeconds(60.0);
    try std.testing.expectEqual(@as(u64, 60000), d.toMilliseconds());
    try std.testing.expectEqual(@as(u64, 2646000), d.toSamples(44100));
}

test "ChannelLayout" {
    try std.testing.expectEqual(@as(u8, 2), ChannelLayout.stereo.channelCount());
    try std.testing.expectEqual(@as(u8, 6), ChannelLayout.surround_51.channelCount());
    try std.testing.expectEqual(ChannelLayout.stereo, ChannelLayout.fromChannelCount(2));
}
