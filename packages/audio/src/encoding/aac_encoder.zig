// Home Audio Library - AAC Encoder
// Legacy prototype/configuration helpers. encode rejects unsupported payloads.
// For interoperable AAC-LC use native_aac.zig (opt-in standalone FDK codec).

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = std.math;

/// AAC profile
pub const AacProfile = enum(u5) {
    aac_main = 1,
    aac_lc = 2, // Low Complexity (most common)
    aac_ssr = 3,
    aac_ltp = 4,
    sbr = 5, // Spectral Band Replication
    aac_scalable = 6,

    pub fn getAudioObjectType(self: AacProfile) u5 {
        return @as(u5, @bitCast(self));
    }
};

/// AAC encoder quality
pub const AacQuality = enum {
    low, // ~64 kbps
    medium, // ~128 kbps
    high, // ~192 kbps
    best, // ~256 kbps

    pub fn getBitrate(self: AacQuality) u32 {
        return switch (self) {
            .low => 64,
            .medium => 128,
            .high => 192,
            .best => 256,
        };
    }
};

/// Sample rate index for AAC
pub const SampleRateIndex = enum(u4) {
    rate_96000 = 0,
    rate_88200 = 1,
    rate_64000 = 2,
    rate_48000 = 3,
    rate_44100 = 4,
    rate_32000 = 5,
    rate_24000 = 6,
    rate_22050 = 7,
    rate_16000 = 8,
    rate_12000 = 9,
    rate_11025 = 10,
    rate_8000 = 11,
    rate_7350 = 12,
    reserved1 = 13,
    reserved2 = 14,
    explicit = 15,

    pub fn fromRate(rate: u32) SampleRateIndex {
        return switch (rate) {
            96000 => .rate_96000,
            88200 => .rate_88200,
            64000 => .rate_64000,
            48000 => .rate_48000,
            44100 => .rate_44100,
            32000 => .rate_32000,
            24000 => .rate_24000,
            22050 => .rate_22050,
            16000 => .rate_16000,
            12000 => .rate_12000,
            11025 => .rate_11025,
            8000 => .rate_8000,
            7350 => .rate_7350,
            else => .rate_44100,
        };
    }
};

/// Channel configuration
pub const ChannelConfig = enum(u4) {
    specific = 0, // Defined in program_config_element()
    mono = 1, // 1 channel: center
    stereo = 2, // 2 channels: left, right
    three = 3, // 3 channels: center, left, right
    four = 4, // 4 channels: center, left, right, rear
    five = 5, // 5 channels: center, left, right, left surround, right surround
    five_one = 6, // 5.1 channels
    seven_one = 7, // 7.1 channels
    reserved = 8,

    pub fn fromChannels(channels: u8) ChannelConfig {
        return switch (channels) {
            1 => .mono,
            2 => .stereo,
            3 => .three,
            4 => .four,
            5 => .five,
            6 => .five_one,
            8 => .seven_one,
            else => .stereo,
        };
    }
};

/// ADTS (Audio Data Transport Stream) frame header
pub const AdtsHeader = struct {
    syncword: u12 = 0xFFF, // Always 0xFFF
    id: u1 = 0, // 0 = MPEG-4, 1 = MPEG-2
    layer: u2 = 0, // Always 0
    protection_absent: bool = true,
    profile: u2, // Audio Object Type - 1
    sampling_frequency_index: u4,
    private_bit: u1 = 0,
    channel_configuration: u3,
    original_copy: u1 = 0,
    home: u1 = 0,
    copyright_id_bit: u1 = 0,
    copyright_id_start: u1 = 0,
    frame_length: u13,
    adts_buffer_fullness: u11 = 0x7FF, // VBR
    number_of_raw_data_blocks: u2 = 0, // 1 raw data block

    pub fn encode(self: AdtsHeader) [7]u8 {
        var header: [7]u8 = undefined;

        // Byte 0: syncword high 8 bits
        header[0] = 0xFF;

        // Byte 1: syncword low 4 bits + id + layer + protection
        header[1] = 0xF0;
        header[1] |= @as(u8, self.id) << 3;
        header[1] |= @as(u8, self.layer) << 1;
        header[1] |= if (self.protection_absent) 1 else 0;

        // Byte 2: profile + sampling freq index + private + channel config high 2 bits
        header[2] = @as(u8, self.profile) << 6;
        header[2] |= @as(u8, self.sampling_frequency_index) << 2;
        header[2] |= @as(u8, self.private_bit) << 1;
        header[2] |= @as(u8, (self.channel_configuration >> 2) & 1);

        // Byte 3: channel config low 2 bits + original + home + copyright + frame length high 2 bits
        header[3] = @as(u8, self.channel_configuration & 3) << 6;
        header[3] |= @as(u8, self.original_copy) << 5;
        header[3] |= @as(u8, self.home) << 4;
        header[3] |= @as(u8, self.copyright_id_bit) << 3;
        header[3] |= @as(u8, self.copyright_id_start) << 2;
        header[3] |= @as(u8, @truncate((self.frame_length >> 11) & 3));

        // Byte 4: frame length middle 8 bits
        header[4] = @as(u8, @truncate((self.frame_length >> 3) & 0xFF));

        // Byte 5: frame length low 3 bits + buffer fullness high 5 bits
        header[5] = @as(u8, @truncate(self.frame_length & 7)) << 5;
        header[5] |= @as(u8, @truncate((self.adts_buffer_fullness >> 6) & 0x1F));

        // Byte 6: buffer fullness low 6 bits + number of raw data blocks
        header[6] = @as(u8, @truncate(self.adts_buffer_fullness & 0x3F)) << 2;
        header[6] |= @as(u8, self.number_of_raw_data_blocks);

        return header;
    }
};

/// AAC encoder
pub const AacEncoder = struct {
    allocator: Allocator,
    sample_rate: u32,
    channels: u8,
    bitrate: u32,
    profile: AacProfile,

    // Output buffer
    output: std.ArrayList(u8),

    // MDCT state
    mdct_buffer: []f32,
    prev_samples: []f32,

    // Quantization state
    scale_factors: []u8,

    // Frame counter
    frame_count: u32,

    const Self = @This();

    pub const SAMPLES_PER_FRAME = 1024; // AAC LC frame size
    pub const NUM_SCALE_FACTOR_BANDS = 49; // Max for long windows

    pub fn init(allocator: Allocator, sample_rate: u32, channels: u8, quality: AacQuality) !Self {
        return initWithProfile(allocator, sample_rate, channels, quality, .aac_lc);
    }

    pub fn initWithProfile(
        allocator: Allocator,
        sample_rate: u32,
        channels: u8,
        quality: AacQuality,
        profile: AacProfile,
    ) !Self {
        const mdct_buffer = try allocator.alloc(f32, SAMPLES_PER_FRAME * 2);
        errdefer allocator.free(mdct_buffer);
        const prev_samples = try allocator.alloc(f32, SAMPLES_PER_FRAME * @as(usize, channels));
        errdefer allocator.free(prev_samples);
        const scale_factors = try allocator.alloc(u8, NUM_SCALE_FACTOR_BANDS);
        return Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .channels = channels,
            .bitrate = quality.getBitrate(),
            .profile = profile,
            .output = .empty,
            .mdct_buffer = mdct_buffer,
            .prev_samples = prev_samples,
            .scale_factors = scale_factors,
            .frame_count = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.output.deinit(self.allocator);
        self.allocator.free(self.mdct_buffer);
        self.allocator.free(self.prev_samples);
        self.allocator.free(self.scale_factors);
    }

    /// The old envelope payload was not AAC. Never return it as encoded audio.
    /// Use native_aac.Encoder for verified raw AAC-LC packets and codec delay.
    pub fn encode(self: *Self, samples: []const f32) !void {
        _ = self;
        _ = samples;
        return error.UnsupportedLegacyEncoder;
    }

    /// Finalize and return encoded AAC data
    pub fn finalize(self: *Self) ![]u8 {
        return try self.allocator.dupe(u8, self.output.items);
    }

    /// Get encoded data
    pub fn getData(self: *Self) []const u8 {
        return self.output.items;
    }

    /// Reset encoder
    pub fn reset(self: *Self) void {
        self.output.clearRetainingCapacity();
        @memset(self.mdct_buffer, 0);
        @memset(self.prev_samples, 0);
        self.frame_count = 0;
    }

    /// Get frame count
    pub fn getFrameCount(self: *Self) u32 {
        return self.frame_count;
    }

    /// Get duration in seconds
    pub fn getDuration(self: *Self) f64 {
        return @as(f64, @floatFromInt(self.frame_count)) * SAMPLES_PER_FRAME / @as(f64, @floatFromInt(self.sample_rate));
    }
};

/// Audio Specific Config generator (for MP4/M4A containers)
pub const AudioSpecificConfig = struct {
    audio_object_type: AacProfile,
    sample_rate: u32,
    channels: u8,

    pub fn encode(self: AudioSpecificConfig) [2]u8 {
        var config: [2]u8 = undefined;

        const aot = self.audio_object_type.getAudioObjectType();
        const sri = @as(u4, @bitCast(SampleRateIndex.fromRate(self.sample_rate)));
        const cc = @backingInt(ChannelConfig.fromChannels(self.channels));

        // audioObjectType (5 bits) + samplingFrequencyIndex (4 bits)
        config[0] = @as(u8, aot) << 3;
        config[0] |= @as(u8, @intCast((sri >> 1) & 0x07));

        // samplingFrequencyIndex (1 bit) + channelConfiguration (4 bits) + padding (3 bits)
        config[1] = @as(u8, @intCast((sri & 1))) << 7;
        config[1] |= @as(u8, @intCast(cc)) << 3;

        return config;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "AacEncoder init" {
    const allocator = std.testing.allocator;

    var encoder = try AacEncoder.init(allocator, 44100, 2, .medium);
    defer encoder.deinit();

    try std.testing.expectEqual(@as(u32, 128), encoder.bitrate);
}

test "AacEncoder encode" {
    const allocator = std.testing.allocator;

    var encoder = try AacEncoder.init(allocator, 44100, 1, .medium);
    defer encoder.deinit();

    var samples: [AacEncoder.SAMPLES_PER_FRAME]f32 = undefined;
    for (0..AacEncoder.SAMPLES_PER_FRAME) |i| {
        const t = @as(f32, @floatFromInt(i)) / 44100.0;
        samples[i] = @sin(t * 440 * 2 * math.pi);
    }

    try std.testing.expectError(error.UnsupportedLegacyEncoder, encoder.encode(&samples));
    try std.testing.expectEqual(@as(u32, 0), encoder.getFrameCount());
}

test "AdtsHeader encode" {
    const header = AdtsHeader{
        .profile = 1, // LC
        .sampling_frequency_index = 4, // 44100 Hz
        .channel_configuration = 2, // Stereo
        .frame_length = 100,
    };

    const bytes = header.encode();
    try std.testing.expectEqual(@as(u8, 0xFF), bytes[0]);
    try std.testing.expectEqual(@as(u8, 0xF1), bytes[1] & 0xF1);
}

test "AudioSpecificConfig encode" {
    const config = AudioSpecificConfig{
        .audio_object_type = .aac_lc,
        .sample_rate = 44100,
        .channels = 2,
    };

    const bytes = config.encode();
    try std.testing.expect(bytes[0] != 0); // Should have content
}
test "legacy AAC allocation failure releases earlier buffers" {
    const Check = struct {
        fn run(allocator: Allocator) !void {
            var encoder = try AacEncoder.init(allocator, 48000, 2, .medium);
            defer encoder.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}
