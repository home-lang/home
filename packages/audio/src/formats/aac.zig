// Home Audio Library - AAC Format
// Advanced Audio Coding decoder/encoder (ADTS format)

const std = @import("std");
const types = @import("../core/types.zig");
const frame_mod = @import("../core/frame.zig");
const err = @import("../core/error.zig");

pub const AudioFrame = frame_mod.AudioFrame;
pub const SampleFormat = types.SampleFormat;
pub const ChannelLayout = types.ChannelLayout;
pub const Timestamp = types.Timestamp;
pub const Duration = types.Duration;
pub const AudioError = err.AudioError;

// ============================================================================
// AAC Constants
// ============================================================================

/// Audio Object Types
pub const AudioObjectType = enum(u6) {
    null = 0,
    aac_main = 1,
    aac_lc = 2, // Low Complexity (most common)
    aac_ssr = 3, // Scalable Sample Rate
    aac_ltp = 4, // Long Term Prediction
    sbr = 5, // Spectral Band Replication
    aac_scalable = 6,
    twinvq = 7,
    celp = 8,
    hvxc = 9,
    ttsi = 12,
    main_synthetic = 13,
    wavetable_synthesis = 14,
    general_midi = 15,
    algorithmic_synthesis = 16,
    er_aac_lc = 17, // Error Resilient
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
    ps = 29, // Parametric Stereo
    mpeg_surround = 30,
    layer_1 = 32,
    layer_2 = 33,
    layer_3 = 34,
    _,
};

/// Sample rate index to Hz
const SAMPLE_RATES = [_]u32{
    96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
    16000, 12000, 11025, 8000,  7350,  0,     0,     0,
};

/// Channel configuration to channel count
const CHANNEL_CONFIGS = [_]u8{
    0, // Defined in program_config_element
    1, // Front center
    2, // Front left, front right
    3, // Front center, front left, front right
    4, // Front center, front left, front right, back center
    5, // Front center, front left, front right, back left, back right
    6, // Front center, front left, front right, back left, back right, LFE
    8, // Front center, front left, front right, side left, side right, back left, back right, LFE
};

// ============================================================================
// ADTS Header
// ============================================================================

/// ADTS (Audio Data Transport Stream) header
pub const AdtsHeader = struct {
    /// MPEG ID (0 = MPEG-4, 1 = MPEG-2)
    mpeg_id: u1,

    /// Layer (always 0)
    layer: u2,

    /// Protection absent (1 = no CRC, 0 = CRC present)
    protection_absent: bool,

    /// Audio object type minus 1
    profile: u2,

    /// Sample rate index
    sample_rate_index: u4,

    /// Channel configuration
    channel_configuration: u3,

    /// Frame length including header
    frame_length: u13,

    /// Buffer fullness
    buffer_fullness: u11,

    /// Number of raw data blocks minus 1
    num_raw_data_blocks: u2,

    /// CRC (if protection_absent = 0)
    crc: ?u16,

    const Self = @This();

    /// Parse ADTS header from data
    pub fn parse(data: []const u8) !Self {
        if (data.len < 7) return AudioError.TruncatedData;

        // Check sync word (0xFFF)
        if (data[0] != 0xFF or (data[1] & 0xF0) != 0xF0) {
            return AudioError.SyncLost;
        }

        const mpeg_id: u1 = @truncate((data[1] >> 3) & 0x01);
        const layer: u2 = @truncate((data[1] >> 1) & 0x03);
        const protection_absent = (data[1] & 0x01) != 0;

        const profile: u2 = @truncate((data[2] >> 6) & 0x03);
        const sample_rate_index: u4 = @truncate((data[2] >> 2) & 0x0F);
        const channel_configuration: u3 = @truncate(((data[2] & 0x01) << 2) | ((data[3] >> 6) & 0x03));

        const frame_length: u13 = @truncate((@as(u16, data[3] & 0x03) << 11) |
            (@as(u16, data[4]) << 3) |
            ((data[5] >> 5) & 0x07));

        const buffer_fullness: u11 = @truncate((@as(u16, data[5] & 0x1F) << 6) |
            ((data[6] >> 2) & 0x3F));

        const num_raw_data_blocks: u2 = @truncate(data[6] & 0x03);

        var crc: ?u16 = null;
        if (!protection_absent) {
            if (data.len < 9) return AudioError.TruncatedData;
            crc = std.mem.readInt(u16, data[7..9], .big);
        }

        return Self{
            .mpeg_id = mpeg_id,
            .layer = layer,
            .protection_absent = protection_absent,
            .profile = profile,
            .sample_rate_index = sample_rate_index,
            .channel_configuration = channel_configuration,
            .frame_length = frame_length,
            .buffer_fullness = buffer_fullness,
            .num_raw_data_blocks = num_raw_data_blocks,
            .crc = crc,
        };
    }

    /// Get header size in bytes
    pub fn headerSize(self: Self) usize {
        return if (self.protection_absent) 7 else 9;
    }

    /// Get sample rate in Hz
    pub fn getSampleRate(self: Self) u32 {
        if (self.sample_rate_index < SAMPLE_RATES.len) {
            return SAMPLE_RATES[self.sample_rate_index];
        }
        return 0;
    }

    /// Get number of channels
    pub fn getChannels(self: Self) u8 {
        if (self.channel_configuration < CHANNEL_CONFIGS.len) {
            return CHANNEL_CONFIGS[self.channel_configuration];
        }
        return 0;
    }

    /// Get audio object type
    pub fn getAudioObjectType(self: Self) AudioObjectType {
        return @enumFromInt(@as(u6, self.profile) + 1);
    }

    /// Get samples per frame (always 1024 for AAC)
    pub fn getSamplesPerFrame(self: Self) u32 {
        _ = self;
        return 1024;
    }

    /// Encode to bytes
    pub fn encode(self: Self) [7]u8 {
        var bytes: [7]u8 = undefined;

        // Sync word + ID + layer + protection
        bytes[0] = 0xFF;
        bytes[1] = 0xF0 | (@as(u8, self.mpeg_id) << 3) | (@as(u8, self.layer) << 1) |
            @as(u8, if (self.protection_absent) 1 else 0);

        // Profile + sampling frequency + private + channel config
        bytes[2] = (@as(u8, self.profile) << 6) | (@as(u8, self.sample_rate_index) << 2) |
            @as(u8, @truncate(self.channel_configuration >> 2));

        // Channel config + frame length
        bytes[3] = (@as(u8, @truncate(self.channel_configuration & 0x03)) << 6) |
            @as(u8, @truncate((self.frame_length >> 11) & 0x03));

        bytes[4] = @truncate((self.frame_length >> 3) & 0xFF);

        // Frame length + buffer fullness
        bytes[5] = @as(u8, @truncate((self.frame_length & 0x07) << 5)) |
            @as(u8, @truncate((self.buffer_fullness >> 6) & 0x1F));

        // Buffer fullness + num raw data blocks
        bytes[6] = @as(u8, @truncate((self.buffer_fullness & 0x3F) << 2)) |
            @as(u8, self.num_raw_data_blocks);

        return bytes;
    }
};

// ============================================================================
// AudioSpecificConfig
// ============================================================================

/// Audio Specific Config (for MP4/M4A containers)
pub const AudioSpecificConfig = struct {
    audio_object_type: AudioObjectType,
    sample_rate_index: u4,
    sample_rate: u32, // Explicit if index == 15
    channel_configuration: u4,

    // SBR extension
    sbr_present: bool,
    extension_sample_rate: ?u32,

    // PS extension
    ps_present: bool,

    const Self = @This();

    /// Parse from data
    pub fn parse(data: []const u8) !Self {
        if (data.len < 2) return AudioError.TruncatedData;

        var config = Self{
            .audio_object_type = undefined,
            .sample_rate_index = undefined,
            .sample_rate = 0,
            .channel_configuration = undefined,
            .sbr_present = false,
            .extension_sample_rate = null,
            .ps_present = false,
        };

        // Parse with bit reader
        var bit_pos: usize = 0;

        // Audio Object Type (5 bits)
        var aot = readBits(data, &bit_pos, 5);
        if (aot == 31) {
            aot = 32 + readBits(data, &bit_pos, 6);
        }
        config.audio_object_type = @enumFromInt(@as(u6, @truncate(aot)));

        // Sample Rate Index (4 bits)
        config.sample_rate_index = @truncate(readBits(data, &bit_pos, 4));
        if (config.sample_rate_index == 15) {
            // Explicit sample rate (24 bits)
            config.sample_rate = @truncate(readBits(data, &bit_pos, 24));
        } else if (config.sample_rate_index < SAMPLE_RATES.len) {
            config.sample_rate = SAMPLE_RATES[config.sample_rate_index];
        }

        // Channel Configuration (4 bits)
        config.channel_configuration = @truncate(readBits(data, &bit_pos, 4));

        return config;
    }

    fn readBits(data: []const u8, bit_pos: *usize, num_bits: usize) u32 {
        var result: u32 = 0;
        for (0..num_bits) |_| {
            const byte_idx = bit_pos.* / 8;
            const bit_idx: u3 = @truncate(7 - (bit_pos.* % 8));

            if (byte_idx < data.len) {
                const bit: u32 = (data[byte_idx] >> bit_idx) & 1;
                result = (result << 1) | bit;
            }
            bit_pos.* += 1;
        }
        return result;
    }

    /// Get sample rate in Hz
    pub fn getSampleRate(self: Self) u32 {
        if (self.sample_rate > 0) return self.sample_rate;
        if (self.sample_rate_index < SAMPLE_RATES.len) {
            return SAMPLE_RATES[self.sample_rate_index];
        }
        return 0;
    }

    /// Get number of channels
    pub fn getChannels(self: Self) u8 {
        if (self.channel_configuration < CHANNEL_CONFIGS.len) {
            return CHANNEL_CONFIGS[self.channel_configuration];
        }
        return 0;
    }
};

// ============================================================================
// ADTS Parser
// ============================================================================

pub const AdtsParser = struct {
    data: []const u8,
    pos: usize,
    first_header: ?AdtsHeader,
    total_frames: u64,

    const Self = @This();

    /// Create parser from data
    pub fn init(data: []const u8) !Self {
        var parser = Self{
            .data = data,
            .pos = 0,
            .first_header = null,
            .total_frames = 0,
        };

        try parser.findFirstFrame();
        parser.countFrames();

        return parser;
    }

    fn findFirstFrame(self: *Self) !void {
        while (self.pos + 7 <= self.data.len) {
            if (self.data[self.pos] == 0xFF and (self.data[self.pos + 1] & 0xF0) == 0xF0) {
                self.first_header = AdtsHeader.parse(self.data[self.pos..]) catch {
                    self.pos += 1;
                    continue;
                };
                return;
            }
            self.pos += 1;
        }
        return AudioError.SyncLost;
    }

    fn countFrames(self: *Self) void {
        var pos = self.pos;
        var count: u64 = 0;

        while (pos + 7 <= self.data.len) {
            const header = AdtsHeader.parse(self.data[pos..]) catch break;
            if (header.frame_length == 0 or pos + header.frame_length > self.data.len) break;
            pos += header.frame_length;
            count += 1;
        }

        self.total_frames = count;
    }

    /// Get sample rate
    pub fn getSampleRate(self: *const Self) u32 {
        if (self.first_header) |h| return h.getSampleRate();
        return 44100;
    }

    /// Get number of channels
    pub fn getChannels(self: *const Self) u8 {
        if (self.first_header) |h| return h.getChannels();
        return 2;
    }

    /// Get duration in seconds
    pub fn getDuration(self: *const Self) f64 {
        const sample_rate = self.getSampleRate();
        if (sample_rate == 0) return 0;
        return @as(f64, @floatFromInt(self.total_frames * 1024)) / @as(f64, @floatFromInt(sample_rate));
    }

    /// Get total samples
    pub fn getTotalSamples(self: *const Self) u64 {
        return self.total_frames * 1024;
    }

    /// Get estimated bitrate in kbps
    pub fn getBitrate(self: *const Self) u32 {
        const duration = self.getDuration();
        if (duration > 0) {
            const bits = @as(f64, @floatFromInt(self.data.len)) * 8;
            return @intFromFloat(bits / duration / 1000);
        }
        return 0;
    }
};

// ============================================================================
// AAC Reader
// ============================================================================

pub const AacReader = struct {
    data: []const u8,
    parser: AdtsParser,
    pos: usize,
    current_frame: u64,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Create reader from memory buffer
    pub fn fromMemory(allocator: std.mem.Allocator, data: []const u8) !Self {
        var parser = try AdtsParser.init(data);

        return Self{
            .data = data,
            .parser = parser,
            .pos = parser.pos,
            .current_frame = 0,
            .allocator = allocator,
        };
    }

    /// Get sample rate
    pub fn getSampleRate(self: *const Self) u32 {
        return self.parser.getSampleRate();
    }

    /// Get number of channels
    pub fn getChannels(self: *const Self) u8 {
        return self.parser.getChannels();
    }

    /// Get duration in seconds
    pub fn getDuration(self: *const Self) f64 {
        return self.parser.getDuration();
    }

    /// Get bitrate in kbps
    pub fn getBitrate(self: *const Self) u32 {
        return self.parser.getBitrate();
    }
};

// ============================================================================
// AAC Writer
// ============================================================================

pub const AacWriter = struct {
    buffer: std.ArrayList(u8),
    channels: u8,
    sample_rate: u32,
    sample_rate_index: u4,
    profile: u2,
    frames_written: u64,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize a new AAC writer (ADTS format)
    pub fn init(
        allocator: std.mem.Allocator,
        channels: u8,
        sample_rate: u32,
    ) !Self {
        // Find sample rate index
        var sample_rate_index: u4 = 15;
        for (SAMPLE_RATES, 0..) |rate, idx| {
            if (rate == sample_rate) {
                sample_rate_index = @intCast(idx);
                break;
            }
        }

        return Self{
            .buffer = std.ArrayList(u8).init(allocator),
            .channels = channels,
            .sample_rate = sample_rate,
            .sample_rate_index = sample_rate_index,
            .profile = 1, // AAC-LC
            .frames_written = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit();
    }

    /// Write raw AAC frame data
    pub fn writeFrame(self: *Self, frame_data: []const u8) !void {
        // Create ADTS header
        const channel_config: u3 = @min(7, self.channels);
        const frame_length: u13 = @intCast(7 + frame_data.len);

        const header = AdtsHeader{
            .mpeg_id = 0, // MPEG-4
            .layer = 0,
            .protection_absent = true,
            .profile = self.profile,
            .sample_rate_index = self.sample_rate_index,
            .channel_configuration = channel_config,
            .frame_length = frame_length,
            .buffer_fullness = 0x7FF, // VBR
            .num_raw_data_blocks = 0,
            .crc = null,
        };

        try self.buffer.appendSlice(&header.encode());
        try self.buffer.appendSlice(frame_data);
        self.frames_written += 1;
    }

    /// Finalize and get the AAC data
    pub fn finalize(self: *Self) ![]u8 {
        return try self.allocator.dupe(u8, self.buffer.items);
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Check if data is an AAC/ADTS file
pub fn isAac(data: []const u8) bool {
    if (data.len < 2) return false;
    return data[0] == 0xFF and (data[1] & 0xF0) == 0xF0;
}

/// Check if data is AAC in M4A container
pub fn isM4a(data: []const u8) bool {
    if (data.len < 12) return false;
    if (!std.mem.eql(u8, data[4..8], "ftyp")) return false;

    // Check for M4A-related brands
    return std.mem.eql(u8, data[8..12], "M4A ") or
        std.mem.eql(u8, data[8..12], "mp42") or
        std.mem.eql(u8, data[8..12], "isom");
}

/// Decode AAC from memory
pub fn decode(allocator: std.mem.Allocator, data: []const u8) !AudioFrame {
    _ = allocator;
    _ = data;
    // Full AAC decoding is very complex and requires implementing:
    // - Huffman decoding
    // - Inverse quantization
    // - M/S stereo decoding
    // - Intensity stereo
    // - TNS (Temporal Noise Shaping)
    // - Inverse MDCT
    // - Window overlap-add
    return AudioError.NotImplemented;
}

// ============================================================================
// Tests
// ============================================================================

test "AAC/ADTS detection" {
    const adts_data = [_]u8{ 0xFF, 0xF1, 0x50, 0x80, 0x00, 0x1F, 0xFC };
    try std.testing.expect(isAac(&adts_data));

    const not_aac = [_]u8{ 'R', 'I', 'F', 'F' };
    try std.testing.expect(!isAac(&not_aac));
}

test "ADTS header parsing" {
    // Minimal ADTS header: sync + MPEG-4 + AAC-LC + 44100Hz + stereo + frame_length=7
    const adts_header = [_]u8{
        0xFF, 0xF1, // Sync + MPEG-4 + layer 0 + no CRC
        0x50, // AAC-LC + 44100Hz (index 4)
        0x80, // Stereo (2 channels)
        0x00, 0x1F, 0xFC, // Frame length = 7, buffer fullness = 0x7FF
    };

    const header = try AdtsHeader.parse(&adts_header);
    try std.testing.expectEqual(@as(u32, 44100), header.getSampleRate());
    try std.testing.expectEqual(@as(u8, 2), header.getChannels());
    try std.testing.expectEqual(AudioObjectType.aac_lc, header.getAudioObjectType());
}

test "M4A detection" {
    var m4a_data: [12]u8 = undefined;
    @memset(m4a_data[0..4], 0);
    @memcpy(m4a_data[4..8], "ftyp");
    @memcpy(m4a_data[8..12], "M4A ");

    try std.testing.expect(isM4a(&m4a_data));
}
