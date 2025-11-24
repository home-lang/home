const std = @import("std");

/// WSS (Wide Screen Signaling) - ITU-R BT.1119-2, ETSI EN 300 294
/// Embedded in line 23 of PAL/SECAM video to signal aspect ratio and other parameters
pub const Wss = struct {
    /// Aspect ratio format
    pub const AspectRatio = enum(u4) {
        full_4_3 = 0b1000, // 4:3 full format
        letterbox_14_9_center = 0b0001, // 14:9 letterbox, center
        letterbox_14_9_top = 0b0010, // 14:9 letterbox, top
        letterbox_16_9_center = 0b1011, // 16:9 letterbox, center
        letterbox_16_9_top = 0b0100, // 16:9 letterbox, top
        letterbox_gt_16_9_center = 0b1101, // >16:9 letterbox, center
        full_16_9_anamorphic = 0b0111, // 16:9 full format (anamorphic)
        full_14_9_center = 0b1110, // 14:9 full format, center

        _,
    };

    /// Camera mode
    pub const CameraMode = enum(u1) {
        camera = 0,
        film = 1,
    };

    /// Color coding
    pub const ColorCoding = enum(u1) {
        normal_pal = 0,
        motion_adaptive_colorplus = 1,
    };

    /// Helper signals
    pub const HelperSignals = enum(u1) {
        no_helper = 0,
        modulated_helper = 1,
    };

    /// Teletext subtitles
    pub const Subtitles = enum(u1) {
        no_subtitles = 0,
        subtitles_in_teletext = 1,
    };

    /// Surround sound
    pub const SurroundSound = enum(u1) {
        no_surround = 0,
        surround_sound = 1,
    };

    /// Copyright
    pub const Copyright = enum(u1) {
        no_copyright = 0,
        copyright_asserted = 1,
    };

    /// Copy protection
    pub const CopyProtection = enum(u1) {
        copy_allowed = 0,
        copy_restricted = 1,
    };

    /// Complete WSS data
    pub const Data = struct {
        aspect_ratio: AspectRatio,
        camera_mode: CameraMode,
        color_coding: ColorCoding,
        helper_signals: HelperSignals,
        subtitles: Subtitles,
        surround_sound: SurroundSound,
        copyright: Copyright,
        copy_protection: CopyProtection,

        /// Get human-readable description
        pub fn describe(self: Data) []const u8 {
            return switch (self.aspect_ratio) {
                .full_4_3 => "4:3 full format",
                .letterbox_14_9_center => "14:9 letterbox centered",
                .letterbox_14_9_top => "14:9 letterbox top aligned",
                .letterbox_16_9_center => "16:9 letterbox centered",
                .letterbox_16_9_top => "16:9 letterbox top aligned",
                .letterbox_gt_16_9_center => ">16:9 letterbox centered",
                .full_16_9_anamorphic => "16:9 anamorphic",
                .full_14_9_center => "14:9 full format centered",
                else => "Unknown aspect ratio format",
            };
        }

        /// Check if letterboxed
        pub fn isLetterbox(self: Data) bool {
            return switch (self.aspect_ratio) {
                .letterbox_14_9_center,
                .letterbox_14_9_top,
                .letterbox_16_9_center,
                .letterbox_16_9_top,
                .letterbox_gt_16_9_center,
                => true,
                else => false,
            };
        }

        /// Get the effective aspect ratio as a float
        pub fn getAspectRatioValue(self: Data) f32 {
            return switch (self.aspect_ratio) {
                .full_4_3 => 4.0 / 3.0,
                .letterbox_14_9_center, .letterbox_14_9_top, .full_14_9_center => 14.0 / 9.0,
                .letterbox_16_9_center, .letterbox_16_9_top, .full_16_9_anamorphic => 16.0 / 9.0,
                .letterbox_gt_16_9_center => 2.21, // Common cinema aspect
                else => 4.0 / 3.0,
            };
        }

        /// Check if content is film-originated
        pub fn isFilm(self: Data) bool {
            return self.camera_mode == .film;
        }

        /// Check if subtitles are present
        pub fn hasSubtitles(self: Data) bool {
            return self.subtitles == .subtitles_in_teletext;
        }

        /// Check if surround sound is signaled
        pub fn hasSurroundSound(self: Data) bool {
            return self.surround_sound == .surround_sound;
        }

        /// Check if copy protected
        pub fn isCopyProtected(self: Data) bool {
            return self.copy_protection == .copy_restricted;
        }
    };

    /// WSS bit assignments (14 bits total)
    pub const BitAssignment = struct {
        // Group 1 (bits 0-3): Aspect ratio format
        aspect_ratio: u4,

        // Group 2 (bit 4): Enhanced services
        enhanced_services: u1, // 0 = no enhancement

        // Group 3 (bits 5-7): Subtitles and surround
        subtitles: u1,
        reserved1: u1,
        surround_sound: u1,

        // Group 4 (bits 8-10): Copyright and helper
        copyright: u1,
        copy_protection: u1,
        reserved2: u1,

        // Group 5 (bits 11-13): Camera mode, color coding, helper
        camera_mode: u1,
        color_coding: u1,
        helper_signals: u1,
    };
};

/// WSS decoder
pub const WssDecoder = struct {
    /// Decode WSS from 14-bit data word
    pub fn decode(bits: u14) Wss.Data {
        // Extract bit fields
        const aspect_bits: u4 = @truncate(bits & 0x0F);
        const subtitles_bit: u1 = @truncate((bits >> 5) & 0x01);
        const surround_bit: u1 = @truncate((bits >> 7) & 0x01);
        const copyright_bit: u1 = @truncate((bits >> 8) & 0x01);
        const copy_protection_bit: u1 = @truncate((bits >> 9) & 0x01);
        const camera_mode_bit: u1 = @truncate((bits >> 11) & 0x01);
        const color_coding_bit: u1 = @truncate((bits >> 12) & 0x01);
        const helper_signals_bit: u1 = @truncate((bits >> 13) & 0x01);

        return .{
            .aspect_ratio = @enumFromInt(aspect_bits),
            .camera_mode = @enumFromInt(camera_mode_bit),
            .color_coding = @enumFromInt(color_coding_bit),
            .helper_signals = @enumFromInt(helper_signals_bit),
            .subtitles = @enumFromInt(subtitles_bit),
            .surround_sound = @enumFromInt(surround_bit),
            .copyright = @enumFromInt(copyright_bit),
            .copy_protection = @enumFromInt(copy_protection_bit),
        };
    }

    /// Decode WSS from VBI line 23 waveform
    pub fn decodeFromVbi(vbi_data: []const u8) !u14 {
        // WSS is encoded as binary phase shift keying (BPSK)
        // Start code: 111000111000 (not 100011100011)
        // Then 14 data bits

        if (vbi_data.len < 29) return error.InsufficientData; // Need at least 12 + 14 + parity bits

        // Simplified decoding - in practice would need proper BPSK demodulation
        // Here we assume bits are already extracted

        var data_bits: u14 = 0;
        var bit_index: u5 = 0;

        // Skip start code (12 bits)
        const start_offset = 12;

        // Extract 14 data bits
        while (bit_index < 14) : (bit_index += 1) {
            const byte_index = (start_offset + bit_index) / 8;
            const bit_offset: u3 = @truncate((start_offset + bit_index) % 8);

            if (byte_index >= vbi_data.len) return error.InsufficientData;

            const bit = (vbi_data[byte_index] >> bit_offset) & 1;
            data_bits |= @as(u14, bit) << bit_index;
        }

        return data_bits;
    }

    /// Encode WSS data to 14-bit word
    pub fn encode(data: Wss.Data) u14 {
        var bits: u14 = 0;

        bits |= @intFromEnum(data.aspect_ratio);
        bits |= @as(u14, @intFromEnum(data.subtitles)) << 5;
        bits |= @as(u14, @intFromEnum(data.surround_sound)) << 7;
        bits |= @as(u14, @intFromEnum(data.copyright)) << 8;
        bits |= @as(u14, @intFromEnum(data.copy_protection)) << 9;
        bits |= @as(u14, @intFromEnum(data.camera_mode)) << 11;
        bits |= @as(u14, @intFromEnum(data.color_coding)) << 12;
        bits |= @as(u14, @intFromEnum(data.helper_signals)) << 13;

        return bits;
    }

    /// Encode WSS to VBI line 23 waveform
    pub fn encodeToVbi(data: Wss.Data, allocator: std.mem.Allocator) ![]u8 {
        const bits = encode(data);

        // Start code (12 bits): 111000111000
        const start_code: u12 = 0b111000111000;

        // Total 26 bits (12 start + 14 data)
        // Store in bytes (4 bytes needed)
        var vbi = try allocator.alloc(u8, 4);
        @memset(vbi, 0);

        // Write start code
        var bit_pos: u5 = 0;
        var temp_start = start_code;
        while (bit_pos < 12) : (bit_pos += 1) {
            const byte_index = bit_pos / 8;
            const bit_offset: u3 = @truncate(bit_pos % 8);
            if ((temp_start & 1) != 0) {
                vbi[byte_index] |= @as(u8, 1) << bit_offset;
            }
            temp_start >>= 1;
        }

        // Write data bits
        bit_pos = 0;
        var temp_data = bits;
        while (bit_pos < 14) : (bit_pos += 1) {
            const total_pos = 12 + bit_pos;
            const byte_index = total_pos / 8;
            const bit_offset: u3 = @truncate(total_pos % 8);
            if ((temp_data & 1) != 0) {
                vbi[byte_index] |= @as(u8, 1) << bit_offset;
            }
            temp_data >>= 1;
        }

        return vbi;
    }

    /// Validate WSS data
    pub fn validate(data: Wss.Data) bool {
        // Check if aspect ratio is a known valid value
        return switch (data.aspect_ratio) {
            .full_4_3,
            .letterbox_14_9_center,
            .letterbox_14_9_top,
            .letterbox_16_9_center,
            .letterbox_16_9_top,
            .letterbox_gt_16_9_center,
            .full_16_9_anamorphic,
            .full_14_9_center,
            => true,
            _ => false,
        };
    }
};

/// WSS detector for continuous monitoring
pub const WssDetector = struct {
    current_wss: ?Wss.Data,
    frame_count: u64,
    wss_change_count: u64,
    valid_wss_count: u64,

    pub fn init() WssDetector {
        return .{
            .current_wss = null,
            .frame_count = 0,
            .wss_change_count = 0,
            .valid_wss_count = 0,
        };
    }

    /// Process a frame's WSS data
    pub fn processFrame(self: *WssDetector, wss_bits: ?u14) void {
        self.frame_count += 1;

        if (wss_bits) |bits| {
            const wss = WssDecoder.decode(bits);

            if (WssDecoder.validate(wss)) {
                self.valid_wss_count += 1;

                if (self.current_wss) |current| {
                    if (@intFromEnum(current.aspect_ratio) != @intFromEnum(wss.aspect_ratio) or
                        current.camera_mode != wss.camera_mode or
                        current.subtitles != wss.subtitles or
                        current.surround_sound != wss.surround_sound or
                        current.copy_protection != wss.copy_protection)
                    {
                        self.wss_change_count += 1;
                    }
                }

                self.current_wss = wss;
            }
        }
    }

    /// Get current WSS data
    pub fn getCurrentWss(self: *WssDetector) ?Wss.Data {
        return self.current_wss;
    }

    /// Get statistics
    pub fn getStats(self: *WssDetector) Stats {
        return .{
            .frame_count = self.frame_count,
            .valid_wss_count = self.valid_wss_count,
            .wss_change_count = self.wss_change_count,
            .wss_present_rate = if (self.frame_count > 0)
                @as(f32, @floatFromInt(self.valid_wss_count)) / @as(f32, @floatFromInt(self.frame_count))
            else
                0.0,
        };
    }

    pub const Stats = struct {
        frame_count: u64,
        valid_wss_count: u64,
        wss_change_count: u64,
        wss_present_rate: f32,
    };
};

/// Convert WSS to AFD equivalent
pub fn wssToAfd(wss: Wss.Data) u4 {
    // Map WSS aspect ratio to AFD codes
    return switch (wss.aspect_ratio) {
        .full_4_3 => 0b1001, // Full frame 4:3
        .letterbox_14_9_center => 0b0011, // 14:9 letterbox top (close enough)
        .letterbox_14_9_top => 0b0011, // 14:9 letterbox top
        .letterbox_16_9_center => 0b0010, // 16:9 letterbox top (close enough)
        .letterbox_16_9_top => 0b0010, // 16:9 letterbox top
        .letterbox_gt_16_9_center => 0b0100, // >16:9 letterbox
        .full_16_9_anamorphic => 0b1010, // Full frame 16:9
        .full_14_9_center => 0b1011, // Full frame 14:9
        else => 0b1000, // Same as coded frame (default)
    };
}
