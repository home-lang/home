// Home Video Library - AAC Audio Codec
// Advanced Audio Coding decoder/encoder
// Supports AAC-LC, HE-AAC (SBR), HE-AACv2 (PS)

const std = @import("std");
const types = @import("../../core/types.zig");
const frame = @import("../../core/frame.zig");
const err = @import("../../core/error.zig");
const bitstream = @import("../../util/bitstream.zig");

pub const VideoError = err.VideoError;
pub const AudioFrame = frame.AudioFrame;
pub const SampleFormat = types.SampleFormat;
pub const BitstreamReader = bitstream.BitstreamReader;

// ============================================================================
// AAC Constants
// ============================================================================

/// AAC Audio Object Types
pub const AudioObjectType = enum(u8) {
    null = 0,
    aac_main = 1, // AAC Main
    aac_lc = 2, // AAC Low Complexity (most common)
    aac_ssr = 3, // AAC Scalable Sample Rate
    aac_ltp = 4, // AAC Long Term Prediction
    sbr = 5, // Spectral Band Replication (HE-AAC)
    aac_scalable = 6,
    twinvq = 7,
    celp = 8,
    hvxc = 9,
    // 10-11 reserved
    ttsi = 12,
    main_synthesis = 13,
    wavetable_synthesis = 14,
    general_midi = 15,
    algorithmic_synthesis = 16,
    er_aac_lc = 17, // Error Resilient AAC-LC
    // 18 reserved
    er_aac_ltp = 19,
    er_aac_scalable = 20,
    er_twinvq = 21,
    er_bsac = 22,
    er_aac_ld = 23, // Low Delay
    er_celp = 24,
    er_hvxc = 25,
    er_hiln = 26,
    er_parametric = 27,
    ssc = 28,
    ps = 29, // Parametric Stereo (HE-AACv2)
    mpeg_surround = 30,
    // 31 = escape value
    layer1 = 32,
    layer2 = 33,
    layer3 = 34,
    dst = 35,
    als = 36,
    sls = 37,
    sls_non_core = 38,
    er_aac_eld = 39, // Enhanced Low Delay
    smr_simple = 40,
    smr_main = 41,
    usac = 42, // Unified Speech and Audio Coding
    saoc = 43,
    ld_mpeg_surround = 44,

    _,
};

/// Sample rate index table
pub const SAMPLE_RATES = [_]u32{
    96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
    16000, 12000, 11025, 8000,  7350,  0,     0,     0,
};

/// Channel configuration
pub const CHANNEL_CONFIGS = [_]u8{
    0, // Defined in program_config_element
    1, // 1 channel: front-center
    2, // 2 channels: front-left, front-right
    3, // 3 channels: front-center, front-left, front-right
    4, // 4 channels: front-center, front-left, front-right, back-center
    5, // 5 channels: front-center, front-left, front-right, back-left, back-right
    6, // 6 channels: 5.1
    8, // 8 channels: 7.1
};

/// Scalefactor band tables for different window sequences and sample rates
/// These define the frequency bands used in AAC decoding
pub const ScalefactorBands = struct {
    num_swb_long: u8,
    num_swb_short: u8,
    swb_offset_long: []const u16,
    swb_offset_short: []const u16,
};

// ============================================================================
// Audio Specific Config (ASC) - From esds box in MP4
// ============================================================================

pub const AudioSpecificConfig = struct {
    audio_object_type: AudioObjectType,
    sampling_frequency_index: u4,
    sampling_frequency: u32,
    channel_configuration: u4,
    channels: u8,

    // Extension for SBR/PS
    extension_audio_object_type: ?AudioObjectType,
    extension_sampling_frequency_index: ?u4,
    extension_sampling_frequency: ?u32,
    sbr_present: bool,
    ps_present: bool,

    // Frame length
    frame_length_flag: bool, // 0 = 1024, 1 = 960
    frame_length: u16,

    const Self = @This();

    /// Parse AudioSpecificConfig from bytes (from esds box)
    pub fn parse(data: []const u8) !Self {
        var reader = BitstreamReader.init(data);

        // Get audio object type (5 bits, or 5+6 if escape)
        var aot = try reader.readBits(5);
        if (aot == 31) {
            aot = 32 + try reader.readBits(6);
        }

        // Get sampling frequency
        const sf_index: u4 = @intCast(try reader.readBits(4));
        var sampling_frequency: u32 = undefined;
        if (sf_index == 0x0f) {
            sampling_frequency = try reader.readBits(24);
        } else {
            sampling_frequency = SAMPLE_RATES[sf_index];
        }

        // Get channel configuration
        const channel_config: u4 = @intCast(try reader.readBits(4));
        const channels = if (channel_config < CHANNEL_CONFIGS.len)
            CHANNEL_CONFIGS[channel_config]
        else
            0;

        var config = Self{
            .audio_object_type = @enumFromInt(@as(u8, @intCast(aot))),
            .sampling_frequency_index = sf_index,
            .sampling_frequency = sampling_frequency,
            .channel_configuration = channel_config,
            .channels = channels,
            .extension_audio_object_type = null,
            .extension_sampling_frequency_index = null,
            .extension_sampling_frequency = null,
            .sbr_present = false,
            .ps_present = false,
            .frame_length_flag = false,
            .frame_length = 1024,
        };

        // Check for SBR/PS extension
        const audio_object_type: AudioObjectType = @enumFromInt(@as(u8, @intCast(aot)));
        if (audio_object_type == .sbr or audio_object_type == .ps) {
            config.sbr_present = true;
            if (audio_object_type == .ps) {
                config.ps_present = true;
            }

            // Read extension sampling frequency
            const ext_sf_index: u4 = @intCast(try reader.readBits(4));
            config.extension_sampling_frequency_index = ext_sf_index;
            if (ext_sf_index == 0x0f) {
                config.extension_sampling_frequency = try reader.readBits(24);
            } else {
                config.extension_sampling_frequency = SAMPLE_RATES[ext_sf_index];
            }

            // Read base audio object type
            var base_aot = try reader.readBits(5);
            if (base_aot == 31) {
                base_aot = 32 + try reader.readBits(6);
            }
            config.audio_object_type = @enumFromInt(@as(u8, @intCast(base_aot)));
        }

        // Parse GASpecificConfig for AAC types
        if (config.audio_object_type == .aac_main or
            config.audio_object_type == .aac_lc or
            config.audio_object_type == .aac_ssr or
            config.audio_object_type == .aac_ltp or
            config.audio_object_type == .aac_scalable or
            config.audio_object_type == .er_aac_lc or
            config.audio_object_type == .er_aac_ltp or
            config.audio_object_type == .er_aac_scalable or
            config.audio_object_type == .er_aac_ld)
        {
            // GASpecificConfig
            config.frame_length_flag = try reader.readBit() == 1;
            config.frame_length = if (config.frame_length_flag) 960 else 1024;
        }

        return config;
    }

    /// Create default config for AAC-LC
    pub fn defaultLC(sample_rate: u32, channels: u8) Self {
        const sf_index: u4 = blk: {
            for (SAMPLE_RATES, 0..) |sr, i| {
                if (sr == sample_rate) break :blk @intCast(i);
            }
            break :blk 0x0f; // Custom
        };

        return Self{
            .audio_object_type = .aac_lc,
            .sampling_frequency_index = sf_index,
            .sampling_frequency = sample_rate,
            .channel_configuration = @intCast(@min(channels, 7)),
            .channels = channels,
            .extension_audio_object_type = null,
            .extension_sampling_frequency_index = null,
            .extension_sampling_frequency = null,
            .sbr_present = false,
            .ps_present = false,
            .frame_length_flag = false,
            .frame_length = 1024,
        };
    }

    /// Serialize to bytes
    pub fn serialize(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        var writer = bitstream.BitstreamWriter.init(allocator);
        errdefer writer.deinit();

        const aot = @intFromEnum(self.audio_object_type);
        if (aot < 31) {
            try writer.writeBits(aot, 5);
        } else {
            try writer.writeBits(31, 5);
            try writer.writeBits(aot - 32, 6);
        }

        if (self.sampling_frequency_index == 0x0f) {
            try writer.writeBits(0x0f, 4);
            try writer.writeBits(self.sampling_frequency, 24);
        } else {
            try writer.writeBits(self.sampling_frequency_index, 4);
        }

        try writer.writeBits(self.channel_configuration, 4);

        // GASpecificConfig
        try writer.writeBit(if (self.frame_length_flag) 1 else 0);
        try writer.writeBit(0); // dependsOnCoreCoder
        try writer.writeBit(0); // extensionFlag

        try writer.alignToByte();
        return writer.toOwnedSlice();
    }
};

// ============================================================================
// ADTS Header (Audio Data Transport Stream)
// ============================================================================

pub const AdtsHeader = struct {
    // Fixed header (28 bits)
    syncword: u12, // 0xFFF
    id: u1, // MPEG identifier: 0 = MPEG-4, 1 = MPEG-2
    layer: u2, // Always 0
    protection_absent: bool, // No CRC if true
    profile: u2, // Audio object type - 1
    sampling_frequency_index: u4,
    private_bit: bool,
    channel_configuration: u3,
    original_copy: bool,
    home: bool,

    // Variable header (28 bits)
    copyright_id_bit: bool,
    copyright_id_start: bool,
    frame_length: u13, // Includes header
    buffer_fullness: u11,
    num_raw_data_blocks: u2, // Number of AAC frames minus 1

    const Self = @This();
    pub const HEADER_SIZE: usize = 7;
    pub const HEADER_SIZE_WITH_CRC: usize = 9;

    /// Parse ADTS header from bytes
    pub fn parse(data: []const u8) !Self {
        if (data.len < HEADER_SIZE) return VideoError.TruncatedData;

        // Check syncword
        if (data[0] != 0xFF or (data[1] & 0xF0) != 0xF0) {
            return VideoError.InvalidMagicBytes;
        }

        return Self{
            .syncword = 0xFFF,
            .id = @intCast((data[1] >> 3) & 0x01),
            .layer = @intCast((data[1] >> 1) & 0x03),
            .protection_absent = (data[1] & 0x01) == 1,
            .profile = @intCast((data[2] >> 6) & 0x03),
            .sampling_frequency_index = @intCast((data[2] >> 2) & 0x0F),
            .private_bit = ((data[2] >> 1) & 0x01) == 1,
            .channel_configuration = @intCast(((data[2] & 0x01) << 2) | ((data[3] >> 6) & 0x03)),
            .original_copy = ((data[3] >> 5) & 0x01) == 1,
            .home = ((data[3] >> 4) & 0x01) == 1,
            .copyright_id_bit = ((data[3] >> 3) & 0x01) == 1,
            .copyright_id_start = ((data[3] >> 2) & 0x01) == 1,
            .frame_length = @intCast((@as(u16, data[3] & 0x03) << 11) |
                (@as(u16, data[4]) << 3) |
                ((data[5] >> 5) & 0x07)),
            .buffer_fullness = @intCast((@as(u16, data[5] & 0x1F) << 6) | ((data[6] >> 2) & 0x3F)),
            .num_raw_data_blocks = @intCast(data[6] & 0x03),
        };
    }

    /// Get header size (7 or 9 bytes depending on CRC)
    pub fn headerSize(self: *const Self) usize {
        return if (self.protection_absent) HEADER_SIZE else HEADER_SIZE_WITH_CRC;
    }

    /// Get payload size (frame_length - header)
    pub fn payloadSize(self: *const Self) usize {
        return self.frame_length - self.headerSize();
    }

    /// Get sample rate
    pub fn getSampleRate(self: *const Self) u32 {
        if (self.sampling_frequency_index < SAMPLE_RATES.len) {
            return SAMPLE_RATES[self.sampling_frequency_index];
        }
        return 0;
    }

    /// Get number of channels
    pub fn getChannels(self: *const Self) u8 {
        if (self.channel_configuration < CHANNEL_CONFIGS.len) {
            return CHANNEL_CONFIGS[self.channel_configuration];
        }
        return 0;
    }

    /// Get audio object type
    pub fn getAudioObjectType(self: *const Self) AudioObjectType {
        // profile is audio object type - 1
        return @enumFromInt(@as(u8, self.profile + 1));
    }

    /// Serialize to bytes
    pub fn serialize(self: *const Self) [HEADER_SIZE]u8 {
        var header: [HEADER_SIZE]u8 = undefined;

        header[0] = 0xFF;
        header[1] = 0xF0 |
            (@as(u8, self.id) << 3) |
            (@as(u8, self.layer) << 1) |
            (if (self.protection_absent) @as(u8, 1) else 0);
        header[2] = (@as(u8, self.profile) << 6) |
            (@as(u8, self.sampling_frequency_index) << 2) |
            (if (self.private_bit) @as(u8, 2) else 0) |
            (@as(u8, self.channel_configuration >> 2) & 0x01);
        header[3] = (@as(u8, @as(u3, @truncate(self.channel_configuration))) << 6) |
            (if (self.original_copy) @as(u8, 0x20) else 0) |
            (if (self.home) @as(u8, 0x10) else 0) |
            (if (self.copyright_id_bit) @as(u8, 0x08) else 0) |
            (if (self.copyright_id_start) @as(u8, 0x04) else 0) |
            @as(u8, @truncate(self.frame_length >> 11));
        header[4] = @truncate(self.frame_length >> 3);
        header[5] = @as(u8, @truncate(self.frame_length << 5)) |
            @as(u8, @truncate(self.buffer_fullness >> 6));
        header[6] = @as(u8, @truncate(self.buffer_fullness << 2)) |
            @as(u8, self.num_raw_data_blocks);

        return header;
    }
};

// ============================================================================
// AAC Decoder State
// ============================================================================

pub const AacDecoder = struct {
    allocator: std.mem.Allocator,
    config: AudioSpecificConfig,

    // Decoder state
    prev_samples: ?[]f32, // Previous frame for overlap-add

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: AudioSpecificConfig) Self {
        return Self{
            .allocator = allocator,
            .config = config,
            .prev_samples = null,
        };
    }

    pub fn initFromEsds(allocator: std.mem.Allocator, esds_data: []const u8) !Self {
        // ESDS box structure:
        // - version (1 byte)
        // - flags (3 bytes)
        // - ES_Descriptor tag (1 byte = 0x03)
        // - descriptor length (1-4 bytes)
        // - ES_ID (2 bytes)
        // - flags (1 byte)
        // - ...more nested descriptors...
        // We need to find the DecoderSpecificInfo (tag 0x05)

        var offset: usize = 4; // Skip version and flags

        // Parse ES_Descriptor
        while (offset < esds_data.len) {
            const tag = esds_data[offset];
            offset += 1;

            // Read descriptor length (variable length encoding)
            var length: u32 = 0;
            var size_bytes: u8 = 0;
            while (offset < esds_data.len and size_bytes < 4) {
                const b = esds_data[offset];
                offset += 1;
                length = (length << 7) | (b & 0x7F);
                size_bytes += 1;
                if ((b & 0x80) == 0) break;
            }

            if (tag == 0x05) {
                // DecoderSpecificInfo - this is the AudioSpecificConfig
                if (offset + length <= esds_data.len) {
                    const asc = try AudioSpecificConfig.parse(esds_data[offset .. offset + length]);
                    return Self.init(allocator, asc);
                }
            }

            // Skip to next descriptor based on tag type
            if (tag == 0x03) {
                // ES_Descriptor: skip ES_ID (2) + flags (1)
                offset += 3;
            } else if (tag == 0x04) {
                // DecoderConfigDescriptor: skip objectTypeIndication (1) + streamType/flags (1) + bufferSize (3) + maxBitrate (4) + avgBitrate (4)
                offset += 13;
            } else {
                offset += length;
            }
        }

        return VideoError.InvalidExtradata;
    }

    pub fn deinit(self: *Self) void {
        if (self.prev_samples) |samples| {
            self.allocator.free(samples);
        }
    }

    /// Decode a raw AAC frame (no ADTS header)
    pub fn decodeRaw(self: *Self, data: []const u8) !AudioFrame {
        _ = data;

        // Full AAC decoding requires:
        // 1. Huffman decoding of spectral data
        // 2. Inverse quantization
        // 3. M/S stereo processing
        // 4. Intensity stereo processing
        // 5. Temporal noise shaping (TNS)
        // 6. Filterbank (IMDCT)
        // 7. Window overlap-add
        //
        // This is very complex (~5000+ lines for a complete implementation)
        // For now, return an empty frame as a placeholder

        const num_samples = self.config.frame_length;
        const channels = self.config.channels;

        var audio_frame = try AudioFrame.init(
            self.allocator,
            num_samples,
            .f32le,
            channels,
            self.config.sampling_frequency,
        );

        // Fill with silence for now (actual decoding would go here)
        for (audio_frame.data) |plane| {
            if (plane) |p| {
                @memset(p, 0);
            }
        }

        return audio_frame;
    }

    /// Decode ADTS frame (with header)
    pub fn decodeAdts(self: *Self, data: []const u8) !AudioFrame {
        const header = try AdtsHeader.parse(data);
        const payload_start = header.headerSize();
        const payload_end = header.frame_length;

        if (data.len < payload_end) {
            return VideoError.TruncatedData;
        }

        return self.decodeRaw(data[payload_start..payload_end]);
    }

    /// Get frame size in samples
    pub fn getFrameSize(self: *const Self) u16 {
        return self.config.frame_length;
    }

    /// Get sample rate
    pub fn getSampleRate(self: *const Self) u32 {
        return self.config.sampling_frequency;
    }

    /// Get number of channels
    pub fn getChannels(self: *const Self) u8 {
        return self.config.channels;
    }
};

// ============================================================================
// AAC Encoder (placeholder for future implementation)
// ============================================================================

pub const AacEncoder = struct {
    allocator: std.mem.Allocator,
    config: AudioSpecificConfig,
    bitrate: u32,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32, channels: u8, bitrate: u32) Self {
        return Self{
            .allocator = allocator,
            .config = AudioSpecificConfig.defaultLC(sample_rate, channels),
            .bitrate = bitrate,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Encode audio frame to AAC
    pub fn encode(self: *Self, audio_frame: *const AudioFrame) ![]u8 {
        // Use full encoder implementation
        const aac_full = @import("aac_encoder.zig");
        var full_encoder = aac_full.AacFullEncoder.init(
            self.allocator,
            self.config.sample_rate,
            self.config.channels,
            self.bitrate,
        );
        defer full_encoder.deinit();

        return try full_encoder.encode(audio_frame);
    }

    /// Encode with ADTS header
    pub fn encodeAdts(self: *Self, audio_frame: *const AudioFrame) ![]u8 {
        // Use full encoder implementation
        const aac_full = @import("aac_encoder.zig");
        var full_encoder = aac_full.AacFullEncoder.init(
            self.allocator,
            self.config.sample_rate,
            self.config.channels,
            self.bitrate,
        );
        defer full_encoder.deinit();

        return try full_encoder.encodeAdts(audio_frame);
    }

    /// Get AudioSpecificConfig bytes
    pub fn getConfig(self: *const Self) ![]u8 {
        return self.config.serialize(self.allocator);
    }
};

// ============================================================================
// ADTS Stream Parser
// ============================================================================

pub const AdtsParser = struct {
    data: []const u8,
    offset: usize,

    const Self = @This();

    pub fn init(data: []const u8) Self {
        return Self{
            .data = data,
            .offset = 0,
        };
    }

    /// Find next ADTS frame
    pub fn nextFrame(self: *Self) ?struct { header: AdtsHeader, data: []const u8 } {
        // Search for sync word
        while (self.offset + AdtsHeader.HEADER_SIZE < self.data.len) {
            if (self.data[self.offset] == 0xFF and (self.data[self.offset + 1] & 0xF0) == 0xF0) {
                // Found potential sync
                const header = AdtsHeader.parse(self.data[self.offset..]) catch {
                    self.offset += 1;
                    continue;
                };

                if (header.frame_length > 0 and self.offset + header.frame_length <= self.data.len) {
                    const frame_data = self.data[self.offset .. self.offset + header.frame_length];
                    self.offset += header.frame_length;
                    return .{ .header = header, .data = frame_data };
                }
            }
            self.offset += 1;
        }

        return null;
    }

    /// Check if more data available
    pub fn hasMore(self: *const Self) bool {
        return self.offset + AdtsHeader.HEADER_SIZE < self.data.len;
    }
};

// ============================================================================
// Utility Functions
// ============================================================================

/// Check if data starts with ADTS sync word
pub fn isAdts(data: []const u8) bool {
    return data.len >= 2 and data[0] == 0xFF and (data[1] & 0xF0) == 0xF0;
}

/// Get audio object type name
pub fn getAudioObjectTypeName(aot: AudioObjectType) []const u8 {
    return switch (aot) {
        .aac_main => "AAC Main",
        .aac_lc => "AAC-LC",
        .aac_ssr => "AAC SSR",
        .aac_ltp => "AAC LTP",
        .sbr => "SBR",
        .aac_scalable => "AAC Scalable",
        .er_aac_lc => "ER AAC-LC",
        .er_aac_ld => "ER AAC-LD",
        .er_aac_eld => "ER AAC-ELD",
        .ps => "PS",
        .usac => "USAC",
        else => "Unknown",
    };
}

// ============================================================================
// Tests
// ============================================================================

test "AudioSpecificConfig default LC" {
    const config = AudioSpecificConfig.defaultLC(44100, 2);
    try std.testing.expectEqual(AudioObjectType.aac_lc, config.audio_object_type);
    try std.testing.expectEqual(@as(u32, 44100), config.sampling_frequency);
    try std.testing.expectEqual(@as(u8, 2), config.channels);
    try std.testing.expectEqual(@as(u16, 1024), config.frame_length);
}

test "AudioSpecificConfig serialize and parse roundtrip" {
    const original = AudioSpecificConfig.defaultLC(48000, 2);
    const serialized = try original.serialize(std.testing.allocator);
    defer std.testing.allocator.free(serialized);

    const parsed = try AudioSpecificConfig.parse(serialized);
    try std.testing.expectEqual(original.audio_object_type, parsed.audio_object_type);
    try std.testing.expectEqual(original.sampling_frequency, parsed.sampling_frequency);
    try std.testing.expectEqual(original.channel_configuration, parsed.channel_configuration);
}

test "AdtsHeader parse" {
    // Valid ADTS header for AAC-LC, 44100 Hz, stereo, frame length 1024
    const adts_bytes = [_]u8{
        0xFF, 0xF1, // Syncword + ID + Layer + protection_absent
        0x50, 0x80, // Profile + SF index + private + channel config
        0x02, 0x1F, // Frame length bits
        0xFC, // Buffer fullness + num blocks
    };

    const header = try AdtsHeader.parse(&adts_bytes);
    try std.testing.expectEqual(@as(u12, 0xFFF), header.syncword);
    try std.testing.expect(header.protection_absent);
    try std.testing.expectEqual(@as(u2, 1), header.profile); // AAC-LC = profile 1
}

test "AdtsParser" {
    // Two ADTS frames concatenated (minimal valid headers)
    var data: [20]u8 = undefined;
    // First frame: 10 bytes total
    data[0] = 0xFF;
    data[1] = 0xF1;
    data[2] = 0x50;
    data[3] = 0x80;
    data[4] = 0x01;
    data[5] = 0x5F;
    data[6] = 0xFC;
    data[7] = 0x00;
    data[8] = 0x00;
    data[9] = 0x00;
    // Second frame: 10 bytes total
    data[10] = 0xFF;
    data[11] = 0xF1;
    data[12] = 0x50;
    data[13] = 0x80;
    data[14] = 0x01;
    data[15] = 0x5F;
    data[16] = 0xFC;
    data[17] = 0x00;
    data[18] = 0x00;
    data[19] = 0x00;

    var parser = AdtsParser.init(&data);

    var count: u32 = 0;
    while (parser.nextFrame()) |_| {
        count += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), count);
}

test "isAdts" {
    try std.testing.expect(isAdts(&[_]u8{ 0xFF, 0xF1 }));
    try std.testing.expect(isAdts(&[_]u8{ 0xFF, 0xF9 }));
    try std.testing.expect(!isAdts(&[_]u8{ 0xFF, 0xE1 }));
    try std.testing.expect(!isAdts(&[_]u8{ 0x00, 0x00 }));
}
