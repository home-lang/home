const std = @import("std");

/// Apple ProRes codec detection and basic helpers
/// ProRes is a family of intermediate codecs designed for post-production
pub const ProRes = struct {
    /// ProRes codec types
    pub const CodecType = enum(u32) {
        proxy = 0x61707063, // 'apco' - ProRes 422 Proxy
        lt = 0x61706373, // 'apcs' - ProRes 422 LT
        standard = 0x6170636E, // 'apcn' - ProRes 422
        hq = 0x61706368, // 'apch' - ProRes 422 HQ
        @"4444" = 0x61703468, // 'ap4h' - ProRes 4444
        @"4444_xq" = 0x61703478, // 'ap4x' - ProRes 4444 XQ
        raw = 0x61707268, // 'aprh' - ProRes RAW (read-only)
        raw_hq = 0x6170726E, // 'aprn' - ProRes RAW HQ (read-only)
    };

    /// ProRes chroma format
    pub const ChromaFormat = enum {
        yuv422_10bit,
        yuv444_10bit,
        yuv444_12bit,
        yuv422_12bit, // XQ
    };

    /// ProRes frame header (simplified)
    pub const FrameHeader = struct {
        frame_size: u32,
        codec_tag: CodecType,
        width: u16,
        height: u16,
        chroma_format: u8,
        interlace_mode: u8,
        aspect_ratio_code: u8,
        framerate_code: u8,
        color_primaries: u8,
        transfer_function: u8,
        color_matrix: u8,
        alpha_channel_type: u8,
        flags: u16,

        /// Check if frame has alpha
        pub fn hasAlpha(self: *const FrameHeader) bool {
            return self.alpha_channel_type != 0;
        }

        /// Get codec type name
        pub fn getCodecName(self: *const FrameHeader) []const u8 {
            return switch (self.codec_tag) {
                .proxy => "ProRes 422 Proxy",
                .lt => "ProRes 422 LT",
                .standard => "ProRes 422",
                .hq => "ProRes 422 HQ",
                .@"4444" => "ProRes 4444",
                .@"4444_xq" => "ProRes 4444 XQ",
                .raw => "ProRes RAW",
                .raw_hq => "ProRes RAW HQ",
            };
        }

        /// Get approximate target bitrate for resolution
        pub fn getTargetBitrate(self: *const FrameHeader, framerate: f32) u64 {
            const pixels = @as(u64, self.width) * @as(u64, self.height);
            const fps: u64 = @intFromFloat(framerate);

            // Approximate bitrates per pixel for each codec
            const bits_per_pixel: f32 = switch (self.codec_tag) {
                .proxy => 0.75,
                .lt => 1.25,
                .standard => 2.0,
                .hq => 3.0,
                .@"4444" => 4.5,
                .@"4444_xq" => 6.0,
                .raw, .raw_hq => 12.0,
            };

            return @intFromFloat(@as(f64, @floatFromInt(pixels)) * bits_per_pixel * @as(f64, @floatFromInt(fps)));
        }
    };

    /// ProRes frame info
    pub const FrameInfo = struct {
        codec_type: CodecType,
        width: u16,
        height: u16,
        interlaced: bool,
        has_alpha: bool,
        bit_depth: u8,
        chroma_format: ChromaFormat,
    };
};

/// ProRes frame parser
pub const ProResParser = struct {
    /// Detect if data is ProRes
    pub fn isProRes(data: []const u8) bool {
        if (data.len < 8) return false;

        // ProRes frame starts with frame size (4 bytes) then codec tag
        if (data.len < 8) return false;

        const codec_tag = std.mem.readInt(u32, data[4..8], .big);
        return switch (codec_tag) {
            0x61707063, // apco - Proxy
            0x61706373, // apcs - LT
            0x6170636E, // apcn - Standard
            0x61706368, // apch - HQ
            0x61703468, // ap4h - 4444
            0x61703478, // ap4x - 4444 XQ
            0x61707268, // aprh - RAW
            0x6170726E, // aprn - RAW HQ
            => true,
            else => false,
        };
    }

    /// Parse ProRes frame header
    pub fn parseFrameHeader(data: []const u8) !ProRes.FrameHeader {
        if (data.len < 20) return error.InsufficientData;

        var header: ProRes.FrameHeader = undefined;

        // Frame size (4 bytes, big-endian)
        header.frame_size = std.mem.readInt(u32, data[0..4], .big);

        // Codec tag (4 bytes)
        const codec_tag = std.mem.readInt(u32, data[4..8], .big);
        header.codec_tag = @enumFromInt(codec_tag);

        if (data.len < header.frame_size) return error.InsufficientData;

        // Header size and version
        const header_size = std.mem.readInt(u16, data[8..10], .big);
        _ = header_size;

        // Reserved
        // const version = data[10];

        // Dimensions
        header.width = std.mem.readInt(u16, data[14..16], .big);
        header.height = std.mem.readInt(u16, data[16..18], .big);

        // Chroma format (2 bits in flags)
        header.chroma_format = data[12] >> 6;

        // Interlace mode
        header.interlace_mode = (data[12] >> 4) & 0x03;

        // Aspect ratio
        header.aspect_ratio_code = data[13] >> 4;

        // Framerate
        header.framerate_code = data[13] & 0x0F;

        // Color info
        header.color_primaries = data[18];
        header.transfer_function = data[19];

        if (data.len > 20) {
            header.color_matrix = data[20];
        } else {
            header.color_matrix = 0;
        }

        if (data.len > 21) {
            header.alpha_channel_type = data[21];
        } else {
            header.alpha_channel_type = 0;
        }

        if (data.len > 22) {
            header.flags = std.mem.readInt(u16, data[22..24], .big);
        } else {
            header.flags = 0;
        }

        return header;
    }

    /// Get ProRes frame info
    pub fn getFrameInfo(data: []const u8) !ProRes.FrameInfo {
        const header = try parseFrameHeader(data);

        return .{
            .codec_type = header.codec_tag,
            .width = header.width,
            .height = header.height,
            .interlaced = header.interlace_mode != 0,
            .has_alpha = header.hasAlpha(),
            .bit_depth = if (header.codec_tag == .@"4444_xq") 12 else 10,
            .chroma_format = switch (header.codec_tag) {
                .@"4444" => .yuv444_10bit,
                .@"4444_xq" => .yuv444_12bit,
                else => .yuv422_10bit,
            },
        };
    }

    /// Validate ProRes frame
    pub fn validateFrame(data: []const u8) bool {
        if (!isProRes(data)) return false;

        const header = parseFrameHeader(data) catch return false;

        // Basic validation
        if (header.width == 0 or header.height == 0) return false;
        if (header.width > 16384 or header.height > 16384) return false;
        if (header.frame_size > data.len) return false;

        return true;
    }
};

/// ProRes container info (typically in QuickTime MOV)
pub const ProResContainer = struct {
    /// Get codec FourCC for MOV atom
    pub fn getCodecFourCC(codec_type: ProRes.CodecType) [4]u8 {
        const val = @intFromEnum(codec_type);
        return .{
            @truncate(val >> 24),
            @truncate(val >> 16),
            @truncate(val >> 8),
            @truncate(val),
        };
    }

    /// Check if FourCC is ProRes
    pub fn isProResFourCC(fourcc: [4]u8) bool {
        const val = @as(u32, fourcc[0]) << 24 |
            @as(u32, fourcc[1]) << 16 |
            @as(u32, fourcc[2]) << 8 |
            @as(u32, fourcc[3]);

        return switch (val) {
            0x61707063, 0x61706373, 0x6170636E, 0x61706368,
            0x61703468, 0x61703478, 0x61707268, 0x6170726E,
            => true,
            else => false,
        };
    }
};

/// ProRes encoder recommendations
pub const ProResRecommendations = struct {
    /// Get recommended ProRes codec for use case
    pub fn getRecommendedCodec(use_case: UseCase) ProRes.CodecType {
        return switch (use_case) {
            .offline_editing => .proxy,
            .online_editing => .lt,
            .high_quality_delivery => .standard,
            .finishing_mastering => .hq,
            .vfx_graphics_alpha => .@"4444",
            .extreme_quality_hdr => .@"4444_xq",
        };
    }

    pub const UseCase = enum {
        offline_editing,
        online_editing,
        high_quality_delivery,
        finishing_mastering,
        vfx_graphics_alpha,
        extreme_quality_hdr,
    };

    /// Get storage requirements (MB per minute)
    pub fn getStoragePerMinute(codec_type: ProRes.CodecType, width: u16, height: u16, framerate: f32) u64 {
        const header = ProRes.FrameHeader{
            .frame_size = 0,
            .codec_tag = codec_type,
            .width = width,
            .height = height,
            .chroma_format = 0,
            .interlace_mode = 0,
            .aspect_ratio_code = 0,
            .framerate_code = 0,
            .color_primaries = 0,
            .transfer_function = 0,
            .color_matrix = 0,
            .alpha_channel_type = 0,
            .flags = 0,
        };

        const bitrate_bps = header.getTargetBitrate(framerate);
        const bytes_per_second = bitrate_bps / 8;
        const mb_per_minute = (bytes_per_second * 60) / (1024 * 1024);

        return mb_per_minute;
    }
};
