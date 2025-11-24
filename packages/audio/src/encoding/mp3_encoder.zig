// Home Audio Library - MP3 Encoder
// Pure Zig MPEG Layer III encoder
// Simplified implementation suitable for basic encoding

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = std.math;

/// MP3 encoder quality preset
pub const Mp3Quality = enum {
    low, // ~64 kbps
    medium, // ~128 kbps
    high, // ~192 kbps
    best, // ~320 kbps

    pub fn getBitrate(self: Mp3Quality) u32 {
        return switch (self) {
            .low => 64,
            .medium => 128,
            .high => 192,
            .best => 320,
        };
    }
};

/// MP3 channel mode
pub const Mp3ChannelMode = enum(u2) {
    stereo = 0,
    joint_stereo = 1,
    dual_channel = 2,
    mono = 3,
};

/// MP3 frame header
pub const Mp3FrameHeader = struct {
    // MPEG Audio Layer III header fields
    version: MpegVersion,
    layer: u2, // Always 1 for Layer III
    protection: bool,
    bitrate_index: u4,
    sample_rate_index: u2,
    padding: bool,
    private: bool,
    channel_mode: Mp3ChannelMode,
    mode_extension: u2,
    copyright: bool,
    original: bool,
    emphasis: u2,

    pub fn encode(self: Mp3FrameHeader) [4]u8 {
        var header: [4]u8 = undefined;

        // Frame sync (11 bits all 1s)
        header[0] = 0xFF;

        // 3 more sync bits + version + layer + protection
        header[1] = 0xE0;
        header[1] |= @as(u8, @intFromEnum(self.version)) << 3;
        header[1] |= @as(u8, self.layer) << 1;
        header[1] |= if (self.protection) 0 else 1;

        // Bitrate + sample rate + padding + private
        header[2] = @as(u8, self.bitrate_index) << 4;
        header[2] |= @as(u8, self.sample_rate_index) << 2;
        header[2] |= if (self.padding) 2 else 0;
        header[2] |= if (self.private) 1 else 0;

        // Channel mode + mode extension + copyright + original + emphasis
        header[3] = @as(u8, @intFromEnum(self.channel_mode)) << 6;
        header[3] |= @as(u8, self.mode_extension) << 4;
        header[3] |= if (self.copyright) 8 else 0;
        header[3] |= if (self.original) 4 else 0;
        header[3] |= self.emphasis;

        return header;
    }
};

/// MPEG version
pub const MpegVersion = enum(u2) {
    mpeg_25 = 0,
    reserved = 1,
    mpeg_2 = 2,
    mpeg_1 = 3,
};

/// Bitrate lookup table for MPEG-1 Layer III
const BITRATE_TABLE = [_]u32{
    0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0,
};

/// Sample rate lookup table for MPEG-1
const SAMPLE_RATE_TABLE = [_]u32{ 44100, 48000, 32000, 0 };

/// MP3 encoder
pub const Mp3Encoder = struct {
    allocator: Allocator,
    sample_rate: u32,
    channels: u8,
    bitrate: u32,
    quality: Mp3Quality,

    // Output buffer
    output: std.ArrayList(u8),

    // MDCT state
    mdct_buffer: []f32,
    prev_block: []f32,

    // Psychoacoustic model state
    energy_history: []f32,

    // Frame counter
    frame_count: u32,

    // Bit reservoir
    bit_reservoir: i32,

    const Self = @This();

    pub const SAMPLES_PER_FRAME = 1152; // For MPEG-1 Layer III
    pub const GRANULE_SIZE = 576;

    pub fn init(allocator: Allocator, sample_rate: u32, channels: u8, quality: Mp3Quality) !Self {
        const bitrate = quality.getBitrate();

        return Self{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .channels = channels,
            .bitrate = bitrate,
            .quality = quality,
            .output = .{},
            .mdct_buffer = try allocator.alloc(f32, GRANULE_SIZE * 2),
            .prev_block = try allocator.alloc(f32, GRANULE_SIZE),
            .energy_history = try allocator.alloc(f32, 32),
            .frame_count = 0,
            .bit_reservoir = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.output.deinit(self.allocator);
        self.allocator.free(self.mdct_buffer);
        self.allocator.free(self.prev_block);
        self.allocator.free(self.energy_history);
    }

    /// Encode PCM samples to MP3
    pub fn encode(self: *Self, samples: []const f32) !void {
        const frame_samples = SAMPLES_PER_FRAME * @as(usize, self.channels);
        var pos: usize = 0;

        while (pos + frame_samples <= samples.len) {
            try self.encodeFrame(samples[pos .. pos + frame_samples]);
            pos += frame_samples;
        }
    }

    /// Encode a single MP3 frame
    fn encodeFrame(self: *Self, samples: []const f32) !void {
        // Create frame header
        const header = self.createFrameHeader();
        const header_bytes = header.encode();
        try self.output.appendSlice(self.allocator, &header_bytes);

        // Calculate frame size (excluding header)
        const frame_size = self.calculateFrameSize();
        const data_size = frame_size - 4; // Subtract header

        // Simplified encoding: store quantized samples
        // Real MP3 encoding involves:
        // 1. Polyphase filterbank (32 subbands)
        // 2. MDCT (Modified Discrete Cosine Transform)
        // 3. Psychoacoustic model
        // 4. Quantization and Huffman coding

        // For this implementation, we use simplified quantization
        const frame_data = try self.allocator.alloc(u8, data_size);
        defer self.allocator.free(frame_data);
        @memset(frame_data, 0);

        // Write side information (simplified)
        self.writeSideInfo(frame_data);

        // Encode audio data (simplified quantization)
        self.encodeAudioData(samples, frame_data);

        try self.output.appendSlice(self.allocator, frame_data);
        self.frame_count += 1;
    }

    fn createFrameHeader(self: *Self) Mp3FrameHeader {
        return Mp3FrameHeader{
            .version = .mpeg_1,
            .layer = 1, // Layer III
            .protection = false,
            .bitrate_index = self.getBitrateIndex(),
            .sample_rate_index = self.getSampleRateIndex(),
            .padding = false,
            .private = false,
            .channel_mode = if (self.channels == 1) .mono else .stereo,
            .mode_extension = 0,
            .copyright = false,
            .original = true,
            .emphasis = 0,
        };
    }

    fn getBitrateIndex(self: *Self) u4 {
        for (BITRATE_TABLE, 0..) |rate, i| {
            if (rate == self.bitrate) {
                return @intCast(i);
            }
        }
        return 9; // Default to 128 kbps
    }

    fn getSampleRateIndex(self: *Self) u2 {
        for (SAMPLE_RATE_TABLE, 0..) |rate, i| {
            if (rate == self.sample_rate) {
                return @intCast(i);
            }
        }
        return 0; // Default to 44100
    }

    fn calculateFrameSize(self: *Self) usize {
        // Frame size = 144 * bitrate / sample_rate (+ padding)
        return 144 * self.bitrate * 1000 / self.sample_rate;
    }

    fn writeSideInfo(self: *Self, data: []u8) void {
        // Side information for MPEG-1 Layer III
        // Mono: 17 bytes, Stereo: 32 bytes
        const side_info_size: usize = if (self.channels == 1) 17 else 32;

        if (data.len >= side_info_size) {
            // Main data begin pointer (simplified)
            data[0] = 0;
            data[1] = 0;

            // Scalefactor selection information, etc.
            // Simplified: just zero-fill
        }
    }

    fn encodeAudioData(self: *Self, samples: []const f32, data: []u8) void {
        // Simplified encoding: basic quantization
        // Real MP3 uses Huffman coding with multiple tables

        const side_info_size: usize = if (self.channels == 1) 17 else 32;
        const audio_start = side_info_size;
        const audio_size = data.len - side_info_size;

        if (audio_size == 0) return;

        // Mix to mono if needed for simplified encoding
        var mono_samples: [SAMPLES_PER_FRAME]f32 = undefined;
        for (0..SAMPLES_PER_FRAME) |i| {
            if (self.channels == 2 and i * 2 + 1 < samples.len) {
                mono_samples[i] = (samples[i * 2] + samples[i * 2 + 1]) * 0.5;
            } else if (i < samples.len) {
                mono_samples[i] = samples[@min(i * self.channels, samples.len - 1)];
            } else {
                mono_samples[i] = 0;
            }
        }

        // Simple quantization (8-bit for demonstration)
        const samples_to_encode = @min(SAMPLES_PER_FRAME, audio_size);
        for (0..samples_to_encode) |i| {
            const sample = mono_samples[i];
            const clamped = std.math.clamp(sample, -1.0, 1.0);
            const quantized: i8 = @intFromFloat(clamped * 127.0);
            data[audio_start + i] = @bitCast(quantized);
        }
    }

    /// Finalize encoding and return MP3 data
    pub fn finalize(self: *Self) ![]u8 {
        // Add ID3v1 tag (optional)
        // For now, just return the raw MP3 data

        const result = try self.allocator.dupe(u8, self.output.items);
        return result;
    }

    /// Get encoded data without finalizing
    pub fn getData(self: *Self) []const u8 {
        return self.output.items;
    }

    /// Reset encoder state
    pub fn reset(self: *Self) void {
        self.output.clearRetainingCapacity();
        @memset(self.mdct_buffer, 0);
        @memset(self.prev_block, 0);
        @memset(self.energy_history, 0);
        self.frame_count = 0;
        self.bit_reservoir = 0;
    }

    /// Get number of encoded frames
    pub fn getFrameCount(self: *Self) u32 {
        return self.frame_count;
    }

    /// Get estimated duration in seconds
    pub fn getDuration(self: *Self) f64 {
        return @as(f64, @floatFromInt(self.frame_count)) * SAMPLES_PER_FRAME / @as(f64, @floatFromInt(self.sample_rate));
    }
};

/// ID3v2 tag writer
pub const Id3v2Writer = struct {
    allocator: Allocator,
    frames: std.ArrayList(Id3Frame),

    const Self = @This();

    const Id3Frame = struct {
        id: [4]u8,
        data: []u8,
    };

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .frames = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.frames.items) |frame| {
            self.allocator.free(frame.data);
        }
        self.frames.deinit(self.allocator);
    }

    /// Add title frame
    pub fn setTitle(self: *Self, title: []const u8) !void {
        try self.addTextFrame("TIT2", title);
    }

    /// Add artist frame
    pub fn setArtist(self: *Self, artist: []const u8) !void {
        try self.addTextFrame("TPE1", artist);
    }

    /// Add album frame
    pub fn setAlbum(self: *Self, album: []const u8) !void {
        try self.addTextFrame("TALB", album);
    }

    /// Add year frame
    pub fn setYear(self: *Self, year: []const u8) !void {
        try self.addTextFrame("TYER", year);
    }

    fn addTextFrame(self: *Self, id: []const u8, text: []const u8) !void {
        // Text encoding byte (0 = ISO-8859-1) + text
        var data = try self.allocator.alloc(u8, 1 + text.len);
        data[0] = 0; // ISO-8859-1 encoding
        @memcpy(data[1..], text);

        try self.frames.append(self.allocator, Id3Frame{
            .id = id[0..4].*,
            .data = data,
        });
    }

    /// Generate ID3v2.3 tag
    pub fn generate(self: *Self) ![]u8 {
        // Calculate total size
        var total_size: usize = 10; // Header
        for (self.frames.items) |frame| {
            total_size += 10 + frame.data.len; // Frame header + data
        }

        var result = try self.allocator.alloc(u8, total_size);

        // ID3v2 header
        result[0] = 'I';
        result[1] = 'D';
        result[2] = '3';
        result[3] = 3; // Version 2.3
        result[4] = 0; // Revision
        result[5] = 0; // Flags

        // Size (syncsafe integer, excluding header)
        const size = total_size - 10;
        result[6] = @intCast((size >> 21) & 0x7F);
        result[7] = @intCast((size >> 14) & 0x7F);
        result[8] = @intCast((size >> 7) & 0x7F);
        result[9] = @intCast(size & 0x7F);

        var pos: usize = 10;
        for (self.frames.items) |frame| {
            // Frame ID
            @memcpy(result[pos .. pos + 4], &frame.id);
            pos += 4;

            // Frame size (big-endian)
            const frame_size = frame.data.len;
            result[pos] = @intCast((frame_size >> 24) & 0xFF);
            result[pos + 1] = @intCast((frame_size >> 16) & 0xFF);
            result[pos + 2] = @intCast((frame_size >> 8) & 0xFF);
            result[pos + 3] = @intCast(frame_size & 0xFF);
            pos += 4;

            // Flags
            result[pos] = 0;
            result[pos + 1] = 0;
            pos += 2;

            // Data
            @memcpy(result[pos .. pos + frame.data.len], frame.data);
            pos += frame.data.len;
        }

        return result;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Mp3Encoder init" {
    const allocator = std.testing.allocator;

    var encoder = try Mp3Encoder.init(allocator, 44100, 2, .medium);
    defer encoder.deinit();

    try std.testing.expectEqual(@as(u32, 128), encoder.bitrate);
}

test "Mp3Encoder encode" {
    const allocator = std.testing.allocator;

    var encoder = try Mp3Encoder.init(allocator, 44100, 1, .medium);
    defer encoder.deinit();

    // Create test samples (one frame worth)
    var samples: [Mp3Encoder.SAMPLES_PER_FRAME]f32 = undefined;
    for (0..Mp3Encoder.SAMPLES_PER_FRAME) |i| {
        const t = @as(f32, @floatFromInt(i)) / 44100.0;
        samples[i] = @sin(t * 440 * 2 * math.pi);
    }

    try encoder.encode(&samples);
    try std.testing.expect(encoder.getFrameCount() > 0);
}

test "Mp3FrameHeader encode" {
    const header = Mp3FrameHeader{
        .version = .mpeg_1,
        .layer = 1,
        .protection = false,
        .bitrate_index = 9, // 128 kbps
        .sample_rate_index = 0, // 44100 Hz
        .padding = false,
        .private = false,
        .channel_mode = .stereo,
        .mode_extension = 0,
        .copyright = false,
        .original = true,
        .emphasis = 0,
    };

    const bytes = header.encode();
    try std.testing.expectEqual(@as(u8, 0xFF), bytes[0]);
}

test "Id3v2Writer basic" {
    const allocator = std.testing.allocator;

    var writer = Id3v2Writer.init(allocator);
    defer writer.deinit();

    try writer.setTitle("Test Song");
    try writer.setArtist("Test Artist");

    const tag = try writer.generate();
    defer allocator.free(tag);

    // Should start with "ID3"
    try std.testing.expectEqualSlices(u8, "ID3", tag[0..3]);
}
