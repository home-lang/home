// Home Audio Library - AAC Encoder
// Pure Zig Advanced Audio Coding encoder
// Simplified LC-AAC implementation

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
        return @intFromEnum(self);
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
        return Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .channels = channels,
            .bitrate = quality.getBitrate(),
            .profile = profile,
            .output = .{},
            .mdct_buffer = try allocator.alloc(f32, SAMPLES_PER_FRAME * 2),
            .prev_samples = try allocator.alloc(f32, SAMPLES_PER_FRAME * @as(usize, channels)),
            .scale_factors = try allocator.alloc(u8, NUM_SCALE_FACTOR_BANDS),
            .frame_count = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.output.deinit(self.allocator);
        self.allocator.free(self.mdct_buffer);
        self.allocator.free(self.prev_samples);
        self.allocator.free(self.scale_factors);
    }

    /// Encode PCM samples to AAC (ADTS format)
    pub fn encode(self: *Self, samples: []const f32) !void {
        const frame_samples = SAMPLES_PER_FRAME * @as(usize, self.channels);
        var pos: usize = 0;

        while (pos + frame_samples <= samples.len) {
            try self.encodeFrame(samples[pos .. pos + frame_samples]);
            pos += frame_samples;
        }
    }

    /// Encode a single AAC frame
    fn encodeFrame(self: *Self, samples: []const f32) !void {
        // Simplified AAC encoding:
        // 1. Apply MDCT
        // 2. Quantize spectral coefficients
        // 3. Huffman encode
        // 4. Pack into ADTS frame

        // For this implementation, we create simplified encoded data
        var frame_data: std.ArrayList(u8) = .{};
        defer frame_data.deinit(self.allocator);

        // Encode raw data block
        try self.encodeRawDataBlock(samples, &frame_data);

        // Calculate total frame size (header + data)
        const frame_length: u13 = @intCast(7 + frame_data.items.len);

        // Create ADTS header
        const header = AdtsHeader{
            .profile = @intCast(@intFromEnum(self.profile) - 1),
            .sampling_frequency_index = @intFromEnum(SampleRateIndex.fromRate(self.sample_rate)),
            .channel_configuration = @intCast(@intFromEnum(ChannelConfig.fromChannels(self.channels))),
            .frame_length = frame_length,
        };

        // Write header
        const header_bytes = header.encode();
        try self.output.appendSlice(self.allocator, &header_bytes);

        // Write data
        try self.output.appendSlice(self.allocator, frame_data.items);

        self.frame_count += 1;
    }

    fn encodeRawDataBlock(self: *Self, samples: []const f32, data: *std.ArrayList(u8)) !void {
        // Simplified encoding: just store quantized spectral data
        // Real AAC encoding involves:
        // 1. Psychoacoustic analysis
        // 2. TNS (Temporal Noise Shaping)
        // 3. M/S stereo coding
        // 4. Intensity stereo
        // 5. Scale factor band grouping
        // 6. Huffman coding

        // Mix to mono for simplified encoding
        var mono_samples: [SAMPLES_PER_FRAME]f32 = undefined;
        for (0..SAMPLES_PER_FRAME) |i| {
            if (self.channels == 2 and i * 2 + 1 < samples.len) {
                mono_samples[i] = (samples[i * 2] + samples[i * 2 + 1]) * 0.5;
            } else if (i * self.channels < samples.len) {
                mono_samples[i] = samples[i * self.channels];
            } else {
                mono_samples[i] = 0;
            }
        }

        // Apply simple windowing (sine window)
        var windowed: [SAMPLES_PER_FRAME * 2]f32 = undefined;
        @memcpy(windowed[0..SAMPLES_PER_FRAME], self.prev_samples[0..SAMPLES_PER_FRAME]);
        @memcpy(windowed[SAMPLES_PER_FRAME..], &mono_samples);
        @memcpy(self.prev_samples[0..SAMPLES_PER_FRAME], &mono_samples);

        for (0..SAMPLES_PER_FRAME * 2) |i| {
            const w = @sin(math.pi / (2.0 * SAMPLES_PER_FRAME * 2) * (@as(f32, @floatFromInt(i)) + 0.5));
            windowed[i] *= w;
        }

        // Simplified MDCT output (just store envelope)
        const bytes_per_frame = @max(32, self.bitrate * SAMPLES_PER_FRAME / self.sample_rate / 8);

        for (0..bytes_per_frame) |i| {
            // Simple spectral envelope approximation
            const start = i * SAMPLES_PER_FRAME / bytes_per_frame;
            const end = (i + 1) * SAMPLES_PER_FRAME / bytes_per_frame;

            var energy: f32 = 0;
            for (start..end) |j| {
                energy += windowed[j] * windowed[j];
            }
            energy = @sqrt(energy / @as(f32, @floatFromInt(end - start)));

            const quantized: u8 = @intFromFloat(std.math.clamp(energy * 255.0, 0, 255));
            try data.append(self.allocator, quantized);
        }
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
        const sri = @intFromEnum(SampleRateIndex.fromRate(self.sample_rate));
        const cc = @intFromEnum(ChannelConfig.fromChannels(self.channels));

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

    try encoder.encode(&samples);
    try std.testing.expect(encoder.getFrameCount() > 0);
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
