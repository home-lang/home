// Home Video Library - Opus Audio Codec
// Opus audio codec header parsing for WebM/Ogg containers
// Reference: RFC 6716, RFC 7845

const std = @import("std");
const types = @import("../../core/types.zig");
const err = @import("../../core/error.zig");

const VideoError = err.VideoError;

// ============================================================================
// Opus Channel Mapping Family
// ============================================================================

pub const ChannelMappingFamily = enum(u8) {
    /// RTP mapping (mono/stereo)
    rtp = 0,
    /// Vorbis channel order
    vorbis = 1,
    /// Ambisonics
    ambisonics = 2,
    /// Ambisonics with non-diegetic stereo
    ambisonics_with_stereo = 3,
    _,
};

// ============================================================================
// Opus Application
// ============================================================================

pub const Application = enum {
    /// Best for most VoIP/videoconference applications
    voip,
    /// Best for broadcast/high-fidelity music applications
    audio,
    /// Best for low-latency applications
    restricted_lowdelay,
};

// ============================================================================
// Opus Bandwidth
// ============================================================================

pub const Bandwidth = enum(u8) {
    narrowband = 0, // 4 kHz
    mediumband = 1, // 6 kHz
    wideband = 2, // 8 kHz
    superwideband = 3, // 12 kHz
    fullband = 4, // 20 kHz

    pub fn getMaxFrequency(self: Bandwidth) u32 {
        return switch (self) {
            .narrowband => 4000,
            .mediumband => 6000,
            .wideband => 8000,
            .superwideband => 12000,
            .fullband => 20000,
        };
    }
};

// ============================================================================
// Opus Frame Duration
// ============================================================================

pub const FrameDuration = enum {
    ms_2_5,
    ms_5,
    ms_10,
    ms_20,
    ms_40,
    ms_60,

    pub fn toMicroseconds(self: FrameDuration) u32 {
        return switch (self) {
            .ms_2_5 => 2500,
            .ms_5 => 5000,
            .ms_10 => 10000,
            .ms_20 => 20000,
            .ms_40 => 40000,
            .ms_60 => 60000,
        };
    }

    pub fn toSamples(self: FrameDuration, sample_rate: u32) u32 {
        return self.toMicroseconds() * sample_rate / 1_000_000;
    }
};

// ============================================================================
// Opus ID Header (Ogg/WebM)
// ============================================================================

pub const IdHeader = struct {
    version: u8,
    channels: u8,
    pre_skip: u16,
    input_sample_rate: u32,
    output_gain: i16,
    channel_mapping_family: ChannelMappingFamily,

    // Channel mapping (only if family != 0)
    stream_count: ?u8,
    coupled_count: ?u8,
    channel_mapping: ?[255]u8,

    pub fn parse(data: []const u8) !IdHeader {
        // Minimum size: 8 (magic) + 11 (header) = 19 bytes
        if (data.len < 19) {
            return VideoError.TruncatedData;
        }

        // Check magic signature "OpusHead"
        if (!std.mem.eql(u8, data[0..8], "OpusHead")) {
            return VideoError.InvalidMagicBytes;
        }

        const version = data[8];
        if (version > 15) {
            // Version must be compatible (0-15)
            return VideoError.UnsupportedCodec;
        }

        const channels = data[9];
        if (channels == 0) {
            return VideoError.InvalidChannelLayout;
        }

        const pre_skip = std.mem.readInt(u16, data[10..12], .little);
        const input_sample_rate = std.mem.readInt(u32, data[12..16], .little);
        const output_gain = std.mem.readInt(i16, data[16..18], .little);
        const mapping_family: ChannelMappingFamily = @enumFromInt(data[18]);

        var header = IdHeader{
            .version = version,
            .channels = channels,
            .pre_skip = pre_skip,
            .input_sample_rate = input_sample_rate,
            .output_gain = output_gain,
            .channel_mapping_family = mapping_family,
            .stream_count = null,
            .coupled_count = null,
            .channel_mapping = null,
        };

        // Parse channel mapping if family != 0
        if (@intFromEnum(mapping_family) != 0) {
            if (data.len < 21 + channels) {
                return VideoError.TruncatedData;
            }

            header.stream_count = data[19];
            header.coupled_count = data[20];

            var mapping: [255]u8 = undefined;
            @memcpy(mapping[0..channels], data[21..][0..channels]);
            header.channel_mapping = mapping;
        }

        return header;
    }

    /// Get the output gain in dB
    pub fn getOutputGainDb(self: *const IdHeader) f32 {
        return @as(f32, @floatFromInt(self.output_gain)) / 256.0;
    }

    /// Get pre-skip in seconds
    pub fn getPreSkipSeconds(self: *const IdHeader) f32 {
        return @as(f32, @floatFromInt(self.pre_skip)) / 48000.0;
    }

    /// Get total number of streams
    pub fn getTotalStreams(self: *const IdHeader) u8 {
        return self.stream_count orelse 1;
    }
};

// ============================================================================
// Opus Comment Header (Ogg)
// ============================================================================

pub const CommentHeader = struct {
    vendor_string: []const u8,
    user_comments: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !CommentHeader {
        if (data.len < 16) {
            return VideoError.TruncatedData;
        }

        // Check magic signature "OpusTags"
        if (!std.mem.eql(u8, data[0..8], "OpusTags")) {
            return VideoError.InvalidMagicBytes;
        }

        var pos: usize = 8;

        // Vendor string length
        if (pos + 4 > data.len) return VideoError.TruncatedData;
        const vendor_len = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;

        if (pos + vendor_len > data.len) return VideoError.TruncatedData;
        const vendor_string = try allocator.dupe(u8, data[pos..][0..vendor_len]);
        pos += vendor_len;

        // User comment list length
        if (pos + 4 > data.len) {
            allocator.free(vendor_string);
            return VideoError.TruncatedData;
        }
        const comment_count = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;

        var comments = std.ArrayList([]const u8).init(allocator);
        errdefer {
            for (comments.items) |c| allocator.free(c);
            comments.deinit();
            allocator.free(vendor_string);
        }

        for (0..comment_count) |_| {
            if (pos + 4 > data.len) return VideoError.TruncatedData;
            const comment_len = std.mem.readInt(u32, data[pos..][0..4], .little);
            pos += 4;

            if (pos + comment_len > data.len) return VideoError.TruncatedData;
            const comment = try allocator.dupe(u8, data[pos..][0..comment_len]);
            try comments.append(comment);
            pos += comment_len;
        }

        return CommentHeader{
            .vendor_string = vendor_string,
            .user_comments = comments,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CommentHeader) void {
        for (self.user_comments.items) |c| {
            self.allocator.free(c);
        }
        self.user_comments.deinit();
        self.allocator.free(self.vendor_string);
    }

    /// Get a specific tag value (e.g., "TITLE", "ARTIST")
    pub fn getTag(self: *const CommentHeader, name: []const u8) ?[]const u8 {
        for (self.user_comments.items) |comment| {
            if (comment.len > name.len + 1 and comment[name.len] == '=') {
                if (std.ascii.eqlIgnoreCase(comment[0..name.len], name)) {
                    return comment[name.len + 1 ..];
                }
            }
        }
        return null;
    }
};

// ============================================================================
// Opus Packet TOC (Table of Contents)
// ============================================================================

pub const PacketToc = struct {
    config: u5,
    stereo: bool,
    frame_count_code: u2,

    pub fn parse(byte: u8) PacketToc {
        return .{
            .config = @intCast(byte >> 3),
            .stereo = ((byte >> 2) & 1) != 0,
            .frame_count_code = @intCast(byte & 0x03),
        };
    }

    /// Get the bandwidth from config
    pub fn getBandwidth(self: *const PacketToc) Bandwidth {
        const config = self.config;
        if (config < 4) return .narrowband;
        if (config < 8) return .mediumband;
        if (config < 12) return .wideband;
        if (config < 14) return .superwideband;
        return .fullband;
    }

    /// Get frame duration from config
    pub fn getFrameDuration(self: *const PacketToc) FrameDuration {
        const config = self.config;

        // SILK-only modes
        if (config < 12) {
            return switch (config % 4) {
                0 => .ms_10,
                1 => .ms_20,
                2 => .ms_40,
                3 => .ms_60,
                else => unreachable,
            };
        }

        // Hybrid modes
        if (config < 16) {
            return if ((config % 2) == 0) .ms_10 else .ms_20;
        }

        // CELT-only modes
        return switch (config % 4) {
            0 => .ms_2_5,
            1 => .ms_5,
            2 => .ms_10,
            3 => .ms_20,
            else => unreachable,
        };
    }

    /// Get number of frames in the packet
    pub fn getFrameCount(self: *const PacketToc, packet_data: []const u8) u8 {
        return switch (self.frame_count_code) {
            0 => 1,
            1, 2 => 2,
            3 => if (packet_data.len > 1) packet_data[1] & 0x3F else 0,
        };
    }

    /// Check if this is a SILK-only mode
    pub fn isSilk(self: *const PacketToc) bool {
        return self.config < 12;
    }

    /// Check if this is a CELT-only mode
    pub fn isCelt(self: *const PacketToc) bool {
        return self.config >= 16;
    }

    /// Check if this is a hybrid mode
    pub fn isHybrid(self: *const PacketToc) bool {
        return self.config >= 12 and self.config < 16;
    }
};

// ============================================================================
// Opus dOps Box (MP4)
// ============================================================================

pub const DOpsBox = struct {
    version: u8,
    output_channel_count: u8,
    pre_skip: u16,
    input_sample_rate: u32,
    output_gain: i16,
    channel_mapping_family: ChannelMappingFamily,
    stream_count: ?u8,
    coupled_count: ?u8,
    channel_mapping: ?[255]u8,

    pub fn parse(data: []const u8) !DOpsBox {
        if (data.len < 11) {
            return VideoError.TruncatedData;
        }

        const version = data[0];
        const output_channel_count = data[1];
        const pre_skip = std.mem.readInt(u16, data[2..4], .big);
        const input_sample_rate = std.mem.readInt(u32, data[4..8], .big);
        const output_gain = std.mem.readInt(i16, data[8..10], .big);
        const mapping_family: ChannelMappingFamily = @enumFromInt(data[10]);

        var dops = DOpsBox{
            .version = version,
            .output_channel_count = output_channel_count,
            .pre_skip = pre_skip,
            .input_sample_rate = input_sample_rate,
            .output_gain = output_gain,
            .channel_mapping_family = mapping_family,
            .stream_count = null,
            .coupled_count = null,
            .channel_mapping = null,
        };

        if (@intFromEnum(mapping_family) != 0) {
            if (data.len < 13 + output_channel_count) {
                return VideoError.TruncatedData;
            }
            dops.stream_count = data[11];
            dops.coupled_count = data[12];

            var mapping: [255]u8 = undefined;
            @memcpy(mapping[0..output_channel_count], data[13..][0..output_channel_count]);
            dops.channel_mapping = mapping;
        }

        return dops;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Bandwidth properties" {
    try std.testing.expectEqual(@as(u32, 4000), Bandwidth.narrowband.getMaxFrequency());
    try std.testing.expectEqual(@as(u32, 20000), Bandwidth.fullband.getMaxFrequency());
}

test "FrameDuration properties" {
    try std.testing.expectEqual(@as(u32, 2500), FrameDuration.ms_2_5.toMicroseconds());
    try std.testing.expectEqual(@as(u32, 20000), FrameDuration.ms_20.toMicroseconds());

    // 48kHz sample rate
    try std.testing.expectEqual(@as(u32, 960), FrameDuration.ms_20.toSamples(48000));
    try std.testing.expectEqual(@as(u32, 120), FrameDuration.ms_2_5.toSamples(48000));
}

test "IdHeader parsing" {
    const opus_head = [_]u8{
        'O', 'p', 'u', 's', 'H', 'e', 'a', 'd', // Magic
        0x01, // Version
        0x02, // Channels (stereo)
        0x38, 0x01, // Pre-skip (312)
        0x80, 0xBB, 0x00, 0x00, // Input sample rate (48000)
        0x00, 0x00, // Output gain (0)
        0x00, // Channel mapping family (RTP)
    };

    const header = try IdHeader.parse(&opus_head);
    try std.testing.expectEqual(@as(u8, 1), header.version);
    try std.testing.expectEqual(@as(u8, 2), header.channels);
    try std.testing.expectEqual(@as(u16, 312), header.pre_skip);
    try std.testing.expectEqual(@as(u32, 48000), header.input_sample_rate);
    try std.testing.expectEqual(ChannelMappingFamily.rtp, header.channel_mapping_family);
}

test "IdHeader output gain" {
    var header: IdHeader = undefined;
    header.output_gain = 256; // +1 dB
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), header.getOutputGainDb(), 0.01);

    header.output_gain = -512; // -2 dB
    try std.testing.expectApproxEqAbs(@as(f32, -2.0), header.getOutputGainDb(), 0.01);
}

test "PacketToc parsing" {
    // Config 15 (hybrid, 20ms), stereo, 1 frame
    const toc = PacketToc.parse(0x7C); // 01111 1 00
    try std.testing.expectEqual(@as(u5, 15), toc.config);
    try std.testing.expect(toc.stereo);
    try std.testing.expectEqual(@as(u2, 0), toc.frame_count_code);
    try std.testing.expect(toc.isHybrid());
}

test "PacketToc bandwidth" {
    var toc: PacketToc = undefined;

    toc.config = 0;
    try std.testing.expectEqual(Bandwidth.narrowband, toc.getBandwidth());

    toc.config = 8;
    try std.testing.expectEqual(Bandwidth.wideband, toc.getBandwidth());

    toc.config = 16;
    try std.testing.expectEqual(Bandwidth.fullband, toc.getBandwidth());
}

test "PacketToc mode detection" {
    var toc: PacketToc = undefined;

    toc.config = 5;
    try std.testing.expect(toc.isSilk());
    try std.testing.expect(!toc.isCelt());
    try std.testing.expect(!toc.isHybrid());

    toc.config = 14;
    try std.testing.expect(!toc.isSilk());
    try std.testing.expect(!toc.isCelt());
    try std.testing.expect(toc.isHybrid());

    toc.config = 20;
    try std.testing.expect(!toc.isSilk());
    try std.testing.expect(toc.isCelt());
    try std.testing.expect(!toc.isHybrid());
}
