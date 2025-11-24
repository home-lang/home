// Home Video Library - HDR Metadata Parsing
// HDR10, HDR10+, Dolby Vision, HLG metadata support

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// HDR Format Types
// ============================================================================

pub const HdrFormat = enum {
    sdr, // Standard Dynamic Range
    hdr10, // HDR10 (static metadata)
    hdr10plus, // HDR10+ (dynamic metadata)
    dolby_vision, // Dolby Vision
    hlg, // Hybrid Log-Gamma
    unknown,
};

// ============================================================================
// Color Volume / Mastering Display Metadata (SMPTE ST 2086)
// ============================================================================

/// Mastering display color volume (static HDR metadata)
pub const MasteringDisplayColorVolume = struct {
    // Display primaries in CIE 1931 xy chromaticity (0.00002 units)
    display_primaries_x: [3]u16 = .{ 0, 0, 0 }, // RGB
    display_primaries_y: [3]u16 = .{ 0, 0, 0 },

    // White point in CIE 1931 xy chromaticity
    white_point_x: u16 = 0,
    white_point_y: u16 = 0,

    // Display luminance range in cd/m² (0.0001 units)
    max_luminance: u32 = 0, // Maximum luminance
    min_luminance: u32 = 0, // Minimum luminance

    /// Get display primaries as floating point
    pub fn getDisplayPrimaries(self: *const MasteringDisplayColorVolume) struct {
        red: [2]f32,
        green: [2]f32,
        blue: [2]f32,
    } {
        return .{
            .red = .{
                @as(f32, @floatFromInt(self.display_primaries_x[0])) * 0.00002,
                @as(f32, @floatFromInt(self.display_primaries_y[0])) * 0.00002,
            },
            .green = .{
                @as(f32, @floatFromInt(self.display_primaries_x[1])) * 0.00002,
                @as(f32, @floatFromInt(self.display_primaries_y[1])) * 0.00002,
            },
            .blue = .{
                @as(f32, @floatFromInt(self.display_primaries_x[2])) * 0.00002,
                @as(f32, @floatFromInt(self.display_primaries_y[2])) * 0.00002,
            },
        };
    }

    /// Get white point as floating point
    pub fn getWhitePoint(self: *const MasteringDisplayColorVolume) [2]f32 {
        return .{
            @as(f32, @floatFromInt(self.white_point_x)) * 0.00002,
            @as(f32, @floatFromInt(self.white_point_y)) * 0.00002,
        };
    }

    /// Get max luminance in cd/m²
    pub fn getMaxLuminance(self: *const MasteringDisplayColorVolume) f32 {
        return @as(f32, @floatFromInt(self.max_luminance)) * 0.0001;
    }

    /// Get min luminance in cd/m²
    pub fn getMinLuminance(self: *const MasteringDisplayColorVolume) f32 {
        return @as(f32, @floatFromInt(self.min_luminance)) * 0.0001;
    }
};

// ============================================================================
// Content Light Level (SMPTE ST 2094-10)
// ============================================================================

/// Content light level info
pub const ContentLightLevel = struct {
    max_cll: u16 = 0, // Maximum Content Light Level (cd/m²)
    max_fall: u16 = 0, // Maximum Frame-Average Light Level (cd/m²)
};

// ============================================================================
// HDR10+ Dynamic Metadata (SMPTE ST 2094-40)
// ============================================================================

pub const Hdr10PlusMetadata = struct {
    application_version: u8 = 0,
    num_windows: u8 = 1,

    // Per-window data (simplified - usually 1 window)
    targeted_system_display_maximum_luminance: u32 = 0,
    targeted_system_display_actual_peak_luminance_flag: bool = false,

    // Bezier curve for tone mapping
    num_bezier_curve_anchors: u8 = 0,
    bezier_curve_anchors: [15]u16 = [_]u16{0} ** 15,
    knee_point_x: u16 = 0,
    knee_point_y: u16 = 0,

    // Color saturation
    color_saturation_mapping_flag: bool = false,
    color_saturation_weight: u8 = 0,
};

/// Parse HDR10+ metadata from SEI payload
pub fn parseHdr10Plus(data: []const u8) ?Hdr10PlusMetadata {
    if (data.len < 7) return null;

    // Check country code and terminal provider
    if (data[0] != 0xB5) return null; // USA
    if (data[1] != 0x00 or data[2] != 0x3C) return null; // Samsung

    var meta = Hdr10PlusMetadata{};
    meta.application_version = data[3];

    // Parse remaining fields (simplified)
    if (data.len >= 10) {
        meta.num_windows = data[4] & 0x03;
        meta.targeted_system_display_maximum_luminance =
            (@as(u32, data[5]) << 24) |
            (@as(u32, data[6]) << 16) |
            (@as(u32, data[7]) << 8) |
            data[8];
    }

    return meta;
}

// ============================================================================
// Dolby Vision Metadata
// ============================================================================

pub const DolbyVisionProfile = enum(u8) {
    profile_4 = 4, // HEVCMain10, cross-compatible (retired)
    profile_5 = 5, // HEVCMain10, single-layer
    profile_7 = 7, // HEVCMain10, dual-layer (MEL)
    profile_8 = 8, // HEVCMain10, single-layer, HDR10 compatible
    profile_9 = 9, // AV1Main10, single-layer
    unknown = 255,
};

pub const DolbyVisionLevel = enum(u8) {
    level_1 = 1, // HD
    level_2 = 2, // HD High
    level_3 = 3, // QHD
    level_4 = 4, // FHD24
    level_5 = 5, // FHD30
    level_6 = 6, // FHD60
    level_7 = 7, // UHD24
    level_8 = 8, // UHD30
    level_9 = 9, // UHD48
    level_10 = 10, // UHD60
    level_11 = 11, // UHD120
    level_12 = 12, // 8K24
    level_13 = 13, // 8K30
    unknown = 255,
};

/// Dolby Vision configuration record (dvcC/dvvC box)
pub const DolbyVisionConfiguration = struct {
    dv_version_major: u8 = 1,
    dv_version_minor: u8 = 0,
    dv_profile: u8 = 0,
    dv_level: u8 = 0,
    rpu_present_flag: bool = true,
    el_present_flag: bool = false,
    bl_present_flag: bool = true,
    dv_bl_signal_compatibility_id: u8 = 0,

    pub fn getProfile(self: *const DolbyVisionConfiguration) DolbyVisionProfile {
        return switch (self.dv_profile) {
            4 => .profile_4,
            5 => .profile_5,
            7 => .profile_7,
            8 => .profile_8,
            9 => .profile_9,
            else => .unknown,
        };
    }

    pub fn getLevel(self: *const DolbyVisionConfiguration) DolbyVisionLevel {
        return switch (self.dv_level) {
            1...13 => @enumFromInt(self.dv_level),
            else => .unknown,
        };
    }

    /// Check if content is HDR10 compatible
    pub fn isHdr10Compatible(self: *const DolbyVisionConfiguration) bool {
        return self.dv_bl_signal_compatibility_id == 1 or
            self.dv_bl_signal_compatibility_id == 4;
    }
};

/// Parse Dolby Vision configuration from dvcC/dvvC box
pub fn parseDolbyVisionConfig(data: []const u8) ?DolbyVisionConfiguration {
    if (data.len < 4) return null;

    var config = DolbyVisionConfiguration{};
    config.dv_version_major = data[0];
    config.dv_version_minor = data[1];

    // Profile (7 bits) + Level (6 bits) + flags
    config.dv_profile = (data[2] >> 1) & 0x7F;
    config.dv_level = ((data[2] & 0x01) << 5) | ((data[3] >> 3) & 0x1F);
    config.rpu_present_flag = (data[3] & 0x04) != 0;
    config.el_present_flag = (data[3] & 0x02) != 0;
    config.bl_present_flag = (data[3] & 0x01) != 0;

    if (data.len >= 5) {
        config.dv_bl_signal_compatibility_id = (data[4] >> 4) & 0x0F;
    }

    return config;
}

// ============================================================================
// HDR Metadata Container
// ============================================================================

/// Complete HDR metadata for a video stream
pub const HdrMetadata = struct {
    format: HdrFormat = .sdr,

    // Color primaries and transfer characteristics
    color_primaries: u8 = 2, // Unspecified
    transfer_characteristics: u8 = 2,
    matrix_coefficients: u8 = 2,

    // Static metadata (HDR10)
    mastering_display: ?MasteringDisplayColorVolume = null,
    content_light_level: ?ContentLightLevel = null,

    // Dolby Vision
    dolby_vision_config: ?DolbyVisionConfiguration = null,

    /// Detect HDR format from color characteristics
    pub fn detectFormat(self: *HdrMetadata) void {
        // Check for Dolby Vision first
        if (self.dolby_vision_config != null) {
            self.format = .dolby_vision;
            return;
        }

        // Check transfer characteristics
        switch (self.transfer_characteristics) {
            16 => { // PQ (ST 2084)
                if (self.mastering_display != null) {
                    self.format = .hdr10;
                } else {
                    self.format = .unknown;
                }
            },
            18 => self.format = .hlg, // HLG
            else => self.format = .sdr,
        }

        // BT.2020 primaries with PQ suggests HDR10
        if (self.color_primaries == 9 and self.transfer_characteristics == 16) {
            self.format = .hdr10;
        }
    }

    /// Check if content is HDR
    pub fn isHdr(self: *const HdrMetadata) bool {
        return self.format != .sdr and self.format != .unknown;
    }

    /// Get peak brightness in nits (cd/m²)
    pub fn getPeakBrightness(self: *const HdrMetadata) ?f32 {
        if (self.mastering_display) |md| {
            return md.getMaxLuminance();
        }
        if (self.content_light_level) |cll| {
            return @floatFromInt(cll.max_cll);
        }
        return null;
    }
};

// ============================================================================
// HEVC SEI Parsing for HDR Metadata
// ============================================================================

/// Parse mastering display color volume SEI (payload type 137)
pub fn parseMasteringDisplaySei(data: []const u8) ?MasteringDisplayColorVolume {
    if (data.len < 24) return null;

    var md = MasteringDisplayColorVolume{};

    // Display primaries (G, B, R order in SEI)
    md.display_primaries_x[1] = std.mem.readInt(u16, data[0..2], .big); // G
    md.display_primaries_y[1] = std.mem.readInt(u16, data[2..4], .big);
    md.display_primaries_x[2] = std.mem.readInt(u16, data[4..6], .big); // B
    md.display_primaries_y[2] = std.mem.readInt(u16, data[6..8], .big);
    md.display_primaries_x[0] = std.mem.readInt(u16, data[8..10], .big); // R
    md.display_primaries_y[0] = std.mem.readInt(u16, data[10..12], .big);

    // White point
    md.white_point_x = std.mem.readInt(u16, data[12..14], .big);
    md.white_point_y = std.mem.readInt(u16, data[14..16], .big);

    // Luminance
    md.max_luminance = std.mem.readInt(u32, data[16..20], .big);
    md.min_luminance = std.mem.readInt(u32, data[20..24], .big);

    return md;
}

/// Parse content light level SEI (payload type 144)
pub fn parseContentLightLevelSei(data: []const u8) ?ContentLightLevel {
    if (data.len < 4) return null;

    return ContentLightLevel{
        .max_cll = std.mem.readInt(u16, data[0..2], .big),
        .max_fall = std.mem.readInt(u16, data[2..4], .big),
    };
}

// ============================================================================
// Common HDR Presets
// ============================================================================

pub const HdrPresets = struct {
    /// DCI-P3 D65 mastering display (common for HDR content)
    pub const DCI_P3_D65 = MasteringDisplayColorVolume{
        .display_primaries_x = .{ 34000, 13250, 7500 }, // R, G, B
        .display_primaries_y = .{ 16000, 34500, 3000 },
        .white_point_x = 15635,
        .white_point_y = 16450,
        .max_luminance = 10000000, // 1000 nits
        .min_luminance = 500, // 0.05 nits
    };

    /// BT.2020 mastering display
    pub const BT2020 = MasteringDisplayColorVolume{
        .display_primaries_x = .{ 35400, 8500, 6550 },
        .display_primaries_y = .{ 14600, 39850, 2300 },
        .white_point_x = 15635,
        .white_point_y = 16450,
        .max_luminance = 40000000, // 4000 nits
        .min_luminance = 50, // 0.005 nits
    };
};

// ============================================================================
// Tests
// ============================================================================

test "MasteringDisplayColorVolume conversions" {
    const testing = std.testing;

    const md = HdrPresets.DCI_P3_D65;

    const max_lum = md.getMaxLuminance();
    try testing.expectApproxEqAbs(@as(f32, 1000.0), max_lum, 0.01);

    const white = md.getWhitePoint();
    try testing.expectApproxEqAbs(@as(f32, 0.3127), white[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.329), white[1], 0.001);
}

test "HDR format detection" {
    const testing = std.testing;

    var meta = HdrMetadata{
        .color_primaries = 9, // BT.2020
        .transfer_characteristics = 16, // PQ
        .mastering_display = HdrPresets.DCI_P3_D65,
    };

    meta.detectFormat();
    try testing.expectEqual(HdrFormat.hdr10, meta.format);
    try testing.expect(meta.isHdr());
}

test "Dolby Vision configuration" {
    const testing = std.testing;

    // Profile 8.1 config
    const data = [_]u8{ 0x01, 0x00, 0x10, 0x45, 0x10 };
    const config = parseDolbyVisionConfig(&data);

    try testing.expect(config != null);
    try testing.expectEqual(DolbyVisionProfile.profile_8, config.?.getProfile());
    try testing.expect(config.?.isHdr10Compatible());
}

test "Content light level parsing" {
    const testing = std.testing;

    // MaxCLL=1000, MaxFALL=400
    const data = [_]u8{ 0x03, 0xE8, 0x01, 0x90 };
    const cll = parseContentLightLevelSei(&data);

    try testing.expect(cll != null);
    try testing.expectEqual(@as(u16, 1000), cll.?.max_cll);
    try testing.expectEqual(@as(u16, 400), cll.?.max_fall);
}
