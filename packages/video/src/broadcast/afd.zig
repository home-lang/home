const std = @import("std");

/// AFD (Active Format Description) - SMPTE ST 2016-1, ITU-R BT.1847
/// Describes the intended display format of video within a coded frame
pub const Afd = struct {
    /// AFD codes (4-bit values)
    pub const Code = enum(u4) {
        // Reserved values
        reserved_0000 = 0b0000,
        reserved_0001 = 0b0001,

        // Box modes (16:9 source in 4:3 coded frame)
        box_16x9_top = 0b0010, // 16:9 image letterboxed top
        box_14x9_top = 0b0011, // 14:9 image letterboxed top
        box_gt_16x9 = 0b0100, // >16:9 image letterboxed

        // Standard aspect ratios
        same_as_coded = 0b1000, // Same as coded frame
        full_4x3 = 0b1001, // 4:3 full frame
        full_16x9 = 0b1010, // 16:9 full frame
        full_14x9 = 0b1011, // 14:9 full frame

        // Center crop modes
        full_4x3_protected_center = 0b1101, // 4:3 with 14:9 center
        full_16x9_protected_center = 0b1110, // 16:9 with 14:9 center
        full_16x9_protected_4x3 = 0b1111, // 16:9 with 4:3 center

        // Pillarbox modes (4:3 source in 16:9 coded frame)
        pillar_4x3_center = 0b0101, // 4:3 image pillarboxed center
        pillar_14x9_center = 0b0110, // 14:9 image pillarboxed center

        _,
    };

    /// Aspect ratio
    pub const AspectRatio = enum {
        ratio_4_3,
        ratio_16_9,
        ratio_14_9,
        ratio_custom,
    };

    /// AFD data structure
    pub const Data = struct {
        active_format: Code,
        aspect_ratio_flag: bool, // false = 4:3, true = 16:9

        /// Get human-readable description
        pub fn describe(self: Data) []const u8 {
            return switch (self.active_format) {
                .box_16x9_top => "16:9 letterbox top aligned",
                .box_14x9_top => "14:9 letterbox top aligned",
                .box_gt_16x9 => ">16:9 letterbox centered",
                .same_as_coded => "Same as coded frame",
                .full_4x3 => "Full frame 4:3",
                .full_16x9 => "Full frame 16:9",
                .full_14x9 => "Full frame 14:9",
                .full_4x3_protected_center => "4:3 full frame with 14:9 center protection",
                .full_16x9_protected_center => "16:9 full frame with 14:9 center protection",
                .full_16x9_protected_4x3 => "16:9 full frame with 4:3 center protection",
                .pillar_4x3_center => "4:3 pillarbox centered",
                .pillar_14x9_center => "14:9 pillarbox centered",
                else => "Reserved or unknown AFD code",
            };
        }

        /// Get the intended display aspect ratio
        pub fn getDisplayAspectRatio(self: Data) AspectRatio {
            return switch (self.active_format) {
                .full_4x3, .full_4x3_protected_center, .pillar_4x3_center => .ratio_4_3,
                .full_16x9, .full_16x9_protected_center, .full_16x9_protected_4x3, .box_16x9_top => .ratio_16_9,
                .full_14x9, .box_14x9_top, .pillar_14x9_center => .ratio_14_9,
                .same_as_coded => if (self.aspect_ratio_flag) .ratio_16_9 else .ratio_4_3,
                else => .ratio_custom,
            };
        }

        /// Check if this is letterboxed content
        pub fn isLetterbox(self: Data) bool {
            return switch (self.active_format) {
                .box_16x9_top, .box_14x9_top, .box_gt_16x9 => true,
                else => false,
            };
        }

        /// Check if this is pillarboxed content
        pub fn isPillarbox(self: Data) bool {
            return switch (self.active_format) {
                .pillar_4x3_center, .pillar_14x9_center => true,
                else => false,
            };
        }

        /// Check if center area is protected (safe for cropping)
        pub fn hasProtectedCenter(self: Data) bool {
            return switch (self.active_format) {
                .full_4x3_protected_center,
                .full_16x9_protected_center,
                .full_16x9_protected_4x3,
                => true,
                else => false,
            };
        }

        /// Get the active area rectangle (normalized 0.0-1.0)
        pub fn getActiveArea(self: Data, coded_width: u32, coded_height: u32) ActiveArea {
            const w: f32 = @floatFromInt(coded_width);
            const h: f32 = @floatFromInt(coded_height);

            return switch (self.active_format) {
                // Letterbox - reduce height
                .box_16x9_top => .{
                    .x = 0.0,
                    .y = 0.0,
                    .width = 1.0,
                    .height = 0.75, // 4:3 -> 16:9
                },
                .box_14x9_top => .{
                    .x = 0.0,
                    .y = 0.0,
                    .width = 1.0,
                    .height = 0.857, // 4:3 -> 14:9
                },
                .box_gt_16x9 => .{
                    .x = 0.0,
                    .y = 0.125,
                    .width = 1.0,
                    .height = 0.75, // Wider than 16:9
                },

                // Pillarbox - reduce width
                .pillar_4x3_center => .{
                    .x = 0.125,
                    .y = 0.0,
                    .width = 0.75, // 16:9 -> 4:3
                    .height = 1.0,
                },
                .pillar_14x9_center => .{
                    .x = 0.071,
                    .y = 0.0,
                    .width = 0.857, // 16:9 -> 14:9
                    .height = 1.0,
                },

                // Full frame
                .same_as_coded,
                .full_4x3,
                .full_16x9,
                .full_14x9,
                .full_4x3_protected_center,
                .full_16x9_protected_center,
                .full_16x9_protected_4x3,
                => .{
                    .x = 0.0,
                    .y = 0.0,
                    .width = 1.0,
                    .height = 1.0,
                },

                else => .{
                    .x = 0.0,
                    .y = 0.0,
                    .width = 1.0,
                    .height = 1.0,
                },
            };
        }
    };

    pub const ActiveArea = struct {
        x: f32, // Normalized position (0.0-1.0)
        y: f32,
        width: f32, // Normalized size (0.0-1.0)
        height: f32,

        /// Convert to pixel coordinates
        pub fn toPixels(self: ActiveArea, coded_width: u32, coded_height: u32) PixelArea {
            return .{
                .x = @intFromFloat(self.x * @as(f32, @floatFromInt(coded_width))),
                .y = @intFromFloat(self.y * @as(f32, @floatFromInt(coded_height))),
                .width = @intFromFloat(self.width * @as(f32, @floatFromInt(coded_width))),
                .height = @intFromFloat(self.height * @as(f32, @floatFromInt(coded_height))),
            };
        }
    };

    pub const PixelArea = struct {
        x: u32,
        y: u32,
        width: u32,
        height: u32,
    };
};

/// AFD parser for H.264/HEVC user data
pub const AfdParser = struct {
    /// Parse AFD from H.264 SEI user data registered ITU-T T.35
    pub fn parseFromSeiUserData(data: []const u8) !Afd.Data {
        if (data.len < 4) return error.InvalidAfdData;

        // ITU-T T.35 country code (0xB5 for USA)
        const country_code = data[0];
        if (country_code != 0xB5) return error.UnsupportedCountryCode;

        // Terminal provider code (0x0031 for ATSC)
        const provider_code = @as(u16, data[1]) << 8 | data[2];
        if (provider_code != 0x0031) return error.UnsupportedProviderCode;

        // User identifier (0x47413934 for ATSC DTG1)
        if (data.len < 8) return error.InvalidAfdData;
        const user_id = @as(u32, data[3]) << 24 |
            @as(u32, data[4]) << 16 |
            @as(u32, data[5]) << 8 |
            @as(u32, data[6]);

        if (user_id != 0x47413934) return error.UnsupportedUserIdentifier;

        // User data type code (0x03 for AFD data)
        const type_code = data[7];
        if (type_code != 0x03) return error.NotAfdData;

        if (data.len < 9) return error.InvalidAfdData;

        // AFD data byte
        const afd_byte = data[8];
        const active_format: Afd.Code = @enumFromInt(@as(u4, @truncate(afd_byte & 0x0F)));
        const aspect_ratio_flag = (afd_byte & 0x40) != 0;

        return Afd.Data{
            .active_format = active_format,
            .aspect_ratio_flag = aspect_ratio_flag,
        };
    }

    /// Parse AFD from MPEG-2 user data
    pub fn parseFromMpeg2UserData(data: []const u8) !Afd.Data {
        if (data.len < 1) return error.InvalidAfdData;

        // Direct AFD byte encoding
        const afd_byte = data[0];
        const active_format: Afd.Code = @enumFromInt(@as(u4, @truncate(afd_byte & 0x0F)));
        const aspect_ratio_flag = (afd_byte & 0x40) != 0;

        return Afd.Data{
            .active_format = active_format,
            .aspect_ratio_flag = aspect_ratio_flag,
        };
    }

    /// Encode AFD as H.264 SEI user data
    pub fn encodeToSeiUserData(afd: Afd.Data, allocator: std.mem.Allocator) ![]u8 {
        var data = try allocator.alloc(u8, 9);

        // ITU-T T.35 country code (USA)
        data[0] = 0xB5;

        // Terminal provider code (ATSC)
        data[1] = 0x00;
        data[2] = 0x31;

        // User identifier (ATSC DTG1)
        data[3] = 0x47; // 'G'
        data[4] = 0x41; // 'A'
        data[5] = 0x39; // '9'
        data[6] = 0x34; // '4'

        // User data type code (AFD data)
        data[7] = 0x03;

        // AFD data byte
        var afd_byte: u8 = 0;
        afd_byte |= @intFromEnum(afd.active_format);
        if (afd.aspect_ratio_flag) {
            afd_byte |= 0x40;
        }
        data[8] = afd_byte;

        return data;
    }
};

/// AFD detector - extracts AFD from video frames
pub const AfdDetector = struct {
    current_afd: ?Afd.Data,
    frame_count: u64,
    afd_change_count: u64,

    pub fn init() AfdDetector {
        return .{
            .current_afd = null,
            .frame_count = 0,
            .afd_change_count = 0,
        };
    }

    /// Process a frame's user data
    pub fn processFrame(self: *AfdDetector, user_data: ?[]const u8) !void {
        self.frame_count += 1;

        if (user_data) |data| {
            const afd = AfdParser.parseFromSeiUserData(data) catch return;

            if (self.current_afd) |current| {
                if (@intFromEnum(current.active_format) != @intFromEnum(afd.active_format) or
                    current.aspect_ratio_flag != afd.aspect_ratio_flag)
                {
                    self.afd_change_count += 1;
                }
            }

            self.current_afd = afd;
        }
    }

    /// Get current AFD data
    pub fn getCurrentAfd(self: *AfdDetector) ?Afd.Data {
        return self.current_afd;
    }

    /// Get statistics
    pub fn getStats(self: *AfdDetector) Stats {
        return .{
            .frame_count = self.frame_count,
            .afd_change_count = self.afd_change_count,
        };
    }

    pub const Stats = struct {
        frame_count: u64,
        afd_change_count: u64,
    };
};
