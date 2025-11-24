// Home Video Library - AAC/ADTS Muxer
// Raw AAC audio with ADTS headers and LATM support

const std = @import("std");

/// AAC profile
pub const AACProfile = enum(u8) {
    main = 1,
    lc = 2,       // Low Complexity (most common)
    ssr = 3,      // Scalable Sample Rate
    ltp = 4,      // Long Term Prediction
    he = 5,       // High Efficiency (HE-AAC)
    scalable = 6,
    _,
};

/// ADTS header
pub const ADTSHeader = struct {
    sync_word: u16 = 0xFFF,
    mpeg_version: u1 = 0, // 0 = MPEG-4, 1 = MPEG-2
    layer: u2 = 0,
    protection_absent: bool = true,
    profile: AACProfile,
    sample_rate_index: u4,
    private_bit: bool = false,
    channel_config: u3,
    original: bool = false,
    home: bool = false,
    copyright_id: bool = false,
    copyright_start: bool = false,
    frame_length: u13, // Including header
    buffer_fullness: u11 = 0x7FF, // VBR
    num_raw_blocks: u2 = 0, // Number of AAC frames - 1

    pub fn encode(self: *const ADTSHeader) [7]u8 {
        var header: [7]u8 = undefined;

        // Syncword (12 bits)
        header[0] = 0xFF;
        header[1] = 0xF0;

        // MPEG version (1 bit), Layer (2 bits), protection absent (1 bit)
        header[1] |= @as(u8, self.mpeg_version) << 3;
        header[1] |= @as(u8, self.layer) << 1;
        header[1] |= @as(u8, if (self.protection_absent) 1 else 0);

        // Profile (2 bits), sample rate index (4 bits), private bit (1 bit), channel config (3 bits)
        const profile_value: u8 = @intFromEnum(self.profile) - 1; // 0-indexed
        header[2] = (profile_value & 0x3) << 6;
        header[2] |= (@as(u8, self.sample_rate_index) & 0xF) << 2;
        header[2] |= @as(u8, if (self.private_bit) 1 else 0) << 1;
        header[2] |= (@as(u8, self.channel_config) >> 2) & 0x1;

        // Channel config (2 bits), original (1 bit), home (1 bit), copyright ID (1 bit), copyright start (1 bit), frame length (2 bits)
        header[3] = (@as(u8, self.channel_config) & 0x3) << 6;
        header[3] |= @as(u8, if (self.original) 1 else 0) << 5;
        header[3] |= @as(u8, if (self.home) 1 else 0) << 4;
        header[3] |= @as(u8, if (self.copyright_id) 1 else 0) << 3;
        header[3] |= @as(u8, if (self.copyright_start) 1 else 0) << 2;
        header[3] |= @as(u8, (self.frame_length >> 11) & 0x3);

        // Frame length (11 bits), buffer fullness (5 bits)
        header[4] = @as(u8, (self.frame_length >> 3) & 0xFF);
        header[5] = (@as(u8, self.frame_length) & 0x7) << 5;
        header[5] |= @as(u8, (self.buffer_fullness >> 6) & 0x1F);

        // Buffer fullness (6 bits), num raw blocks (2 bits)
        header[6] = (@as(u8, self.buffer_fullness) & 0x3F) << 2;
        header[6] |= @as(u8, self.num_raw_blocks) & 0x3;

        return header;
    }

    pub fn decode(header: [7]u8) !ADTSHeader {
        // Check syncword
        if (header[0] != 0xFF or (header[1] & 0xF0) != 0xF0) {
            return error.InvalidADTSSyncWord;
        }

        const mpeg_version: u1 = @intCast((header[1] >> 3) & 0x1);
        const protection_absent = (header[1] & 0x1) == 1;

        const profile_value = (header[2] >> 6) & 0x3;
        const profile: AACProfile = @enumFromInt(profile_value + 1);

        const sample_rate_index: u4 = @intCast((header[2] >> 2) & 0xF);

        const private_bit = ((header[2] >> 1) & 0x1) == 1;

        const channel_config: u3 = @intCast(((@as(u16, header[2]) & 0x1) << 2) | (@as(u16, header[3]) >> 6));

        const original = ((header[3] >> 5) & 0x1) == 1;
        const home = ((header[3] >> 4) & 0x1) == 1;
        const copyright_id = ((header[3] >> 3) & 0x1) == 1;
        const copyright_start = ((header[3] >> 2) & 0x1) == 1;

        const frame_length: u13 = @intCast(((@as(u32, header[3]) & 0x3) << 11) |
            (@as(u32, header[4]) << 3) |
            (@as(u32, header[5]) >> 5));

        const buffer_fullness: u11 = @intCast(((@as(u16, header[5]) & 0x1F) << 6) |
            (@as(u16, header[6]) >> 2));

        const num_raw_blocks: u2 = @intCast(header[6] & 0x3);

        return .{
            .mpeg_version = mpeg_version,
            .protection_absent = protection_absent,
            .profile = profile,
            .sample_rate_index = sample_rate_index,
            .private_bit = private_bit,
            .channel_config = channel_config,
            .original = original,
            .home = home,
            .copyright_id = copyright_id,
            .copyright_start = copyright_start,
            .frame_length = frame_length,
            .buffer_fullness = buffer_fullness,
            .num_raw_blocks = num_raw_blocks,
        };
    }
};

/// AAC sample rate index mapping
pub fn getSampleRateIndex(sample_rate: u32) !u4 {
    return switch (sample_rate) {
        96000 => 0,
        88200 => 1,
        64000 => 2,
        48000 => 3,
        44100 => 4,
        32000 => 5,
        24000 => 6,
        22050 => 7,
        16000 => 8,
        12000 => 9,
        11025 => 10,
        8000 => 11,
        7350 => 12,
        else => error.UnsupportedSampleRate,
    };
}

/// AAC/ADTS muxer
pub const AACMuxer = struct {
    allocator: std.mem.Allocator,
    profile: AACProfile,
    sample_rate: u32,
    channels: u8,

    // Options
    use_adts: bool = true, // If false, output raw AAC
    enable_crc: bool = false,

    // Frames
    frames: std.ArrayList([]const u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, profile: AACProfile, sample_rate: u32, channels: u8) !Self {
        // Validate parameters
        _ = try getSampleRateIndex(sample_rate);

        if (channels == 0 or channels > 7) {
            return error.InvalidChannelCount;
        }

        return .{
            .allocator = allocator,
            .profile = profile,
            .sample_rate = sample_rate,
            .channels = channels,
            .frames = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.frames.deinit();
    }

    pub fn addFrame(self: *Self, aac_data: []const u8) !void {
        try self.frames.append(aac_data);
    }

    pub fn finalize(self: *Self) ![]u8 {
        var output = std.ArrayList(u8).init(self.allocator);
        errdefer output.deinit();

        const sample_rate_index = try getSampleRateIndex(self.sample_rate);

        for (self.frames.items) |frame_data| {
            if (self.use_adts) {
                // Write ADTS header
                const header_size: u16 = if (self.enable_crc) 9 else 7;
                const frame_length: u13 = @intCast(header_size + frame_data.len);

                const header = ADTSHeader{
                    .protection_absent = !self.enable_crc,
                    .profile = self.profile,
                    .sample_rate_index = sample_rate_index,
                    .channel_config = @intCast(self.channels),
                    .frame_length = frame_length,
                };

                const header_bytes = header.encode();
                try output.appendSlice(&header_bytes);

                // CRC (if enabled)
                if (self.enable_crc) {
                    const crc = self.calculateCRC(frame_data);
                    try output.writer().writeInt(u16, crc, .big);
                }
            }

            // Write AAC frame data
            try output.appendSlice(frame_data);
        }

        return output.toOwnedSlice();
    }

    fn calculateCRC(self: *Self, data: []const u8) u16 {
        _ = self;

        // CRC-16 for AAC (simplified)
        var crc: u16 = 0xFFFF;

        for (data) |byte| {
            crc ^= @as(u16, byte) << 8;

            var i: u8 = 0;
            while (i < 8) : (i += 1) {
                if (crc & 0x8000 != 0) {
                    crc = (crc << 1) ^ 0x8005;
                } else {
                    crc = crc << 1;
                }
            }
        }

        return crc;
    }
};

/// LATM (Low-overhead Audio Transport Multiplex) muxer
pub const LATMMuxer = struct {
    allocator: std.mem.Allocator,
    profile: AACProfile,
    sample_rate: u32,
    channels: u8,

    // Config
    audio_mux_version: u1 = 0,
    all_streams_same_time_framing: bool = true,
    num_sub_frames: u8 = 1,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, profile: AACProfile, sample_rate: u32, channels: u8) !Self {
        return .{
            .allocator = allocator,
            .profile = profile,
            .sample_rate = sample_rate,
            .channels = channels,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn encodeFrame(self: *Self, aac_data: []const u8) ![]u8 {
        var output = std.ArrayList(u8).init(self.allocator);
        errdefer output.deinit();

        // LATM sync word (11 bits = 0x2B7)
        try output.writer().writeByte(0x56);
        try output.writer().writeByte(0xE0); // 0b11100000

        // Audio mux length information (13 bits)
        const payload_length: u13 = @intCast(aac_data.len);
        try output.writer().writeByte(@intCast((payload_length >> 5) & 0xFF));
        try output.writer().writeByte(@intCast((payload_length << 3) & 0xF8));

        // Stream mux config (simplified)
        // Would normally include audio specific config, but simplified here

        // Payload
        try output.appendSlice(aac_data);

        return output.toOwnedSlice();
    }
};

/// AAC demuxer for ADTS streams
pub const AACDemuxer = struct {
    data: []const u8,
    pos: usize = 0,

    const Self = @This();

    pub fn init(data: []const u8) Self {
        return .{
            .data = data,
        };
    }

    pub fn readFrame(self: *Self) !?ADTSFrame {
        if (self.pos + 7 > self.data.len) return null;

        // Parse ADTS header
        const header_bytes: [7]u8 = self.data[self.pos..][0..7].*;
        const header = try ADTSHeader.decode(header_bytes);

        if (self.pos + header.frame_length > self.data.len) {
            return error.TruncatedFrame;
        }

        const header_size: usize = if (header.protection_absent) 7 else 9;
        const payload_size = header.frame_length - header_size;

        const payload_start = self.pos + header_size;
        const payload = self.data[payload_start .. payload_start + payload_size];

        self.pos += header.frame_length;

        return ADTSFrame{
            .header = header,
            .payload = payload,
        };
    }

    pub const ADTSFrame = struct {
        header: ADTSHeader,
        payload: []const u8,
    };
};
