// Home Audio Library - Opus Format
// Opus Interactive Audio Codec decoder

const std = @import("std");
const types = @import("../core/types.zig");
const frame_mod = @import("../core/frame.zig");
const err = @import("../core/error.zig");
const ogg = @import("ogg.zig");

pub const AudioFrame = frame_mod.AudioFrame;
pub const SampleFormat = types.SampleFormat;
pub const ChannelLayout = types.ChannelLayout;
pub const Timestamp = types.Timestamp;
pub const Duration = types.Duration;
pub const Metadata = types.Metadata;
pub const AudioError = err.AudioError;

// ============================================================================
// Opus Constants
// ============================================================================

const OPUS_MAGIC = "OpusHead".*;
const OPUS_TAGS_MAGIC = "OpusTags".*;

/// Opus channel mapping family
pub const ChannelMappingFamily = enum(u8) {
    rtp = 0, // RTP mapping (mono/stereo)
    vorbis = 1, // Vorbis channel order
    custom = 255, // Application-defined
    _,
};

/// Opus bandwidth
pub const Bandwidth = enum {
    narrowband, // 4 kHz
    mediumband, // 6 kHz
    wideband, // 8 kHz
    superwideband, // 12 kHz
    fullband, // 20 kHz
};

// ============================================================================
// Opus Head (Identification Header)
// ============================================================================

pub const OpusHead = struct {
    /// Version number (should be 1)
    version: u8,

    /// Number of output channels
    channels: u8,

    /// Pre-skip samples
    pre_skip: u16,

    /// Input sample rate (informational)
    input_sample_rate: u32,

    /// Output gain in dB (Q7.8 format)
    output_gain: i16,

    /// Channel mapping family
    mapping_family: ChannelMappingFamily,

    /// Stream count (for mapping family > 0)
    stream_count: ?u8,

    /// Coupled stream count (for mapping family > 0)
    coupled_count: ?u8,

    /// Channel mapping table (for mapping family > 0)
    channel_mapping: ?[]const u8,

    const Self = @This();

    /// Parse Opus identification header
    pub fn parse(data: []const u8) !Self {
        if (data.len < 19) return AudioError.TruncatedData;

        // Check magic
        if (!std.mem.eql(u8, data[0..8], &OPUS_MAGIC)) {
            return AudioError.InvalidFormat;
        }

        const version = data[8];
        if (version != 1) return AudioError.UnsupportedFormat;

        const channels = data[9];
        if (channels == 0) return AudioError.InvalidHeader;

        const pre_skip = std.mem.readInt(u16, data[10..12], .little);
        const input_sample_rate = std.mem.readInt(u32, data[12..16], .little);
        const output_gain = std.mem.readInt(i16, data[16..18], .little);
        const mapping_family: ChannelMappingFamily = @enumFromInt(data[18]);

        var head = Self{
            .version = version,
            .channels = channels,
            .pre_skip = pre_skip,
            .input_sample_rate = input_sample_rate,
            .output_gain = output_gain,
            .mapping_family = mapping_family,
            .stream_count = null,
            .coupled_count = null,
            .channel_mapping = null,
        };

        // Parse channel mapping for family > 0
        if (mapping_family != .rtp) {
            if (data.len < 21 + channels) return AudioError.TruncatedData;
            head.stream_count = data[19];
            head.coupled_count = data[20];
            head.channel_mapping = data[21..][0..channels];
        }

        return head;
    }

    /// Get output sample rate (always 48000 for Opus)
    pub fn getOutputSampleRate(self: Self) u32 {
        _ = self;
        return 48000; // Opus always decodes to 48 kHz
    }

    /// Get output gain in dB
    pub fn getOutputGainDb(self: Self) f32 {
        return @as(f32, @floatFromInt(self.output_gain)) / 256.0;
    }

    /// Get channel layout
    pub fn getChannelLayout(self: Self) ChannelLayout {
        return ChannelLayout.fromChannelCount(self.channels);
    }
};

// ============================================================================
// Opus Tags (Comment Header)
// ============================================================================

pub const OpusTags = struct {
    vendor: []const u8,
    comments: std.ArrayList(Comment),
    allocator: std.mem.Allocator,

    pub const Comment = struct {
        field: []const u8,
        value: []const u8,
    };

    const Self = @This();

    /// Parse Opus tags header
    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !Self {
        if (data.len < 16) return AudioError.TruncatedData;

        // Check magic
        if (!std.mem.eql(u8, data[0..8], &OPUS_TAGS_MAGIC)) {
            return AudioError.InvalidFormat;
        }

        var pos: usize = 8;

        // Vendor string
        const vendor_len = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;

        if (pos + vendor_len > data.len) return AudioError.TruncatedData;
        const vendor = try allocator.dupe(u8, data[pos..][0..vendor_len]);
        pos += vendor_len;

        // Comment count
        if (pos + 4 > data.len) return AudioError.TruncatedData;
        const comment_count = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;

        var comments = std.ArrayList(Comment).init(allocator);
        errdefer {
            for (comments.items) |c| {
                allocator.free(c.field);
                allocator.free(c.value);
            }
            comments.deinit();
        }

        for (0..comment_count) |_| {
            if (pos + 4 > data.len) break;

            const comment_len = std.mem.readInt(u32, data[pos..][0..4], .little);
            pos += 4;

            if (pos + comment_len > data.len) break;
            const comment_data = data[pos..][0..comment_len];
            pos += comment_len;

            // Find '=' separator
            if (std.mem.indexOf(u8, comment_data, "=")) |eq_pos| {
                const field = try allocator.dupe(u8, comment_data[0..eq_pos]);
                const value = try allocator.dupe(u8, comment_data[eq_pos + 1 ..]);
                try comments.append(.{ .field = field, .value = value });
            }
        }

        return Self{
            .vendor = vendor,
            .comments = comments,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.vendor);
        for (self.comments.items) |c| {
            self.allocator.free(c.field);
            self.allocator.free(c.value);
        }
        self.comments.deinit();
    }

    /// Get a field value (case-insensitive)
    pub fn get(self: *const Self, field: []const u8) ?[]const u8 {
        for (self.comments.items) |c| {
            if (std.ascii.eqlIgnoreCase(c.field, field)) {
                return c.value;
            }
        }
        return null;
    }

    /// Convert to Metadata
    pub fn toMetadata(self: *const Self) Metadata {
        var meta = Metadata{};

        meta.title = self.get("TITLE");
        meta.artist = self.get("ARTIST");
        meta.album = self.get("ALBUM");
        meta.album_artist = self.get("ALBUMARTIST");
        meta.genre = self.get("GENRE");
        meta.comment = self.get("COMMENT");

        if (self.get("DATE") orelse self.get("YEAR")) |year_str| {
            meta.year = std.fmt.parseInt(u16, year_str[0..@min(4, year_str.len)], 10) catch null;
        }

        if (self.get("TRACKNUMBER")) |track_str| {
            meta.track_number = std.fmt.parseInt(u16, track_str, 10) catch null;
        }

        return meta;
    }
};

// ============================================================================
// Opus Packet Info
// ============================================================================

pub const OpusPacketInfo = struct {
    /// Table of Contents byte
    toc: u8,

    /// Configuration number (0-31)
    config: u5,

    /// Stereo flag
    stereo: bool,

    /// Frame count code
    frame_count_code: u2,

    /// Number of frames in packet
    frame_count: u8,

    /// Frame sizes in bytes
    frame_sizes: [48]u16,

    /// Total payload size
    payload_size: usize,

    const Self = @This();

    /// Parse packet info from raw Opus packet
    pub fn parse(data: []const u8) !Self {
        if (data.len < 1) return AudioError.TruncatedData;

        const toc = data[0];
        const config: u5 = @truncate(toc >> 3);
        const stereo = (toc & 0x04) != 0;
        const frame_count_code: u2 = @truncate(toc & 0x03);

        var info = Self{
            .toc = toc,
            .config = config,
            .stereo = stereo,
            .frame_count_code = frame_count_code,
            .frame_count = 0,
            .frame_sizes = [_]u16{0} ** 48,
            .payload_size = 0,
        };

        var pos: usize = 1;

        switch (frame_count_code) {
            0 => {
                // 1 frame
                info.frame_count = 1;
                info.frame_sizes[0] = @intCast(data.len - 1);
            },
            1 => {
                // 2 frames, equal size
                info.frame_count = 2;
                const frame_size: u16 = @intCast((data.len - 1) / 2);
                info.frame_sizes[0] = frame_size;
                info.frame_sizes[1] = frame_size;
            },
            2 => {
                // 2 frames, different sizes
                if (data.len < 2) return AudioError.TruncatedData;
                info.frame_count = 2;

                // Parse first frame size
                var size1: u16 = data[pos];
                pos += 1;
                if (size1 >= 252) {
                    if (pos >= data.len) return AudioError.TruncatedData;
                    size1 = @as(u16, data[pos]) * 4 + size1;
                    pos += 1;
                }
                info.frame_sizes[0] = size1;
                info.frame_sizes[1] = @intCast(data.len - pos - size1);
            },
            3 => {
                // Arbitrary number of frames
                if (data.len < 2) return AudioError.TruncatedData;

                const frame_count_byte = data[pos];
                pos += 1;

                info.frame_count = frame_count_byte & 0x3F;
                const vbr = (frame_count_byte & 0x80) != 0;
                const padding = (frame_count_byte & 0x40) != 0;

                // Skip padding if present
                if (padding) {
                    while (pos < data.len and data[pos] == 255) {
                        pos += 1;
                    }
                    if (pos < data.len) {
                        pos += 1;
                    }
                }

                if (vbr) {
                    // Variable bitrate - parse each frame size
                    for (0..info.frame_count - 1) |i| {
                        if (pos >= data.len) break;
                        var size: u16 = data[pos];
                        pos += 1;
                        if (size >= 252) {
                            if (pos >= data.len) break;
                            size = @as(u16, data[pos]) * 4 + size;
                            pos += 1;
                        }
                        info.frame_sizes[i] = size;
                    }
                    // Last frame gets remaining bytes
                    var total: usize = 0;
                    for (0..info.frame_count - 1) |i| {
                        total += info.frame_sizes[i];
                    }
                    if (data.len > pos + total) {
                        info.frame_sizes[info.frame_count - 1] = @intCast(data.len - pos - total);
                    }
                } else {
                    // Constant bitrate
                    const remaining = data.len - pos;
                    const frame_size: u16 = @intCast(remaining / info.frame_count);
                    for (0..info.frame_count) |i| {
                        info.frame_sizes[i] = frame_size;
                    }
                }
            },
        }

        info.payload_size = data.len;
        return info;
    }

    /// Get frame duration in samples at 48 kHz
    pub fn getFrameDuration(self: Self) u32 {
        // Duration is determined by config number
        const durations = [_]u32{
            // SILK-only modes
            480, 960, 1920, 2880, // NB (10, 20, 40, 60 ms)
            480, 960, 1920, 2880, // MB
            480, 960, 1920, 2880, // WB
            480, 960, // SWB (10, 20 ms)
            480, 960, // FB
            // Hybrid modes
            480, 960, // SWB
            480, 960, // FB
            // CELT-only modes
            120, 240, 480, 960, // 2.5, 5, 10, 20 ms
            120, 240, 480, 960,
            120, 240, 480, 960,
            120, 240, 480, 960,
        };

        if (self.config < durations.len) {
            return durations[self.config];
        }
        return 960; // Default to 20ms
    }

    /// Get bandwidth
    pub fn getBandwidth(self: Self) Bandwidth {
        return switch (self.config) {
            0...3 => .narrowband,
            4...7 => .mediumband,
            8...11 => .wideband,
            12...13, 16...17 => .superwideband,
            14...15, 18...31 => .fullband,
        };
    }
};

// ============================================================================
// Opus Reader
// ============================================================================

pub const OpusReader = struct {
    data: []const u8,
    pos: usize,
    head: OpusHead,
    tags: ?OpusTags,
    audio_data_start: usize,
    total_samples: u64,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Create reader from memory buffer
    pub fn fromMemory(allocator: std.mem.Allocator, data: []const u8) !Self {
        if (data.len < 47) return AudioError.TruncatedData;

        // Must be in Ogg container
        if (!ogg.isOgg(data)) {
            return AudioError.InvalidFormat;
        }

        var reader = Self{
            .data = data,
            .pos = 0,
            .head = undefined,
            .tags = null,
            .audio_data_start = 0,
            .total_samples = 0,
            .allocator = allocator,
        };

        try reader.parseHeaders();
        return reader;
    }

    fn parseHeaders(self: *Self) !void {
        // First page: OpusHead
        const first_page = try ogg.OggPage.parse(self.data);
        if (!first_page.isFirstPage()) return AudioError.InvalidFormat;

        self.head = try OpusHead.parse(first_page.data);
        self.pos = first_page.total_size;

        // Second page: OpusTags
        if (self.pos < self.data.len) {
            const second_page = try ogg.OggPage.parse(self.data[self.pos..]);
            self.tags = OpusTags.parse(self.allocator, second_page.data) catch null;
            self.pos += second_page.total_size;
        }

        self.audio_data_start = self.pos;

        // Find last granule position for duration
        self.findTotalSamples();
    }

    fn findTotalSamples(self: *Self) void {
        var pos = self.data.len;

        // Search backwards for last page
        while (pos > 27) {
            pos -= 1;
            if (pos + 4 <= self.data.len and std.mem.eql(u8, self.data[pos..][0..4], "OggS")) {
                if (ogg.OggPage.parse(self.data[pos..])) |page| {
                    if (page.isLastPage() and page.granule_position >= 0) {
                        // Subtract pre-skip
                        const total = @as(u64, @intCast(page.granule_position));
                        self.total_samples = if (total > self.head.pre_skip) total - self.head.pre_skip else 0;
                        return;
                    }
                } else |_| {}
            }
        }
    }

    pub fn deinit(self: *Self) void {
        if (self.tags) |*t| {
            t.deinit();
        }
    }

    /// Get sample rate (always 48000 for Opus)
    pub fn getSampleRate(self: *const Self) u32 {
        return self.head.getOutputSampleRate();
    }

    /// Get original input sample rate
    pub fn getInputSampleRate(self: *const Self) u32 {
        return self.head.input_sample_rate;
    }

    /// Get number of channels
    pub fn getChannels(self: *const Self) u8 {
        return self.head.channels;
    }

    /// Get duration in seconds
    pub fn getDuration(self: *const Self) f64 {
        if (self.total_samples == 0) return 0;
        return @as(f64, @floatFromInt(self.total_samples)) / 48000.0;
    }

    /// Get total samples
    pub fn getTotalSamples(self: *const Self) u64 {
        return self.total_samples;
    }

    /// Get metadata
    pub fn getMetadata(self: *const Self) ?Metadata {
        if (self.tags) |*t| {
            return t.toMetadata();
        }
        return null;
    }

    /// Get pre-skip samples
    pub fn getPreSkip(self: *const Self) u16 {
        return self.head.pre_skip;
    }

    /// Get output gain in dB
    pub fn getOutputGain(self: *const Self) f32 {
        return self.head.getOutputGainDb();
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Check if data is an Opus file (in Ogg container)
pub fn isOpus(data: []const u8) bool {
    if (!ogg.isOgg(data)) return false;

    // Parse first page and check for OpusHead
    const page = ogg.OggPage.parse(data) catch return false;
    if (page.data.len < 8) return false;

    return std.mem.eql(u8, page.data[0..8], "OpusHead");
}

/// Decode Opus from memory
pub fn decode(allocator: std.mem.Allocator, data: []const u8) !AudioFrame {
    _ = allocator;
    _ = data;
    // Full Opus decoding is very complex and requires implementing:
    // - Range decoder
    // - SILK decoder (for voice)
    // - CELT decoder (for music)
    // - Hybrid mode combining both
    return AudioError.NotImplemented;
}

// ============================================================================
// Tests
// ============================================================================

test "Opus detection" {
    // Minimal Ogg page with OpusHead
    var opus_data: [64]u8 = undefined;
    @memcpy(opus_data[0..4], "OggS");
    opus_data[4] = 0; // Version
    opus_data[5] = 0x02; // BOS flag
    @memset(opus_data[6..26], 0); // Granule, serial, page#, CRC
    opus_data[26] = 1; // 1 segment
    opus_data[27] = 19; // Segment size

    // OpusHead
    @memcpy(opus_data[28..36], "OpusHead");
    opus_data[36] = 1; // Version
    opus_data[37] = 2; // Channels
    std.mem.writeInt(u16, opus_data[38..40], 312, .little); // Pre-skip
    std.mem.writeInt(u32, opus_data[40..44], 48000, .little); // Sample rate
    std.mem.writeInt(i16, opus_data[44..46], 0, .little); // Output gain
    opus_data[46] = 0; // Mapping family

    try std.testing.expect(isOpus(&opus_data));
}

test "OpusHead parsing" {
    var head_data: [19]u8 = undefined;
    @memcpy(head_data[0..8], "OpusHead");
    head_data[8] = 1; // Version
    head_data[9] = 2; // Channels
    std.mem.writeInt(u16, head_data[10..12], 312, .little); // Pre-skip
    std.mem.writeInt(u32, head_data[12..16], 44100, .little); // Input sample rate
    std.mem.writeInt(i16, head_data[16..18], 0, .little); // Output gain
    head_data[18] = 0; // Mapping family

    const head = try OpusHead.parse(&head_data);
    try std.testing.expectEqual(@as(u8, 2), head.channels);
    try std.testing.expectEqual(@as(u32, 48000), head.getOutputSampleRate());
    try std.testing.expectEqual(@as(u32, 44100), head.input_sample_rate);
}

test "OpusPacketInfo" {
    // Simple 1-frame packet
    const packet = [_]u8{ 0xFC, 0x01, 0x02, 0x03 }; // Config 31, stereo, 1 frame
    const info = try OpusPacketInfo.parse(&packet);

    try std.testing.expectEqual(@as(u8, 1), info.frame_count);
    try std.testing.expect(info.stereo);
}
