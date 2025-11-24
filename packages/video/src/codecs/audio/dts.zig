const std = @import("std");

/// DTS (Digital Theater Systems) audio codec
/// DTS, DTS-ES, DTS-HD, DTS:X
pub const Dts = struct {
    /// DTS codec variant
    pub const Variant = enum {
        dts, // Core DTS
        dts_es, // Extended Surround
        dts_96_24, // 96kHz/24bit
        dts_hd_hra, // High Resolution Audio
        dts_hd_ma, // Master Audio (lossless)
        dts_express, // Low bitrate (LBR)
        dts_x, // Object-based
    };

    /// Audio mode (AMODE)
    pub const AudioMode = enum(u4) {
        mono = 0, // A (mono)
        dual_mono = 1, // A + B (dual mono)
        stereo = 2, // L + R (stereo)
        stereo_sum_diff = 3, // (L+R) + (L-R)
        stereo_lt_rt = 4, // LT + RT (Dolby Surround encoded)
        surround_3_0 = 5, // C + L + R
        surround_2_1 = 6, // L + R + S
        surround_3_1 = 7, // C + L + R + S
        surround_2_2 = 8, // L + R + SL + SR
        surround_3_2 = 9, // C + L + R + SL + SR
        reserved_a = 10,
        reserved_b = 11,
        reserved_c = 12,
        reserved_d = 13,
        reserved_e = 14,
        reserved_f = 15,
    };

    /// Sample rate codes
    pub const SampleRate = enum(u4) {
        invalid = 0,
        @"8000" = 1,
        @"16000" = 2,
        @"32000" = 3,
        invalid_4 = 4,
        invalid_5 = 5,
        @"11025" = 6,
        @"22050" = 7,
        @"44100" = 8,
        invalid_9 = 9,
        invalid_a = 10,
        @"12000" = 11,
        @"24000" = 12,
        @"48000" = 13,
        @"96000" = 14,
        @"192000" = 15,

        pub fn toHz(self: SampleRate) u32 {
            return switch (self) {
                .@"8000" => 8000,
                .@"16000" => 16000,
                .@"32000" => 32000,
                .@"11025" => 11025,
                .@"22050" => 22050,
                .@"44100" => 44100,
                .@"12000" => 12000,
                .@"24000" => 24000,
                .@"48000" => 48000,
                .@"96000" => 96000,
                .@"192000" => 192000,
                else => 0,
            };
        }
    };

    /// Bitrate codes (for core DTS)
    pub const BitrateCode = enum(u5) {
        @"32" = 0,
        @"56" = 1,
        @"64" = 2,
        @"96" = 3,
        @"112" = 4,
        @"128" = 5,
        @"192" = 6,
        @"224" = 7,
        @"256" = 8,
        @"320" = 9,
        @"384" = 10,
        @"448" = 11,
        @"512" = 12,
        @"576" = 13,
        @"640" = 14,
        @"768" = 15,
        @"896" = 16,
        @"1024" = 17,
        @"1152" = 18,
        @"1280" = 19,
        @"1344" = 20,
        @"1408" = 21,
        @"1411_2" = 22,
        @"1472" = 23,
        @"1536" = 24,
        open = 29, // Open bitrate
        variable = 30, // Variable bitrate
        lossless = 31, // Lossless
        _,

        pub fn toKbps(self: BitrateCode) u16 {
            return switch (self) {
                .@"32" => 32,
                .@"56" => 56,
                .@"64" => 64,
                .@"96" => 96,
                .@"112" => 112,
                .@"128" => 128,
                .@"192" => 192,
                .@"224" => 224,
                .@"256" => 256,
                .@"320" => 320,
                .@"384" => 384,
                .@"448" => 448,
                .@"512" => 512,
                .@"576" => 576,
                .@"640" => 640,
                .@"768" => 768,
                .@"896" => 896,
                .@"1024" => 1024,
                .@"1152" => 1152,
                .@"1280" => 1280,
                .@"1344" => 1344,
                .@"1408" => 1408,
                .@"1411_2" => 1411,
                .@"1472" => 1472,
                .@"1536" => 1536,
                else => 0,
            };
        }
    };

    /// DTS core frame header
    pub const CoreFrameHeader = struct {
        sync_word: u32, // 0x7FFE8001 (BE) or 0xFE7F0180 (14-bit LE)
        frame_type: u1,
        deficit_sample_count: u5,
        crc_present: bool,
        pcm_sample_blocks: u7, // Number of PCM sample blocks - 1
        frame_size: u14, // Frame size in bytes - 1
        audio_mode: AudioMode,
        sample_rate: SampleRate,
        bitrate: BitrateCode,
        downmix: bool,
        dynamic_range: bool,
        timestamp: bool,
        auxiliary_data: bool,
        hdcd: bool,
        ext_audio_id: u3,
        ext_audio: bool,
        aspf: bool, // Audio sync word insertion flag
        lfe: u2, // LFE channel
        predictor_history: bool,
    };

    /// DTS-HD extension header
    pub const HdHeader = struct {
        extension_sync_word: u32,
        user_defined_bits: u8,
        extension_size: u32,
        is_hd_master_audio: bool,
        hd_sample_rate: u32,
        hd_channels: u8,
    };
};

/// DTS parser
pub const DtsParser = struct {
    pub fn parseCoreFrameHeader(data: []const u8) !Dts.CoreFrameHeader {
        if (data.len < 10) return error.InsufficientData;

        // Check sync word (big endian)
        const sync_be = (@as(u32, data[0]) << 24) | (@as(u32, data[1]) << 16) | (@as(u32, data[2]) << 8) | data[3];

        if (sync_be != 0x7FFE8001) {
            // Try 14-bit little endian sync
            const sync_14le = (@as(u32, data[0]) << 24) | (@as(u32, data[1]) << 16) | (@as(u32, data[2]) << 8) | data[3];
            if (sync_14le != 0xFE7F0180 and sync_14le != 0xFF1F00E8) {
                return error.InvalidSyncWord;
            }
        }

        var header: Dts.CoreFrameHeader = undefined;
        header.sync_word = sync_be;

        // Frame type (1 bit) and deficit sample count (5 bits)
        header.frame_type = @truncate(data[4] >> 7);
        header.deficit_sample_count = @truncate((data[4] >> 2) & 0x1F);

        // CRC present flag (1 bit)
        header.crc_present = (data[4] & 0x02) != 0;

        // PCM sample blocks (7 bits)
        header.pcm_sample_blocks = @truncate(((data[4] & 0x01) << 6) | (data[5] >> 2));

        // Frame size (14 bits)
        header.frame_size = @truncate(((@as(u16, data[5]) & 0x03) << 12) | (@as(u16, data[6]) << 4) | (data[7] >> 4));

        // Audio mode (6 bits)
        header.audio_mode = @enumFromInt(@as(u4, @truncate((data[7] & 0x0F))));

        // Sample rate (4 bits)
        header.sample_rate = @enumFromInt(@as(u4, @truncate(data[8] >> 4)));

        // Bitrate (5 bits)
        header.bitrate = @enumFromInt(@as(u5, @truncate(((data[8] & 0x0F) << 1) | (data[9] >> 7))));

        // Flags
        header.downmix = (data[9] & 0x40) != 0;
        header.dynamic_range = (data[9] & 0x20) != 0;
        header.timestamp = (data[9] & 0x10) != 0;
        header.auxiliary_data = (data[9] & 0x08) != 0;
        header.hdcd = (data[9] & 0x04) != 0;
        header.ext_audio_id = @truncate((data[9] & 0x03) << 1);

        if (data.len > 10) {
            header.ext_audio_id |= @truncate(data[10] >> 7);
            header.ext_audio = (data[10] & 0x40) != 0;
            header.aspf = (data[10] & 0x20) != 0;
            header.lfe = @truncate((data[10] >> 3) & 0x03);
            header.predictor_history = (data[10] & 0x04) != 0;
        } else {
            header.ext_audio = false;
            header.aspf = false;
            header.lfe = 0;
            header.predictor_history = false;
        }

        return header;
    }

    pub fn getFrameSize(header: Dts.CoreFrameHeader) u16 {
        return header.frame_size + 1;
    }

    pub fn getSampleCount(header: Dts.CoreFrameHeader) u16 {
        return (@as(u16, header.pcm_sample_blocks) + 1) * 32;
    }

    pub fn getChannelCount(header: Dts.CoreFrameHeader) u8 {
        const base_channels: u8 = switch (header.audio_mode) {
            .mono => 1,
            .dual_mono => 2,
            .stereo, .stereo_sum_diff, .stereo_lt_rt => 2,
            .surround_3_0 => 3,
            .surround_2_1 => 3,
            .surround_3_1 => 4,
            .surround_2_2 => 4,
            .surround_3_2 => 5,
            else => 2,
        };

        // Add LFE channel if present
        const lfe_channels: u8 = if (header.lfe > 0) 1 else 0;

        return base_channels + lfe_channels;
    }

    pub fn getSampleRate(header: Dts.CoreFrameHeader) u32 {
        return header.sample_rate.toHz();
    }

    pub fn getBitrate(header: Dts.CoreFrameHeader) u16 {
        return header.bitrate.toKbps();
    }

    pub fn detectHdExtension(data: []const u8, core_frame_size: usize) ?Dts.HdHeader {
        // DTS-HD extension starts after core frame
        if (data.len < core_frame_size + 8) return null;

        const ext_data = data[core_frame_size..];

        // Check for DTS-HD sync word (0x64582025)
        const sync = (@as(u32, ext_data[0]) << 24) | (@as(u32, ext_data[1]) << 16) | (@as(u32, ext_data[2]) << 8) | ext_data[3];

        if (sync != 0x64582025) return null;

        var hd_header = Dts.HdHeader{
            .extension_sync_word = sync,
            .user_defined_bits = ext_data[4],
            .extension_size = 0,
            .is_hd_master_audio = false,
            .hd_sample_rate = 0,
            .hd_channels = 0,
        };

        // Parse extension substream header
        if (ext_data.len >= 9) {
            const ext_ss_hdr = ext_data[5];
            hd_header.is_hd_master_audio = (ext_ss_hdr & 0x80) != 0;
        }

        return hd_header;
    }

    pub fn isDts(data: []const u8) bool {
        if (data.len < 4) return false;

        const sync = (@as(u32, data[0]) << 24) | (@as(u32, data[1]) << 16) | (@as(u32, data[2]) << 8) | data[3];

        // Check for various DTS sync patterns
        return sync == 0x7FFE8001 or // Core, big endian
            sync == 0xFE7F0180 or // Core, 14-bit little endian
            sync == 0xFF1F00E8 or // Core, 14-bit big endian
            sync == 0x64582025; // DTS-HD extension
    }

    pub fn findNextFrame(data: []const u8, offset: usize) ?usize {
        var i = offset;
        while (i + 3 < data.len) : (i += 1) {
            const sync = (@as(u32, data[i]) << 24) | (@as(u32, data[i + 1]) << 16) | (@as(u32, data[i + 2]) << 8) | data[i + 3];

            if (sync == 0x7FFE8001 or sync == 0xFE7F0180 or sync == 0xFF1F00E8) {
                // Verify by parsing header
                if (parseCoreFrameHeader(data[i..])) |_| {
                    return i;
                } else |_| {
                    continue;
                }
            }
        }
        return null;
    }
};

/// DTS decoder (stub - decode only)
pub const DtsDecoder = struct {
    allocator: std.mem.Allocator,
    variant: Dts.Variant,
    sample_rate: u32,
    channels: u8,
    bitrate: u16,

    pub fn init(allocator: std.mem.Allocator) DtsDecoder {
        return .{
            .allocator = allocator,
            .variant = .dts,
            .sample_rate = 48000,
            .channels = 6,
            .bitrate = 0,
        };
    }

    pub fn deinit(self: *DtsDecoder) void {
        _ = self;
    }

    pub fn detectFormat(self: *DtsDecoder, data: []const u8) !void {
        const header = try DtsParser.parseCoreFrameHeader(data);

        self.sample_rate = DtsParser.getSampleRate(header);
        self.channels = DtsParser.getChannelCount(header);
        self.bitrate = DtsParser.getBitrate(header);

        // Check for HD extension
        const frame_size = DtsParser.getFrameSize(header);
        if (DtsParser.detectHdExtension(data, frame_size)) |hd| {
            self.variant = if (hd.is_hd_master_audio) .dts_hd_ma else .dts_hd_hra;
        } else {
            self.variant = .dts;
        }
    }

    pub fn decodeFrame(self: *DtsDecoder, data: []const u8) ![]f32 {
        // Use full decoder implementation
        const dts_full = @import("dts_decoder.zig");
        var full_decoder = dts_full.DtsFullDecoder.init(self.allocator);
        defer full_decoder.deinit();

        return try full_decoder.decodeFrame(data);
    }
};

/// Check if data is DTS stream
pub fn isDts(data: []const u8) bool {
    return DtsParser.isDts(data);
}
