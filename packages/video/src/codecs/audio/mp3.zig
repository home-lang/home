const std = @import("std");

/// MP3 (MPEG-1/2 Audio Layer III) codec
pub const Mp3 = struct {
    /// MPEG version
    pub const Version = enum(u2) {
        mpeg_2_5 = 0,
        reserved = 1,
        mpeg_2 = 2,
        mpeg_1 = 3,
    };

    /// Layer
    pub const Layer = enum(u2) {
        reserved = 0,
        layer_3 = 1,
        layer_2 = 2,
        layer_1 = 3,
    };

    /// Channel mode
    pub const ChannelMode = enum(u2) {
        stereo = 0,
        joint_stereo = 1,
        dual_channel = 2,
        mono = 3,
    };

    /// Emphasis
    pub const Emphasis = enum(u2) {
        none = 0,
        ms_50_15 = 1,
        reserved = 2,
        ccit_j_17 = 3,
    };

    /// MP3 frame header
    pub const FrameHeader = struct {
        sync: u11,
        version: Version,
        layer: Layer,
        protection: bool,
        bitrate_index: u4,
        sample_rate_index: u2,
        padding: bool,
        private_bit: bool,
        channel_mode: ChannelMode,
        mode_extension: u2,
        copyright: bool,
        original: bool,
        emphasis: Emphasis,

        pub fn getSampleRate(self: *const FrameHeader) u32 {
            const rates = switch (self.version) {
                .mpeg_1 => [3]u32{ 44100, 48000, 32000 },
                .mpeg_2 => [3]u32{ 22050, 24000, 16000 },
                .mpeg_2_5 => [3]u32{ 11025, 12000, 8000 },
                else => [3]u32{ 0, 0, 0 },
            };

            if (self.sample_rate_index >= 3) return 0;
            return rates[self.sample_rate_index];
        }

        pub fn getBitrate(self: *const FrameHeader) u32 {
            // Bitrate table (kbps)
            const bitrate_table_v1_l3 = [_]u32{ 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0 };
            const bitrate_table_v2_l3 = [_]u32{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0 };

            const table = if (self.version == .mpeg_1) bitrate_table_v1_l3 else bitrate_table_v2_l3;

            if (self.bitrate_index >= table.len) return 0;
            return table[self.bitrate_index];
        }

        pub fn getFrameSize(self: *const FrameHeader) u32 {
            const bitrate = self.getBitrate();
            const sample_rate = self.getSampleRate();

            if (bitrate == 0 or sample_rate == 0) return 0;

            const samples_per_frame: u32 = if (self.version == .mpeg_1) 1152 else 576;
            const frame_size = (samples_per_frame * bitrate * 1000) / (8 * sample_rate);

            return if (self.padding) frame_size + 1 else frame_size;
        }

        pub fn getChannelCount(self: *const FrameHeader) u8 {
            return if (self.channel_mode == .mono) 1 else 2;
        }
    };

    /// Xing/Info header for VBR
    pub const XingHeader = struct {
        frames: u32,
        bytes: u32,
        quality: u8,
        has_toc: bool,
        toc: [100]u8,
    };

    /// VBRI header (Fraunhofer)
    pub const VbriHeader = struct {
        version: u16,
        delay: u16,
        quality: u16,
        bytes: u32,
        frames: u32,
        toc_entries: u16,
    };
};

/// MP3 frame parser
pub const Mp3Parser = struct {
    pub fn parseFrameHeader(data: []const u8) !Mp3.FrameHeader {
        if (data.len < 4) return error.InsufficientData;

        // Check sync word (11 bits, all 1s)
        if (data[0] != 0xFF or (data[1] & 0xE0) != 0xE0) {
            return error.InvalidSync;
        }

        var header: Mp3.FrameHeader = undefined;

        header.sync = 0x7FF;
        header.version = @enumFromInt(@as(u2, @truncate((data[1] >> 3) & 0x03)));
        header.layer = @enumFromInt(@as(u2, @truncate((data[1] >> 1) & 0x03)));
        header.protection = (data[1] & 0x01) == 0;

        header.bitrate_index = @truncate(data[2] >> 4);
        header.sample_rate_index = @truncate((data[2] >> 2) & 0x03);
        header.padding = (data[2] & 0x02) != 0;
        header.private_bit = (data[2] & 0x01) != 0;

        header.channel_mode = @enumFromInt(@as(u2, @truncate(data[3] >> 6)));
        header.mode_extension = @truncate((data[3] >> 4) & 0x03);
        header.copyright = (data[3] & 0x08) != 0;
        header.original = (data[3] & 0x04) != 0;
        header.emphasis = @enumFromInt(@as(u2, @truncate(data[3] & 0x03)));

        return header;
    }

    pub fn parseXingHeader(data: []const u8) !Mp3.XingHeader {
        if (data.len < 120) return error.InsufficientData;

        var header: Mp3.XingHeader = undefined;

        // Look for "Xing" or "Info" marker
        const offset = if (std.mem.indexOf(u8, data[0..200], "Xing")) |pos|
            pos
        else if (std.mem.indexOf(u8, data[0..200], "Info")) |pos|
            pos
        else
            return error.NoXingHeader;

        // Flags
        const flags = (@as(u32, data[offset + 4]) << 24) | (@as(u32, data[offset + 5]) << 16) | (@as(u32, data[offset + 6]) << 8) | data[offset + 7];

        var pos = offset + 8;

        // Frames field (if present)
        if ((flags & 0x01) != 0) {
            if (pos + 4 > data.len) return error.InsufficientData;
            header.frames = (@as(u32, data[pos]) << 24) | (@as(u32, data[pos + 1]) << 16) | (@as(u32, data[pos + 2]) << 8) | data[pos + 3];
            pos += 4;
        } else {
            header.frames = 0;
        }

        // Bytes field (if present)
        if ((flags & 0x02) != 0) {
            if (pos + 4 > data.len) return error.InsufficientData;
            header.bytes = (@as(u32, data[pos]) << 24) | (@as(u32, data[pos + 1]) << 16) | (@as(u32, data[pos + 2]) << 8) | data[pos + 3];
            pos += 4;
        } else {
            header.bytes = 0;
        }

        // TOC (if present)
        header.has_toc = (flags & 0x04) != 0;
        if (header.has_toc) {
            if (pos + 100 > data.len) return error.InsufficientData;
            @memcpy(&header.toc, data[pos .. pos + 100]);
            pos += 100;
        }

        // Quality field (if present)
        if ((flags & 0x08) != 0) {
            if (pos + 4 > data.len) return error.InsufficientData;
            header.quality = data[pos + 3];
        } else {
            header.quality = 0;
        }

        return header;
    }

    pub fn findNextFrame(data: []const u8, offset: usize) ?usize {
        var i = offset;
        while (i + 1 < data.len) : (i += 1) {
            if (data[i] == 0xFF and (data[i + 1] & 0xE0) == 0xE0) {
                // Verify it's a valid header
                if (parseFrameHeader(data[i..])) |_| {
                    return i;
                } else |_| {
                    continue;
                }
            }
        }
        return null;
    }

    pub fn calculateDuration(data: []const u8) !u64 {
        // Try to find Xing header first
        if (parseXingHeader(data)) |xing| {
            if (xing.frames > 0) {
                const header = try parseFrameHeader(data);
                const samples_per_frame: u64 = if (header.version == .mpeg_1) 1152 else 576;
                const sample_rate = header.getSampleRate();
                const total_samples = samples_per_frame * xing.frames;
                return (total_samples * 1_000_000) / sample_rate;
            }
        } else |_| {}

        // Count frames manually
        var frame_count: u64 = 0;
        var offset: usize = 0;
        var first_header: ?Mp3.FrameHeader = null;

        while (offset < data.len) {
            const header = parseFrameHeader(data[offset..]) catch break;

            if (first_header == null) {
                first_header = header;
            }

            const frame_size = header.getFrameSize();
            if (frame_size == 0) break;

            frame_count += 1;
            offset += frame_size;
        }

        if (first_header) |header| {
            const samples_per_frame: u64 = if (header.version == .mpeg_1) 1152 else 576;
            const sample_rate = header.getSampleRate();
            const total_samples = samples_per_frame * frame_count;
            return (total_samples * 1_000_000) / sample_rate;
        }

        return 0;
    }
};

/// Check if data is MP3
pub fn isMp3(data: []const u8) bool {
    if (data.len < 4) return false;

    // Check for sync word
    if (data[0] == 0xFF and (data[1] & 0xE0) == 0xE0) {
        return Mp3Parser.parseFrameHeader(data) != error.InvalidSync;
    }

    // Check for ID3v2 tag
    if (data.len >= 10 and std.mem.eql(u8, data[0..3], "ID3")) {
        return true;
    }

    return false;
}

/// MP3 container reader (with ID3 support)
pub const Mp3Reader = struct {
    allocator: std.mem.Allocator,
    data: []const u8,
    audio_offset: usize,
    first_frame_header: ?Mp3.FrameHeader,

    pub fn init(allocator: std.mem.Allocator, data: []const u8) !Mp3Reader {
        var reader = Mp3Reader{
            .allocator = allocator,
            .data = data,
            .audio_offset = 0,
            .first_frame_header = null,
        };

        // Skip ID3v2 tag if present
        if (data.len >= 10 and std.mem.eql(u8, data[0..3], "ID3")) {
            const tag_size = (@as(u32, data[6] & 0x7F) << 21) | (@as(u32, data[7] & 0x7F) << 14) | (@as(u32, data[8] & 0x7F) << 7) | (data[9] & 0x7F);
            reader.audio_offset = 10 + tag_size;
        }

        // Find first frame
        if (Mp3Parser.findNextFrame(data, reader.audio_offset)) |pos| {
            reader.audio_offset = pos;
            reader.first_frame_header = try Mp3Parser.parseFrameHeader(data[pos..]);
        }

        return reader;
    }

    pub fn getSampleRate(self: *const Mp3Reader) u32 {
        if (self.first_frame_header) |header| {
            return header.getSampleRate();
        }
        return 0;
    }

    pub fn getChannelCount(self: *const Mp3Reader) u8 {
        if (self.first_frame_header) |header| {
            return header.getChannelCount();
        }
        return 0;
    }

    pub fn getBitrate(self: *const Mp3Reader) u32 {
        if (self.first_frame_header) |header| {
            return header.getBitrate();
        }
        return 0;
    }

    pub fn getDuration(self: *const Mp3Reader) !u64 {
        return Mp3Parser.calculateDuration(self.data[self.audio_offset..]);
    }
};
