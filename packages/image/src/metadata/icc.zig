// ICC Profile Parser/Writer
// Implements ICC.1:2022 specification
// Based on: https://www.color.org/specification/ICC.1-2022-05.pdf

const std = @import("std");

// ============================================================================
// ICC Constants
// ============================================================================

const ICC_HEADER_SIZE = 128;
const ICC_MAGIC = "acsp";

// Profile class signatures
pub const ProfileClass = enum(u32) {
    input_device = 0x73636E72, // 'scnr'
    display_device = 0x6D6E7472, // 'mntr'
    output_device = 0x70727472, // 'prtr'
    device_link = 0x6C696E6B, // 'link'
    color_space = 0x73706163, // 'spac'
    abstract = 0x61627374, // 'abst'
    named_color = 0x6E6D636C, // 'nmcl'
    _,
};

// Color space signatures
pub const ColorSpace = enum(u32) {
    xyz = 0x58595A20, // 'XYZ '
    lab = 0x4C616220, // 'Lab '
    luv = 0x4C757620, // 'Luv '
    ycbcr = 0x59436272, // 'YCbr'
    yxy = 0x59787920, // 'Yxy '
    rgb = 0x52474220, // 'RGB '
    gray = 0x47524159, // 'GRAY'
    hsv = 0x48535620, // 'HSV '
    hls = 0x484C5320, // 'HLS '
    cmyk = 0x434D594B, // 'CMYK'
    cmy = 0x434D5920, // 'CMY '
    _,
};

// Tag signatures
pub const TagSignature = enum(u32) {
    // Required tags
    profile_description = 0x64657363, // 'desc'
    media_white_point = 0x77747074, // 'wtpt'
    copyright = 0x63707274, // 'cprt'

    // Common tags
    red_colorant = 0x7258595A, // 'rXYZ'
    green_colorant = 0x6758595A, // 'gXYZ'
    blue_colorant = 0x6258595A, // 'bXYZ'

    red_trc = 0x72545243, // 'rTRC'
    green_trc = 0x67545243, // 'gTRC'
    blue_trc = 0x62545243, // 'bTRC'

    a_to_b0 = 0x41324230, // 'A2B0'
    b_to_a0 = 0x42324130, // 'B2A0'

    chromatic_adaptation = 0x63686164, // 'chad'
    device_mfg_desc = 0x646D6E64, // 'dmnd'
    device_model_desc = 0x646D6464, // 'dmdd'
    viewing_conditions = 0x76696577, // 'view'

    gamut = 0x67616D74, // 'gamt'
    gray_trc = 0x6B545243, // 'kTRC'

    // Measurement tags
    measurement = 0x6D656173, // 'meas'
    technology = 0x74656368, // 'tech'

    _,
};

// Tag types
const TagType = enum(u32) {
    xyz = 0x58595A20, // 'XYZ '
    curve = 0x63757276, // 'curv'
    parametric_curve = 0x70617261, // 'para'
    text = 0x74657874, // 'text'
    mluc = 0x6D6C7563, // 'mluc' (multi-localized unicode)
    desc = 0x64657363, // 'desc'
    sf32 = 0x73663332, // 'sf32' (s15Fixed16Array)
    _,
};

// ============================================================================
// ICC Data Types
// ============================================================================

pub const XYZNumber = struct {
    x: f64,
    y: f64,
    z: f64,

    pub fn fromS15Fixed16(data: []const u8) XYZNumber {
        return XYZNumber{
            .x = s15Fixed16ToFloat(data[0..4]),
            .y = s15Fixed16ToFloat(data[4..8]),
            .z = s15Fixed16ToFloat(data[8..12]),
        };
    }
};

// ============================================================================
// ICC Profile Structure
// ============================================================================

pub const ICCProfile = struct {
    allocator: std.mem.Allocator,

    // Header fields
    size: u32 = 0,
    preferred_cmm: u32 = 0,
    version: u32 = 0,
    profile_class: ProfileClass = .display_device,
    color_space: ColorSpace = .rgb,
    pcs: ColorSpace = .xyz, // Profile Connection Space
    creation_date: [12]u8 = undefined,
    signature: u32 = 0,
    platform: u32 = 0,
    flags: u32 = 0,
    device_manufacturer: u32 = 0,
    device_model: u32 = 0,
    device_attributes: u64 = 0,
    rendering_intent: u32 = 0,
    illuminant: XYZNumber = .{ .x = 0.9642, .y = 1.0, .z = 0.8249 }, // D50

    // Description
    description: ?[]const u8 = null,
    copyright: ?[]const u8 = null,

    // Colorants (for RGB profiles)
    red_colorant: ?XYZNumber = null,
    green_colorant: ?XYZNumber = null,
    blue_colorant: ?XYZNumber = null,

    // White point
    white_point: XYZNumber = .{ .x = 0.9642, .y = 1.0, .z = 0.8249 },

    // TRC (Tone Response Curve) - simplified as gamma
    red_gamma: f64 = 2.2,
    green_gamma: f64 = 2.2,
    blue_gamma: f64 = 2.2,

    // Raw tag data for custom access
    tags: std.AutoHashMap(u32, []const u8),

    pub fn init(allocator: std.mem.Allocator) ICCProfile {
        return ICCProfile{
            .allocator = allocator,
            .tags = std.AutoHashMap(u32, []const u8).init(allocator),
        };
    }

    pub fn deinit(self: *ICCProfile) void {
        if (self.description) |d| self.allocator.free(d);
        if (self.copyright) |c| self.allocator.free(c);

        var iter = self.tags.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.tags.deinit();
    }

    pub fn isSRGB(self: *const ICCProfile) bool {
        // Check if this profile is close to sRGB
        if (self.color_space != .rgb) return false;

        // Check colorants against sRGB primaries
        const srgb_red = XYZNumber{ .x = 0.4358, .y = 0.2224, .z = 0.0139 };
        const srgb_green = XYZNumber{ .x = 0.3853, .y = 0.7170, .z = 0.0971 };
        const srgb_blue = XYZNumber{ .x = 0.1430, .y = 0.0606, .z = 0.7139 };

        const tolerance = 0.01;

        if (self.red_colorant) |rc| {
            if (@abs(rc.x - srgb_red.x) > tolerance or
                @abs(rc.y - srgb_red.y) > tolerance)
            {
                return false;
            }
        }

        if (self.green_colorant) |gc| {
            if (@abs(gc.x - srgb_green.x) > tolerance or
                @abs(gc.y - srgb_green.y) > tolerance)
            {
                return false;
            }
        }

        if (self.blue_colorant) |bc| {
            if (@abs(bc.x - srgb_blue.x) > tolerance or
                @abs(bc.y - srgb_blue.y) > tolerance)
            {
                return false;
            }
        }

        return true;
    }
};

// ============================================================================
// ICC Profile Parser
// ============================================================================

pub fn parse(allocator: std.mem.Allocator, data: []const u8) !ICCProfile {
    var profile = ICCProfile.init(allocator);
    errdefer profile.deinit();

    if (data.len < ICC_HEADER_SIZE) return profile;

    // Parse header
    profile.size = std.mem.readInt(u32, data[0..4], .big);
    profile.preferred_cmm = std.mem.readInt(u32, data[4..8], .big);
    profile.version = std.mem.readInt(u32, data[8..12], .big);
    profile.profile_class = @enumFromInt(std.mem.readInt(u32, data[12..16], .big));
    profile.color_space = @enumFromInt(std.mem.readInt(u32, data[16..20], .big));
    profile.pcs = @enumFromInt(std.mem.readInt(u32, data[20..24], .big));

    @memcpy(&profile.creation_date, data[24..36]);

    profile.signature = std.mem.readInt(u32, data[36..40], .big);

    // Validate signature
    if (!std.mem.eql(u8, data[36..40], ICC_MAGIC)) {
        return profile;
    }

    profile.platform = std.mem.readInt(u32, data[40..44], .big);
    profile.flags = std.mem.readInt(u32, data[44..48], .big);
    profile.device_manufacturer = std.mem.readInt(u32, data[48..52], .big);
    profile.device_model = std.mem.readInt(u32, data[52..56], .big);
    profile.device_attributes = std.mem.readInt(u64, data[56..64], .big);
    profile.rendering_intent = std.mem.readInt(u32, data[64..68], .big);

    // Illuminant
    profile.illuminant = XYZNumber.fromS15Fixed16(data[68..80]);

    // Read tag table
    if (data.len < 132) return profile;

    const tag_count = std.mem.readInt(u32, data[128..132], .big);
    var pos: usize = 132;

    var i: u32 = 0;
    while (i < tag_count and pos + 12 <= data.len) : (i += 1) {
        const tag_sig = std.mem.readInt(u32, data[pos..][0..4], .big);
        const tag_offset = std.mem.readInt(u32, data[pos + 4 ..][0..8], .big);
        const tag_size = std.mem.readInt(u32, data[pos + 8 ..][0..12], .big);

        if (tag_offset + tag_size <= data.len) {
            const tag_data = data[tag_offset..][0..tag_size];

            try parseTag(allocator, tag_sig, tag_data, &profile);
        }

        pos += 12;
    }

    return profile;
}

fn parseTag(allocator: std.mem.Allocator, sig: u32, data: []const u8, profile: *ICCProfile) !void {
    if (data.len < 8) return;

    const tag_type: TagType = @enumFromInt(std.mem.readInt(u32, data[0..4], .big));

    const tag: TagSignature = @enumFromInt(sig);

    switch (tag) {
        .profile_description => {
            profile.description = try parseTextTag(allocator, data, tag_type);
        },
        .copyright => {
            profile.copyright = try parseTextTag(allocator, data, tag_type);
        },
        .media_white_point => {
            if (tag_type == .xyz and data.len >= 20) {
                profile.white_point = XYZNumber.fromS15Fixed16(data[8..20]);
            }
        },
        .red_colorant => {
            if (tag_type == .xyz and data.len >= 20) {
                profile.red_colorant = XYZNumber.fromS15Fixed16(data[8..20]);
            }
        },
        .green_colorant => {
            if (tag_type == .xyz and data.len >= 20) {
                profile.green_colorant = XYZNumber.fromS15Fixed16(data[8..20]);
            }
        },
        .blue_colorant => {
            if (tag_type == .xyz and data.len >= 20) {
                profile.blue_colorant = XYZNumber.fromS15Fixed16(data[8..20]);
            }
        },
        .red_trc => {
            profile.red_gamma = parseTRCGamma(data, tag_type);
        },
        .green_trc => {
            profile.green_gamma = parseTRCGamma(data, tag_type);
        },
        .blue_trc => {
            profile.blue_gamma = parseTRCGamma(data, tag_type);
        },
        else => {
            // Store raw data for unknown tags
            const tag_copy = try allocator.dupe(u8, data);
            try profile.tags.put(sig, tag_copy);
        },
    }
}

fn parseTextTag(allocator: std.mem.Allocator, data: []const u8, tag_type: TagType) !?[]const u8 {
    switch (tag_type) {
        .text => {
            // Simple ASCII text
            if (data.len > 8) {
                const text = trimNull(data[8..]);
                return try allocator.dupe(u8, text);
            }
        },
        .desc => {
            // textDescriptionType
            if (data.len > 12) {
                const count = std.mem.readInt(u32, data[8..12], .big);
                if (12 + count <= data.len) {
                    const text = trimNull(data[12..][0..count]);
                    return try allocator.dupe(u8, text);
                }
            }
        },
        .mluc => {
            // Multi-localized unicode
            if (data.len > 16) {
                const record_count = std.mem.readInt(u32, data[8..12], .big);
                const record_size = std.mem.readInt(u32, data[12..16], .big);
                _ = record_size;

                if (record_count > 0 and data.len > 28) {
                    // Get first record (usually en_US)
                    const string_length = std.mem.readInt(u32, data[20..24], .big);
                    const string_offset = std.mem.readInt(u32, data[24..28], .big);

                    if (string_offset + string_length <= data.len) {
                        // UTF-16BE to ASCII (simplified)
                        const utf16_data = data[string_offset..][0..string_length];
                        var ascii = try allocator.alloc(u8, string_length / 2);
                        errdefer allocator.free(ascii);

                        var j: usize = 0;
                        var k: usize = 0;
                        while (j + 1 < utf16_data.len) : (j += 2) {
                            const char = std.mem.readInt(u16, utf16_data[j..][0..2], .big);
                            if (char < 128) {
                                ascii[k] = @truncate(char);
                                k += 1;
                            }
                        }

                        return allocator.realloc(ascii, k) catch ascii[0..k];
                    }
                }
            }
        },
        else => {},
    }
    return null;
}

fn parseTRCGamma(data: []const u8, tag_type: TagType) f64 {
    if (tag_type == .curve and data.len >= 12) {
        const count = std.mem.readInt(u32, data[8..12], .big);

        if (count == 0) {
            return 1.0; // Linear
        } else if (count == 1 and data.len >= 14) {
            // Single u8Fixed8Number value
            const gamma_fixed = std.mem.readInt(u16, data[12..14], .big);
            return @as(f64, @floatFromInt(gamma_fixed)) / 256.0;
        }
        // For curve tables, approximate gamma
        return 2.2;
    } else if (tag_type == .parametric_curve and data.len >= 16) {
        const func_type = std.mem.readInt(u16, data[8..10], .big);
        _ = func_type;

        // Read gamma parameter
        const gamma = s15Fixed16ToFloat(data[12..16]);
        return gamma;
    }
    return 2.2; // Default sRGB gamma
}

// ============================================================================
// ICC Profile Generator
// ============================================================================

pub fn createSRGBProfile(allocator: std.mem.Allocator) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    // We'll build a minimal sRGB profile
    var tags = std.ArrayList(TagEntry).init(allocator);
    defer tags.deinit();

    var tag_data = std.ArrayList(u8).init(allocator);
    defer tag_data.deinit();

    // Description tag
    const desc = "sRGB IEC61966-2.1";
    try addTextTag(&tags, &tag_data, .profile_description, desc);

    // Copyright
    const copyright = "Public Domain";
    try addTextTag(&tags, &tag_data, .copyright, copyright);

    // White point (D50)
    try addXYZTag(&tags, &tag_data, .media_white_point, .{ .x = 0.9642, .y = 1.0, .z = 0.8249 });

    // Colorants (sRGB primaries in XYZ)
    try addXYZTag(&tags, &tag_data, .red_colorant, .{ .x = 0.4358, .y = 0.2224, .z = 0.0139 });
    try addXYZTag(&tags, &tag_data, .green_colorant, .{ .x = 0.3853, .y = 0.7170, .z = 0.0971 });
    try addXYZTag(&tags, &tag_data, .blue_colorant, .{ .x = 0.1430, .y = 0.0606, .z = 0.7139 });

    // TRC (gamma 2.2 approximation)
    try addGammaTag(&tags, &tag_data, .red_trc, 2.2);
    try addGammaTag(&tags, &tag_data, .green_trc, 2.2);
    try addGammaTag(&tags, &tag_data, .blue_trc, 2.2);

    // Calculate sizes
    const header_size: usize = 128;
    const tag_table_size: usize = 4 + tags.items.len * 12;
    const data_offset = header_size + tag_table_size;
    const total_size = data_offset + tag_data.items.len;

    // Write header
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(total_size)))); // Size
    try output.appendNTimes(0, 4); // Preferred CMM
    try output.appendSlice(&[_]u8{ 0x02, 0x40, 0x00, 0x00 }); // Version 2.4
    try output.appendSlice(&std.mem.toBytes(@as(u32, @intFromEnum(ProfileClass.display_device)))); // Class
    try output.appendSlice(&std.mem.toBytes(@as(u32, @intFromEnum(ColorSpace.rgb)))); // Color space
    try output.appendSlice(&std.mem.toBytes(@as(u32, @intFromEnum(ColorSpace.xyz)))); // PCS

    // Date/time (zeros)
    try output.appendNTimes(0, 12);

    // Signature 'acsp'
    try output.appendSlice(ICC_MAGIC);

    // Platform (zeros)
    try output.appendNTimes(0, 4);

    // Flags
    try output.appendNTimes(0, 4);

    // Device manufacturer/model
    try output.appendNTimes(0, 8);

    // Device attributes
    try output.appendNTimes(0, 8);

    // Rendering intent (perceptual)
    try output.appendNTimes(0, 4);

    // Illuminant (D50)
    try output.appendSlice(&floatToS15Fixed16(0.9642));
    try output.appendSlice(&floatToS15Fixed16(1.0));
    try output.appendSlice(&floatToS15Fixed16(0.8249));

    // Creator
    try output.appendNTimes(0, 4);

    // Profile ID (zeros for now)
    try output.appendNTimes(0, 16);

    // Reserved
    try output.appendNTimes(0, 28);

    // Tag count
    try output.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(tags.items.len))));

    // Tag table
    for (tags.items) |tag| {
        try output.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, @intFromEnum(tag.sig))));
        try output.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(data_offset + tag.offset))));
        try output.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(tag.size))));
    }

    // Tag data
    try output.appendSlice(tag_data.items);

    return output.toOwnedSlice();
}

const TagEntry = struct {
    sig: TagSignature,
    offset: usize,
    size: usize,
};

fn addTextTag(tags: *std.ArrayList(TagEntry), data: *std.ArrayList(u8), sig: TagSignature, text: []const u8) !void {
    const start = data.items.len;

    // Type signature 'desc'
    try data.appendSlice("desc");
    // Reserved
    try data.appendNTimes(0, 4);
    // Count (including null)
    try data.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(text.len + 1))));
    // Text
    try data.appendSlice(text);
    try data.append(0);

    // Pad to 4-byte boundary
    while (data.items.len % 4 != 0) {
        try data.append(0);
    }

    try tags.append(TagEntry{
        .sig = sig,
        .offset = start,
        .size = data.items.len - start,
    });
}

fn addXYZTag(tags: *std.ArrayList(TagEntry), data: *std.ArrayList(u8), sig: TagSignature, xyz: XYZNumber) !void {
    const start = data.items.len;

    // Type signature 'XYZ '
    try data.appendSlice("XYZ ");
    // Reserved
    try data.appendNTimes(0, 4);
    // XYZ values
    try data.appendSlice(&floatToS15Fixed16(xyz.x));
    try data.appendSlice(&floatToS15Fixed16(xyz.y));
    try data.appendSlice(&floatToS15Fixed16(xyz.z));

    try tags.append(TagEntry{
        .sig = sig,
        .offset = start,
        .size = data.items.len - start,
    });
}

fn addGammaTag(tags: *std.ArrayList(TagEntry), data: *std.ArrayList(u8), sig: TagSignature, gamma: f64) !void {
    const start = data.items.len;

    // Type signature 'curv'
    try data.appendSlice("curv");
    // Reserved
    try data.appendNTimes(0, 4);
    // Count = 1 (single gamma value)
    try data.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, 1)));
    // Gamma as u8Fixed8Number
    const gamma_fixed: u16 = @intFromFloat(@round(gamma * 256.0));
    try data.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u16, gamma_fixed)));

    // Pad to 4-byte boundary
    while (data.items.len % 4 != 0) {
        try data.append(0);
    }

    try tags.append(TagEntry{
        .sig = sig,
        .offset = start,
        .size = data.items.len - start,
    });
}

// ============================================================================
// Helper Functions
// ============================================================================

fn s15Fixed16ToFloat(bytes: *const [4]u8) f64 {
    const value = std.mem.readInt(i32, bytes, .big);
    return @as(f64, @floatFromInt(value)) / 65536.0;
}

fn floatToS15Fixed16(value: f64) [4]u8 {
    const fixed: i32 = @intFromFloat(@round(value * 65536.0));
    return std.mem.toBytes(std.mem.nativeToBig(i32, fixed));
}

fn trimNull(data: []const u8) []const u8 {
    var end = data.len;
    while (end > 0 and data[end - 1] == 0) {
        end -= 1;
    }
    return data[0..end];
}

// ============================================================================
// Tests
// ============================================================================

test "ICC magic" {
    try std.testing.expectEqualSlices(u8, "acsp", ICC_MAGIC);
}

test "s15Fixed16 conversion" {
    const bytes = [_]u8{ 0x00, 0x01, 0x00, 0x00 }; // 1.0
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), s15Fixed16ToFloat(&bytes), 0.0001);
}

test "XYZ from s15Fixed16" {
    const data = [_]u8{
        0x00, 0x00, 0xF6, 0xD6, // 0.9642
        0x00, 0x01, 0x00, 0x00, // 1.0
        0x00, 0x00, 0xD3, 0x2D, // 0.8249
    };
    const xyz = XYZNumber.fromS15Fixed16(&data);
    try std.testing.expectApproxEqAbs(@as(f64, 0.9642), xyz.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), xyz.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8249), xyz.z, 0.001);
}
