// Home Video Library - HEVC/H.265 Codec
// ITU-T H.265 / ISO/IEC 23008-2 (MPEG-H Part 2)

const std = @import("std");
const types = @import("../../core/types.zig");
const frame = @import("../../core/frame.zig");
const err = @import("../../core/error.zig");
const bitstream = @import("../../util/bitstream.zig");

pub const VideoError = err.VideoError;
pub const VideoFrame = frame.VideoFrame;
pub const PixelFormat = types.PixelFormat;
pub const BitstreamReader = bitstream.BitstreamReader;

// ============================================================================
// HEVC Constants
// ============================================================================

/// NAL Unit Types for HEVC
pub const NalUnitType = enum(u6) {
    trail_n = 0, // Trailing picture, non-reference
    trail_r = 1, // Trailing picture, reference
    tsa_n = 2, // Temporal sub-layer access, non-reference
    tsa_r = 3, // Temporal sub-layer access, reference
    stsa_n = 4, // Step-wise temporal sub-layer access, non-reference
    stsa_r = 5, // Step-wise temporal sub-layer access, reference
    radl_n = 6, // Random access decodable leading, non-reference
    radl_r = 7, // Random access decodable leading, reference
    rasl_n = 8, // Random access skipped leading, non-reference
    rasl_r = 9, // Random access skipped leading, reference
    rsv_vcl_n10 = 10,
    rsv_vcl_r11 = 11,
    rsv_vcl_n12 = 12,
    rsv_vcl_r13 = 13,
    rsv_vcl_n14 = 14,
    rsv_vcl_r15 = 15,
    bla_w_lp = 16, // Broken link access with leading pictures
    bla_w_radl = 17,
    bla_n_lp = 18, // Broken link access without leading pictures
    idr_w_radl = 19, // IDR with RADL
    idr_n_lp = 20, // IDR without leading pictures
    cra = 21, // Clean random access
    rsv_irap_vcl22 = 22,
    rsv_irap_vcl23 = 23,
    rsv_vcl24 = 24,
    rsv_vcl25 = 25,
    rsv_vcl26 = 26,
    rsv_vcl27 = 27,
    rsv_vcl28 = 28,
    rsv_vcl29 = 29,
    rsv_vcl30 = 30,
    rsv_vcl31 = 31,
    vps = 32, // Video parameter set
    sps = 33, // Sequence parameter set
    pps = 34, // Picture parameter set
    access_unit_delimiter = 35,
    eos = 36, // End of sequence
    eob = 37, // End of bitstream
    filler_data = 38,
    prefix_sei = 39, // Prefix SEI
    suffix_sei = 40, // Suffix SEI
    rsv_nvcl41 = 41,
    rsv_nvcl42 = 42,
    rsv_nvcl43 = 43,
    rsv_nvcl44 = 44,
    rsv_nvcl45 = 45,
    rsv_nvcl46 = 46,
    rsv_nvcl47 = 47,
    unspec48 = 48,
    unspec49 = 49,
    unspec50 = 50,
    unspec51 = 51,
    unspec52 = 52,
    unspec53 = 53,
    unspec54 = 54,
    unspec55 = 55,
    unspec56 = 56,
    unspec57 = 57,
    unspec58 = 58,
    unspec59 = 59,
    unspec60 = 60,
    unspec61 = 61,
    unspec62 = 62,
    unspec63 = 63,

    pub fn isVcl(self: NalUnitType) bool {
        const val = @intFromEnum(self);
        return val <= 31;
    }

    pub fn isIdr(self: NalUnitType) bool {
        return self == .idr_w_radl or self == .idr_n_lp;
    }

    pub fn isIrap(self: NalUnitType) bool {
        const val = @intFromEnum(self);
        return val >= 16 and val <= 23;
    }

    pub fn isKeyframe(self: NalUnitType) bool {
        return self.isIrap();
    }

    pub fn isReference(self: NalUnitType) bool {
        const val = @intFromEnum(self);
        // Odd numbers in VCL range are reference pictures
        return val <= 31 and (val % 2 == 1);
    }
};

/// Profile IDC values
pub const Profile = enum(u8) {
    main = 1,
    main_10 = 2,
    main_still_picture = 3,
    rext = 4, // Range extension
    high_throughput = 5,
    multiview_main = 6,
    scalable_main = 7,
    three_d_main = 8,
    screen_content_coding = 9,
    scalable_rext = 10,
    high_throughput_screen_content_coding = 11,

    _,
};

/// Tier
pub const Tier = enum(u1) {
    main = 0,
    high = 1,
};

// ============================================================================
// NAL Unit Header (2 bytes for HEVC)
// ============================================================================

pub const NalUnitHeader = struct {
    forbidden_zero_bit: u1,
    nal_unit_type: NalUnitType,
    nuh_layer_id: u6,
    nuh_temporal_id_plus1: u3,

    const Self = @This();

    pub fn parse(data: []const u8) !Self {
        if (data.len < 2) return VideoError.TruncatedData;

        const byte0 = data[0];
        const byte1 = data[1];

        return Self{
            .forbidden_zero_bit = @intCast((byte0 >> 7) & 0x01),
            .nal_unit_type = @enumFromInt(@as(u6, @truncate((byte0 >> 1) & 0x3F))),
            .nuh_layer_id = @intCast(((byte0 & 0x01) << 5) | ((byte1 >> 3) & 0x1F)),
            .nuh_temporal_id_plus1 = @intCast(byte1 & 0x07),
        };
    }

    pub fn toBytes(self: *const Self) [2]u8 {
        return .{
            (@as(u8, self.forbidden_zero_bit) << 7) |
                (@as(u8, @intFromEnum(self.nal_unit_type)) << 1) |
                @as(u8, self.nuh_layer_id >> 5),
            (@as(u8, self.nuh_layer_id & 0x1F) << 3) |
                @as(u8, self.nuh_temporal_id_plus1),
        };
    }

    pub fn temporalId(self: *const Self) u3 {
        return if (self.nuh_temporal_id_plus1 > 0) self.nuh_temporal_id_plus1 - 1 else 0;
    }
};

// ============================================================================
// Profile Tier Level
// ============================================================================

pub const ProfileTierLevel = struct {
    general_profile_space: u2,
    general_tier_flag: Tier,
    general_profile_idc: u5,
    general_profile_compatibility_flags: u32,
    general_progressive_source_flag: bool,
    general_interlaced_source_flag: bool,
    general_non_packed_constraint_flag: bool,
    general_frame_only_constraint_flag: bool,
    general_level_idc: u8,

    const Self = @This();

    pub fn parse(reader: *BitstreamReader, profile_present: bool, max_sub_layers: u8) !Self {
        var ptl = Self{
            .general_profile_space = 0,
            .general_tier_flag = .main,
            .general_profile_idc = 0,
            .general_profile_compatibility_flags = 0,
            .general_progressive_source_flag = false,
            .general_interlaced_source_flag = false,
            .general_non_packed_constraint_flag = false,
            .general_frame_only_constraint_flag = false,
            .general_level_idc = 0,
        };

        if (profile_present) {
            ptl.general_profile_space = @intCast(try reader.readBits(2));
            ptl.general_tier_flag = @enumFromInt(try reader.readBit());
            ptl.general_profile_idc = @intCast(try reader.readBits(5));
            ptl.general_profile_compatibility_flags = try reader.readBits(32);
            ptl.general_progressive_source_flag = try reader.readBit() == 1;
            ptl.general_interlaced_source_flag = try reader.readBit() == 1;
            ptl.general_non_packed_constraint_flag = try reader.readBit() == 1;
            ptl.general_frame_only_constraint_flag = try reader.readBit() == 1;

            // Skip 44 reserved bits
            _ = try reader.readBits(32);
            _ = try reader.readBits(12);
        }

        ptl.general_level_idc = @intCast(try reader.readBits(8));

        // Skip sub-layer info
        if (max_sub_layers > 1) {
            var i: u8 = 0;
            while (i < max_sub_layers - 1) : (i += 1) {
                _ = try reader.readBit(); // sub_layer_profile_present_flag
                _ = try reader.readBit(); // sub_layer_level_present_flag
            }
            if (max_sub_layers - 1 < 8) {
                const padding = (8 - (max_sub_layers - 1)) * 2;
                _ = try reader.readBits(@intCast(padding));
            }
        }

        return ptl;
    }

    /// Get level as a float (e.g., 5.1 = 153 / 30)
    pub fn level(self: *const Self) f32 {
        return @as(f32, @floatFromInt(self.general_level_idc)) / 30.0;
    }

    /// Get profile name
    pub fn profileName(self: *const Self) []const u8 {
        return switch (self.general_profile_idc) {
            1 => "Main",
            2 => "Main 10",
            3 => "Main Still Picture",
            4 => "Range Extensions",
            5 => "High Throughput",
            else => "Unknown",
        };
    }
};

// ============================================================================
// Video Parameter Set (VPS)
// ============================================================================

pub const Vps = struct {
    vps_video_parameter_set_id: u4,
    vps_base_layer_internal_flag: bool,
    vps_base_layer_available_flag: bool,
    vps_max_layers: u6,
    vps_max_sub_layers: u3,
    vps_temporal_id_nesting_flag: bool,
    profile_tier_level: ProfileTierLevel,

    const Self = @This();

    pub fn parse(data: []const u8) !Self {
        var reader = BitstreamReader.init(data);

        var vps = Self{
            .vps_video_parameter_set_id = @intCast(try reader.readBits(4)),
            .vps_base_layer_internal_flag = try reader.readBit() == 1,
            .vps_base_layer_available_flag = try reader.readBit() == 1,
            .vps_max_layers = @intCast(try reader.readBits(6) + 1),
            .vps_max_sub_layers = @intCast(try reader.readBits(3) + 1),
            .vps_temporal_id_nesting_flag = try reader.readBit() == 1,
            .profile_tier_level = undefined,
        };

        // Reserved 16 bits (0xFFFF)
        _ = try reader.readBits(16);

        vps.profile_tier_level = try ProfileTierLevel.parse(&reader, true, vps.vps_max_sub_layers);

        return vps;
    }
};

// ============================================================================
// Sequence Parameter Set (SPS)
// ============================================================================

pub const Sps = struct {
    sps_video_parameter_set_id: u4,
    sps_max_sub_layers: u3,
    sps_temporal_id_nesting_flag: bool,
    profile_tier_level: ProfileTierLevel,
    sps_seq_parameter_set_id: u8,
    chroma_format_idc: u8,
    separate_colour_plane_flag: bool,
    pic_width_in_luma_samples: u32,
    pic_height_in_luma_samples: u32,
    conformance_window_flag: bool,
    conf_win_left_offset: u32,
    conf_win_right_offset: u32,
    conf_win_top_offset: u32,
    conf_win_bottom_offset: u32,
    bit_depth_luma: u8,
    bit_depth_chroma: u8,
    log2_max_pic_order_cnt_lsb: u8,

    const Self = @This();

    pub fn parse(data: []const u8) !Self {
        var reader = BitstreamReader.init(data);

        var sps = Self{
            .sps_video_parameter_set_id = @intCast(try reader.readBits(4)),
            .sps_max_sub_layers = @intCast(try reader.readBits(3) + 1),
            .sps_temporal_id_nesting_flag = try reader.readBit() == 1,
            .profile_tier_level = undefined,
            .sps_seq_parameter_set_id = 0,
            .chroma_format_idc = 1,
            .separate_colour_plane_flag = false,
            .pic_width_in_luma_samples = 0,
            .pic_height_in_luma_samples = 0,
            .conformance_window_flag = false,
            .conf_win_left_offset = 0,
            .conf_win_right_offset = 0,
            .conf_win_top_offset = 0,
            .conf_win_bottom_offset = 0,
            .bit_depth_luma = 8,
            .bit_depth_chroma = 8,
            .log2_max_pic_order_cnt_lsb = 0,
        };

        sps.profile_tier_level = try ProfileTierLevel.parse(&reader, true, sps.sps_max_sub_layers);

        sps.sps_seq_parameter_set_id = @intCast(try reader.readUE());
        sps.chroma_format_idc = @intCast(try reader.readUE());

        if (sps.chroma_format_idc == 3) {
            sps.separate_colour_plane_flag = try reader.readBit() == 1;
        }

        sps.pic_width_in_luma_samples = try reader.readUE();
        sps.pic_height_in_luma_samples = try reader.readUE();

        sps.conformance_window_flag = try reader.readBit() == 1;
        if (sps.conformance_window_flag) {
            sps.conf_win_left_offset = try reader.readUE();
            sps.conf_win_right_offset = try reader.readUE();
            sps.conf_win_top_offset = try reader.readUE();
            sps.conf_win_bottom_offset = try reader.readUE();
        }

        sps.bit_depth_luma = @intCast(try reader.readUE() + 8);
        sps.bit_depth_chroma = @intCast(try reader.readUE() + 8);
        sps.log2_max_pic_order_cnt_lsb = @intCast(try reader.readUE() + 4);

        return sps;
    }

    /// Get display width
    pub fn width(self: *const Self) u32 {
        const sub_width_c: u32 = if (self.chroma_format_idc == 1 or self.chroma_format_idc == 2) 2 else 1;
        return self.pic_width_in_luma_samples -
            (self.conf_win_left_offset + self.conf_win_right_offset) * sub_width_c;
    }

    /// Get display height
    pub fn height(self: *const Self) u32 {
        const sub_height_c: u32 = if (self.chroma_format_idc == 1) 2 else 1;
        return self.pic_height_in_luma_samples -
            (self.conf_win_top_offset + self.conf_win_bottom_offset) * sub_height_c;
    }

    /// Get pixel format
    pub fn pixelFormat(self: *const Self) PixelFormat {
        if (self.bit_depth_luma > 8 or self.bit_depth_chroma > 8) {
            return switch (self.chroma_format_idc) {
                0 => .gray16,
                1 => .yuv420p10le,
                2 => .yuv422p10le,
                3 => .yuv444p10le,
                else => .yuv420p,
            };
        }
        return switch (self.chroma_format_idc) {
            0 => .gray8,
            1 => .yuv420p,
            2 => .yuv422p,
            3 => .yuv444p,
            else => .yuv420p,
        };
    }
};

// ============================================================================
// Picture Parameter Set (PPS)
// ============================================================================

pub const Pps = struct {
    pps_pic_parameter_set_id: u8,
    pps_seq_parameter_set_id: u8,
    dependent_slice_segments_enabled_flag: bool,
    output_flag_present_flag: bool,
    num_extra_slice_header_bits: u3,
    sign_data_hiding_enabled_flag: bool,
    cabac_init_present_flag: bool,
    num_ref_idx_l0_default_active: u8,
    num_ref_idx_l1_default_active: u8,
    init_qp: i8,
    constrained_intra_pred_flag: bool,
    transform_skip_enabled_flag: bool,
    cu_qp_delta_enabled_flag: bool,

    const Self = @This();

    pub fn parse(data: []const u8) !Self {
        var reader = BitstreamReader.init(data);

        var pps = Self{
            .pps_pic_parameter_set_id = @intCast(try reader.readUE()),
            .pps_seq_parameter_set_id = @intCast(try reader.readUE()),
            .dependent_slice_segments_enabled_flag = try reader.readBit() == 1,
            .output_flag_present_flag = try reader.readBit() == 1,
            .num_extra_slice_header_bits = @intCast(try reader.readBits(3)),
            .sign_data_hiding_enabled_flag = try reader.readBit() == 1,
            .cabac_init_present_flag = try reader.readBit() == 1,
            .num_ref_idx_l0_default_active = 0,
            .num_ref_idx_l1_default_active = 0,
            .init_qp = 0,
            .constrained_intra_pred_flag = false,
            .transform_skip_enabled_flag = false,
            .cu_qp_delta_enabled_flag = false,
        };

        pps.num_ref_idx_l0_default_active = @intCast(try reader.readUE() + 1);
        pps.num_ref_idx_l1_default_active = @intCast(try reader.readUE() + 1);
        pps.init_qp = @intCast(try reader.readSE() + 26);
        pps.constrained_intra_pred_flag = try reader.readBit() == 1;
        pps.transform_skip_enabled_flag = try reader.readBit() == 1;
        pps.cu_qp_delta_enabled_flag = try reader.readBit() == 1;

        return pps;
    }
};

// ============================================================================
// HEVC Decoder Configuration Record (from hvcC box)
// ============================================================================

pub const HvccRecord = struct {
    configuration_version: u8,
    general_profile_space: u2,
    general_tier_flag: bool,
    general_profile_idc: u5,
    general_profile_compatibility_flags: u32,
    general_constraint_indicator_flags: u48,
    general_level_idc: u8,
    min_spatial_segmentation_idc: u12,
    parallelism_type: u2,
    chroma_format_idc: u2,
    bit_depth_luma: u3,
    bit_depth_chroma: u3,
    avg_frame_rate: u16,
    constant_frame_rate: u2,
    num_temporal_layers: u3,
    temporal_id_nested: bool,
    length_size_minus_one: u2,

    nal_arrays: std.ArrayList(NalArray),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub const NalArray = struct {
        array_completeness: bool,
        nal_unit_type: NalUnitType,
        nal_units: std.ArrayList([]const u8),
    };

    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !Self {
        if (data.len < 23) return VideoError.TruncatedData;

        var config = Self{
            .configuration_version = data[0],
            .general_profile_space = @intCast((data[1] >> 6) & 0x03),
            .general_tier_flag = ((data[1] >> 5) & 0x01) == 1,
            .general_profile_idc = @intCast(data[1] & 0x1F),
            .general_profile_compatibility_flags = std.mem.readInt(u32, data[2..6], .big),
            .general_constraint_indicator_flags = @as(u48, std.mem.readInt(u32, data[6..10], .big)) << 16 |
                std.mem.readInt(u16, data[10..12], .big),
            .general_level_idc = data[12],
            .min_spatial_segmentation_idc = @intCast(std.mem.readInt(u16, data[13..15], .big) & 0x0FFF),
            .parallelism_type = @intCast(data[15] & 0x03),
            .chroma_format_idc = @intCast(data[16] & 0x03),
            .bit_depth_luma = @intCast((data[17] & 0x07) + 8),
            .bit_depth_chroma = @intCast((data[18] & 0x07) + 8),
            .avg_frame_rate = std.mem.readInt(u16, data[19..21], .big),
            .constant_frame_rate = @intCast((data[21] >> 6) & 0x03),
            .num_temporal_layers = @intCast((data[21] >> 3) & 0x07),
            .temporal_id_nested = ((data[21] >> 2) & 0x01) == 1,
            .length_size_minus_one = @intCast(data[21] & 0x03),
            .nal_arrays = .empty,
            .allocator = allocator,
        };

        const num_arrays = data[22];
        var offset: usize = 23;

        var i: u8 = 0;
        while (i < num_arrays) : (i += 1) {
            if (offset + 3 > data.len) break;

            var array = NalArray{
                .array_completeness = ((data[offset] >> 7) & 0x01) == 1,
                .nal_unit_type = @enumFromInt(@as(u6, @truncate(data[offset] & 0x3F))),
                .nal_units = .empty,
            };
            offset += 1;

            const num_nalus = std.mem.readInt(u16, data[offset..][0..2], .big);
            offset += 2;

            var j: u16 = 0;
            while (j < num_nalus) : (j += 1) {
                if (offset + 2 > data.len) break;
                const nalu_len = std.mem.readInt(u16, data[offset..][0..2], .big);
                offset += 2;
                if (offset + nalu_len > data.len) break;

                const nalu_data = try allocator.dupe(u8, data[offset .. offset + nalu_len]);
                try array.nal_units.append(allocator, nalu_data);
                offset += nalu_len;
            }

            try config.nal_arrays.append(allocator, array);
        }

        return config;
    }

    pub fn deinit(self: *Self) void {
        for (self.nal_arrays.items) |*array| {
            for (array.nal_units.items) |nalu| {
                self.allocator.free(nalu);
            }
            array.nal_units.deinit(self.allocator);
        }
        self.nal_arrays.deinit(self.allocator);
    }

    /// Get NAL unit length field size
    pub fn nalLengthSize(self: *const Self) u8 {
        return @as(u8, self.length_size_minus_one) + 1;
    }

    /// Find VPS
    pub fn getVps(self: *const Self) ?[]const u8 {
        for (self.nal_arrays.items) |array| {
            if (array.nal_unit_type == .vps and array.nal_units.items.len > 0) {
                return array.nal_units.items[0];
            }
        }
        return null;
    }

    /// Find SPS
    pub fn getSpsData(self: *const Self) ?[]const u8 {
        for (self.nal_arrays.items) |array| {
            if (array.nal_unit_type == .sps and array.nal_units.items.len > 0) {
                return array.nal_units.items[0];
            }
        }
        return null;
    }

    /// Find PPS
    pub fn getPpsData(self: *const Self) ?[]const u8 {
        for (self.nal_arrays.items) |array| {
            if (array.nal_unit_type == .pps and array.nal_units.items.len > 0) {
                return array.nal_units.items[0];
            }
        }
        return null;
    }
};

// ============================================================================
// HEVC NAL Unit Iterator
// ============================================================================

pub const HevcNalIterator = struct {
    data: []const u8,
    offset: usize,

    const Self = @This();

    pub fn init(data: []const u8) Self {
        return Self{
            .data = data,
            .offset = 0,
        };
    }

    pub fn next(self: *Self) ?struct { header: NalUnitHeader, data: []const u8 } {
        // Find start code
        while (self.offset + 5 < self.data.len) {
            if (self.data[self.offset] == 0 and
                self.data[self.offset + 1] == 0)
            {
                const start_code_len: usize = if (self.data[self.offset + 2] == 1)
                    3
                else if (self.data[self.offset + 2] == 0 and self.data[self.offset + 3] == 1)
                    4
                else {
                    self.offset += 1;
                    continue;
                };

                const nal_start = self.offset + start_code_len;
                if (nal_start + 2 >= self.data.len) return null;

                // Find next start code or end
                var nal_end = nal_start + 2;
                while (nal_end + 3 < self.data.len) {
                    if (self.data[nal_end] == 0 and
                        self.data[nal_end + 1] == 0 and
                        (self.data[nal_end + 2] == 1 or
                        (self.data[nal_end + 2] == 0 and self.data[nal_end + 3] == 1)))
                    {
                        break;
                    }
                    nal_end += 1;
                }
                if (nal_end + 3 >= self.data.len) {
                    nal_end = self.data.len;
                }

                const header = NalUnitHeader.parse(self.data[nal_start..]) catch {
                    self.offset = nal_end;
                    continue;
                };
                self.offset = nal_end;

                return .{
                    .header = header,
                    .data = self.data[nal_start..nal_end],
                };
            }
            self.offset += 1;
        }

        return null;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "NalUnitType" {
    try std.testing.expect(NalUnitType.idr_n_lp.isIdr());
    try std.testing.expect(NalUnitType.idr_w_radl.isIdr());
    try std.testing.expect(!NalUnitType.trail_r.isIdr());

    try std.testing.expect(NalUnitType.cra.isIrap());
    try std.testing.expect(NalUnitType.idr_n_lp.isIrap());
    try std.testing.expect(!NalUnitType.trail_n.isIrap());

    try std.testing.expect(NalUnitType.trail_r.isVcl());
    try std.testing.expect(!NalUnitType.vps.isVcl());
    try std.testing.expect(!NalUnitType.sps.isVcl());
}

test "NalUnitHeader parse" {
    // VPS NAL unit: forbidden_bit=0, type=32, layer_id=0, temporal_id=1
    const header = try NalUnitHeader.parse(&[_]u8{ 0x40, 0x01 });
    try std.testing.expectEqual(NalUnitType.vps, header.nal_unit_type);
    try std.testing.expectEqual(@as(u6, 0), header.nuh_layer_id);
    try std.testing.expectEqual(@as(u3, 1), header.nuh_temporal_id_plus1);
}

test "NalUnitHeader roundtrip" {
    const original = [_]u8{ 0x42, 0x01 }; // SPS
    const header = try NalUnitHeader.parse(&original);
    const serialized = header.toBytes();
    try std.testing.expectEqualSlices(u8, &original, &serialized);
}
