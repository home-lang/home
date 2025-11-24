const std = @import("std");

/// Avid DNxHD/DNxHR codec detection and helpers
/// Professional intermediate codecs for post-production
pub const DnxHd = struct {
    /// DNxHD compression IDs (CIDs)
    pub const CompressionId = enum(u32) {
        // DNxHD (fixed resolution)
        dnxhd_1080p_36 = 1235, // 1920x1080p 36 Mbps
        dnxhd_1080p_115 = 1237, // 1920x1080p 115 Mbps
        dnxhd_1080p_175 = 1238, // 1920x1080p 175 Mbps (10-bit)
        dnxhd_1080p_185 = 1242, // 1920x1080p 185 Mbps
        dnxhd_1080p_365 = 1243, // 1920x1080p 365 Mbps (10-bit)
        dnxhd_1080i_120 = 1241, // 1920x1080i 120 Mbps
        dnxhd_1080i_185 = 1242, // 1920x1080i 185 Mbps
        dnxhd_720p_90 = 1250, // 1280x720p 90 Mbps
        dnxhd_720p_180 = 1251, // 1280x720p 180 Mbps (10-bit)

        // DNxHR (resolution independent)
        dnxhr_lb = 0, // Low Bandwidth (proxy)
        dnxhr_sq = 1, // Standard Quality
        dnxhr_hq = 2, // High Quality
        dnxhr_hqx = 3, // HQ Extended (10-bit)
        dnxhr_444 = 4, // 4:4:4 (10/12-bit)

        _,
    };

    /// DNxHD/HR profile
    pub const Profile = enum {
        dnxhd, // Fixed resolution
        dnxhr, // Resolution independent
    };

    /// Chroma subsampling
    pub const ChromaFormat = enum {
        yuv422,
        yuv444,
    };

    /// Frame header (simplified)
    pub const FrameHeader = struct {
        header_prefix: u32, // Should be 0x000002800100 or 0x000002800200
        compression_id: u32,
        width: u16,
        height: u16,
        bit_depth: u8,
        interlaced: bool,
        chroma_format: ChromaFormat,
        profile: Profile,

        /// Get codec name
        pub fn getCodecName(self: *const FrameHeader) []const u8 {
            if (self.profile == .dnxhr) {
                return switch (self.compression_id) {
                    0 => "DNxHR LB",
                    1 => "DNxHR SQ",
                    2 => "DNxHR HQ",
                    3 => "DNxHR HQX",
                    4 => "DNxHR 444",
                    else => "DNxHR Unknown",
                };
            } else {
                return "DNxHD";
            }
        }

        /// Get target bitrate (approximate)
        pub fn getTargetBitrate(self: *const FrameHeader, framerate: f32) u64 {
            if (self.profile == .dnxhd) {
                // Fixed bitrates based on CID
                return switch (self.compression_id) {
                    1235 => 36_000_000,
                    1237 => 115_000_000,
                    1238 => 175_000_000,
                    1242 => 185_000_000,
                    1243 => 365_000_000,
                    1241 => 120_000_000,
                    1250 => 90_000_000,
                    1251 => 180_000_000,
                    else => 150_000_000,
                };
            } else {
                // DNxHR - calculate based on profile
                const pixels = @as(u64, self.width) * @as(u64, self.height);
                const fps: u64 = @intFromFloat(framerate);

                const bits_per_pixel: f32 = switch (self.compression_id) {
                    0 => 0.5, // LB
                    1 => 1.5, // SQ
                    2 => 2.5, // HQ
                    3 => 3.5, // HQX
                    4 => 5.0, // 444
                    else => 2.0,
                };

                return @intFromFloat(@as(f64, @floatFromInt(pixels)) * bits_per_pixel * @as(f64, @floatFromInt(fps)));
            }
        }

        /// Check if 10-bit
        pub fn is10Bit(self: *const FrameHeader) bool {
            return self.bit_depth == 10;
        }

        /// Check if 4:4:4
        pub fn is444(self: *const FrameHeader) bool {
            return self.chroma_format == .yuv444;
        }
    };
};

/// DNxHD/HR parser
pub const DnxParser = struct {
    /// Detect if data is DNxHD/HR
    pub fn isDnx(data: []const u8) bool {
        if (data.len < 8) return false;

        // DNx frames start with 0x000002800100 (DNxHD) or 0x000002800200 (DNxHR)
        const prefix = std.mem.readInt(u64, data[0..8], .big);
        const prefix_high = prefix >> 16;

        return prefix_high == 0x000002800100 or prefix_high == 0x000002800200;
    }

    /// Parse frame header
    pub fn parseFrameHeader(data: []const u8) !DnxHd.FrameHeader {
        if (data.len < 640) return error.InsufficientData; // DNx header is 640 bytes

        var header: DnxHd.FrameHeader = undefined;

        // Read prefix (5 bytes: 0x00 0x00 0x02 0x80 0x01/0x02)
        const prefix_bytes = data[0..5];
        header.header_prefix = @as(u32, prefix_bytes[0]) << 24 |
            @as(u32, prefix_bytes[1]) << 16 |
            @as(u32, prefix_bytes[2]) << 8 |
            @as(u32, prefix_bytes[3]);

        const format_byte = prefix_bytes[4];
        header.profile = if (format_byte == 0x01) .dnxhd else .dnxhr;

        // Width and height (bytes 27-30)
        header.width = std.mem.readInt(u16, data[27..29], .big);
        header.height = std.mem.readInt(u16, data[29..31], .big);

        // Compression ID
        if (header.profile == .dnxhr) {
            // For DNxHR, CID is in byte 40
            header.compression_id = data[40];
        } else {
            // For DNxHD, CID is in bytes 43-46
            header.compression_id = std.mem.readInt(u32, data[43..47], .big);
        }

        // Bit depth and format flags
        const flags = data[46];
        header.bit_depth = if ((flags & 0x01) != 0) @as(u8, 10) else 8;
        header.interlaced = (flags & 0x02) != 0;

        // Chroma format
        if (header.profile == .dnxhr and header.compression_id == 4) {
            header.chroma_format = .yuv444;
        } else {
            header.chroma_format = .yuv422;
        }

        return header;
    }

    /// Get frame info
    pub fn getFrameInfo(data: []const u8) !FrameInfo {
        const header = try parseFrameHeader(data);

        return .{
            .profile = header.profile,
            .compression_id = header.compression_id,
            .width = header.width,
            .height = header.height,
            .bit_depth = header.bit_depth,
            .interlaced = header.interlaced,
            .chroma_format = header.chroma_format,
        };
    }

    pub const FrameInfo = struct {
        profile: DnxHd.Profile,
        compression_id: u32,
        width: u16,
        height: u16,
        bit_depth: u8,
        interlaced: bool,
        chroma_format: DnxHd.ChromaFormat,
    };

    /// Validate DNx frame
    pub fn validateFrame(data: []const u8) bool {
        if (!isDnx(data)) return false;

        const header = parseFrameHeader(data) catch return false;

        // Basic validation
        if (header.width == 0 or header.height == 0) return false;
        if (header.width > 16384 or header.height > 16384) return false;

        return true;
    }
};

/// DNxHD/HR container info (typically in MXF or MOV)
pub const DnxContainer = struct {
    /// Get codec FourCC for MOV
    pub fn getCodecFourCC(profile: DnxHd.Profile) [4]u8 {
        return if (profile == .dnxhd)
            .{ 'A', 'V', 'd', 'n' } // AVdn - DNxHD
        else
            .{ 'A', 'V', 'd', 'h' }; // AVdh - DNxHR
    }

    /// Check if FourCC is DNx
    pub fn isDnxFourCC(fourcc: [4]u8) bool {
        return std.mem.eql(u8, &fourcc, "AVdn") or
            std.mem.eql(u8, &fourcc, "AVdh");
    }
};

/// DNx encoder recommendations
pub const DnxRecommendations = struct {
    /// Get recommended DNx profile for use case
    pub fn getRecommendedProfile(use_case: UseCase, width: u16) DnxHd.CompressionId {
        // DNxHD for standard resolutions, DNxHR for others
        if (width == 1920) {
            return switch (use_case) {
                .offline_editing => .dnxhd_1080p_36,
                .online_editing => .dnxhd_1080p_115,
                .high_quality_delivery => .dnxhd_1080p_185,
                .finishing_mastering => .dnxhd_1080p_365,
                .vfx_graphics_alpha => .dnxhr_444,
                .extreme_quality_hdr => .dnxhr_444,
            };
        } else if (width == 1280) {
            return switch (use_case) {
                .offline_editing => .dnxhd_720p_90,
                .online_editing => .dnxhd_720p_90,
                .high_quality_delivery => .dnxhd_720p_180,
                .finishing_mastering => .dnxhd_720p_180,
                .vfx_graphics_alpha => .dnxhr_444,
                .extreme_quality_hdr => .dnxhr_444,
            };
        } else {
            // Use DNxHR for non-standard resolutions
            return switch (use_case) {
                .offline_editing => .dnxhr_lb,
                .online_editing => .dnxhr_sq,
                .high_quality_delivery => .dnxhr_hq,
                .finishing_mastering => .dnxhr_hqx,
                .vfx_graphics_alpha => .dnxhr_444,
                .extreme_quality_hdr => .dnxhr_444,
            };
        }
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
    pub fn getStoragePerMinute(compression_id: DnxHd.CompressionId, width: u16, height: u16, framerate: f32) u64 {
        const header = DnxHd.FrameHeader{
            .header_prefix = 0,
            .compression_id = @intFromEnum(compression_id),
            .width = width,
            .height = height,
            .bit_depth = 10,
            .interlaced = false,
            .chroma_format = .yuv422,
            .profile = if (@intFromEnum(compression_id) < 100) .dnxhr else .dnxhd,
        };

        const bitrate_bps = header.getTargetBitrate(framerate);
        const bytes_per_second = bitrate_bps / 8;
        const mb_per_minute = (bytes_per_second * 60) / (1024 * 1024);

        return mb_per_minute;
    }
};
