const std = @import("std");

/// AC-3 (Dolby Digital) and E-AC-3 (Dolby Digital Plus) audio codec
pub const Ac3 = struct {
    /// AC-3 vs E-AC-3
    pub const CodecType = enum {
        ac3, // Standard Dolby Digital
        eac3, // Enhanced AC-3 (Dolby Digital Plus)
    };

    /// Audio coding mode (acmod)
    pub const AudioCodingMode = enum(u3) {
        dualmono = 0, // 1+1 (Ch1, Ch2)
        mono = 1, // 1/0 (C)
        stereo = 2, // 2/0 (L, R)
        surround_3_0 = 3, // 3/0 (L, C, R)
        surround_2_1 = 4, // 2/1 (L, R, S)
        surround_3_1 = 5, // 3/1 (L, C, R, S)
        surround_2_2 = 6, // 2/2 (L, R, SL, SR)
        surround_3_2 = 7, // 3/2 (L, C, R, SL, SR)
    };

    /// Bit stream mode (bsmod)
    pub const BitstreamMode = enum(u3) {
        main_audio = 0,
        music_and_effects = 1,
        visually_impaired = 2,
        hearing_impaired = 3,
        dialogue = 4,
        commentary = 5,
        emergency = 6,
        voice_over = 7,
    };

    /// Sample rates (fscod)
    pub const SampleRate = enum(u2) {
        @"48000" = 0,
        @"44100" = 1,
        @"32000" = 2,
        reserved = 3,

        pub fn toHz(self: SampleRate) u32 {
            return switch (self) {
                .@"48000" => 48000,
                .@"44100" => 44100,
                .@"32000" => 32000,
                .reserved => 0,
            };
        }
    };

    /// Frame size codes (for AC-3)
    pub const FrameSizeCode = struct {
        fscod: SampleRate,
        frmsizecod: u6,

        pub fn getFrameSize(self: FrameSizeCode) u16 {
            // Frame size table (in words, 1 word = 2 bytes)
            const frame_size_table = [3][38]u16{
                // 48 kHz
                .{ 64, 64, 80, 80, 96, 96, 112, 112, 128, 128, 160, 160, 192, 192, 224, 224, 256, 256, 320, 320, 384, 384, 448, 448, 512, 512, 640, 640, 768, 768, 896, 896, 1024, 1024, 1152, 1152, 1280, 1280 },
                // 44.1 kHz
                .{ 69, 70, 87, 88, 104, 105, 121, 122, 139, 140, 174, 175, 208, 209, 243, 244, 278, 279, 348, 349, 417, 418, 487, 488, 557, 558, 696, 697, 835, 836, 975, 976, 1114, 1115, 1253, 1254, 1393, 1394 },
                // 32 kHz
                .{ 96, 96, 120, 120, 144, 144, 168, 168, 192, 192, 240, 240, 288, 288, 336, 336, 384, 384, 480, 480, 576, 576, 672, 672, 768, 768, 960, 960, 1152, 1152, 1344, 1344, 1536, 1536, 1728, 1728, 1920, 1920 },
            };

            const rate_idx = @intFromEnum(self.fscod);
            if (rate_idx >= 3) return 0;
            if (self.frmsizecod >= 38) return 0;

            return frame_size_table[rate_idx][self.frmsizecod] * 2; // Convert words to bytes
        }

        pub fn getBitrate(self: FrameSizeCode) u16 {
            // Bitrate table (kbps)
            const bitrate_table = [19]u16{
                32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640,
            };

            const idx = self.frmsizecod / 2;
            if (idx >= bitrate_table.len) return 0;
            return bitrate_table[idx];
        }
    };

    /// AC-3 syncframe header
    pub const SyncFrame = struct {
        sync_word: u16, // 0x0B77
        crc1: u16,
        fscod: SampleRate,
        frmsizecod: u6,
        bsid: u5, // Bit stream identification
        bsmod: BitstreamMode,
        acmod: AudioCodingMode,
        lfeon: bool, // LFE channel present
        dialnorm: u5, // Dialogue normalization
    };

    /// E-AC-3 frame header
    pub const Eac3Frame = struct {
        sync_word: u16, // 0x0B77
        strmtyp: u2, // Stream type
        substreamid: u3,
        frmsiz: u11, // Frame size in words - 1
        fscod: u2,
        fscod2: u2, // Used if fscod == 3
        acmod: AudioCodingMode,
        lfeon: bool,
        bsid: u5,
        dialnorm: u5,
    };
};

/// AC-3 / E-AC-3 parser
pub const Ac3Parser = struct {
    pub fn parseSyncFrame(data: []const u8) !Ac3.SyncFrame {
        if (data.len < 7) return error.InsufficientData;

        // Check sync word
        const sync_word = (@as(u16, data[0]) << 8) | data[1];
        if (sync_word != 0x0B77) return error.InvalidSyncWord;

        var frame: Ac3.SyncFrame = undefined;
        frame.sync_word = sync_word;
        frame.crc1 = (@as(u16, data[2]) << 8) | data[3];

        // Parse fscod and frmsizecod
        frame.fscod = @enumFromInt(@as(u2, @truncate(data[4] >> 6)));
        frame.frmsizecod = @truncate(data[4] & 0x3F);

        // bsid (bit stream identification)
        frame.bsid = @truncate(data[5] >> 3);

        // Check if this is E-AC-3 (bsid > 10)
        if (frame.bsid > 10) {
            return error.Eac3NotSupported; // Use parseEac3Frame instead
        }

        // bsmod (bit stream mode)
        frame.bsmod = @enumFromInt(@as(u3, @truncate(data[5] & 0x07)));

        // acmod (audio coding mode)
        frame.acmod = @enumFromInt(@as(u3, @truncate(data[6] >> 5)));

        // Additional flags depend on acmod
        var bit_offset: u8 = 5; // Starting bit position in data[6]

        // Center channel exists in modes 3, 5, 7
        if (@intFromEnum(frame.acmod) & 0x01 != 0 and @intFromEnum(frame.acmod) != 1) {
            // cmixlev (2 bits) - center mix level
            bit_offset -= 2;
        }

        // Surround channels exist in modes 4, 5, 6, 7
        if (@intFromEnum(frame.acmod) & 0x04 != 0) {
            // surmixlev (2 bits) - surround mix level
            bit_offset -= 2;
        }

        // Dolby Surround mode if mode == 2 (stereo)
        if (frame.acmod == .stereo) {
            // dsurmod (2 bits)
            bit_offset -= 2;
        }

        // LFE on flag
        if (data.len > 6) {
            const byte_offset = 6 + (5 - bit_offset) / 8;
            const bit_pos = (5 - bit_offset) % 8;
            if (byte_offset < data.len) {
                frame.lfeon = (data[byte_offset] & (@as(u8, 1) << @as(u3, @intCast(7 - bit_pos)))) != 0;
            } else {
                frame.lfeon = false;
            }
        } else {
            frame.lfeon = false;
        }

        // dialnorm (5 bits)
        frame.dialnorm = 31; // Default

        return frame;
    }

    pub fn parseEac3Frame(data: []const u8) !Ac3.Eac3Frame {
        if (data.len < 6) return error.InsufficientData;

        // Check sync word
        const sync_word = (@as(u16, data[0]) << 8) | data[1];
        if (sync_word != 0x0B77) return error.InvalidSyncWord;

        var frame: Ac3.Eac3Frame = undefined;
        frame.sync_word = sync_word;

        // Stream type (2 bits) and substream ID (3 bits)
        frame.strmtyp = @truncate(data[2] >> 6);
        frame.substreamid = @truncate((data[2] >> 3) & 0x07);

        // Frame size (11 bits) - in words - 1
        frame.frmsiz = (@as(u11, data[2] & 0x07) << 8) | data[3];

        // Sample rate code
        frame.fscod = @truncate(data[4] >> 6);
        if (frame.fscod == 3) {
            // Use fscod2
            frame.fscod2 = @truncate((data[4] >> 4) & 0x03);
        } else {
            frame.fscod2 = 0;
        }

        // acmod
        frame.acmod = @enumFromInt(@as(u3, @truncate((data[4] >> 1) & 0x07)));

        // LFE on
        frame.lfeon = (data[4] & 0x01) != 0;

        // bsid
        frame.bsid = @truncate(data[5] >> 3);

        // dialnorm
        frame.dialnorm = 31; // Default

        return frame;
    }

    pub fn getFrameSize(data: []const u8) !u16 {
        if (data.len < 5) return error.InsufficientData;

        const sync_word = (@as(u16, data[0]) << 8) | data[1];
        if (sync_word != 0x0B77) return error.InvalidSyncWord;

        const bsid = @as(u5, @truncate(data[5] >> 3));

        if (bsid <= 10) {
            // AC-3
            const fscod = @as(u2, @truncate(data[4] >> 6));
            const frmsizecod = @as(u6, @truncate(data[4] & 0x3F));

            const fsc = Ac3.FrameSizeCode{
                .fscod = @enumFromInt(fscod),
                .frmsizecod = frmsizecod,
            };

            return fsc.getFrameSize();
        } else {
            // E-AC-3
            const frmsiz = (@as(u16, data[2] & 0x07) << 8) | data[3];
            return (frmsiz + 1) * 2; // Convert words to bytes
        }
    }

    pub fn getChannelCount(acmod: Ac3.AudioCodingMode, lfeon: bool) u8 {
        const base_channels: u8 = switch (acmod) {
            .dualmono => 2,
            .mono => 1,
            .stereo => 2,
            .surround_3_0 => 3,
            .surround_2_1 => 3,
            .surround_3_1 => 4,
            .surround_2_2 => 4,
            .surround_3_2 => 5,
        };

        return base_channels + @intFromBool(lfeon);
    }

    pub fn getSampleRate(frame: Ac3.SyncFrame) u32 {
        return frame.fscod.toHz();
    }

    pub fn getEac3SampleRate(frame: Ac3.Eac3Frame) u32 {
        if (frame.fscod != 3) {
            const fscod: Ac3.SampleRate = @enumFromInt(frame.fscod);
            return fscod.toHz();
        } else {
            // Use fscod2 for reduced sample rates
            return switch (frame.fscod2) {
                0 => 24000,
                1 => 22050,
                2 => 16000,
                else => 0,
            };
        }
    }

    pub fn isAc3(data: []const u8) bool {
        if (data.len < 6) return false;

        const sync_word = (@as(u16, data[0]) << 8) | data[1];
        if (sync_word != 0x0B77) return false;

        const bsid = @as(u5, @truncate(data[5] >> 3));
        return bsid <= 10;
    }

    pub fn isEac3(data: []const u8) bool {
        if (data.len < 6) return false;

        const sync_word = (@as(u16, data[0]) << 8) | data[1];
        if (sync_word != 0x0B77) return false;

        const bsid = @as(u5, @truncate(data[5] >> 3));
        return bsid > 10 and bsid <= 16;
    }

    pub fn getCodecType(data: []const u8) ?Ac3.CodecType {
        if (data.len < 6) return null;

        const sync_word = (@as(u16, data[0]) << 8) | data[1];
        if (sync_word != 0x0B77) return null;

        const bsid = @as(u5, @truncate(data[5] >> 3));

        if (bsid <= 10) return .ac3;
        if (bsid <= 16) return .eac3;
        return null;
    }

    pub fn findNextFrame(data: []const u8, offset: usize) ?usize {
        var i = offset;
        while (i + 1 < data.len) : (i += 1) {
            if (data[i] == 0x0B and data[i + 1] == 0x77) {
                // Verify it's a valid frame
                if (getFrameSize(data[i..])) |_| {
                    return i;
                } else |_| {
                    continue;
                }
            }
        }
        return null;
    }
};

/// AC-3 / E-AC-3 decoder (stub)
pub const Ac3Decoder = struct {
    allocator: std.mem.Allocator,
    codec_type: Ac3.CodecType,
    sample_rate: u32,
    channels: u8,

    pub fn init(allocator: std.mem.Allocator) Ac3Decoder {
        return .{
            .allocator = allocator,
            .codec_type = .ac3,
            .sample_rate = 48000,
            .channels = 6,
        };
    }

    pub fn deinit(self: *Ac3Decoder) void {
        _ = self;
    }

    pub fn decodeFrame(self: *Ac3Decoder, data: []const u8) ![]f32 {
        // Use full decoder implementation
        const ac3_full = @import("ac3_decoder.zig");
        var full_decoder = ac3_full.Ac3FullDecoder.init(self.allocator);
        defer full_decoder.deinit();

        return try full_decoder.decodeFrame(data);
    }

    pub fn detectFormat(self: *Ac3Decoder, data: []const u8) !void {
        if (Ac3Parser.isAc3(data)) {
            const frame = try Ac3Parser.parseSyncFrame(data);
            self.codec_type = .ac3;
            self.sample_rate = Ac3Parser.getSampleRate(frame);
            self.channels = Ac3Parser.getChannelCount(frame.acmod, frame.lfeon);
        } else if (Ac3Parser.isEac3(data)) {
            const frame = try Ac3Parser.parseEac3Frame(data);
            self.codec_type = .eac3;
            self.sample_rate = Ac3Parser.getEac3SampleRate(frame);
            self.channels = Ac3Parser.getChannelCount(frame.acmod, frame.lfeon);
        } else {
            return error.InvalidFormat;
        }
    }
};

/// Check if data is AC-3 or E-AC-3
pub fn isAc3OrEac3(data: []const u8) bool {
    return Ac3Parser.isAc3(data) or Ac3Parser.isEac3(data);
}
