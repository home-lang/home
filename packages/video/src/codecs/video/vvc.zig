// Home Video Library - VVC/H.266 Codec
// Versatile Video Coding (ITU-T H.266 / ISO/IEC 23090-3)

const std = @import("std");
const err = @import("../../core/error.zig");
const bitstream = @import("../../util/bitstream.zig");

const VideoError = err.VideoError;
const BitstreamReader = bitstream.BitstreamReader;

// ============================================================================
// VVC NAL Unit Types
// ============================================================================

pub const NalUnitType = enum(u6) {
    // VCL NAL units
    trail_nut = 0,
    stsa_nut = 1,
    radl_nut = 2,
    rasl_nut = 3,
    rsv_vcl_4 = 4,
    rsv_vcl_5 = 5,
    rsv_vcl_6 = 6,
    idr_w_radl = 7,
    idr_n_lp = 8,
    cra_nut = 9,
    gdr_nut = 10,
    rsv_irap_11 = 11,
    // Non-VCL NAL units
    opi_nut = 12, // Operating point information
    dci_nut = 13, // Decoding capability information
    vps_nut = 14, // Video parameter set
    sps_nut = 15, // Sequence parameter set
    pps_nut = 16, // Picture parameter set
    prefix_aps_nut = 17, // Adaptation parameter set (prefix)
    suffix_aps_nut = 18, // Adaptation parameter set (suffix)
    ph_nut = 19, // Picture header
    aud_nut = 20, // Access unit delimiter
    eos_nut = 21, // End of sequence
    eob_nut = 22, // End of bitstream
    prefix_sei_nut = 23, // SEI (prefix)
    suffix_sei_nut = 24, // SEI (suffix)
    fd_nut = 25, // Filler data
    rsv_nvcl_26 = 26,
    rsv_nvcl_27 = 27,
    unspec_28 = 28,
    unspec_29 = 29,
    unspec_30 = 30,
    unspec_31 = 31,
    // Additional types
    rsv_32 = 32,
    rsv_33 = 33,
    rsv_34 = 34,
    rsv_35 = 35,
    rsv_36 = 36,
    rsv_37 = 37,
    rsv_38 = 38,
    rsv_39 = 39,
    rsv_40 = 40,
    rsv_41 = 41,
    rsv_42 = 42,
    rsv_43 = 43,
    rsv_44 = 44,
    rsv_45 = 45,
    rsv_46 = 46,
    rsv_47 = 47,
    rsv_48 = 48,
    rsv_49 = 49,
    rsv_50 = 50,
    rsv_51 = 51,
    rsv_52 = 52,
    rsv_53 = 53,
    rsv_54 = 54,
    rsv_55 = 55,
    rsv_56 = 56,
    rsv_57 = 57,
    rsv_58 = 58,
    rsv_59 = 59,
    rsv_60 = 60,
    rsv_61 = 61,
    rsv_62 = 62,
    rsv_63 = 63,

    pub fn isVcl(self: NalUnitType) bool {
        return @intFromEnum(self) <= 11;
    }

    pub fn isIdr(self: NalUnitType) bool {
        return self == .idr_w_radl or self == .idr_n_lp;
    }

    pub fn isIrap(self: NalUnitType) bool {
        return self == .idr_w_radl or self == .idr_n_lp or self == .cra_nut or self == .gdr_nut;
    }

    pub fn isParameterSet(self: NalUnitType) bool {
        return self == .vps_nut or self == .sps_nut or self == .pps_nut or
            self == .prefix_aps_nut or self == .suffix_aps_nut;
    }
};

// ============================================================================
// VVC NAL Unit Header
// ============================================================================

pub const NalUnitHeader = struct {
    forbidden_zero_bit: bool,
    nuh_reserved_zero_bit: bool,
    nuh_layer_id: u6,
    nal_unit_type: NalUnitType,
    nuh_temporal_id_plus1: u3,

    pub fn parse(data: []const u8) !NalUnitHeader {
        if (data.len < 2) return VideoError.TruncatedData;

        // VVC NAL header is 2 bytes:
        // forbidden_zero_bit (1) | nuh_reserved_zero_bit (1) | nuh_layer_id (6)
        // nal_unit_type (5) | nuh_temporal_id_plus1 (3)
        return NalUnitHeader{
            .forbidden_zero_bit = (data[0] & 0x80) != 0,
            .nuh_reserved_zero_bit = (data[0] & 0x40) != 0,
            .nuh_layer_id = @truncate(data[0] & 0x3F),
            .nal_unit_type = @enumFromInt(@as(u6, @truncate((data[1] >> 3) & 0x1F))),
            .nuh_temporal_id_plus1 = @truncate(data[1] & 0x07),
        };
    }

    pub fn temporalId(self: *const NalUnitHeader) u3 {
        return if (self.nuh_temporal_id_plus1 > 0) self.nuh_temporal_id_plus1 - 1 else 0;
    }

    pub fn toBytes(self: *const NalUnitHeader) [2]u8 {
        return .{
            (@as(u8, if (self.forbidden_zero_bit) 0x80 else 0)) |
                (@as(u8, if (self.nuh_reserved_zero_bit) 0x40 else 0)) |
                self.nuh_layer_id,
            (@as(u8, @truncate(@intFromEnum(self.nal_unit_type))) << 3) |
                self.nuh_temporal_id_plus1,
        };
    }
};

// ============================================================================
// VVC NAL Unit Iterator
// ============================================================================

pub const VvcNalIterator = struct {
    data: []const u8,
    pos: usize,

    pub fn init(data: []const u8) VvcNalIterator {
        return .{ .data = data, .pos = 0 };
    }

    pub fn next(self: *VvcNalIterator) ?NalUnit {
        // Find start code
        while (self.pos + 3 < self.data.len) {
            if (self.data[self.pos] == 0 and self.data[self.pos + 1] == 0) {
                if (self.data[self.pos + 2] == 1) {
                    const start = self.pos + 3;
                    const end = self.findNextStartCode(start);
                    self.pos = end;

                    if (end > start) {
                        return NalUnit{
                            .data = self.data[start..end],
                            .header = NalUnitHeader.parse(self.data[start..]) catch return null,
                        };
                    }
                } else if (self.data[self.pos + 2] == 0 and self.pos + 3 < self.data.len and self.data[self.pos + 3] == 1) {
                    const start = self.pos + 4;
                    const end = self.findNextStartCode(start);
                    self.pos = end;

                    if (end > start) {
                        return NalUnit{
                            .data = self.data[start..end],
                            .header = NalUnitHeader.parse(self.data[start..]) catch return null,
                        };
                    }
                }
            }
            self.pos += 1;
        }
        return null;
    }

    fn findNextStartCode(self: *const VvcNalIterator, from: usize) usize {
        var i = from;
        while (i + 2 < self.data.len) {
            if (self.data[i] == 0 and self.data[i + 1] == 0) {
                if (self.data[i + 2] == 1 or (self.data[i + 2] == 0 and i + 3 < self.data.len and self.data[i + 3] == 1)) {
                    return i;
                }
            }
            i += 1;
        }
        return self.data.len;
    }
};

pub const NalUnit = struct {
    data: []const u8,
    header: NalUnitHeader,
};

// ============================================================================
// VVC Profile and Level
// ============================================================================

pub const Profile = enum(u8) {
    main_10 = 1,
    main_10_444 = 33,
    main_10_still_picture = 65,
    main_10_444_still_picture = 97,
    multilayer_main_10 = 17,
    multilayer_main_10_444 = 49,

    pub fn toString(self: Profile) []const u8 {
        return switch (self) {
            .main_10 => "Main 10",
            .main_10_444 => "Main 10 4:4:4",
            .main_10_still_picture => "Main 10 Still Picture",
            .main_10_444_still_picture => "Main 10 4:4:4 Still Picture",
            .multilayer_main_10 => "Multilayer Main 10",
            .multilayer_main_10_444 => "Multilayer Main 10 4:4:4",
        };
    }
};

pub const Level = enum(u8) {
    level_1_0 = 16,
    level_2_0 = 32,
    level_2_1 = 35,
    level_3_0 = 48,
    level_3_1 = 51,
    level_4_0 = 64,
    level_4_1 = 67,
    level_5_0 = 80,
    level_5_1 = 83,
    level_5_2 = 86,
    level_6_0 = 96,
    level_6_1 = 99,
    level_6_2 = 102,
    level_6_3 = 105,

    pub fn toFloat(self: Level) f32 {
        return @as(f32, @floatFromInt(@intFromEnum(self))) / 16.0;
    }

    pub fn toString(self: Level) []const u8 {
        return switch (self) {
            .level_1_0 => "1.0",
            .level_2_0 => "2.0",
            .level_2_1 => "2.1",
            .level_3_0 => "3.0",
            .level_3_1 => "3.1",
            .level_4_0 => "4.0",
            .level_4_1 => "4.1",
            .level_5_0 => "5.0",
            .level_5_1 => "5.1",
            .level_5_2 => "5.2",
            .level_6_0 => "6.0",
            .level_6_1 => "6.1",
            .level_6_2 => "6.2",
            .level_6_3 => "6.3",
        };
    }
};

// ============================================================================
// VVC VPS (Video Parameter Set)
// ============================================================================

pub const Vps = struct {
    vps_video_parameter_set_id: u4,
    vps_max_layers_minus1: u6,
    vps_max_sublayers_minus1: u3,
    vps_default_ptl_dpb_hrd_max_tid_flag: bool,
    vps_all_independent_layers_flag: bool,
    vps_each_layer_is_an_ols_flag: bool,
    vps_ols_mode_idc: u2,

    pub fn parse(data: []const u8) !Vps {
        if (data.len < 4) return VideoError.TruncatedData;

        var reader = BitstreamReader.init(data[2..]); // Skip NAL header

        const vps_id = reader.readBits(4) catch return VideoError.TruncatedData;
        const max_layers = reader.readBits(6) catch return VideoError.TruncatedData;
        const max_sublayers = reader.readBits(3) catch return VideoError.TruncatedData;

        var default_ptl_flag = true;
        if (max_sublayers > 0 and max_layers > 0) {
            default_ptl_flag = (reader.readBits(1) catch return VideoError.TruncatedData) != 0;
        }

        var all_independent = true;
        if (max_layers > 0) {
            all_independent = (reader.readBits(1) catch return VideoError.TruncatedData) != 0;
        }

        return Vps{
            .vps_video_parameter_set_id = @intCast(vps_id),
            .vps_max_layers_minus1 = @intCast(max_layers),
            .vps_max_sublayers_minus1 = @intCast(max_sublayers),
            .vps_default_ptl_dpb_hrd_max_tid_flag = default_ptl_flag,
            .vps_all_independent_layers_flag = all_independent,
            .vps_each_layer_is_an_ols_flag = true,
            .vps_ols_mode_idc = 0,
        };
    }
};

// ============================================================================
// VVC SPS (Sequence Parameter Set)
// ============================================================================

pub const Sps = struct {
    sps_seq_parameter_set_id: u4,
    sps_video_parameter_set_id: u4,
    sps_max_sublayers_minus1: u3,
    sps_chroma_format_idc: u2,
    sps_log2_ctu_size_minus5: u2,
    sps_ptl_dpb_hrd_params_present_flag: bool,
    // Profile/tier/level
    profile_idc: ?u8,
    level_idc: ?u8,
    tier_flag: bool,
    // Picture dimensions
    sps_pic_width_max_in_luma_samples: u16,
    sps_pic_height_max_in_luma_samples: u16,
    // Bit depth
    sps_bitdepth_minus8: u4,

    pub fn parse(data: []const u8) !Sps {
        if (data.len < 6) return VideoError.TruncatedData;

        var reader = BitstreamReader.init(data[2..]); // Skip NAL header

        const sps_id = reader.readBits(4) catch return VideoError.TruncatedData;
        const vps_id = reader.readBits(4) catch return VideoError.TruncatedData;
        const max_sublayers = reader.readBits(3) catch return VideoError.TruncatedData;
        const chroma_format = reader.readBits(2) catch return VideoError.TruncatedData;
        const log2_ctu_size = reader.readBits(2) catch return VideoError.TruncatedData;
        const ptl_present = (reader.readBits(1) catch return VideoError.TruncatedData) != 0;

        var profile_idc: ?u8 = null;
        var level_idc: ?u8 = null;
        var tier_flag = false;

        if (ptl_present) {
            // Parse profile_tier_level - simplified
            // Skip constraint flags etc for now
            const general_profile_idc = reader.readBits(7) catch null;
            tier_flag = (reader.readBits(1) catch 0) != 0;
            profile_idc = if (general_profile_idc) |p| @intCast(p) else null;

            // Skip many bits to get to level
            _ = reader.readBits(8) catch {}; // general_level_idc is complex
            level_idc = 64; // Default to level 4.0
        }

        // Decode picture dimensions using exp-golomb
        const width = readUe(&reader) catch 0;
        const height = readUe(&reader) catch 0;

        // Bit depth
        const bitdepth_minus8 = reader.readBits(4) catch 2; // Default 10-bit

        return Sps{
            .sps_seq_parameter_set_id = @intCast(sps_id),
            .sps_video_parameter_set_id = @intCast(vps_id),
            .sps_max_sublayers_minus1 = @intCast(max_sublayers),
            .sps_chroma_format_idc = @intCast(chroma_format),
            .sps_log2_ctu_size_minus5 = @intCast(log2_ctu_size),
            .sps_ptl_dpb_hrd_params_present_flag = ptl_present,
            .profile_idc = profile_idc,
            .level_idc = level_idc,
            .tier_flag = tier_flag,
            .sps_pic_width_max_in_luma_samples = @intCast(width),
            .sps_pic_height_max_in_luma_samples = @intCast(height),
            .sps_bitdepth_minus8 = @intCast(bitdepth_minus8),
        };
    }

    pub fn ctuSize(self: *const Sps) u32 {
        return @as(u32, 1) << (@as(u5, self.sps_log2_ctu_size_minus5) + 5);
    }

    pub fn bitDepth(self: *const Sps) u8 {
        return self.sps_bitdepth_minus8 + 8;
    }

    pub fn chromaFormatString(self: *const Sps) []const u8 {
        return switch (self.sps_chroma_format_idc) {
            0 => "Monochrome",
            1 => "4:2:0",
            2 => "4:2:2",
            3 => "4:4:4",
        };
    }
};

// ============================================================================
// VVC PPS (Picture Parameter Set)
// ============================================================================

pub const Pps = struct {
    pps_pic_parameter_set_id: u6,
    pps_seq_parameter_set_id: u4,
    pps_mixed_nalu_types_in_pic_flag: bool,
    pps_pic_width_in_luma_samples: u16,
    pps_pic_height_in_luma_samples: u16,
    pps_output_flag_present_flag: bool,
    pps_cabac_init_present_flag: bool,

    pub fn parse(data: []const u8) !Pps {
        if (data.len < 4) return VideoError.TruncatedData;

        var reader = BitstreamReader.init(data[2..]); // Skip NAL header

        const pps_id = reader.readBits(6) catch return VideoError.TruncatedData;
        const sps_id = reader.readBits(4) catch return VideoError.TruncatedData;
        const mixed_nalu = (reader.readBits(1) catch return VideoError.TruncatedData) != 0;

        // Picture dimensions
        const width = readUe(&reader) catch 0;
        const height = readUe(&reader) catch 0;

        return Pps{
            .pps_pic_parameter_set_id = @intCast(pps_id),
            .pps_seq_parameter_set_id = @intCast(sps_id),
            .pps_mixed_nalu_types_in_pic_flag = mixed_nalu,
            .pps_pic_width_in_luma_samples = @intCast(width),
            .pps_pic_height_in_luma_samples = @intCast(height),
            .pps_output_flag_present_flag = false,
            .pps_cabac_init_present_flag = false,
        };
    }
};

// ============================================================================
// VVC Decoder Configuration Record (vvcC box for MP4)
// ============================================================================

pub const VvcCRecord = struct {
    length_size_minus_one: u2,
    ptl_present_flag: bool,
    ols_idx: u9,
    num_sublayers: u3,
    constant_frame_rate: u2,
    chroma_format_idc: u2,
    bit_depth_minus8: u3,
    num_bytes_constraint_info: u6,
    general_profile_idc: u7,
    general_tier_flag: bool,
    general_level_idc: u8,
    arrays: std.ArrayListUnmanaged(NaluArray),
    allocator: std.mem.Allocator,

    pub const NaluArray = struct {
        array_completeness: bool,
        nal_unit_type: NalUnitType,
        nalus: std.ArrayListUnmanaged([]const u8),
        allocator: std.mem.Allocator,

        pub fn deinit(self: *NaluArray) void {
            for (self.nalus.items) |nalu| {
                self.allocator.free(nalu);
            }
            self.nalus.deinit(self.allocator);
        }
    };

    pub fn init(allocator: std.mem.Allocator) VvcCRecord {
        return .{
            .length_size_minus_one = 3,
            .ptl_present_flag = true,
            .ols_idx = 0,
            .num_sublayers = 1,
            .constant_frame_rate = 0,
            .chroma_format_idc = 1,
            .bit_depth_minus8 = 2,
            .num_bytes_constraint_info = 0,
            .general_profile_idc = 1,
            .general_tier_flag = false,
            .general_level_idc = 64,
            .arrays = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *VvcCRecord) void {
        for (self.arrays.items) |*arr| {
            arr.deinit();
        }
        self.arrays.deinit(self.allocator);
    }

    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !VvcCRecord {
        if (data.len < 5) return VideoError.TruncatedData;

        var record = VvcCRecord.init(allocator);
        errdefer record.deinit();

        // Parse header fields
        record.length_size_minus_one = @truncate(data[0] & 0x03);
        record.ptl_present_flag = (data[0] & 0x04) != 0;

        var pos: usize = 1;

        if (record.ptl_present_flag) {
            if (data.len < pos + 4) return VideoError.TruncatedData;

            record.ols_idx = (@as(u9, data[pos]) << 1) | ((data[pos + 1] >> 7) & 0x01);
            record.num_sublayers = @truncate((data[pos + 1] >> 4) & 0x07);
            record.constant_frame_rate = @truncate((data[pos + 1] >> 2) & 0x03);
            record.chroma_format_idc = @truncate(data[pos + 1] & 0x03);

            record.bit_depth_minus8 = @truncate((data[pos + 2] >> 5) & 0x07);
            record.num_bytes_constraint_info = @truncate(data[pos + 2] & 0x3F);

            pos += 3;
            pos += record.num_bytes_constraint_info; // Skip constraint info bytes

            if (data.len < pos + 2) return VideoError.TruncatedData;

            record.general_profile_idc = @truncate((data[pos] >> 1) & 0x7F);
            record.general_tier_flag = (data[pos] & 0x01) != 0;
            record.general_level_idc = data[pos + 1];
            pos += 2;

            // Skip PTL sublayer flags
            pos += 1;
        }

        // Parse NAL unit arrays
        if (data.len < pos + 1) return record;

        const num_arrays = data[pos];
        pos += 1;

        for (0..num_arrays) |_| {
            if (data.len < pos + 3) break;

            const array_completeness = (data[pos] & 0x80) != 0;
            const nal_type: NalUnitType = @enumFromInt(@as(u6, @truncate(data[pos] & 0x1F)));
            pos += 1;

            const num_nalus = (@as(u16, data[pos]) << 8) | data[pos + 1];
            pos += 2;

            var array = NaluArray{
                .array_completeness = array_completeness,
                .nal_unit_type = nal_type,
                .nalus = .empty,
                .allocator = allocator,
            };

            for (0..num_nalus) |_| {
                if (data.len < pos + 2) break;

                const nalu_len = (@as(u16, data[pos]) << 8) | data[pos + 1];
                pos += 2;

                if (data.len < pos + nalu_len) break;

                const nalu_data = try allocator.dupe(u8, data[pos .. pos + nalu_len]);
                try array.nalus.append(allocator, nalu_data);
                pos += nalu_len;
            }

            try record.arrays.append(allocator, array);
        }

        return record;
    }

    pub fn lengthSize(self: *const VvcCRecord) u8 {
        return @as(u8, self.length_size_minus_one) + 1;
    }

    pub fn getProfile(self: *const VvcCRecord) ?Profile {
        return std.meta.intToEnum(Profile, self.general_profile_idc) catch null;
    }

    pub fn getLevel(self: *const VvcCRecord) ?Level {
        return std.meta.intToEnum(Level, self.general_level_idc) catch null;
    }

    pub fn bitDepth(self: *const VvcCRecord) u8 {
        return @as(u8, self.bit_depth_minus8) + 8;
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

fn readUe(reader: *BitstreamReader) !u32 {
    // Count leading zeros
    var leading_zeros: u32 = 0;
    while (leading_zeros < 32) {
        const bit = reader.readBits(1) catch return 0;
        if (bit != 0) break;
        leading_zeros += 1;
    }

    if (leading_zeros == 0) return 0;
    if (leading_zeros >= 32) return 0;

    const suffix = reader.readBits(@intCast(leading_zeros)) catch return 0;
    return (@as(u32, 1) << @intCast(leading_zeros)) - 1 + suffix;
}

// ============================================================================
// Tests
// ============================================================================

test "NalUnitHeader parse" {
    const data = [_]u8{ 0x00, 0x79 }; // SPS NAL unit
    const header = try NalUnitHeader.parse(&data);

    try std.testing.expect(!header.forbidden_zero_bit);
    try std.testing.expectEqual(@as(u6, 0), header.nuh_layer_id);
    try std.testing.expectEqual(NalUnitType.sps_nut, header.nal_unit_type);
}

test "NalUnitType methods" {
    try std.testing.expect(NalUnitType.trail_nut.isVcl());
    try std.testing.expect(!NalUnitType.sps_nut.isVcl());
    try std.testing.expect(NalUnitType.idr_w_radl.isIdr());
    try std.testing.expect(NalUnitType.cra_nut.isIrap());
    try std.testing.expect(NalUnitType.sps_nut.isParameterSet());
}

test "Profile and Level" {
    try std.testing.expectEqualStrings("Main 10", Profile.main_10.toString());
    try std.testing.expectEqualStrings("4.0", Level.level_4_0.toString());
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), Level.level_4_0.toFloat(), 0.01);
}

test "VvcCRecord init" {
    const allocator = std.testing.allocator;
    var record = VvcCRecord.init(allocator);
    defer record.deinit();

    try std.testing.expectEqual(@as(u8, 4), record.lengthSize());
    try std.testing.expectEqual(@as(u8, 10), record.bitDepth());
}
