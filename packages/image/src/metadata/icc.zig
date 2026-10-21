// ICC Profile Parser/Writer
// Selected ICC v2/v4 metadata and matrix/TRC primitives; not a complete CMM.
// Based on: https://www.color.org/specification/ICC.1-2022-05.pdf

const std = @import("std");
pub const layout = @import("icc_layout.zig");
pub const Curve = layout.Curve;
pub const Channel = enum { red, green, blue };
pub const validate = layout.validate;
pub const validateRgb = layout.validateRgb;

// ============================================================================
// ICC Constants
// ============================================================================

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
    creation_date: [12]u8 = @splat(0),
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

    // Legacy scalar summaries (sampled curves report an approximation). Use curve()
    // for actual transfer evaluation; gamma alone cannot represent sRGB.
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

    /// Borrowed curve bytes remain valid until this profile is deinitialized or
    /// its public raw-tag map is changed. No caller input buffer is retained.
    pub fn curve(self: *const ICCProfile, channel: Channel) !Curve {
        const name: *const [4]u8 = switch (channel) {
            .red => "rTRC",
            .green => "gTRC",
            .blue => "bTRC",
        };
        const data = self.tags.get(std.mem.readInt(u32, name, .big)) orelse return error.MissingCurve;
        return Curve.init(data);
    }
    pub fn isSRGB(self: *const ICCProfile) bool {
        if (self.color_space != .rgb or self.pcs != .xyz) return false;
        const actual = [_]?XYZNumber{ self.red_colorant, self.green_colorant, self.blue_colorant };
        const expected = [_]XYZNumber{
            .{ .x = 0.436030342570117, .y = 0.222438466210245, .z = 0.013897440074263 },
            .{ .x = 0.385101860087134, .y = 0.716942745571917, .z = 0.097076381494207 },
            .{ .x = 0.143067806654203, .y = 0.060618777416563, .z = 0.713926257896652 },
        };
        for (actual, expected) |maybe, reference| {
            const value = maybe orelse return false;
            if (@abs(value.x - reference.x) > 0.0002 or @abs(value.y - reference.y) > 0.0002 or @abs(value.z - reference.z) > 0.0002) return false;
        }
        if (@abs(self.white_point.x - 0.9642) > 0.0002 or @abs(self.white_point.y - 1) > 0.0002 or @abs(self.white_point.z - 0.8249) > 0.0002) return false;
        for ([_]Channel{ .red, .green, .blue }) |channel| {
            const trc = self.curve(channel) catch return false;
            for (0..257) |i| {
                const x = @as(f64, @floatFromInt(i)) / 256;
                const value = trc.evaluate(x) catch return false;
                if (@abs(value - srgbLinear(x)) > 0.00005) return false;
            }
        }
        return true;
    }
};

// ============================================================================
// ICC Profile Parser
// ============================================================================

pub fn parse(allocator: std.mem.Allocator, data: []const u8) !ICCProfile {
    const checked = try layout.validate(data);
    try checked.checkOwnedBudget(64 * 1024 * 1024);
    var profile = ICCProfile.init(allocator);
    errdefer profile.deinit();

    // Parse header
    profile.size = std.mem.readInt(u32, data[0..4], .big);
    profile.preferred_cmm = std.mem.readInt(u32, data[4..8], .big);
    profile.version = std.mem.readInt(u32, data[8..12], .big);
    profile.profile_class = @enumFromInt(std.mem.readInt(u32, data[12..16], .big));
    profile.color_space = @enumFromInt(std.mem.readInt(u32, data[16..20], .big));
    profile.pcs = @enumFromInt(std.mem.readInt(u32, data[20..24], .big));

    @memcpy(&profile.creation_date, data[24..36]);

    profile.signature = std.mem.readInt(u32, data[36..40], .big);

    profile.platform = std.mem.readInt(u32, data[40..44], .big);
    profile.flags = std.mem.readInt(u32, data[44..48], .big);
    profile.device_manufacturer = std.mem.readInt(u32, data[48..52], .big);
    profile.device_model = std.mem.readInt(u32, data[52..56], .big);
    profile.device_attributes = std.mem.readInt(u64, data[56..64], .big);
    profile.rendering_intent = std.mem.readInt(u32, data[64..68], .big);

    // Illuminant
    profile.illuminant = XYZNumber.fromS15Fixed16(data[68..80]);

    // Read tag table
    const tag_count = std.mem.readInt(u32, data[128..132], .big);
    var pos: usize = 132;

    var i: u32 = 0;
    while (i < tag_count and pos + 12 <= data.len) : (i += 1) {
        const tag_sig = std.mem.readInt(u32, data[pos..][0..4], .big);
        const tag_offset = std.mem.readInt(u32, data[pos + 4 ..][0..4], .big);
        const tag_size = std.mem.readInt(u32, data[pos + 8 ..][0..4], .big);

        const tag_offset_usize: usize = tag_offset;
        const tag_size_usize: usize = tag_size;
        if (tag_offset_usize <= data.len and tag_size_usize <= data.len - tag_offset_usize) {
            const tag_data = data[tag_offset_usize..][0..tag_size_usize];

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
            _ = try Curve.init(data);
            try rememberTag(allocator, sig, data, profile);
            profile.red_gamma = parseTRCGamma(data, tag_type);
        },
        .green_trc => {
            _ = try Curve.init(data);
            try rememberTag(allocator, sig, data, profile);
            profile.green_gamma = parseTRCGamma(data, tag_type);
        },
        .blue_trc => {
            _ = try Curve.init(data);
            try rememberTag(allocator, sig, data, profile);
            profile.blue_gamma = parseTRCGamma(data, tag_type);
        },
        else => {
            // Store raw data for unknown tags
            try rememberTag(allocator, sig, data, profile);
        },
    }
}

fn rememberTag(allocator: std.mem.Allocator, sig: u32, data: []const u8, profile: *ICCProfile) !void {
    const copy = try allocator.dupe(u8, data);
    const previous = profile.tags.fetchPut(sig, copy) catch |err| {
        allocator.free(copy);
        return err;
    };
    if (previous) |entry| allocator.free(entry.value);
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
            if (data.len < 16 or std.mem.readInt(u32, data[8..12], .big) == 0) return null;
            const length: usize = std.mem.readInt(u32, data[20..24], .big);
            const offset: usize = std.mem.readInt(u32, data[24..28], .big);
            const text = data[offset..][0..length];
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);
            var at: usize = 0;
            while (at < text.len) {
                const first = std.mem.readInt(u16, text[at..][0..2], .big);
                at += 2;
                var point: u21 = first;
                if (first >= 0xD800 and first <= 0xDBFF) {
                    if (at == text.len) return error.InvalidText;
                    const second = std.mem.readInt(u16, text[at..][0..2], .big);
                    if (second < 0xDC00 or second > 0xDFFF) return error.InvalidText;
                    at += 2;
                    point = 0x10000 + (@as(u21, first - 0xD800) << 10) + second - 0xDC00;
                } else if (first >= 0xDC00 and first <= 0xDFFF) return error.InvalidText;
                var encoded: [4]u8 = undefined;
                const count = try std.unicode.utf8Encode(point, &encoded);
                try out.appendSlice(allocator, encoded[0..count]);
            }
            return try out.toOwnedSlice(allocator);
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
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    // We'll build a minimal sRGB profile
    var tags: std.ArrayList(TagEntry) = .empty;
    defer tags.deinit(allocator);

    var tag_data: std.ArrayList(u8) = .empty;
    defer tag_data.deinit(allocator);

    // Description tag
    const desc = "sRGB IEC61966-2.1";
    try addTextTag(allocator, &tags, &tag_data, .profile_description, desc);

    // Copyright
    const copyright = "Public Domain";
    try addTextTag(allocator, &tags, &tag_data, .copyright, copyright);

    // White point (D50)
    try addXYZTag(allocator, &tags, &tag_data, .media_white_point, .{ .x = 0.9642, .y = 1.0, .z = 0.8249 });

    // ICC published D65-to-D50-adapted sRGB matrix columns.
    // https://registry.color.org/rgb-registry/files/sRGB.pdf (section B.2)
    try addXYZTag(allocator, &tags, &tag_data, .red_colorant, .{ .x = 0.436030342570117, .y = 0.222438466210245, .z = 0.013897440074263 });
    try addXYZTag(allocator, &tags, &tag_data, .green_colorant, .{ .x = 0.385101860087134, .y = 0.716942745571917, .z = 0.097076381494207 });
    try addXYZTag(allocator, &tags, &tag_data, .blue_colorant, .{ .x = 0.143067806654203, .y = 0.060618777416563, .z = 0.713926257896652 });

    // ICC v2 uses a sampled curve for the actual piecewise sRGB transfer.
    // The three channel tags share an identical immutable body.
    try addSRGBCurve(allocator, &tags, &tag_data);
    const trc = tags.items[tags.items.len - 1];
    try tags.append(allocator, .{ .sig = .green_trc, .offset = trc.offset, .size = trc.size });
    try tags.append(allocator, .{ .sig = .blue_trc, .offset = trc.offset, .size = trc.size });
    try addAdaptation(allocator, &tags, &tag_data);

    // Calculate sizes
    const header_size: usize = 128;
    const tag_table_size: usize = 4 + tags.items.len * 12;
    const data_offset = header_size + tag_table_size;
    const total_size = data_offset + tag_data.items.len;

    // Write header
    try output.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(total_size)))); // Size
    try output.appendNTimes(allocator, 0, 4); // Preferred CMM
    try output.appendSlice(allocator, &[_]u8{ 0x02, 0x40, 0x00, 0x00 }); // Version 2.4
    try output.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, @intFromEnum(ProfileClass.display_device)))); // Class
    try output.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, @intFromEnum(ColorSpace.rgb)))); // Color space
    try output.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, @intFromEnum(ColorSpace.xyz)))); // PCS

    // Deterministic profile-definition epoch, not the image capture time.
    for ([_]u16{ 2000, 1, 1, 0, 0, 0 }) |value| try output.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, value)));

    // Signature 'acsp'
    try output.appendSlice(allocator, ICC_MAGIC);

    // Platform (zeros)
    try output.appendNTimes(allocator, 0, 4);

    // Flags
    try output.appendNTimes(allocator, 0, 4);

    // Device manufacturer/model
    try output.appendNTimes(allocator, 0, 8);

    // Device attributes
    try output.appendNTimes(allocator, 0, 8);

    // Rendering intent (perceptual)
    try output.appendNTimes(allocator, 0, 4);

    // Illuminant (D50)
    try output.appendSlice(allocator, &floatToS15Fixed16(0.9642));
    try output.appendSlice(allocator, &floatToS15Fixed16(1.0));
    try output.appendSlice(allocator, &floatToS15Fixed16(0.8249));

    // Creator
    try output.appendNTimes(allocator, 0, 4);

    // Profile ID (zeros for now)
    try output.appendNTimes(allocator, 0, 16);

    // Reserved
    try output.appendNTimes(allocator, 0, 28);

    // Tag count
    try output.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(tags.items.len))));

    // Tag table
    for (tags.items) |tag| {
        try output.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, @intFromEnum(tag.sig))));
        try output.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(data_offset + tag.offset))));
        try output.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(tag.size))));
    }

    // Tag data
    try output.appendSlice(allocator, tag_data.items);

    return output.toOwnedSlice(allocator);
}

const TagEntry = struct {
    sig: TagSignature,
    offset: usize,
    size: usize,
};

fn addTextTag(allocator: std.mem.Allocator, tags: *std.ArrayList(TagEntry), data: *std.ArrayList(u8), sig: TagSignature, text: []const u8) !void {
    const start = data.items.len;

    if (sig == .copyright) {
        try data.appendSlice(allocator, "text");
        try data.appendNTimes(allocator, 0, 4);
        try data.appendSlice(allocator, text);
        try data.append(allocator, 0);
    } else {
        try data.appendSlice(allocator, "desc");
        try data.appendNTimes(allocator, 0, 4);
        try data.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(text.len + 1))));
        try data.appendSlice(allocator, text);
        try data.append(allocator, 0);
        try data.appendNTimes(allocator, 0, 8 + 70); // Unicode language/count + Mac ScriptCode/count/string
    }

    // Pad to 4-byte boundary
    while (data.items.len % 4 != 0) {
        try data.append(allocator, 0);
    }

    try tags.append(allocator, TagEntry{
        .sig = sig,
        .offset = start,
        .size = data.items.len - start,
    });
}

fn addXYZTag(allocator: std.mem.Allocator, tags: *std.ArrayList(TagEntry), data: *std.ArrayList(u8), sig: TagSignature, xyz: XYZNumber) !void {
    const start = data.items.len;

    // Type signature 'XYZ '
    try data.appendSlice(allocator, "XYZ ");
    // Reserved
    try data.appendNTimes(allocator, 0, 4);
    // XYZ values
    try data.appendSlice(allocator, &floatToS15Fixed16(xyz.x));
    try data.appendSlice(allocator, &floatToS15Fixed16(xyz.y));
    try data.appendSlice(allocator, &floatToS15Fixed16(xyz.z));

    try tags.append(allocator, TagEntry{
        .sig = sig,
        .offset = start,
        .size = data.items.len - start,
    });
}

fn srgbLinear(x: f64) f64 {
    return if (x <= 0.04045) x / 12.92 else std.math.pow(f64, (x + 0.055) / 1.055, 2.4);
}
fn addSRGBCurve(allocator: std.mem.Allocator, tags: *std.ArrayList(TagEntry), data: *std.ArrayList(u8)) !void {
    const start = data.items.len;
    try data.appendSlice(allocator, "curv");
    try data.appendNTimes(allocator, 0, 4);
    const samples = 4096;
    try data.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, samples)));
    for (0..samples) |i| {
        const x = @as(f64, @floatFromInt(i)) / (samples - 1);
        const value: u16 = @intFromFloat(@round(srgbLinear(x) * 65535));
        try data.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, value)));
    }
    try tags.append(allocator, .{ .sig = .red_trc, .offset = start, .size = data.items.len - start });
}
fn addAdaptation(allocator: std.mem.Allocator, tags: *std.ArrayList(TagEntry), data: *std.ArrayList(u8)) !void {
    const start = data.items.len;
    try data.appendSlice(allocator, "sf32");
    try data.appendNTimes(allocator, 0, 4);
    for ([_]f64{ 1.047844353856414, 0.022898981050086, -0.050206647741605, 0.029549007606644, 0.990508028941971, -0.017074711360960, -0.009250984365223, 0.015072338237051, 0.751717835079977 }) |value| try data.appendSlice(allocator, &floatToS15Fixed16(value));
    try tags.append(allocator, .{ .sig = .chromatic_adaptation, .offset = start, .size = data.items.len - start });
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

test "generated sRGB profile parses with exact signatures" {
    const allocator = std.testing.allocator;
    const encoded = try createSRGBProfile(allocator);
    defer allocator.free(encoded);

    var profile = try parse(allocator, encoded);
    defer profile.deinit();

    try std.testing.expectEqual(@as(u32, @intCast(encoded.len)), profile.size);
    try std.testing.expectEqual(ProfileClass.display_device, profile.profile_class);
    try std.testing.expectEqual(ColorSpace.rgb, profile.color_space);
    try std.testing.expectEqual(ColorSpace.xyz, profile.pcs);
    try std.testing.expectEqualStrings("sRGB IEC61966-2.1", profile.description.?);
    try std.testing.expectEqualStrings("Public Domain", profile.copyright.?);
    try std.testing.expect(profile.isSRGB());
    try std.testing.expectApproxEqAbs(@as(f64, 2.2), profile.red_gamma, 0.01);
}
