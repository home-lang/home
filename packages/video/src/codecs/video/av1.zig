// Home Video Library - AV1 Codec
// AOMedia Video 1 (AV1) bitstream parsing
// Reference: AV1 Bitstream & Decoding Process Specification

const std = @import("std");
const types = @import("../../core/types.zig");
const err = @import("../../core/error.zig");

const VideoError = err.VideoError;

// ============================================================================
// AV1 OBU Types
// ============================================================================

pub const ObuType = enum(u4) {
    reserved_0 = 0,
    sequence_header = 1,
    temporal_delimiter = 2,
    frame_header = 3,
    tile_group = 4,
    metadata = 5,
    frame = 6,
    redundant_frame_header = 7,
    tile_list = 8,
    reserved_9 = 9,
    reserved_10 = 10,
    reserved_11 = 11,
    reserved_12 = 12,
    reserved_13 = 13,
    reserved_14 = 14,
    padding = 15,

    pub fn isValid(self: ObuType) bool {
        return switch (self) {
            .reserved_0, .reserved_9, .reserved_10, .reserved_11, .reserved_12, .reserved_13, .reserved_14 => false,
            else => true,
        };
    }
};

// ============================================================================
// AV1 Profile
// ============================================================================

pub const Profile = enum(u3) {
    main = 0, // 8-10 bit, 4:2:0
    high = 1, // 8-10 bit, 4:4:4
    professional = 2, // 8-12 bit, 4:2:0, 4:2:2, 4:4:4

    pub fn getMaxBitDepth(self: Profile) u8 {
        return switch (self) {
            .main, .high => 10,
            .professional => 12,
        };
    }
};

// ============================================================================
// AV1 Level
// ============================================================================

pub const Level = enum(u5) {
    level_2_0 = 0,
    level_2_1 = 1,
    level_2_2 = 2,
    level_2_3 = 3,
    level_3_0 = 4,
    level_3_1 = 5,
    level_3_2 = 6,
    level_3_3 = 7,
    level_4_0 = 8,
    level_4_1 = 9,
    level_4_2 = 10,
    level_4_3 = 11,
    level_5_0 = 12,
    level_5_1 = 13,
    level_5_2 = 14,
    level_5_3 = 15,
    level_6_0 = 16,
    level_6_1 = 17,
    level_6_2 = 18,
    level_6_3 = 19,
    level_7_0 = 20,
    level_7_1 = 21,
    level_7_2 = 22,
    level_7_3 = 23,
    _,

    pub fn getMajor(self: Level) u8 {
        const val = @intFromEnum(self);
        return 2 + val / 4;
    }

    pub fn getMinor(self: Level) u8 {
        const val = @intFromEnum(self);
        return val % 4;
    }
};

// ============================================================================
// AV1 Frame Type
// ============================================================================

pub const FrameType = enum(u2) {
    key_frame = 0,
    inter_frame = 1,
    intra_only_frame = 2,
    switch_frame = 3,

    pub fn isKeyFrame(self: FrameType) bool {
        return self == .key_frame;
    }

    pub fn isIntraOnly(self: FrameType) bool {
        return self == .key_frame or self == .intra_only_frame;
    }
};

// ============================================================================
// AV1 Color Config
// ============================================================================

pub const ColorConfig = struct {
    bit_depth: u8,
    mono_chrome: bool,
    color_primaries: u8,
    transfer_characteristics: u8,
    matrix_coefficients: u8,
    color_range: bool, // false = studio, true = full
    subsampling_x: bool,
    subsampling_y: bool,
    chroma_sample_position: u8,
    separate_uv_delta_q: bool,
};

// ============================================================================
// AV1 Timing Info
// ============================================================================

pub const TimingInfo = struct {
    num_units_in_display_tick: u32,
    time_scale: u32,
    equal_picture_interval: bool,
    num_ticks_per_picture: ?u32,

    pub fn getFrameRate(self: *const TimingInfo) f64 {
        if (self.num_ticks_per_picture) |ticks| {
            return @as(f64, @floatFromInt(self.time_scale)) /
                (@as(f64, @floatFromInt(self.num_units_in_display_tick)) * @as(f64, @floatFromInt(ticks)));
        }
        return @as(f64, @floatFromInt(self.time_scale)) / @as(f64, @floatFromInt(self.num_units_in_display_tick));
    }
};

// ============================================================================
// AV1 Sequence Header
// ============================================================================

pub const SequenceHeader = struct {
    profile: Profile,
    still_picture: bool,
    reduced_still_picture_header: bool,
    timing_info: ?TimingInfo,
    decoder_model_info_present: bool,
    operating_points_cnt: u8,
    operating_point_idc: [32]u16,
    seq_level_idx: [32]Level,
    seq_tier: [32]u1,

    max_frame_width: u32,
    max_frame_height: u32,
    frame_id_numbers_present: bool,
    delta_frame_id_length: ?u8,
    additional_frame_id_length: ?u8,

    use_128x128_superblock: bool,
    enable_filter_intra: bool,
    enable_intra_edge_filter: bool,
    enable_interintra_compound: bool,
    enable_masked_compound: bool,
    enable_warped_motion: bool,
    enable_dual_filter: bool,
    enable_order_hint: bool,
    enable_jnt_comp: bool,
    enable_ref_frame_mvs: bool,
    seq_force_screen_content_tools: u8,
    seq_force_integer_mv: u8,
    order_hint_bits: u8,

    enable_superres: bool,
    enable_cdef: bool,
    enable_restoration: bool,

    color_config: ColorConfig,
    film_grain_params_present: bool,

    pub fn getAspectRatio(self: *const SequenceHeader) f64 {
        return @as(f64, @floatFromInt(self.max_frame_width)) / @as(f64, @floatFromInt(self.max_frame_height));
    }
};

// ============================================================================
// AV1 OBU Header
// ============================================================================

pub const ObuHeader = struct {
    obu_type: ObuType,
    extension_flag: bool,
    has_size_field: bool,
    temporal_id: u3,
    spatial_id: u2,
    size: u64,

    pub fn headerSize(self: *const ObuHeader) usize {
        var size: usize = 1;
        if (self.extension_flag) size += 1;
        if (self.has_size_field) {
            // LEB128 size varies
            size += leb128Size(self.size);
        }
        return size;
    }
};

// ============================================================================
// AV1 Codec Configuration Record (av1C box)
// ============================================================================

pub const Av1CRecord = struct {
    marker: u1,
    version: u7,
    seq_profile: Profile,
    seq_level_idx_0: Level,
    seq_tier_0: u1,
    high_bitdepth: bool,
    twelve_bit: bool,
    monochrome: bool,
    chroma_subsampling_x: bool,
    chroma_subsampling_y: bool,
    chroma_sample_position: u8,
    initial_presentation_delay_present: bool,
    initial_presentation_delay: ?u4,
    config_obus: ?[]const u8,

    pub fn parse(data: []const u8) !Av1CRecord {
        if (data.len < 4) {
            return VideoError.TruncatedData;
        }

        const byte0 = data[0];
        const marker: u1 = @intCast(byte0 >> 7);
        const version: u7 = @intCast(byte0 & 0x7F);

        if (marker != 1 or version != 1) {
            return VideoError.InvalidHeader;
        }

        const byte1 = data[1];
        const seq_profile: Profile = @enumFromInt(@as(u3, @truncate(byte1 >> 5)));
        const seq_level_idx_0: Level = @enumFromInt(@as(u5, @truncate(byte1 & 0x1F)));

        const byte2 = data[2];
        const seq_tier_0: u1 = @intCast(byte2 >> 7);
        const high_bitdepth = (byte2 & 0x40) != 0;
        const twelve_bit = (byte2 & 0x20) != 0;
        const monochrome = (byte2 & 0x10) != 0;
        const chroma_subsampling_x = (byte2 & 0x08) != 0;
        const chroma_subsampling_y = (byte2 & 0x04) != 0;
        const chroma_sample_position: u8 = @truncate(byte2 & 0x03);

        const byte3 = data[3];
        const initial_delay_present = (byte3 & 0x10) != 0;
        const initial_delay: ?u4 = if (initial_delay_present) @truncate(byte3 & 0x0F) else null;

        var config_obus: ?[]const u8 = null;
        if (data.len > 4) {
            config_obus = data[4..];
        }

        return Av1CRecord{
            .marker = marker,
            .version = version,
            .seq_profile = seq_profile,
            .seq_level_idx_0 = seq_level_idx_0,
            .seq_tier_0 = seq_tier_0,
            .high_bitdepth = high_bitdepth,
            .twelve_bit = twelve_bit,
            .monochrome = monochrome,
            .chroma_subsampling_x = chroma_subsampling_x,
            .chroma_subsampling_y = chroma_subsampling_y,
            .chroma_sample_position = chroma_sample_position,
            .initial_presentation_delay_present = initial_delay_present,
            .initial_presentation_delay = initial_delay,
            .config_obus = config_obus,
        };
    }

    pub fn getBitDepth(self: *const Av1CRecord) u8 {
        if (self.twelve_bit) return 12;
        if (self.high_bitdepth) return 10;
        return 8;
    }

    pub fn getChromaSubsampling(self: *const Av1CRecord) []const u8 {
        if (self.monochrome) return "4:0:0";
        if (self.chroma_subsampling_x and self.chroma_subsampling_y) return "4:2:0";
        if (self.chroma_subsampling_x) return "4:2:2";
        return "4:4:4";
    }
};

// ============================================================================
// AV1 OBU Parser
// ============================================================================

pub const ObuParser = struct {
    data: []const u8,
    pos: usize,

    const Self = @This();

    pub fn init(data: []const u8) Self {
        return .{
            .data = data,
            .pos = 0,
        };
    }

    /// Parse the next OBU header
    pub fn parseObuHeader(self: *Self) !ObuHeader {
        if (self.pos >= self.data.len) {
            return VideoError.UnexpectedEof;
        }

        const header_byte = self.data[self.pos];
        self.pos += 1;

        const forbidden_bit = (header_byte >> 7) & 1;
        if (forbidden_bit != 0) {
            return VideoError.InvalidHeader;
        }

        const obu_type: ObuType = @enumFromInt(@as(u4, @truncate((header_byte >> 3) & 0x0F)));
        const extension_flag = ((header_byte >> 2) & 1) != 0;
        const has_size_field = ((header_byte >> 1) & 1) != 0;

        var temporal_id: u3 = 0;
        var spatial_id: u2 = 0;

        if (extension_flag) {
            if (self.pos >= self.data.len) {
                return VideoError.TruncatedData;
            }
            const ext_byte = self.data[self.pos];
            self.pos += 1;
            temporal_id = @intCast((ext_byte >> 5) & 0x07);
            spatial_id = @intCast((ext_byte >> 3) & 0x03);
        }

        var size: u64 = 0;
        if (has_size_field) {
            size = try self.readLeb128();
        } else {
            // Size extends to end of data
            size = self.data.len - self.pos;
        }

        return ObuHeader{
            .obu_type = obu_type,
            .extension_flag = extension_flag,
            .has_size_field = has_size_field,
            .temporal_id = temporal_id,
            .spatial_id = spatial_id,
            .size = size,
        };
    }

    /// Get the data for the current OBU (after header)
    pub fn getObuData(self: *Self, header: *const ObuHeader) ![]const u8 {
        const size: usize = @intCast(header.size);
        if (self.pos + size > self.data.len) {
            return VideoError.TruncatedData;
        }
        const data = self.data[self.pos..][0..size];
        self.pos += size;
        return data;
    }

    /// Skip the current OBU
    pub fn skipObu(self: *Self, header: *const ObuHeader) void {
        const size: usize = @intCast(header.size);
        self.pos = @min(self.pos + size, self.data.len);
    }

    fn readLeb128(self: *Self) !u64 {
        var value: u64 = 0;
        var i: u6 = 0;

        while (i < 8) {
            if (self.pos >= self.data.len) {
                return VideoError.TruncatedData;
            }

            const byte = self.data[self.pos];
            self.pos += 1;

            value |= @as(u64, byte & 0x7F) << (i * 7);

            if ((byte & 0x80) == 0) {
                break;
            }
            i += 1;
        }

        return value;
    }

    pub fn hasMore(self: *const Self) bool {
        return self.pos < self.data.len;
    }
};

// ============================================================================
// OBU Iterator
// ============================================================================

pub const ObuIterator = struct {
    parser: ObuParser,

    const Self = @This();

    pub fn init(data: []const u8) Self {
        return .{
            .parser = ObuParser.init(data),
        };
    }

    pub const ObuEntry = struct {
        header: ObuHeader,
        data: []const u8,
    };

    pub fn next(self: *Self) !?ObuEntry {
        if (!self.parser.hasMore()) {
            return null;
        }

        const header = try self.parser.parseObuHeader();
        const data = try self.parser.getObuData(&header);

        return ObuEntry{
            .header = header,
            .data = data,
        };
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

fn leb128Size(value: u64) usize {
    if (value == 0) return 1;
    var v = value;
    var size: usize = 0;
    while (v > 0) {
        v >>= 7;
        size += 1;
    }
    return size;
}

// ============================================================================
// Tests
// ============================================================================

test "ObuType validity" {
    try std.testing.expect(ObuType.sequence_header.isValid());
    try std.testing.expect(ObuType.frame.isValid());
    try std.testing.expect(!ObuType.reserved_0.isValid());
    try std.testing.expect(!ObuType.reserved_9.isValid());
}

test "Profile properties" {
    try std.testing.expectEqual(@as(u8, 10), Profile.main.getMaxBitDepth());
    try std.testing.expectEqual(@as(u8, 12), Profile.professional.getMaxBitDepth());
}

test "Level properties" {
    try std.testing.expectEqual(@as(u8, 2), Level.level_2_0.getMajor());
    try std.testing.expectEqual(@as(u8, 0), Level.level_2_0.getMinor());
    try std.testing.expectEqual(@as(u8, 5), Level.level_5_2.getMajor());
    try std.testing.expectEqual(@as(u8, 2), Level.level_5_2.getMinor());
}

test "FrameType properties" {
    try std.testing.expect(FrameType.key_frame.isKeyFrame());
    try std.testing.expect(!FrameType.inter_frame.isKeyFrame());
    try std.testing.expect(FrameType.key_frame.isIntraOnly());
    try std.testing.expect(FrameType.intra_only_frame.isIntraOnly());
    try std.testing.expect(!FrameType.inter_frame.isIntraOnly());
}

test "Av1CRecord parsing" {
    // Valid av1C record
    const av1c_data = [_]u8{
        0x81, // marker=1, version=1
        0x04, // profile=0, level=4 (3.0)
        0x0C, // tier=0, high_bitdepth=0, twelve_bit=0, mono=0, subx=1, suby=1, pos=0
        0x00, // no initial delay
    };

    const record = try Av1CRecord.parse(&av1c_data);
    try std.testing.expectEqual(Profile.main, record.seq_profile);
    try std.testing.expectEqual(Level.level_3_0, record.seq_level_idx_0);
    try std.testing.expectEqual(@as(u8, 8), record.getBitDepth());
    try std.testing.expectEqualStrings("4:2:0", record.getChromaSubsampling());
}

test "Av1CRecord bit depth" {
    var record = Av1CRecord{
        .marker = 1,
        .version = 1,
        .seq_profile = .main,
        .seq_level_idx_0 = .level_4_0,
        .seq_tier_0 = 0,
        .high_bitdepth = false,
        .twelve_bit = false,
        .monochrome = false,
        .chroma_subsampling_x = true,
        .chroma_subsampling_y = true,
        .chroma_sample_position = 0,
        .initial_presentation_delay_present = false,
        .initial_presentation_delay = null,
        .config_obus = null,
    };

    try std.testing.expectEqual(@as(u8, 8), record.getBitDepth());

    record.high_bitdepth = true;
    try std.testing.expectEqual(@as(u8, 10), record.getBitDepth());

    record.twelve_bit = true;
    try std.testing.expectEqual(@as(u8, 12), record.getBitDepth());
}

test "ObuParser basic" {
    // Simple OBU with temporal delimiter
    const obu_data = [_]u8{
        0x12, // type=2 (temporal_delimiter), has_size=1
        0x00, // size=0 (LEB128)
    };

    var parser = ObuParser.init(&obu_data);
    const header = try parser.parseObuHeader();

    try std.testing.expectEqual(ObuType.temporal_delimiter, header.obu_type);
    try std.testing.expect(header.has_size_field);
    try std.testing.expectEqual(@as(u64, 0), header.size);
}

test "ObuIterator" {
    const obu_data = [_]u8{
        0x12, 0x00, // temporal delimiter, size=0
        0x0A, 0x02, 0xAA, 0xBB, // sequence header, size=2, data=AA BB
    };

    var iter = ObuIterator.init(&obu_data);

    const first = try iter.next();
    try std.testing.expect(first != null);
    try std.testing.expectEqual(ObuType.temporal_delimiter, first.?.header.obu_type);

    const second = try iter.next();
    try std.testing.expect(second != null);
    try std.testing.expectEqual(ObuType.sequence_header, second.?.header.obu_type);
    try std.testing.expectEqual(@as(usize, 2), second.?.data.len);

    const third = try iter.next();
    try std.testing.expect(third == null);
}

test "leb128Size" {
    try std.testing.expectEqual(@as(usize, 1), leb128Size(0));
    try std.testing.expectEqual(@as(usize, 1), leb128Size(127));
    try std.testing.expectEqual(@as(usize, 2), leb128Size(128));
    try std.testing.expectEqual(@as(usize, 2), leb128Size(16383));
    try std.testing.expectEqual(@as(usize, 3), leb128Size(16384));
}
